import SwiftUI

/// 轻量添加 Sheet（设计文档 §8.6）：文件列表 + 预设选择 + 「这些是电影」总开关。
struct AddFilesSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var presetID = ""
    @State private var markAsMovies = false

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

            HStack {
                Spacer()
                TextButton(title: "取消") {
                    store.cancelAdd()
                    dismiss()
                }
                PrimaryButton(title: "添加 \(store.pendingAddURLs.count) 个文件") {
                    store.confirmAdd(presetID: presetID, markAsMovies: markAsMovies)
                    dismiss()
                }
            }
        }
        .padding(Theme.Spacing.s3)
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
