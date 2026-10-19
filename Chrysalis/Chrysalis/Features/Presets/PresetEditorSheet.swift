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

/// 自定义预设编辑器（设计文档 §6.6 / P3.5）：名称、编码、容器、分辨率、帧率、
/// 基准码率（含推荐）、音频码率/采样率/声道；实时体积估算。
struct PresetEditorSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let context: PresetEditorContext

    @State private var name = ""
    @State private var videoCodec: VideoCodec = .h264
    @State private var container: MediaContainer = .mp4
    @State private var resolution: ResolutionSetting = .source
    @State private var frameRate: FrameRateSetting = .source
    @State private var bitrateText = ""
    @State private var audioBitrate = 192_000
    @State private var audioSampleRate: Double?
    @State private var audioChannels = 2
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

            fieldRow("容器") {
                Picker("容器", selection: $container) {
                    Text("MP4").tag(MediaContainer.mp4)
                    Text("MOV").tag(MediaContainer.mov)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            fieldRow("分辨率") {
                Picker("分辨率", selection: $resolution) {
                    ForEach(ResolutionSetting.allCases, id: \.self) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            fieldRow("帧率") {
                Picker("帧率", selection: $frameRate) {
                    ForEach(FrameRateSetting.allCases, id: \.self) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            fieldRow("基准码率（1080p）") {
                HStack(spacing: 6) {
                    TextField("8", text: $bitrateText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Mbps")
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.textSecondary)
                    TextButton(title: "用推荐值 \(Fmt.mbpsNumber(recommendedBitrate))") {
                        bitrateText = Fmt.mbpsNumber(recommendedBitrate)
                    }
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

            fieldRow("采样率") {
                Picker("采样率", selection: $audioSampleRate) {
                    Text("保持源").tag(Double?.none)
                    ForEach(AudioPolicy.sampleRateChoices, id: \.self) { rate in
                        Text(sampleRateLabel(rate)).tag(Double?.some(rate))
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            fieldRow("声道") {
                Picker("声道", selection: $audioChannels) {
                    Text("立体声").tag(2)
                    Text("单声道").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(bitrateHint)
                Text("分辨率按短边匹配、只缩不放；帧率只降不升；H.264/HEVC 宽高取偶数。")
                Text("非 44.1/48 kHz 的源采样率统一重采样到 48 kHz。")
                if let audioHint {
                    Text(audioHint)
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

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
        .frame(width: 460)
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
            load(from: base)
        case .edit(let preset):
            name = preset.name
            load(from: preset)
        }
    }

    private func load(from preset: TranscodePreset) {
        videoCodec = preset.videoCodec
        container = preset.container
        resolution = preset.resolution
        frameRate = preset.frameRate
        audioBitrate = preset.audio.bitrate
        audioSampleRate = preset.audio.sampleRateOverride
        audioChannels = preset.audio.maxChannels
        bitrateText = Fmt.mbpsNumber(preset.bitrate1080p)
    }

    // MARK: - 辅助

    private func sampleRateLabel(_ rate: Double) -> String {
        rate == 44_100 ? "44.1 kHz" : "48 kHz"
    }

    /// 码率推荐（设计文档 P3.5）：H.264 8 Mbps / HEVC 6 Mbps（@1080p）。
    private var recommendedBitrate: Int {
        videoCodec == .hevc ? 6_000_000 : 8_000_000
    }

    private var bitrateHint: String {
        "推荐 \(Fmt.mbpsNumber(recommendedBitrate)) Mbps @1080p；实际码率随输出像素数缩放，并在预设范围内夹取。"
    }

    private var audioHint: String? {
        guard audioChannels == 1, audioBitrate > 256_000 else { return nil }
        return "单声道下 320 kbps 超出系统编码器上限，转码时会按 256 kbps 编码。"
    }

    private var basePreset: TranscodePreset {
        switch context.mode {
        case .create(let base, _): base
        case .edit(let preset): preset
        }
    }

    /// 表单当前值的临时预设（仅用于实时估算）。
    private var draftPreset: TranscodePreset {
        var draft = TranscodePreset.copy(of: basePreset, name: name)
        draft.videoCodec = videoCodec
        draft.container = container
        draft.resolution = resolution
        draft.frameRate = frameRate
        draft.audio = AudioPolicy(
            bitrate: audioBitrate,
            sampleRateOverride: audioSampleRate,
            maxChannels: audioChannels
        )
        if let bitrate = bitrate1080p {
            draft.bitrate1080p = bitrate
            draft.bitrateRange = PresetStore.scaled(
                basePreset.bitrateRange,
                by: Double(bitrate) / Double(basePreset.bitrate1080p)
            )
        }
        return draft
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
        guard bitrate1080p != nil else { return "预计大小：—" }
        return "预计大小：\(draftPreset.hourlyEstimateLabel)（按目标码率估算）"
    }

    private func save() {
        guard let bitrate = bitrate1080p else { return }
        let draft = PresetDraft(
            name: name,
            videoCodec: videoCodec,
            container: container,
            resolution: resolution,
            frameRate: frameRate,
            bitrate1080p: bitrate,
            audioBitrate: audioBitrate,
            audioSampleRate: audioSampleRate,
            audioChannels: audioChannels
        )
        switch context.mode {
        case .create(let base, _):
            guard let created = presets.create(copyOf: base, draft: draft) else { return }
            presets.select(id: created.id)
        case .edit(let preset):
            _ = presets.update(id: preset.id, draft: draft)
        }
        dismiss()
    }
}
