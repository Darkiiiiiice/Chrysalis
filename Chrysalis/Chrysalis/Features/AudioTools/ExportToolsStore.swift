import SwiftUI

/// 导出工具状态（设计文档 §7.17 / §7.18）：音频提取 / GIF 动图 / 雪碧图三分区，选中文件共享。
@Observable
@MainActor
final class ExportToolsStore {
    enum ToolTab: String, CaseIterable, Identifiable {
        case audio
        case gif
        case sprite
        case wallpaper

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audio: "音频提取"
            case .gif: "GIF 动图"
            case .sprite: "雪碧图"
            case .wallpaper: "动态壁纸"
            }
        }
    }

    var selectedTab: ToolTab = .audio

    /// 选中文件（三分区共享）。
    var selectedURL: URL?
    /// 音轨信息与波形（无音轨时 nil，音频分区提示不可提取；GIF / 雪碧图不依赖）。
    var analysis: AudioTrackAnalysis?
    var hasNoAudioTrack = false
    var isAnalyzing = false
    /// 操作结果提示（人话）。
    var message: String?

    // 音频提取
    var format: AudioExportFormat = .m4a
    var isExtracting = false
    var progress: Double = 0
    var exportURL: URL?

    // GIF 动图
    var gifWidth: GifWidth = .w360
    var isExportingGif = false
    var gifProgress: Double = 0
    var gifExportURL: URL?

    // 雪碧图
    var spriteLayout: SpriteLayout = .grid5x4
    var isExportingSprite = false
    var spriteProgress: Double = 0
    var spriteExportURL: URL?

    // 动态壁纸
    var isExportingWallpaper = false
    var wallpaperProgress: Double = 0
    var wallpaperExportURL: URL?

    var isBusy: Bool {
        isAnalyzing || isExtracting || isExportingGif || isExportingSprite || isExportingWallpaper
    }

    var canExtractAudio: Bool {
        selectedURL != nil && analysis != nil && !isBusy
    }

    var canExportGif: Bool {
        selectedURL != nil && !isBusy
    }

    var canExportSprite: Bool {
        selectedURL != nil && !isBusy
    }

    var canExportWallpaper: Bool {
        selectedURL != nil && !isBusy
    }

    /// 选择文件并分析音轨（fileImporter / 拖放共用）。
    func select(url: URL) {
        guard !isBusy else { return }
        selectedURL = url
        analysis = nil
        hasNoAudioTrack = false
        message = nil
        exportURL = nil
        gifExportURL = nil
        spriteExportURL = nil
        wallpaperExportURL = nil
        Task { await analyzeCurrent() }
    }

    private func analyzeCurrent() async {
        guard let url = selectedURL else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let result = try await AudioExtractor.analyze(url: url)
            if let result {
                analysis = result
                hasNoAudioTrack = false
            } else {
                analysis = nil
                hasNoAudioTrack = true
            }
        } catch {
            analysis = nil
            hasNoAudioTrack = false
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 提取音频：写源文件目录 `<名称>.<ext>`，重名加 `-1` 不覆盖。
    func extractAudio() {
        guard canExtractAudio, let url = selectedURL else { return }
        let target = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        isExtracting = true
        progress = 0
        message = nil
        exportURL = nil
        let format = self.format
        runExport(target: target) { store, url in
            try await AudioExtractor.extract(url: url, format: format, outputURL: target) { fraction in
                Task { @MainActor [weak self] in
                    self?.progress = fraction
                }
            }
        } completion: { store, output in
            store.exportURL = output
            store.progress = 1
            store.message = "已导出：\(output.lastPathComponent)"
        } failure: { store, error in
            store.message = error
        } finish: { store in
            store.isExtracting = false
        }
    }

    /// 导出 GIF：写源文件目录 `<名称>.gif`。
    func exportGif() {
        guard canExportGif, let url = selectedURL else { return }
        let target = url.deletingPathExtension().appendingPathExtension("gif")
        isExportingGif = true
        gifProgress = 0
        message = nil
        gifExportURL = nil
        let width = self.gifWidth
        runExport(target: target) { store, url in
            try await AnimatedGIFExporter.export(url: url, width: width, outputURL: target) { fraction in
                Task { @MainActor [weak self] in
                    self?.gifProgress = fraction
                }
            }
        } completion: { store, output in
            store.gifExportURL = output
            store.gifProgress = 1
            store.message = "已导出：\(output.lastPathComponent)"
        } failure: { store, error in
            store.message = error
        } finish: { store in
            store.isExportingGif = false
        }
    }

    /// 导出雪碧图：写源文件目录 `<名称>-雪碧图.jpg`。
    func exportSprite() {
        guard canExportSprite, let url = selectedURL else { return }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-雪碧图.jpg")
        isExportingSprite = true
        spriteProgress = 0
        message = nil
        spriteExportURL = nil
        let layout = self.spriteLayout
        runExport(target: target) { store, url in
            try await SpriteSheetExporter.export(url: url, layout: layout, outputURL: target) { fraction in
                Task { @MainActor [weak self] in
                    self?.spriteProgress = fraction
                }
            }
        } completion: { store, output in
            store.spriteExportURL = output
            store.spriteProgress = 1
            store.message = "已导出：\(output.lastPathComponent)"
        } failure: { store, error in
            store.message = error
        } finish: { store in
            store.isExportingSprite = false
        }
    }

    /// 导出动态壁纸：写源文件目录 `<名称>-动态壁纸.heic`（时间模式 16 状态）。
    func exportWallpaper() {
        guard canExportWallpaper, let url = selectedURL else { return }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-动态壁纸.heic")
        isExportingWallpaper = true
        wallpaperProgress = 0
        message = nil
        wallpaperExportURL = nil
        runExport(target: target) { store, url in
            try await DynamicWallpaperExporter.export(url: url, outputURL: target) { fraction in
                Task { @MainActor [weak self] in
                    self?.wallpaperProgress = fraction
                }
            }
        } completion: { store, output in
            store.wallpaperExportURL = output
            store.wallpaperProgress = 1
            store.message = "已导出：\(output.lastPathComponent)"
        } failure: { store, error in
            store.message = error
        } finish: { store in
            store.isExportingWallpaper = false
        }
    }

    func clearMessage() {
        message = nil
    }

    // MARK: 导出共用骨架（安全作用域 + 统一错误文案）

    private func runExport(
        target: URL,
        body: @escaping @Sendable (ExportToolsStore, URL) async throws -> URL,
        completion: @escaping @MainActor (ExportToolsStore, URL) -> Void,
        failure: @escaping @MainActor (ExportToolsStore, String) -> Void,
        finish: @escaping @MainActor (ExportToolsStore) -> Void
    ) {
        guard let url = selectedURL else { return }
        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { scoped ? url.stopAccessingSecurityScopedResource() : () }
            guard let self else { return }
            do {
                let output = try await body(self, url)
                completion(self, output)
            } catch {
                failure(self, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            finish(self)
        }
    }
}
