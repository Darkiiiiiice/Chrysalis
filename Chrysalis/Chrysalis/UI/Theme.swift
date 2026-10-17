import SwiftUI

/// 设计 Token（设计文档 §8.2）：颜色只在此处引用 Asset Catalog，视图里不写死 hex。
enum Theme {
    // MARK: 颜色（Any = 浅色，Dark = 深色，两套都在 Asset Catalog 里）
    static let bg = Color("bg")
    static let surface = Color("surface")
    static let surfaceElevated = Color("surfaceElevated")
    static let border = Color("border")
    static let textPrimary = Color("textPrimary")
    static let textSecondary = Color("textSecondary")
    /// 强调色复用系统 `AccentColor` 槽位（其 Any/Dark 两套值与 §8.2 的 `accent` 一致，
    /// 同时让系统控件自动取色）；避免额外资源与生成符号重名。
    static let accent = Color("AccentColor")
    static let accentText = Color("accentText")
    static let success = Color("success")
    static let warning = Color("warning")
    static let error = Color("error")

    // MARK: 间距（4pt 网格）
    enum Spacing {
        static let s1: CGFloat = 8
        static let s2: CGFloat = 12
        static let s3: CGFloat = 16
        static let s4: CGFloat = 24
        static let s5: CGFloat = 32
    }

    // MARK: 尺寸
    enum Size {
        static let sidebarWidth: CGFloat = 208
        static let inspectorWidth: CGFloat = 304
        static let queueRowHeight: CGFloat = 64
        static let contentInset: CGFloat = 24
        static let controlHeight: CGFloat = 28
        static let hitTarget: CGFloat = 28
        static let thumbnailWidth: CGFloat = 64
        static let thumbnailHeight: CGFloat = 36
        static let progressLine: CGFloat = 2
        static let statusDot: CGFloat = 6
    }

    // MARK: 圆角
    enum Radius {
        static let control: CGFloat = 8
        static let iconControl: CGFloat = 6
        static let thumbnail: CGFloat = 6
        static let inspector: CGFloat = 10
        static let dropZone: CGFloat = 16
    }

    // MARK: 字体（SF Pro / SF Mono；数字统一等宽）
    enum TextStyle {
        static let display = Font.system(size: 28, weight: .semibold)
        static let section = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyEmphasized = Font.system(size: 13, weight: .semibold)
        static let caption = Font.system(size: 11, weight: .medium)
        static let label = Font.system(size: 10, weight: .medium)
        static let numericSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let numeric = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let badge = Font.system(size: 9, weight: .medium, design: .monospaced)
        /// 检查器分区标题：11px 大写 Secondary。
        static let inspectorHeader = Font.system(size: 11, weight: .semibold, design: .monospaced)
    }

    // MARK: 动效（120–300ms easeOut；Reduce Motion 全降级）
    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let selection = Animation.easeOut(duration: 0.18)
        static let inspector = Animation.easeOut(duration: 0.22)
        static let toast = Animation.easeOut(duration: 0.30)
    }
}
