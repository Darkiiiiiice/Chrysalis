import SwiftUI

/// 预设页（设计文档 §8.6 / §6.6）：两列卡片网格；内置只读可「复制为自定义」，自定义可编辑/删除。
struct PresetsScreen: View {
    @Environment(QueueStore.self) private var store

    @State private var editorContext: PresetEditorContext?
    @State private var pendingDeletion: TranscodePreset?

    private var presets: PresetStore { store.presets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: Theme.Spacing.s3)],
                    alignment: .leading,
                    spacing: Theme.Spacing.s3
                ) {
                    ForEach(presets.allPresets) { preset in
                        PresetCard(
                            preset: preset,
                            isSelected: preset.id == presets.selectedPresetID,
                            onSelect: { presets.select(id: preset.id) },
                            onDuplicate: {
                                editorContext = .create(
                                    copyOf: preset,
                                    suggestedName: presets.uniqueName(basedOn: preset.name)
                                )
                            },
                            onEdit: { editorContext = .edit(preset) },
                            onDelete: { pendingDeletion = preset }
                        )
                    }
                }
                .padding(Theme.Size.contentInset)
            }
        }
        .background(Theme.bg)
        .sheet(item: $editorContext) { context in
            PresetEditorSheet(context: context)
        }
        .confirmationDialog(
            "删除预设「\(pendingDeletion?.name ?? "")」？",
            isPresented: isDeletionDialogPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let preset = pendingDeletion {
                    presets.delete(id: preset.id)
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("已加入队列的任务不受影响。")
        }
    }

    private var isDeletionDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("预设")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("新任务默认使用选中的预设")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Size.contentInset)
        .frame(height: 44)
        .background(Theme.bg)
    }
}

/// 预设卡片（设计文档 §8.6）：名称、编码/容器/音频、预计体积；选中 accent 描边 + 4% 填充。
struct PresetCard: View {
    let preset: TranscodePreset
    let isSelected: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
                Text(preset.name)
                    .font(Theme.TextStyle.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Text("默认")
                        .font(Theme.TextStyle.badge)
                        .tracking(0.6)
                        .foregroundStyle(Theme.accent)
                }
            }

            Text(preset.summary)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)

            Text(preset.detailLabel)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)

            Text(preset.hourlyEstimateLabel)
                .font(Theme.TextStyle.numericSmall)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: Theme.Spacing.s2) {
                if preset.isBuiltIn {
                    TextButton(title: "复制为自定义", action: onDuplicate)
                } else {
                    TextButton(title: "编辑", action: onEdit)
                    TextButton(title: "删除", tint: Theme.error, action: onDelete)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(Theme.Spacing.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(isSelected ? Theme.accent : Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
        .accessibilityElement(children: .contain)
    }

    private var cardFill: Color {
        if isSelected { return Theme.accent.opacity(0.04) }
        return isHovered ? Theme.surfaceElevated : Theme.surface
    }
}
