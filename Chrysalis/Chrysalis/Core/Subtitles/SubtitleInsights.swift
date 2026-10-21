import Foundation
import FoundationModels

// MARK: - 字幕内容理解（P8.4，设计文档 §7.7）：本地 Foundation Models，完全离线

/// Foundation Models 可用性三态（设计文档：可用 / 未启用 Apple Intelligence / 设备不支持）。
enum SubtitleInsightAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceDisabled
    case deviceUnsupported

    static func current() -> SubtitleInsightAvailability {
        guard #available(macOS 26.0, *) else { return .deviceUnsupported }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceDisabled
        case .unavailable:
            return .deviceUnsupported
        @unknown default:
            return .deviceUnsupported
        }
    }

    var guidance: String {
        switch self {
        case .available: ""
        case .appleIntelligenceDisabled:
            "内容理解需要开启 Apple Intelligence（系统设置 → Apple Intelligence 与 Siri）。"
        case .deviceUnsupported:
            "本机不支持 Apple Intelligence，内容理解功能不可用。"
        }
    }
}

/// 金句（结构化输出；原文精确匹配校验后保留，防幻觉）。
struct SubtitleQuote: Sendable, Equatable, Codable {
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var kind: String

    /// 时间戳展示（00:01:23）。
    var timeRange: String {
        "\(Fmt.duration(seconds: startSeconds)) – \(Fmt.duration(seconds: endSeconds))"
    }
}

/// 一份字幕的内容理解结果。
struct SubtitleInsights: Sendable, Equatable {
    var summary: String
    var quotes: [SubtitleQuote]
    /// 角色对白统计（说话人 → 条数）；无标记时由 LLM 推断。
    var speakerStats: [String: Int]

    /// Markdown 导出（报告 + 金句时间戳列表 + 对白统计）。
    func markdown(fileName: String) -> String {
        var output = "# 字幕内容理解：\(fileName)\n\n"
        output += "## 摘要\n\n\(summary)\n\n"
        output += "## 金句（含时间戳）\n\n"
        if quotes.isEmpty {
            output += "（未提取到金句）\n\n"
        } else {
            for quote in quotes {
                output += "- \(quote.timeRange)｜\(quote.text)（\(quote.kind)）\n"
            }
            output += "\n"
        }
        output += "## 对白统计\n\n"
        if speakerStats.isEmpty {
            output += "（无说话人标记，无法统计）\n"
        } else {
            for (speaker, count) in speakerStats.sorted(by: { $0.value > $1.value }) {
                output += "- \(speaker)：\(count) 条\n"
            }
        }
        return output
    }
}

/// 内容理解执行器（全部本地推理，无网络请求）。
enum SubtitleInsightsEngine {
    /// 说话人标记统计（纯规则：ASS Name 字段非空即计一条）。
    static func speakerStats(from document: SubtitleDocument) -> [String: Int] {
        var stats: [String: Int] = [:]
        for cue in document.cues {
            guard let speaker = cue.speaker?.trimmingCharacters(in: .whitespaces), !speaker.isEmpty else { continue }
            stats[speaker, default: 0] += 1
        }
        return stats
    }

    /// 金句原文校验：提取文本必须能在字幕原文中精确命中（忽略空白差异），未命中丢弃（防幻觉）。
    static func validatedQuotes(_ quotes: [SubtitleQuote], document: SubtitleDocument) -> [SubtitleQuote] {
        let corpus = document.cues.flatMap(\.lines).map {
            $0.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        }
        return quotes.filter { quote in
            let needle = quote.text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            guard !needle.isEmpty else { return false }
            return corpus.contains { $0.contains(needle) }
        }
    }

    /// 生成结构化提示词（分块摘要的 Map 输入）。
    static func chunkSummaries(_ document: SubtitleDocument, chunkSeconds: Double = 300) -> [(start: Double, text: String)] {
        guard let last = document.cues.map(\.end).max(), last > 0 else { return [] }
        var chunks: [(start: Double, text: String)] = []
        var index = 0.0
        while index < last {
            let windowEnd = index + chunkSeconds
            let lines = document.cues
                .filter { $0.start >= index && $0.start < windowEnd }
                .sorted { $0.start < $1.start }
                .map { cue in
                    "[\(Fmt.duration(seconds: cue.start))] \(cue.lines.joined(separator: " / "))"
                }
            if !lines.isEmpty {
                chunks.append((index, lines.joined(separator: "\n")))
            }
            index = windowEnd
        }
        return chunks
    }
}

