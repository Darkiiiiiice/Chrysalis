import SwiftUI

/// 空状态 / 拖放区（设计文档 §8.4）：1px 虚线、圆角 16、24px 网格；
/// 拖入时 accent 边框 + 4% accent 填充。
struct DropZoneView: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        ZStack {
            GridBackground()
            VStack(spacing: Theme.Spacing.s2) {
                Text("拖入视频")
                    .font(Theme.TextStyle.display)
                    .foregroundStyle(Theme.textPrimary)
                Text("或点击选择文件")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous)
                .fill(store.isDropTargeted ? Theme.accent.opacity(0.04) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous)
                .strokeBorder(
                    store.isDropTargeted ? Theme.accent : Theme.border,
                    style: StrokeStyle(lineWidth: 1, dash: store.isDropTargeted ? [] : [4, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous))
        .onTapGesture {
            store.isAddFilesPresented = true
        }
        .animation(Theme.Motion.selection, value: store.isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("拖入视频，或点击选择文件")
    }
}
