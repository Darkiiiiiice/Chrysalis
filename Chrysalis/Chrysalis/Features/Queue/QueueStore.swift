import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import os

/// 队列状态与任务编排（MainActor；设计文档 §5 状态流）。
@MainActor
@Observable
final class QueueStore {
    // MARK: - 横幅

    struct Banner: Identifiable, Equatable, Sendable {
        enum Kind: Sendable {
            case info
            case warning
            case error
        }

        let id = UUID()
        var kind: Kind
        var message: String
    }

    // MARK: - 对外状态

    private(set) var jobs: [TranscodeJob] = []
    private(set) var capabilities: HardwareCapabilities?
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var banner: Banner?
    private(set) var isRunningBatch = false
    private(set) var outputDirectory: URL?
    /// 添加 Sheet 待入队的文件（设计文档 §8.6 添加文件）。
    private(set) var pendingAddURLs: [URL] = []

    /// 电影元数据服务（TMDB；设计文档 §7.5）。
    let metadataService = MovieMetadataService()
    /// 匹配候选（仅内存，不持久化）。
    private(set) var movieCandidates: [UUID: [MovieCandidate]] = [:]
    /// 元数据确认 Sheet 的呈现上下文。
    var confirmMovieContext: ConfirmMovieContext?
    /// TMDB 凭据是否已配置（设置页与确认 Sheet 展示）。
    private(set) var isTMDBConfigured = false
    /// TMDB 网络代理设置（设计文档 §7.5；改动即时持久化并生效）。
    var proxySettings = ProxySettingsStore.load() {
        didSet { ProxySettingsStore.save(proxySettings) }
    }

    /// 预设仓库（内置 + 自定义；设计文档 §6.6 / §9）。
    let presets = PresetStore()

    var selectedJobID: UUID?
    var isInspectorPresented = false
    var isAddFilesPresented = false
    /// 轻量添加 Sheet 的呈现状态。
    var isAddSheetPresented = false
    var isChooseOutputPresented = false
    var isDropTargeted = false
    var sidebarSelection: SidebarItem = .queue

    // MARK: - 私有状态

    private var engines: [UUID: TranscodeEngine] = [:]
    private var runnerTask: Task<Void, Never>?
    private var isStopRequested = false
    private var bannerDismissTask: Task<Void, Never>?
    /// 已选择输出目录的沙盒作用域持有（选择器返回的 URL 需要显式开始访问）。
    private var heldOutputScopeURL: URL?
    /// 输出目录的 App Scope 安全书签（重启恢复，设计文档 §9）。
    private var outputDirectoryBookmarkData: Data?

    // MARK: - 生命周期

    /// 启动时：探测硬件能力（设计文档 §7）→ 恢复上次队列（设计文档 §9）。
    func bootstrap() async {
        if capabilities == nil {
            let probe = await Task.detached(priority: .userInitiated) {
                VideoToolboxCapabilities.probe()
            }.value
            capabilities = probe
            Log.app.info("硬件能力：\(probe.summaryText, privacy: .public)")
        }
        // 载入 TMDB 凭据（设计文档 §7.5：Keychain；不写日志）
        let storedCredential = KeychainStore.readTMDB()
        isTMDBConfigured = storedCredential != nil
        await metadataService.setCredential(storedCredential.map(TMDBCredential.detect))
        restoreQueue()
    }

    // MARK: - 添加文件

    /// 拖放 / 文件选择入口（设计文档 §8.6）：过滤容器与重复项后，打开轻量添加 Sheet。
    func prepareAdd(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var ignoredCount = 0
        var duplicateCount = 0
        var accepted: [URL] = []

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard MediaInspector.supportedExtensions.contains(ext) else {
                ignoredCount += 1
                continue
            }
            let path = url.path(percentEncoded: false)
            if jobs.contains(where: { $0.inputURL.path(percentEncoded: false) == path && !$0.state.isTerminal })
                || pendingAddURLs.contains(where: { $0.path(percentEncoded: false) == path }) {
                duplicateCount += 1
                continue
            }
            accepted.append(url)
        }

        if ignoredCount > 0 {
            showBanner(kind: .info, message: "已忽略 \(ignoredCount) 个不支持的文件（v1 仅支持 MP4 / MOV / M4V）。")
        } else if duplicateCount > 0 {
            showBanner(kind: .info, message: "\(duplicateCount) 个文件已在队列中，已跳过重复项。")
        }