/// Foundation Models 会话封装（macOS 26+；三态降级由 UI 侧根据 availability 控制）。
@MainActor
@Observable
final class SubtitleInsightsSession {
    private(set) var isRunning = false
    private(set) var progressText = ""
    private(set) var insights: SubtitleInsights?
    private(set) var errorText: String?

    /// 生成内容理解（摘要 Map-Reduce + 金句提取 + 对白统计）。
    func run(document: SubtitleDocument, fileName: String) async {
        guard SubtitleInsightAvailability.current() == .available else {
            errorText = SubtitleInsightAvailability.current().guidance
            return
        }
        guard !document.cues.isEmpty else {
            errorText = "字幕没有可分析的内容。"
            return
        }
        isRunning = true
        errorText = nil
        insights = nil
        defer { isRunning = false }

        do {
            let session = LanguageModelSession()

            // 1) 摘要：按 5 分钟窗口分块逐块摘要，再汇总
            let chunks = SubtitleInsightsEngine.chunkSummaries(document)
            var partialSummaries: [String] = []
            for (position, chunk) in chunks.enumerated() {
                progressText = "分块摘要 \(position + 1)/\(chunks.count)…"
                let prompt = """
                以下是视频字幕的一段文本（从 \(Fmt.duration(seconds: chunk.start)) 开始）。
                用 2–3 句中文概括这段内容，只输出概括本身：
                \(chunk.text)
                """
                let response = try await session.respond(to: prompt)
                partialSummaries.append(response.content)
            }
            progressText = "汇总摘要…"
            let summaryPrompt = """
            下面是同一部视频各段的概括，请合并成一段 3–5 句的完整中文摘要，只输出摘要本身：
            \(partialSummaries.joined(separator: "\n"))
            """
            let summaryResponse = try await session.respond(to: summaryPrompt)

            // 2) 金句提取（带时间戳，原文校验）
            progressText = "提取金句…"
            let cuesForQuotes = document.cues
                .sorted { $0.start < $1.start }
                .map { "[\(Fmt.duration(seconds: $0.start))–\(Fmt.duration(seconds: $0.end))] \($0.lines.joined(separator: " / "))" }
                .joined(separator: "\n")
            let quotePrompt = """
            从以下电影字幕中挑出 3–8 句最有代表性或最打动人的台词（金句）。
            只从原文中挑选，逐字保留，不要改写。每句给出它所在的起止时间戳（用原文行首的时间戳）。
            输出 JSON 数组，每个元素含 text（原文）、start（秒，数字）、end（秒，数字）、kind（类型标签：台词/独白/对白，选一个）。
            只输出 JSON，不要其他文字：
            \(cuesForQuotes)
            """
            let quoteResponse = try await session.respond(to: quotePrompt)
            let parsedQuotes = Self.parseQuotes(from: quoteResponse.content)

            // 3) 组装（金句原文校验 + 对白统计）
            let stats = SubtitleInsightsEngine.speakerStats(from: document)
            let validated = SubtitleInsightsEngine.validatedQuotes(parsedQuotes, document: document)
            insights = SubtitleInsights(
                summary: summaryResponse.content,
                quotes: validated,
                speakerStats: stats
            )
            progressText = ""
        } catch {
            progressText = ""
            errorText = "生成失败：\(error.localizedDescription)"
        }
    }

    /// 解析模型返回的 JSON（宽容处理代码块包裹）。
    nonisolated static func parseQuotes(from content: String) -> [SubtitleQuote] {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let array = try? JSONDecoder().decode([SubtitleQuote].self, from: data) else {
            return []
        }
        return array
    }

    func reset() {
        insights = nil
        errorText = nil
        progressText = ""
    }
}
