import Foundation

/// 复古输出风格（设计文档 §7.15：双档固定预设，不提供参数微调）。
enum RetroEffectStyle: String, Sendable, Codable, CaseIterable, Hashable {
    /// VHS 磁带感：色彩渗色 / 扫描线 / 噪点 / 暗角。
    case vhs
    /// 老 DV 数码感：色度偏淡 / 轻噪点 / 日期时间戳 OSD。
    case dv

    var displayName: String {
        switch self {
        case .vhs: "VHS 磁带"
        case .dv: "老 DV"
        }
    }

    /// 检查器风格摘要。
    var summary: String {
        switch self {
        case .vhs: "色彩渗色 · 扫描线 · 噪点 · 暗角"
        case .dv: "色度偏淡 · 轻噪点 · 日期时间戳"
        }
    }
}

/// 任务级复古输出设置（设计文档 §7.15）；`nil` 表示关闭（默认）。
///
/// 与画质修复互斥（一边修复一边做旧语义矛盾）：UI 双向禁用，引擎兜底报错。
struct RetroEffectSetting: Sendable, Codable, Hashable {
    var style: RetroEffectStyle

    init(style: RetroEffectStyle = .vhs) {
        self.style = style
    }

    /// 引擎 notes 文案（检查器「输出」区展示）。
    var notesText: String {
        switch style {
        case .vhs: "复古输出：VHS 风格（CoreImage 滤镜链）"
        case .dv: "复古输出：老 DV 风格（含日期时间戳）"
        }
    }
}
