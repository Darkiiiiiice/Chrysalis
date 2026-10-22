import SwiftUI

/// 音频工具状态（设计文档 §7.17，灵感 13）：选视频 → 波形预览 → 提取导出。
@Observable
@MainActor
final class AudioToolsStore {
    var selectedURL: URL?
    /// 轨道信息与波形（无音轨时 nil，UI 提示不可提取）。
    var analysis: AudioTrackAnalysis?
    /// 选中但无音轨的标记（区分「未选择」与「无音轨」）。
    var hasNoAudioTrack = false
    var isAnalyzing = false
    var format: AudioExportFormat = .m4a
    var isExtracting = false
    /// 提取进度 0–1。
    var progress: Double = 0
    /// 操作结果提示（人话）。
    var message: String?
    /// 最近一次导出的输出 URL（展示路径用）。
    var exportURL: URL?

    var canExtract: Bool {
        selectedURL != nil && analysis != nil && !isAnalyzing && !isExtracting
    }

    /// 选择文件并分析（fileImporter / 拖放共用）。
    func select(url: URL) {
        guard !isAnalyzing, !isExtracting else { return }
        selectedURL = url
        analysis = nil
        hasNoAudioTrack = false
        message = nil
        exportURL = nil
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

    /// 提取导出：写源文件目录 `<名称>.<ext>`，重名加 `-1` 不覆盖。
    func extract() {
        guard canExtract, let url = selectedURL else { return }
        let target = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        isExtracting = true
        progress = 0
        message = nil
        exportURL = nil
        let format = self.format
        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { scoped ? url.stopAccessingSecurityScopedResource() : () }
            guard let self else { return }
            do {
                let output = try await AudioExtractor.extract(
                    url: url,
                    format: format,
                    outputURL: target
                ) { fraction in
                    Task { @MainActor [weak self] in
                        self?.progress = fraction
                    }
                }
                self.exportURL = output
                self.progress = 1
                self.message = "已导出：\(output.lastPathComponent)"
            } catch {
                self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isExtracting = false
        }
    }

    func clearMessage() {
        message = nil
    }
}