        guard !accepted.isEmpty else { return }
        pendingAddURLs = accepted
        isAddSheetPresented = true
    }

    /// 添加 Sheet 确认：按所选预设入队并异步预检；「这些是电影」时启动元数据匹配。
    func confirmAdd(presetID: String, markAsMovies: Bool) {
        let preset = presets.preset(id: presetID) ?? presets.selectedPreset
        presets.select(id: preset.id)
        enqueue(pendingAddURLs, preset: preset, markAsMovies: markAsMovies)
        pendingAddURLs = []
    }

    func cancelAdd() {
        pendingAddURLs = []
    }

    private func enqueue(_ urls: [URL], preset: TranscodePreset, markAsMovies: Bool = false) {
        var addedIDs: [UUID] = []
        for url in urls {
            var job = TranscodeJob(inputURL: url, preset: preset)
            job.inputBookmark = BookmarkStore.makeBookmark(for: url)
            if markAsMovies {
                job.mediaKind = .movie
            }
            jobs.append(job)
            addedIDs.append(job.id)
            inspect(jobID: job.id)
        }
        saveQueue()

        if markAsMovies {
            for id in addedIDs {
                startMatching(jobID: id)
            }
            if isRunningBatch {
                showBanner(kind: .warning, message: "电影任务需确认元数据后才能开始；其余任务不受影响。")
            }
        }
    }

    private func inspect(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let url = job.inputURL

        Task { [weak self] in
            // 面板/拖放来源通常已授权；书签场景在此生效（返回 false 时无需处理）
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let result: Result<MediaInfo, Error>
            do {
                result = .success(try await MediaInspector.inspect(url: url))
            } catch {
                result = .failure(error)
            }
            self?.applyInspection(jobID: jobID, result: result)
        }
    }

    private func applyInspection(jobID: UUID, result: Result<MediaInfo, Error>) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let name = jobs[index].displayName

        switch result {
        case .success(let info):
            jobs[index].mediaInfo = info
            if let reason = MediaInspector.blockingReason(for: info) {
                jobs[index].state = .failed(reason)
                jobs[index].errorText = reason
                showBanner(kind: .error, message: "\(name)：\(reason)")
            }
            loadThumbnail(for: jobID)

        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            jobs[index].state = .failed(message)
            jobs[index].errorText = message
            showBanner(kind: .error, message: "\(name)：\(message)")
        }
        saveQueue()
    }

    private func loadThumbnail(for jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), let info = job.mediaInfo else { return }
        let url = job.inputURL
        let duration = info.durationSeconds

        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let payload = await ThumbnailGenerator.generate(for: url, durationSeconds: duration) else { return }
            self?.thumbnails[jobID] = payload.image
        }
    }

    // MARK: - 输出目录

    func setOutputDirectory(_ url: URL) {
        // 文件夹选择器返回的 URL 是安全作用域：必须持有访问权才能写入（用户选择即授权）。
        let previousHeld = heldOutputScopeURL
        let scoped = url.startAccessingSecurityScopedResource()

        // 可写性预检：尽早暴露沙盒/权限问题，而不是等任务跑到一半才失败。
        guard isWritableDirectory(url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            showBanner(
                kind: .error,
                message: "无法写入「\(url.lastPathComponent)」：请换一个位置（沙盒只允许写入用户显式选择的目录）。"
            )
            return
        }

        // 预检通过才真正切换；旧目录作用域此时释放
        previousHeld?.stopAccessingSecurityScopedResource()
        heldOutputScopeURL = scoped ? url : nil
        outputDirectoryBookmarkData = BookmarkStore.makeBookmark(for: url)
        outputDirectory = url

        // 切换目录时清理残留临时文件（设计文档 §6.4）
        let removed = OutputPlanner.cleanupOrphanTemps(in: url)
        if !removed.isEmpty {
            Log.engine.info("清理残留临时文件 \(removed.count) 个")
        }
        saveQueue()
    }

    /// 真实写入探针：创建并删除一个临时文件，验证目录可写。
    private func isWritableDirectory(_ directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".chrysalis-write-test.tmp")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    func openOutputFolderInFinder() {
        guard let outputDirectory else { return }
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var outputDirectoryDisplayPath: String? {
        outputDirectory.map(Fmt.abbreviatedPath)
    }

    // MARK: - 开始 / 取消

    var canStart: Bool {
        !isRunningBatch && jobs.contains { $0.state == .queued }
    }

    var runningCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    var completedCount: Int {
        jobs.filter { $0.state == .completed }.count
    }

    /// 批量进度（运行中任务的平均 fraction；无运行任务时为 nil）。
    var aggregateProgress: Double? {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0.0) { $0 + ($1.progress?.fraction ?? 0) }
        return total / Double(active.count)
    }

    var selectedJob: TranscodeJob? {
        jobs.first { $0.id == selectedJobID }
    }

    func startAll() {
        guard !isRunningBatch else { return }
        guard outputDirectory != nil else {
            showBanner(kind: .warning, message: "请先选择输出文件夹，再开始转码。")
            isChooseOutputPresented = true
            return
        }

        // 未确认的电影任务拦截「开始全部」，并跳到第一个待确认任务（设计文档 §7.5）
        let unconfirmed = Self.unconfirmedMovieJobs(in: jobs)
        if let first = unconfirmed.first {
            showBanner(
                kind: .warning,
                message: "还有 \(unconfirmed.count) 个电影任务未确认元数据：确认后再开始。"
            )
            openInspector(for: first.id)
            confirmMovieContext = ConfirmMovieContext(id: first.id)
            return
        }

        guard jobs.contains(where: { $0.state == .queued }) else { return }

        isStopRequested = false
        isRunningBatch = true
        runnerTask = Task { [weak self] in
            await self?.runQueue()
        }
    }

    /// 串行执行队列（设计文档 §5：TranscodeEngine 串行；单任务默认）。
    private func runQueue() async {
        defer {
            isRunningBatch = false
            runnerTask = nil
        }
        while !isStopRequested {
            // 未确认元数据的电影任务在队列中等待确认，不参与本轮批量（设计文档 §7.5）
            guard let next = jobs.first(where: {
                $0.state == .queued && $0.mediaInfo != nil && !$0.needsMetadataConfirmation
            }) else { break }
            await runJob(id: next.id)
        }
    }

    private func runJob(id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs[index]
        guard let mediaInfo = job.mediaInfo, let video = mediaInfo.video, let outputDirectory else { return }

        updateState(id: id, state: .preparing)

        // 硬件编码器检查（设计文档 §7：找不到则在 preparing 阶段失败）
        guard let encoder = capabilities?.hardwareEncoder(for: job.preset.videoCodec) else {
            let message = TranscodeEngineError
                .hardwareEncoderUnavailable(job.preset.videoCodec.displayName)
                .errorDescription ?? "硬件编码器不可用"
            fail(id: id, message: message)
            return
        }

        // 输出路径：重名加 -1（设计文档 §6.4 / §9）
        let baseName = job.inputURL.deletingPathExtension().lastPathComponent
        let outputURL = OutputPlanner.uniqueOutputURL(
            directory: outputDirectory,
            baseName: baseName,
            fileExtension: job.preset.container.fileExtension
        )
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].outputURL = outputURL
        }

        // 电影元数据与海报（设计文档 §7.5）：海报只读本地缓存，失败不阻塞
        var posterData: Data?
        if let posterPath = job.movieMetadata?.posterPath {
            posterData = await metadataService.posterData(path: posterPath)
        }

        // P3.5：码率按目标分辨率（短边匹配、只缩不放）缩放
        let targetSize = job.preset.resolution.renderSize(
            sourceWidth: video.displayWidth,
            sourceHeight: video.displayHeight
        ) ?? CGSize(width: video.displayWidth, height: video.displayHeight)

        let request = TranscodeRequest(
            inputURL: job.inputURL,
            outputURL: outputURL,
            videoCodec: job.preset.videoCodec,
            container: job.preset.container,
            resolution: job.preset.resolution,
            frameRate: job.preset.frameRate,
            averageBitrate: job.preset.videoCodec.isProRes
                ? nil
                : job.preset.averageBitrate(
                    videoWidth: Int(targetSize.width),
                    videoHeight: Int(targetSize.height)
                ),
            audioBitrate: job.preset.audio.bitrate,
            audioMaxChannels: job.preset.audio.maxChannels,
            audioSampleRate: job.preset.audio.sampleRateOverride,
            requireHardware: true,
            encoderID: encoder.encoderID,
            metadata: job.movieMetadata,
            posterData: posterData
        )

        let engine = TranscodeEngine()
        engines[id] = engine
        updateState(id: id, state: .running)

        let scoped = job.inputURL.startAccessingSecurityScopedResource()
        defer { if scoped { job.inputURL.stopAccessingSecurityScopedResource() } }

        do {
            let outcome = try await engine.run(request) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress(progress, to: id)
                }
            }
            engines[id] = nil
            applyOutcome(outcome, to: id)
        } catch {
            engines[id] = nil
            if let engineError = error as? TranscodeEngineError, engineError == .cancelled {
                updateState(id: id, state: .cancelled)
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                fail(id: id, message: message)
            }
        }
    }

    func cancelJob(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            jobs[index].state = .cancelled
        case .preparing, .running, .finishing:
            jobs[index].state = .cancelling
            engines[id]?.cancel()
        default:
            return
        }
        saveQueue()
    }

    /// 取消全部：停止批处理并取消当前任务；排队中的任务保留（再次「开始」继续）。
    func cancelAll() {
        isStopRequested = true
        for index in jobs.indices where jobs[index].state.isActive {
            jobs[index].state = .cancelling
            engines[jobs[index].id]?.cancel()
        }
        saveQueue()
    }

    /// 重试：失败 / 取消 / 中断的任务回到排队（保留预设与媒体信息）。
    func retryJob(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isRetryable else { return }
        jobs[index].state = .queued
        jobs[index].progress = nil
        jobs[index].errorText = nil
        jobs[index].outputURL = nil
        jobs[index].outputBytes = nil
        jobs[index].verificationIssues = []
        jobs[index].notes = []
        if jobs[index].mediaInfo == nil {
            inspect(jobID: id)
        }
        // 电影任务重试时刷新候选（未确认且不在匹配中）
        if jobs[index].mediaKind == .movie, !jobs[index].metadataState.isConfirmed,
           jobs[index].metadataState != .searching {
            startMatching(jobID: id)
        }
        saveQueue()
    }

    func clearCompleted() {
        let completedIDs = jobs.filter { $0.state == .completed }.map(\.id)
        guard !completedIDs.isEmpty else { return }
        jobs.removeAll { $0.state == .completed }
        for id in completedIDs {
            thumbnails[id] = nil
        }
        if let selected = selectedJobID, !jobs.contains(where: { $0.id == selected }) {
            selectedJobID = nil
        }
        saveQueue()
    }

    // MARK: - 检查器

    func toggleInspector() {
        isInspectorPresented.toggle()
    }

    func openInspector(for id: UUID) {
        selectedJobID = id
        isInspectorPresented = true
    }

    // MARK: - 电影元数据（设计文档 §7.5）

    /// 单任务「电影」开关。
    func setMovie(_ enabled: Bool, jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if enabled {
            guard jobs[index].mediaKind != .movie else { return }
            jobs[index].mediaKind = .movie
            saveQueue()
            startMatching(jobID: jobID)
        } else {
            jobs[index].mediaKind = .video
            jobs[index].metadataState = .none
            jobs[index].movieMetadata = nil
            movieCandidates[jobID] = nil
            if confirmMovieContext?.id == jobID {
                confirmMovieContext = nil
            }
            saveQueue()
        }
    }

    /// 未确认元数据的排队电影任务（设计文档 §7.5：拦截「开始全部」）。
    nonisolated static func unconfirmedMovieJobs(in jobs: [TranscodeJob]) -> [TranscodeJob] {
        jobs.filter { $0.state == .queued && $0.needsMetadataConfirmation }
    }

    /// 自动匹配：解析文件名 → TMDB 搜索 → 前 5 候选。
    /// 匹配结果永不静默写入；无论置信度多高都要人工确认（设计文档 §7.5）。
    private func startMatching(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.mediaKind == .movie else { return }
        guard job.metadataState != .searching else { return }
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].metadataState = .searching
        saveQueue()

        let filename = job.displayName
        Task { [weak self] in
            guard let self else { return }
            guard await self.metadataService.isConfigured else {
                self.showBanner(
                    kind: .warning,
                    message: "电影任务需要 TMDB API Key 才能自动匹配：可在设置中填写，或手动填写元数据。"
                )
                self.applyMatchFailure(
                    jobID: jobID,
                    message: "未配置 TMDB API Key：可在设置中填写，或手动填写元数据。"
                )
                return
            }
            do {
                let result = try await self.metadataService.match(filename: filename)
                self.movieCandidates[jobID] = result.candidates
                guard let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                self.jobs[index].metadataState = .needsReview
                self.saveQueue()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.applyMatchFailure(jobID: jobID, message: message)
            }
        }
    }

    private func applyMatchFailure(jobID: UUID, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].metadataState = .failed(message)
        Log.tmdb.info("元数据匹配失败：\(message, privacy: .public)")
        saveQueue()
    }

    /// 手动搜索（确认 Sheet 用）；返回错误文案（nil 表示成功，候选已更新）。
    func searchMovieCandidates(jobID: UUID, query: String, year: Int?) async -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请输入搜索关键词。" }
        do {
            let results = try await metadataService.search(query: trimmed, year: year)
            movieCandidates[jobID] = MovieMatcher.rank(
                results,
                parsed: ParsedTitle(primaryTitle: trimmed, alternativeTitle: nil, year: year)
            )
            if results.isEmpty {
                return "没有找到结果：换个关键词试试，或直接手动填写。"
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 候选详情（确认 Sheet 用）。
    func movieDetail(id: Int) async -> Result<MovieMetadata, MetadataError> {
        do {
            return .success(try await metadataService.detail(id: id).movieMetadata)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(MetadataError(message: message))
        }
    }

    /// 确认并提交元数据（此时才允许开始转码）。
    func commitMovieMetadata(jobID: UUID, metadata: MovieMetadata) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].movieMetadata = metadata
        jobs[index].metadataState = .confirmed
        Log.tmdb.info("电影元数据已确认（source=\(metadata.source.rawValue, privacy: .public)）")
        saveQueue()
    }

    /// 清除已填元数据（回到待确认）。
    func clearMovieMetadata(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].movieMetadata = nil
        jobs[index].metadataState = .needsReview
        saveQueue()
    }

    /// 重新匹配（失败后重试）。
    func retryMatch(jobID: UUID) {
        startMatching(jobID: jobID)
    }

    // MARK: - TMDB 设置（设计文档 §7.5）

    /// 验证并保存 TMDB 凭据；返回错误文案（nil 表示成功）。
    func validateAndSaveTMDB(_ raw: String) async -> String? {
        let credential = TMDBCredential.detect(raw)
        guard !credential.value.isEmpty else { return "请输入 API Key 或 Read Access Token。" }
        do {
            try await metadataService.validate(credential)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        guard KeychainStore.saveTMDB(credential.value) else {
            return "无法写入系统钥匙串。"
        }
        await metadataService.setCredential(credential)
        isTMDBConfigured = true
        return nil
    }

    /// 移除已保存的 TMDB 凭据。
    func removeTMDB() {
        KeychainStore.deleteTMDB()
        isTMDBConfigured = false
        Task { await metadataService.setCredential(nil) }
    }

    /// 清除 TMDB 元数据缓存（搜索/详情/海报）。
    func clearMetadataCache() {
        Task { await metadataService.clearCache() }
    }

    /// 网络/代理连通性测试（设计文档 §7.5）：请求 TMDB 配置端点探测可达性。
    /// 探测使用伪 Key，401/429 均说明网络已到达 TMDB；nil 表示连通，否则返回中文失败文案。
    func testTMDBReachability() async -> String? {
        let probe = TMDBCredential(kind: .v3Key, value: "chrysalis-connectivity-probe")
        do {
            try await metadataService.validate(probe)
            return nil
        } catch let error as TMDBError {
            switch error {
            case .invalidKey, .rateLimited:
                return nil
            default:
                return error.errorDescription ?? "网络请求失败。"
            }
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 状态更新（MainActor）

    private func updateState(id: UUID, state: TranscodeJob.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        saveQueue()
    }

    private func fail(id: UUID, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed(message)
        jobs[index].errorText = message
        Log.engine.error("任务失败：\(message, privacy: .public)")
        showBanner(kind: .error, message: "\(jobs[index].displayName)：\(message)")
        saveQueue()
    }

    private func applyProgress(_ progress: TranscodeProgress, to id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .running || jobs[index].state == .finishing else { return }
        jobs[index].progress = progress
        if progress.fraction >= 1, jobs[index].state == .running {
            jobs[index].state = .finishing
        }
    }

    private func applyOutcome(_ outcome: TranscodeOutcome, to id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .completed
        jobs[index].outputURL = outcome.outputURL
        jobs[index].outputBytes = outcome.bytes
        jobs[index].verificationIssues = outcome.verificationIssues
        jobs[index].notes = outcome.notes
        jobs[index].progress = TranscodeProgress(
            fraction: 1,
            processedSeconds: outcome.durationSeconds,
            speed: outcome.averageSpeed,
            etaSeconds: 0
        )
        Log.engine.info(
            "完成 \(outcome.outputURL.lastPathComponent, privacy: .public)：\(Fmt.speed(outcome.averageSpeed), privacy: .public)"
        )
        saveQueue()
    }

    // MARK: - 队列恢复与持久化（设计文档 §9）

    /// 启动时恢复上次队列：解析安全书签；活跃任务变为 interrupted；失效授权明确报错。
    private func restoreQueue() {
        guard jobs.isEmpty, let archive = QueueArchive.load() else { return }

        var restored: [TranscodeJob] = []
        var interruptedCount = 0
        var accessLostCount = 0

        for persisted in archive.jobs {
            var job = TranscodeJob(
                id: persisted.id,
                inputURL: URL(fileURLWithPath: persisted.inputPath),
                preset: persisted.preset
            )
            job.inputBookmark = persisted.inputBookmark
            job.mediaInfo = persisted.mediaInfo
            job.outputURL = persisted.outputPath.map { URL(fileURLWithPath: $0) }
            job.outputBytes = persisted.outputBytes
            job.errorText = persisted.errorText
            job.verificationIssues = persisted.verificationIssues
            job.notes = persisted.notes
            job.mediaKind = persisted.mediaKind ?? .video
            job.metadataState = persisted.metadataState
                ?? (job.mediaKind == .movie ? .needsReview : .none)
            job.movieMetadata = persisted.movieMetadata
            job.state = persisted.state.restoredState
            if job.state == .interrupted {
                interruptedCount += 1
            }

            if let bookmark = persisted.inputBookmark {
                if let resolved = BookmarkStore.resolve(bookmark) {
                    job.inputURL = resolved.url
                    if resolved.isStale, let refreshed = BookmarkStore.makeBookmark(for: resolved.url) {
                        job.inputBookmark = refreshed
                    }
                } else {
                    accessLostCount += 1
                    job.state = .failed("文件访问授权已失效，请重新添加此文件。")
                    job.errorText = "文件访问授权已失效，请重新添加此文件。"
                }
            }
            restored.append(job)
        }

        jobs = restored

        // 输出目录书签：恢复访问权 + 清理残留临时文件
        if let bookmark = archive.outputDirectoryBookmark {
            if let resolved = BookmarkStore.resolve(bookmark) {
                if isWritableDirectory(resolved.url) {
                    heldOutputScopeURL = resolved.url.startAccessingSecurityScopedResource() ? resolved.url : nil
                    outputDirectoryBookmarkData = resolved.isStale
                        ? (BookmarkStore.makeBookmark(for: resolved.url) ?? bookmark)
                        : bookmark
                    outputDirectory = resolved.url
                    OutputPlanner.cleanupOrphanTemps(in: resolved.url)
                } else {
                    showBanner(kind: .warning, message: "上次的输出文件夹不可用，请重新选择。")
                }
            } else {
                showBanner(kind: .warning, message: "输出文件夹授权已失效，请重新选择。")
            }
        }

        // 缺少媒体信息的任务补预检（含刚恢复的排队任务）
        for job in jobs where job.mediaInfo == nil && !job.state.isTerminal {
            inspect(jobID: job.id)
        }

        // 电影任务的候选不持久化：恢复后对未确认的排队任务重新匹配（设计文档 §7.5）
        for job in jobs where job.mediaKind == .movie
            && job.state == .queued && !job.metadataState.isConfirmed {
            startMatching(jobID: job.id)
        }

        if interruptedCount > 0 {
            showBanner(kind: .info, message: "已恢复队列：\(interruptedCount) 个任务因上次退出被中断，可重试。")
        } else if accessLostCount > 0 {
            showBanner(kind: .warning, message: "\(accessLostCount) 个任务的文件访问授权已失效，请重新添加。")
        }

        if !jobs.isEmpty {
            Log.app.info("恢复队列 \(self.jobs.count) 个任务（中断 \(interruptedCount) 个）")
        }
        saveQueue()
    }

    private func saveQueue() {
        QueueArchive(jobs: jobs, outputDirectoryBookmark: outputDirectoryBookmarkData).save()
    }

    // MARK: - 横幅

    func showBanner(kind: Banner.Kind, message: String) {
        let newBanner = Banner(kind: kind, message: message)
        banner = newBanner
        bannerDismissTask?.cancel()
        guard kind != .error else { return }

        // 非错误提示 4 秒自动消失（设计文档 §8.4 Toast 规则）
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self?.banner?.id == newBanner.id {
                self?.banner = nil
            }
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
    }
}

/// 元数据确认 Sheet 的呈现上下文（item-based sheet）。
struct ConfirmMovieContext: Identifiable, Equatable {
    var id: UUID
}
