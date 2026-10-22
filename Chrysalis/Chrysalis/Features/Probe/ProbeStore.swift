import Foundation
import Observation
import os

/// 视频体检状态（设计文档 §7.10；MainActor）。
@MainActor
@Observable
final class ProbeStore {
    private(set) var report: MediaProbeReport?
    private(set) var currentURL: URL?
    private(set) var isScanning = false
    private(set) var isDeepScanning = false
    /// 上次操作的提示（底部轻提示，非模态）。
    private(set) var message: String?

    /// 对文件执行快速体检（秒级）。
    func probe(url: URL) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        currentURL = url
        report = await MediaProbeService.quickReport(url: url)
    }

    /// 深度探测：抽样解码出码率分布 / 关键帧间隔 / VFR（几秒级）。
    func runDeepScan() async {
        guard let url = currentURL, let report = report, !isDeepScanning else { return }
        isDeepScanning = true
        defer { isDeepScanning = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let deep = await MediaProbeService.deepScan(url: url, report: report) {
            self.report?.deep = deep
            self.report?.deepError = nil
            self.report?.deepScannedAt = Date()
            message = "深度探测完成。"
        } else {
            self.report?.deepError = "抽样读取失败：文件可能损坏或无法解封装。"
            message = "深度探测失败。"
        }
    }

    /// 结论是否允许加入转码队列（设计文档 §7.10：绿灯才可用）。
    var canEnqueue: Bool {
        report?.verdict == .ready
    }

    /// 加入转码队列：交给 QueueStore 走现有添加 Sheet（选预设 / 电影标记）。
    func enqueueToQueue(_ queueStore: QueueStore) {
        guard let url = currentURL, canEnqueue else { return }
        queueStore.prepareAdd([url])
        message = "已交由添加流程：选择预设后入队。"
    }

    /// 导出 Markdown（写源文件目录 `<名称>-体检报告.md`，原子落盘）。
    func exportMarkdown() -> URL? {
        guard let report, let url = currentURL else { return nil }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-体检报告.md")
        do {
            try ProbeReportMarkdown.generate(report)
                .write(to: target, atomically: true, encoding: .utf8)
            message = "已导出：\(target.lastPathComponent)"
            return target
        } catch {
            message = "导出失败：无法写入源文件所在目录。"
            return nil
        }
    }

    /// 导出 JSON（原始结构，同目录）。
    func exportJSON() -> URL? {
        guard let report, let url = currentURL else { return nil }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-体检报告.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(report)
            try data.write(to: target, options: .atomic)
            message = "已导出：\(target.lastPathComponent)"
            return target
        } catch {
            message = "导出失败：无法写入源文件所在目录。"
            return nil
        }
    }

    func clearMessage() {
        message = nil
    }

    func reset() {
        report = nil
        currentURL = nil
        message = nil
    }
}
