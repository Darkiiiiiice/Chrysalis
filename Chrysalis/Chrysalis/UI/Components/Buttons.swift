import SwiftUI

/// 主按钮（设计文档 §8.4）：accent 填充、高 28、圆角 8；hover 亮度 +6%，按下缩放 0.98。
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(Theme.TextStyle.bodyEmphasized)
            }
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, Theme.Spacing.s2)
            .frame(height: Theme.Size.controlHeight)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .brightness(isHovered ? 0.06 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Theme.Motion.hover, value: isHovered)
    }
}

/// 图标按钮（28×28、圆角 6）：必须带 tooltip 与 accessibilityLabel（设计文档 §8.4 / §8.7）。
struct IconButton: View {
    let systemImage: String
    let help: String
    var isEnabled: Bool = true
    var accessoryColor: Color?
    let action: () -> Void

    @State private var isHovered = false

    init(
        systemImage: String,
        help: String,
        isEnabled: Bool = true,
        accessoryColor: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.isEnabled = isEnabled
        self.accessoryColor = accessoryColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                .background(
                    isHovered ? Theme.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.iconControl, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Theme.Motion.hover, value: isHovered)
    }

    private var foreground: Color {
        if let accessoryColor { return accessoryColor }
        return isHovered ? Theme.textPrimary : Theme.textSecondary
    }
}

/// 低调文字按钮（如「清空已完成」）。
struct TextButton: View {
    let title: String
    var tint: Color = Theme.textSecondary
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(isHovered && isEnabled ? Theme.textPrimary : tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(Theme.Motion.hover, value: isHovered)
    }
}

/// 按下缩放 0.98（设计文档 §8.4）。
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.hover, value: configuration.isPressed)
    }
}
