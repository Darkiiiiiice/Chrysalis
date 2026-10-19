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

/// 自定义预设编辑器（设计文档 §6.6 / P3.5 / P4）：名称、编码、容器、分辨率、帧率、
/// 码率控制（平均码率 / 质量优先 / 目标大小）、关键帧、Profile、音频；实时体积估算。
struct PresetEditorSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let context: PresetEditorContext

    @State private var name = ""
    @State private var videoCodec: VideoCodec = .h264
    @State private var container: MediaContainer = .mp4
    @State private var resolution: ResolutionSetting = .source
    @State private var frameRate: FrameRateSetting = .source
    @State private var bitrateMode: BitrateMode = .targetBitrate
    @State private var bitrateText = ""
    @State private var quality = 0.65
    @State private var targetSizeText = "700"
    @State private var keyframeInterval: KeyframeIntervalSetting = .auto
    @State private var profile: VideoProfileSetting = .auto
    @State private var audioBitrate = 192_000
    @State private var audioSampleRate: Double?
    @State private var audioChannels = 2
    @State private var pcmBitDepth = 16
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
                    Text("ProRes 422").tag(VideoCodec.proRes422)
                    Text("ProRes 422 HQ").tag(VideoCodec.proRes422HQ)
                    Text("ProRes 422 LT").tag(VideoCodec.proRes422LT)
                    Text("ProRes 422 Proxy").tag(VideoCodec.proRes422Proxy)
                    Text("ProRes 4444").tag(VideoCodec.proRes4444)
                }
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
                .disabled(videoCodec.isProRes)
            }
            if videoCodec.isProRes {
                fieldRow("") {
                    Text("ProRes 仅支持 MOV，已自动选择。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
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

            if videoCodec.isProRes {
                fieldRow("码率") {
                    Text("ProRes 固定码率（由编码档位与分辨率/帧率决定）")
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                fieldRow("码率控制") {
                    Picker("码率控制", selection: $bitrateMode) {
                        ForEach(BitrateMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }

                switch bitrateMode {
                case .targetBitrate:
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
                case .quality:
                    fieldRow("质量") {
                        HStack(spacing: 8) {
                            Slider(value: $quality, in: 0.1...1.0, step: 0.05)
                                .frame(width: 200)
                            Text(String(format: "%.2f", quality))
                                .font(Theme.TextStyle.numericSmall)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                case .targetSize:
                    fieldRow("目标大小") {
                        HStack(spacing: 6) {
                            TextField("700", text: $targetSizeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("MB / 每个文件")
                                .font(Theme.TextStyle.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }

            if !videoCodec.isProRes {
                fieldRow("关键帧间隔") {
                    Picker("关键帧间隔", selection: $keyframeInterval) {
                        ForEach(KeyframeIntervalSetting.allCases, id: \.self) { setting in
                            Text(setting.displayName).tag(setting)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            if videoCodec == .h264 {
                fieldRow("Profile") {
                    Picker("Profile", selection: $profile) {
                        ForEach(VideoProfileSetting.choices(for: videoCodec), id: \.self) { setting in
                            Text(setting.displayName).tag(setting)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            if videoCodec.isProRes {
                fieldRow("PCM 位深") {
                    Picker("PCM 位深", selection: $pcmBitDepth) {
                        ForEach(AudioPolicy.pcmBitDepthChoices, id: \.self) { depth in
                            Text("\(depth)-bit").tag(depth)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            } else {
                fieldRow("音频码率") {
                    Picker("音频码率", selection: $audioBitrate) {
                        ForEach(AudioPolicy.bitrateChoices, id: \.self) { choice in
                            Text("\(choice / 1000) kbps").tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
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
                if !videoCodec.isProRes {
                    Text(bitrateHint)
                }
                Text("分辨率按短边匹配、只缩不放；帧率只降不升；H.264/HEVC 宽高取偶数。")
                Text("非 44.1/48 kHz 的源采样率统一重采样到 48 kHz。")
                if videoCodec.isProRes {
                    Text("ProRes 输出音频固定为 PCM；关键帧/Profile 不适用（帧内编码）。")
                }
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
        .onChange(of: videoCodec) { oldValue, newValue in
            codecChanged(from: oldValue, to: newValue)
        }
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
        bitrateMode = preset.bitrateMode
        quality = preset.quality
        targetSizeText = String(preset.targetSizeMB)
        keyframeInterval = preset.keyframeInterval
        profile = preset.profile
        audioBitrate = preset.audio.bitrate
        audioSampleRate = preset.audio.sampleRateOverride
        audioChannels = preset.audio.maxChannels
        pcmBitDepth = preset.audio.pcmBitDepth ?? 16
        bitrateText = Fmt.mbpsNumber(preset.bitrate1080p)
    }

    /// 编码切换时规整互斥字段：ProRes ⇒ MOV + PCM；离开 ProRes ⇒ 码率回到可用范围。
    private func codecChanged(from oldValue: VideoCodec, to newValue: VideoCodec) {
        if newValue.isProRes {
            container = .mov
            bitrateMode = .targetBitrate
        } else if oldValue.isProRes {
            if let bitrate = parsedBitrate, !(1_000_000...40_000_000).contains(bitrate) {
                bitrateText = Fmt.mbpsNumber(recommendedBitrate)
            }
        }
        if !VideoProfileSetting.choices(for: newValue).contains(profile) {
            profile = .auto
        }
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
        switch bitrateMode {
        case .targetBitrate:
            return "推荐 \(Fmt.mbpsNumber(recommendedBitrate)) Mbps @1080p；实际码率随输出像素数缩放，并在预设范围内夹取。"
        case .quality:
            return "质量优先：编码器按内容分配码率，体积随内容浮动；估算仅供参考。"
        case .targetSize:
            return "目标大小按源时长换算为视频码率（扣除音频），超出预设范围时会夹取并在任务提示中说明。"
        }
    }

    private var audioHint: String? {
        guard !videoCodec.isProRes, audioChannels == 1, audioBitrate > 256_000 else { return nil }
        return "单声道下 320 kbps 超出系统编码器上限，转码时会按 256 kbps 编码。"
    }

    private var basePreset: TranscodePreset {
        switch context.mode {
        case .create(let base, _): base
        case .edit(let preset): preset
        }
    }

    private var parsedBitrate: Int? {
        let normalized = bitrateText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized), value.isFinite else { return nil }
        return Int((value * 1_000_000).rounded())
    }

    /// 码率字段仅在「平均码率」模式必填；其他模式无效输入回退到来源预设值。
    private var effectiveBitrate1080p: Int? {
        if let parsedBitrate { return parsedBitrate }
        if videoCodec.isProRes || bitrateMode != .targetBitrate { return basePreset.bitrate1080p }
        return nil
    }

    private var draft: PresetDraft? {
        guard let bitrate = effectiveBitrate1080p else { return nil }
        return PresetDraft(
            name: name,
            videoCodec: videoCodec,
            container: videoCodec.isProRes ? .mov : container,
            resolution: resolution,
            frameRate: frameRate,
            bitrate1080p: bitrate,
            bitrateMode: videoCodec.isProRes ? .targetBitrate : bitrateMode,
            quality: quality,
            targetSizeMB: Int(targetSizeText.trimmingCharacters(in: .whitespaces)) ?? 0,
            keyframeInterval: keyframeInterval,
            profile: profile,
            audioBitrate: audioBitrate,
            audioSampleRate: audioSampleRate,
            audioChannels: audioChannels,
            audioPCMSampleBitDepth: videoCodec.isProRes ? pcmBitDepth : nil
        )
    }

    /// 表单当前值的临时预设（仅用于实时估算）。
    private var draftPreset: TranscodePreset? {
        guard let draft else { return nil }
        var preset = TranscodePreset.copy(of: basePreset, name: draft.name)
        preset.videoCodec = draft.videoCodec
        preset.container = draft.container
        preset.resolution = draft.resolution
        preset.frameRate = draft.frameRate
        preset.bitrate1080p = draft.bitrate1080p
        preset.bitrateMode = draft.bitrateMode
        preset.quality = draft.quality
        preset.targetSizeMB = draft.targetSizeMB
        preset.keyframeInterval = draft.keyframeInterval
        preset.profile = draft.profile
        preset.audio = AudioPolicy(
            bitrate: draft.audioBitrate,
            sampleRateOverride: draft.audioSampleRate,
            maxChannels: draft.audioChannels,
            pcmBitDepth: draft.audioPCMSampleBitDepth
        )
        if draft.bitrateMode == .targetBitrate,
           !draft.videoCodec.isProRes,
           basePreset.bitrate1080p > 0 {
            preset.bitrateRange = PresetStore.scaled(
                basePreset.bitrateRange,
                by: Double(draft.bitrate1080p) / Double(basePreset.bitrate1080p)
            )
        }
        return preset
    }

    // MARK: - 校验与保存

    private var validationMessage: String? {
        guard let draft else { return "请输入数字（Mbps）。" }
        switch context.mode {
        case .create:
            return presets.validationMessage(draft, excludingID: nil)
        case .edit(let preset):
            return presets.validationMessage(draft, excludingID: preset.id)
        }
    }

    private var estimateLabel: String {
        guard let preset = draftPreset else { return "预计大小：—" }
        let basis: String
        if preset.videoCodec.isProRes {
            basis = "ProRes 标称码率估算"
        } else if preset.bitrateMode == .quality {
            basis = ""
        } else if preset.bitrateMode == .targetSize {
            basis = "目标大小"
        } else {
            basis = "按目标码率估算"
        }
        return "预计大小：\(preset.hourlyEstimateLabel)" + (basis.isEmpty ? "" : "（\(basis)）")
    }

    private func save() {
        guard let draft else { return }
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
