import AppKit
import Foundation
import Observation

// MARK: - 字幕模块状态（设计文档 §7.7：列表 / 质检 / 修复流；P8.4 内容理解）

/// 一份已载入的字幕文件（修复后指向 `-fixed` 副本）。
@MainActor
struct SubtitleItem: Identifiable {
    let id = UUID()
    /// 当前展示的文件（未修复 = 原文件；已修复 = `-fixed` 副本）。
    var url: URL
    /// 原始文件路径（「在 Finder 中显示」与对比用）。
    var originalURL: URL
    var document: SubtitleDocument
    var report: SubtitleReport
    var isFixed = false
    /// 载入失败（解析/编码错误）时的占位信息。
    var errorText: String?
    /// P8.4 内容理解结果（生成后挂载）。
    var insights: SubtitleInsights?

    var fileName: String { url.lastPathComponent }
}

@MainActor
@Observable
final class SubtitleStore {
    private(set) var items: [SubtitleItem] = []
    var selection: UUID?

    private(set) var isLoading = false

    var selectedItem: SubtitleItem? {
        items.first { $0.id == selection }
    }

    // MARK: 载入

    /// 载入字幕文件（解析 + 质检）；解析失败的文件以错误占位形式保留在列表。
    func load(urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["ass", "ssa", "srt", "vtt"].contains(ext) else { continue }
            do {
                let document = try SubtitleParser.parse(url: url)
                let report = SubtitleQualityEngine.analyze(document)
                items.append(SubtitleItem(
                    url: url, originalURL: url, document: document, report: report
                ))
            } catch {
                let failure = SubtitleItem(
                    url: url, originalURL: url,
                    document: SubtitleDocument(format: .srt, rawLines: []),
                    report: SubtitleReport(issues: [], cueCount: 0),
                    errorText: error.localizedDescription
                )
                items.append(failure)
            }
        }
        if selection == nil, let first = items.first {
            selection = first.id
        }
    }

    /// 对选中的自动可修复规则执行修复：生成 `-fixed` 副本（原子写盘），并重新质检。
    func applyFixes(itemID: UUID, rules: Set<SubtitleRule>) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = items[index]
        guard item.errorText == nil else { return }

        let outcome = SubtitleFixer.apply(
            document: item.document, report: item.report, selectedRules: rules
        )
        guard !outcome.appliedRules.isEmpty else { return }

        let fixedText = outcome.newLines.joined(separator: "\n")
        let baseName = item.url.deletingPathExtension().lastPathComponent
        let directory = item.url.deletingLastPathComponent()
        let targetURL = OutputPlanner.uniqueOutputURL(
            directory: directory,
            baseName: "\(baseName)-fixed",
            fileExtension: item.url.pathExtension
        )

        // 原子落盘（设计文档 §7.7：临时文件 → 成功后移动）
        let tempURL = directory.appendingPathComponent(
            ".chrysalis-\(UUID().uuidString).tmp"
        )
        do {
            try fixedText.write(to: tempURL, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            items[index].errorText = "修复结果写入失败：\(error.localizedDescription)"
            return
        }

        // 重新解析与质检修复后的副本
        do {
            let document = try SubtitleParser.parse(url: targetURL)
            let report = SubtitleQualityEngine.analyze(document)
            items[index] = SubtitleItem(
                url: targetURL, originalURL: item.originalURL,
                document: document, report: report, isFixed: true
            )
            selection = items[index].id
        } catch {
            items[index].errorText = "修复后的副本解析失败：\(error.localizedDescription)"
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        if selection == id {
            selection = items.first?.id
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 挂载内容理解结果。
    func attachInsights(itemID: UUID, insights: SubtitleInsights) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].insights = insights
    }

    /// 导出内容理解 Markdown（写源目录 `<名称>-insights.md`，原子落盘），返回导出路径。
    func exportMarkdown(itemID: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == itemID }), let insights = item.insights else { return nil }
        let text = insights.markdown(fileName: item.fileName)
        let target = item.url.deletingLastPathComponent().appendingPathComponent(
            "\(item.url.deletingPathExtension().lastPathComponent)-insights.md"
        )
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    /// 可自动修复的问题数（按钮启用判定）。
    func autoFixableCount(for item: SubtitleItem) -> Int {
        guard item.errorText == nil else { return 0 }
        let autoFixableRules = Set(item.report.issues.filter(\.autoFixable).map(\.rule))
        return item.report.issues
            .filter { $0.autoFixable && autoFixableRules.contains($0.rule) }
            .count
    }
}
