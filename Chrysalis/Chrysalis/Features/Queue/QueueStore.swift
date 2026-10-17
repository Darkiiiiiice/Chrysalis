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

    var selectedJobID: UUID?
    var isInspectorPresented = false
    var isAddFilesPresented = false
    var isChooseOutputPresented = false
    var isDropTargeted = false
    var sidebarSelection: SidebarItem = .queue

    // MARK: - 私有状态

    private var engines: [UUID: TranscodeEngine] = [:]
    private var runnerTask: Task<Void, Never>?
    private var isStopRequested = false
    private var bannerDismissTask: Task<Void, Never>?

    // MARK: - 生命周期

    /// 启动时探测硬件能力（设计文档 §7）。
    func bootstrap() async {
        guard capabilities == nil else { return }
        let probe = await Task.detached(priority: .userInitiated) {
            VideoToolboxCapabilities.probe()
        }.value
        capabilities = probe
        Log.app.info("硬件能力：\(probe.summaryText, privacy: .public)")
    }

    // MARK: - 添加文件

    /// 拖放 / 文件选择入口：过滤容器 → 入队 → 异步预检。
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var ignoredCount = 0
        var duplicateCount = 0

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard MediaInspector.supportedExtensions.contains(ext) else {
                ignoredCount += 1
                continue
            }
            if jobs.contains(where: { $0.inputURL == url && !$0.state.isTerminal }) {
                duplicateCount += 1
                continue
            }
            let job = TranscodeJob(inputURL: url)
            jobs.append(job)
            inspect(jobID: job.id)
        }

        if ignoredCount > 0 {
            showBanner(kind: .info, message: "已忽略 \(ignoredCount) 个不支持的文件（v1 仅支持 MP4 / MOV / M4V）。")
        } else if duplicateCount > 0 {
            showBanner(kind: .info, message: "\(duplicateCount) 个文件已在队列中，已跳过重复项。")
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
        outputDirectory = url
        // 启动/切换目录时清理残留临时文件（设计文档 §6.4）
        let removed = OutputPlanner.cleanupOrphanTemps(in: url)
        if !removed.isEmpty {
            Log.engine.info("清理残留临时文件 \(removed.count) 个")
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
            guard let next = jobs.first(where: { $0.state == .queued && $0.mediaInfo != nil }) else { break }
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

        let request = TranscodeRequest(
            inputURL: job.inputURL,
            outputURL: outputURL,
            videoCodec: job.preset.videoCodec,
            container: job.preset.container,
            averageBitrate: job.preset.videoCodec.isProRes
                ? nil
                : job.preset.averageBitrate(videoWidth: video.displayWidth, videoHeight: video.displayHeight),
            audioBitrate: job.preset.audio.bitrate,
            audioMaxChannels: job.preset.audio.maxChannels,
            audioSampleRate: job.preset.audio.sampleRateOverride,
            requireHardware: true,
            encoderID: encoder.encoderID
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
            break
        }
    }

    /// 取消全部：停止批处理并取消当前任务；排队中的任务保留（再次「开始」继续）。
    func cancelAll() {
        isStopRequested = true
        for index in jobs.indices where jobs[index].state.isActive {
            jobs[index].state = .cancelling
            engines[jobs[index].id]?.cancel()
        }
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
    }

    // MARK: - 检查器

    func toggleInspector() {
        isInspectorPresented.toggle()
    }

    func openInspector(for id: UUID) {
        selectedJobID = id
        isInspectorPresented = true
    }

    // MARK: - 状态更新（MainActor）

    private func updateState(id: UUID, state: TranscodeJob.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    private func fail(id: UUID, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed(message)
        jobs[index].errorText = message
        Log.engine.error("任务失败：\(message, privacy: .public)")
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
        jobs[index].progress = TranscodeProgress(
            fraction: 1,
            processedSeconds: outcome.durationSeconds,
            speed: outcome.averageSpeed,
            etaSeconds: 0
        )
        Log.engine.info(
            "完成 \(outcome.outputURL.lastPathComponent, privacy: .public)：\(Fmt.speed(outcome.averageSpeed), privacy: .public)"
        )
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
