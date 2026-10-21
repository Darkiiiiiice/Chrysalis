import Foundation

// MARK: - 字幕语义模型（设计文档 §7.7：解析器产出，质检与修复共用）

/// 支持的字幕格式（v1：ASS/SSA/SRT/VTT 文本格式；不解析容器内挂字幕流）。
enum SubtitleFormat: String, Sendable, CaseIterable {
    case ass
    case srt
    case vtt

    /// SSA 按 ASS 语义解析（V4 样式表，字段名不同）。
    static func detect(fileExtension: String, content: String) -> SubtitleFormat {
        switch fileExtension.lowercased() {
        case "ass", "ssa": .ass
        case "vtt": .vtt
        case "srt": .srt
        default: content.contains("[Script Info]") ? .ass : (content.hasPrefix("WEBVTT") ? .vtt : .srt)
        }
    }

    /// 展示名（徽章/报告用）。
    var displayName: String {
        switch self {
        case .ass: "ASS/SSA"
        case .srt: "SRT"
        case .vtt: "WebVTT"
        }
    }
}

/// 定位信息（ASS override tags 静态几何近似；设计文档 §7.7「不做像素级渲染」）。
struct SubtitlePosition: Sendable, Equatable {
    /// `\pos(x,y)`（PlayRes 画布坐标）。
    var x: Double?
    var y: Double?
    /// `\move(x1,y1,x2,y2)`：取起止矩形并集。
    var moveFrom: CGPointValue?
    var moveTo: CGPointValue?
    /// `\an(n)` numpad 对齐（1–9）。
    var alignment: Int?
    /// Dialogue 行的 MarginL/R/V（0 表示继承样式）。
    var marginL: Int?
    var marginR: Int?
    var marginV: Int?

    struct CGPointValue: Sendable, Equatable {
        var x: Double
        var y: Double
    }
}

/// 一条字幕（时间轴 + 纯文本行 + 定位）。
struct SubtitleCue: Sendable, Equatable {
    /// 原始行索引（ASS 的 Dialogue 行 / SRT·VTT 的时间行）；修复以「行替换」落地。
    var lineIndex: Int
    var start: Double
    var end: Double
    /// 纯文本行（已剥 override 标签 / HTML 标签；`\N` 已按行拆分）。
    var lines: [String]
    /// ASS 样式名（SRT/VTT 为 nil）。
    var style: String?
    /// ASS 的 Name 字段（说话人标记，P8.4 对白统计优先用）。
    var speaker: String?
    var position: SubtitlePosition?
    /// ASS Dialogue 文本含 override 标签的原始值（修复输出保真用）。
    var rawText: String?

    var duration: Double { end - start }
    /// 纯文本字符数（CPS 计算口径：所有行合并、去空白）。
    var characterCount: Int {
        lines.joined().components(separatedBy: .whitespacesAndNewlines).joined().count
    }
}

/// ASS 样式（质检：字体存在性 / 字号 / 边距；v1 只取质检所需字段）。
struct SubtitleStyle: Sendable, Equatable {
    var name: String
    var fontName: String
    var fontSize: Double
    var alignment: Int
    var marginL: Int
    var marginR: Int
    var marginV: Int
}

/// 解析后的字幕文档。
struct SubtitleDocument: Sendable, Equatable {
    var format: SubtitleFormat
    /// 原始文本行（修复输出保持原格式与样式表保真，只替换被修复的行）。
    var rawLines: [String]
    var cues: [SubtitleCue] = []
    var styles: [SubtitleStyle] = []
    /// ASS 画布尺寸（PlayResX/Y；定位几何近似用）。
    var playResX: Double?
    var playResY: Double?
    /// 检测到的编码名（报告展示）。
    var encoding: String = "UTF-8"

    /// 样式名 → 样式（质检 O(1) 查找）。
    var styleByName: [String: SubtitleStyle] {
        Dictionary(styles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 字幕解析/质检错误（人话提示）。
struct SubtitleError: LocalizedError, Sendable, Equatable {
    var message: String
    var errorDescription: String? { message }

    static func unreadableEncoding() -> SubtitleError {
        SubtitleError(message: "无法识别字幕文件编码：请确认文件是 UTF-8 或 GBK 编码的文本字幕。")
    }
    static func empty() -> SubtitleError {
        SubtitleError(message: "字幕文件是空的。")
    }
    static func noCues(format: SubtitleFormat) -> SubtitleError {
        SubtitleError(message: "未在文件中找到任何 \(format.displayName) 字幕条目。")
    }
}
