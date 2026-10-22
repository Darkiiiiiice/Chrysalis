import Foundation

/// 格式化工具（设计文档 §8.2：数字用等宽字体，避免跳动）。
enum Fmt {
    /// `00:01:23` / `1:02:03`。
    static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        return String(format: "%.1fx", value)
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    /// 日期时间（体检报告 / 历史展示用）。
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func bitrate(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond > 0 else { return "—" }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return String(format: "%.0f kbps", Double(bitsPerSecond) / 1000)
    }

    /// 码率数值（Mbps，去掉多余小数），如 “8” / “2.5”。
    static func mbpsNumber(_ bitsPerSecond: Int) -> String {
        let value = Double(bitsPerSecond) / 1_000_000
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// 码率数值 + 单位，如 “8 Mbps” / “2.5 Mbps”。
    static func mbps(_ bitsPerSecond: Int) -> String {
        "\(mbpsNumber(bitsPerSecond)) Mbps"
    }

    static func sampleRate(_ hertz: Double) -> String {
        guard hertz > 0 else { return "—" }
        return String(format: "%.0f Hz", hertz)
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 0: "—"
        case 1: "单声道"
        case 2: "立体声"
        default: "\(count) 声道"
        }
    }

    /// 把绝对路径缩成 `~/...` 形式（底部状态栏展示）。
    static func abbreviatedPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
