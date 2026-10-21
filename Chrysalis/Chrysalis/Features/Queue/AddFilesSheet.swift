import SwiftUI

/// 轻量添加 Sheet（设计文档 §8.6）：文件列表 + 预设选择 + 「这些是电影」总开关 + 画质修复。
struct AddFilesSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var presetID = ""
    @State private var markAsMovies = false
    @State private var enhancementEnabled = false
    @State private var enhancement = EnhancementSetting.defaultNeural

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            fileList
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(width: 460)
        .background(Theme.bg)
        .onAppear {
            if presetID.isEmpty {
                presetID = store.presets.selectedPresetID
            }
        }
        .onDisappear {
            store.cancelAdd()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("添加文件")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("\(store.pendingAddURLs.count) 个文件")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.s3)
        .frame(height: 44)
    }

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.pendingAddURLs, id: \.self) { url in
                    HStack(spacing: Theme.Spacing.s2) {
                        Image(systemName: "film")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 16)
                        Text(url.lastPathComponent)
                            .font(Theme.TextStyle.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Spacing.s1)
                        Text(fileSizeLabel(url))
                            .font(Theme.TextStyle.numericSmall)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, Theme.Spacing.s3)
                    .frame(height: 30)
                }
            }
            .padding(.vertical, Theme.Spacing.s1)
        }
        .frame(maxHeight: 220)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            HStack(spacing: Theme.Spacing.s2) {
                Text("预设")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)

                Picker("预设", selection: $presetID) {
                    ForEach(store.presets.allPresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)
            }

            Text(selectedSummary)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)

            Toggle("这些是电影（转码前需确认元数据）", isOn: $markAsMovies)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)

            enhancementControls

            HStack {
                Spacer()
                TextButton(title: "取消") {
                    store.cancelAdd()
                    dismiss()
                }
                PrimaryButton(title: "添加 \(store.pendingAddURLs.count) 个文件") {
                    store.confirmAdd(
                        presetID: presetID,
                        markAsMovies: markAsMovies,
                        enhancement: enhancementEnabled ? enhancement : nil
                    )
                    dismiss()
                }
            }
        }
        .padding(Theme.Spacing.s3)
    }

    // MARK: 画质修复（设计文档 §7.6 / §8）

    @ViewBuilder
    private var enhancementControls: some View {
        Toggle("画质修复（2x 超分，输出为源尺寸 ×2）", isOn: $enhancementEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(Theme.TextStyle.body)
            .foregroundStyle(Theme.textPrimary)

        if enhancementEnabled {
            HStack(spacing: Theme.Spacing.s2) {
                Text("修复")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                Picker("模式", selection: Binding(
                    get: { enhancement.mode },
                    set: { mode in
                        enhancement.mode = mode
                    }
                )) {
                    Text(EnhancementMode.neural.displayName).tag(EnhancementMode.neural)
                    Text(EnhancementMode.filter.displayName).tag(EnhancementMode.filter)
                }
                .labelsHidden()
                .fixedSize()

                if enhancement.isNeural {
                    Picker("模型", selection: $enhancement.neuralModel) {
                        ForEach(NeuralUpscalerModel.allCases, id: \.self) { model in
                            Text(model.shortName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Picker("强度", selection: $enhancement.strength) {
                    ForEach(EnhancementStrength.allCases, id: \.self) { strength in
                        Text(strength.displayName).tag(strength)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("分辨率锁定为「保持源」；\(enhancement.speedHint)")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                if enhancement.isNeural {
                    Text("ML 超分为离线慢速处理，开始前可在检查器中调整。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var selectedSummary: String {
        guard let preset = store.presets.preset(id: presetID) else { return "" }
        return "\(preset.summary) · \(preset.bitrateLabel)"
    }

    private func fileSizeLabel(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return "—"
        }
        return Fmt.bytes(size)
    }
}
