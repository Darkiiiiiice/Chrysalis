import SwiftUI

/// Toast（设计文档 §8.4）：底部居中、surfaceElevated + 1px border + 小阴影、
/// 4 秒自动消失、可用一个次级动作（如「在 Finder 中显示」）；不用模态弹窗。
///
/// 错误不走 Toast：错误固定显示在队列顶部的 inline banner（见 `InlineBanner`）。
struct ToastView: View {
    let toast: QueueStore.Toast
    let onAction: (QueueStore.Toast.Action) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s2) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 2)

            Text(toast.message)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                // 短文案贴合内容；超过 340pt 时换行（两行内），不把 Toast 撑得过宽
                .frame(maxWidth: 340, alignment: .leading)

            if toast.action != .none {
                TextButton(title: actionTitle, tint: Theme.accent) {
                    onAction(toast.action)
                }
            }

            IconButton(systemImage: "xmark", help: "关闭提示", action: onDismiss)
        }
        .padding(.leading, Theme.Spacing.s2)
        .padding(.trailing, Theme.Spacing.s1)
        .frame(minHeight: Theme.Size.controlHeight + Theme.Spacing.s1)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: Theme.Radius.inspector, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.inspector, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .shadow(color: Theme.Shadow.elevated, radius: 24, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }

    private var accentColor: Color {
        switch toast.kind {
        case .info: Theme.textSecondary
        case .warning: Theme.warning
        }
    }

    private var actionTitle: String {
        switch toast.action {
        case .none: ""
        case .revealOutputFolder: "在 Finder 中显示"
        }
    }
}
