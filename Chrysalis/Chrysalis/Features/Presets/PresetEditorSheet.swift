import SwiftUI

/// 预设编辑器上下文：新建（复制来源）或编辑现有自定义预设。
struct PresetEditorContext: Identifiable {
    enum Mode {
        case create(copyOf: TranscodePreset, suggestedName: String)
        case edit(TranscodePreset)
    }

    let id = UUID()
    var mode: Mode

    static func create(copyOf preset: TranscodePreset, suggestedName: String) -> PresetEditorContext {
        PresetEditorContext(mode: .create(copyOf: preset, suggestedName: suggestedName))
    }

    static func edit(_ preset: TranscodePreset) -> PresetEditorContext {
        PresetEditorContext(mode: .edit(preset))
    }
}

/// 自定义预设编辑器（设计文档 §6.6）：名称、视频编码、基准码率、音频码率。
struct PresetEditorSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let context: PresetEditorContext

    @State private var name = ""
    @State private var videoCodec: VideoCodec = .h264
    @State private var bitrateText = ""
    @State private var audioBitrate = 192_000
    @State private var didLoad = false

    private var presets: PresetStore { store.presets }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
            Text(isCreating ? "新建预设" : "编辑预设")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)

            fieldRow("名称") {
                TextField("预设名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            fieldRow("视频编码") {
                Picker("视频编码", selection: $videoCodec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC").tag(VideoCodec.hevc)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            fieldRow("基准码率（1080p）") {
                HStack(spacing: 6) {
                    TextField("8", text: $bitrateText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Mbps")
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            fieldRow("音频码率") {
                Picker("音频码率", selection: $audioBitrate) {
                    ForEach(AudioPolicy.bitrateChoices, id: \.self) { choice in
                        Text("\(choice / 1000) kbps").tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            Text("实际码率随输出像素数按 1080p 基准缩放，并在预设范围内夹取。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)

            Text(estimateLabel)
                .font(Theme.TextStyle.numericSmall)
                .foregroundStyle(Theme.textSecondary)

            if let message = validationMessage {
                Text(message)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.error)
            }

            HStack(spacing: Theme.Spacing.s2) {
                Spacer()
                TextButton(title: "取消") {
                    dismiss()
                }
                PrimaryButton(title: "保存", isEnabled: validationMessage == nil) {
                    save()
                }
            }
        }
        .padding(Theme.Spacing.s4)
        .frame(width: 440)
        .background(Theme.bg)
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - 表单

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s2) {
            Text(label)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var isCreating: Bool {
        if case .create = context.mode { return true }
        return false
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        switch context.mode {
        case .create(let base, let suggestedName):
            name = suggestedName
            videoCodec = base.videoCodec
            audioBitrate = base.audio.bitrate
            bitrateText = Fmt.mbpsNumber(base.bitrate1080p)
        case .edit(let preset):
            name = preset.name
            videoCodec = preset.videoCodec
            audioBitrate = preset.audio.bitrate
            bitrateText = Fmt.mbpsNumber(preset.bitrate1080p)
        }
    }

    // MARK: - 校验与保存

    private var bitrate1080p: Int? {
        let normalized = bitrateText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized), value.isFinite else { return nil }
        return Int((value * 1_000_000).rounded())
    }

    private var validationMessage: String? {
        guard let bitrate = bitrate1080p else { return "请输入数字（Mbps）。" }
        switch context.mode {
        case .create:
            return presets.validationMessage(name: name, bitrate1080p: bitrate, excludingID: nil)
        case .edit(let preset):
            return presets.validationMessage(name: name, bitrate1080p: bitrate, excludingID: preset.id)
        }
    }

    private var estimateLabel: String {
        guard let bitrate = bitrate1080p else { return "预计大小：—" }
        let bytes = Int64(((Double(bitrate) * 3600 + Double(audioBitrate) * 3600) / 8.0 * 1.05))
        return "预计大小：1080p · 1 小时 ≈ \(Fmt.bytes(bytes))"
    }

    private func save() {
        guard let bitrate = bitrate1080p else { return }
        switch context.mode {
        case .create(let base, _):
            guard let created = presets.create(
                copyOf: base,
                name: name,
                videoCodec: videoCodec,
                audioBitrate: audioBitrate,
                bitrate1080p: bitrate
            ) else { return }
            presets.select(id: created.id)
        case .edit(let preset):
            _ = presets.update(
                id: preset.id,
                name: name,
                videoCodec: videoCodec,
                audioBitrate: audioBitrate,
                bitrate1080p: bitrate
            )
        }
        dismiss()
    }
}
