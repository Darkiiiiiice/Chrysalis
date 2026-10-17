import SwiftUI

/// `HW` / `SW` 徽章：9px SF Mono 大写、1px 描边（设计文档 §8.4）。
struct AcceleratorBadge: View {
    enum Kind {
        case hardware
        case software
    }

    let kind: Kind

    var body: some View {
        let color = kind == .hardware ? Theme.success : Theme.warning
        Text(kind == .hardware ? "HW" : "SW")
            .font(Theme.TextStyle.badge)
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.7), lineWidth: 1)
            )
            .accessibilityLabel(kind == .hardware ? "硬件加速" : "软件回退")
    }
}

/// 预设标签：10px、1px border、不用彩色底（设计文档 §8.4）。
struct PresetChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.TextStyle.label)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

/// 状态点 6px；运行中 1.6s 呼吸，Reduce Motion 时取消（设计文档 §8.4）。
struct StatusDot: View {
    var color: Color
    var breathing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
            .opacity(breathing && !reduceMotion && dimmed ? 0.35 : 1)
            .onAppear {
                guard breathing, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .onDisappear { dimmed = false }
            .accessibilityHidden(true)
    }
}

/// 2px 细进度线（任务行底部 / 窗口底部；设计文档 §8.3 / §8.4）。
struct ProgressLine: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(color.opacity(0.15))
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: Theme.Size.progressLine)
    }
}

/// 队列顶部 inline banner：左侧 2px 竖线、详情不弹大 alert（设计文档 §8.4）。
struct InlineBanner: View {
    let kind: QueueStore.Banner.Kind
    let message: String
    let onDismiss: () -> Void

    private var color: Color {
        switch kind {
        case .info: Theme.textSecondary
        case .warning: Theme.warning
        case .error: Theme.error
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s2) {
            Rectangle()
                .fill(color)
                .frame(width: 2)
            Text(message)
                .font(Theme.TextStyle.body)
                .foregroundStyle(kind == .error ? Theme.error : Theme.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            IconButton(systemImage: "xmark", help: "关闭提示", action: onDismiss)
        }
        .padding(.trailing, Theme.Spacing.s1)
        .frame(minHeight: 36)
        .background(Theme.surface)
        .accessibilityElement(children: .combine)
    }
}

/// 空状态 24px 细网格（约 3% 透明度；只有拖放区使用，设计文档 §8.4）。
struct GridBackground: View {
    var step: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Theme.textSecondary.opacity(0.05)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 占位页（预设 / 历史 / 设置，后续里程碑补齐）。
struct PlaceholderScreen: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Theme.Spacing.s2) {
            Text(title)
                .font(Theme.TextStyle.display)
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
