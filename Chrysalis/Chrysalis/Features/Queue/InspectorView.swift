import AppKit
import SwiftUI

/// 检查器（设计文档 §8.6）：304px、surfaceElevated、左侧 1px border；
/// 分区：输入 / 输出 / 硬件 / 错误。
struct InspectorView: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    /// A/B 对比窗口入口（设计文档 §7.9）。
    private func openCompare(_ context: CompareContext) {
        openWindow(value: context)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            if let job = store.selectedJob {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                        inputSection(job)
                        metadataSection(job)
                        outputSection(job)
                        enhancementSection(job)
                        loudnessSection(job)
                        frameBlendingSection(job)
                        hardwareSection(job)
                        errorSection(job)
                    }
                    .padding(Theme.Spacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("选择任务查看详情")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surfaceElevated)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    private var header: some View {
        HStack {
            Text("检查器")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton(systemImage: "xmark", help: "隐藏检查器（⌘I）") {
                store.toggleInspector()
            }
        }
        .padding(.leading, Theme.Spacing.s3)
        .padding(.trailing, Theme.Spacing.s2)
        .frame(height: 44)
    }

    // MARK: 输入

    @ViewBuilder
    private func inputSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "输入") {
            if let info = job.mediaInfo {
                InspectorRow(label: "文件", value: job.displayName)
                InspectorRow(label: "容器", value: info.containerLabel)
                InspectorRow(label: "时长", value: info.durationLabel)
                InspectorRow(label: "大小", value: Fmt.bytes(info.fileSizeBytes))
                if let video = info.video {
                    InspectorRow(label: "分辨率", value: info.dimensionsLabel)
                    InspectorRow(label: "视频编码", value: video.codecName)
                    InspectorRow(label: "帧率", value: String(format: "%.2f fps", video.frameRate))
                    InspectorRow(label: "视频码率", value: Fmt.bitrate(video.bitrate ?? 0))
                }
                if let audio = info.audio {
                    InspectorRow(label: "音频编码", value: audio.codecName)
                    InspectorRow(label: "声道", value: Fmt.channels(audio.channelCount))
                    InspectorRow(label: "采样率", value: Fmt.sampleRate(audio.sampleRate))
                } else {
                    InspectorRow(label: "音频", value: "无音轨")
                }
                InspectorRow(
                    label: "HDR",
                    value: info.isHDR ? "\(info.hdrLabel ?? "HDR")（v1 拒绝）" : "否",
                    valueColor: info.isHDR ? Theme.warning : Theme.textPrimary
                )
            } else {
                InspectorRow(label: "状态", value: "读取中…")
            }
        }
    }

    // MARK: 电影元数据（设计文档 §7.5）

    @ViewBuilder
    private func metadataSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "电影元数据") {
            Toggle("标记为电影（转码前需确认）", isOn: movieBinding(job))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)

            if job.mediaKind == .movie {
                InspectorRow(
                    label: "状态",
                    value: metadataStatusText(job),
                    valueColor: metadataStatusColor(job)
                )
                if let metadata = job.movieMetadata {
                    InspectorRow(label: "标题", value: metadata.title)
                    if let year = metadata.year {
                        InspectorRow(label: "年份", value: String(year))
                    }
                    if let director = metadata.director, !director.isEmpty {
                        InspectorRow(label: "导演", value: director)
                    }
                } else if let summary = store.matchedSummary(jobID: job.id) {
                    // 待确认时直接展示匹配结果，不必点开确认窗口（走查反馈）
                    let year = summary.year.map { "（\($0)）" } ?? ""
                    InspectorRow(
                        label: "匹配到",
                        value: "《\(summary.title)》\(year)",
                        valueColor: Theme.textPrimary
                    )
                }
                if let failure = job.metadataState.failureMessage, job.movieMetadata == nil {
                    Text(failure)
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.warning)
                        .textSelection(.enabled)
                }
                HStack(spacing: Theme.Spacing.s2) {
                    TextButton(
                        title: job.movieMetadata == nil ? "确认元数据…" : "查看 / 修改…",
                        tint: Theme.accent
                    ) {
                        store.confirmMovieContext = ConfirmMovieContext(id: job.id)
                    }
                    if job.metadataState.failureMessage != nil {
                        TextButton(title: "重试匹配", tint: Theme.accent) {
                            store.retryMatch(jobID: job.id)
                        }
                    }
                }
            }
        }
    }

    private func movieBinding(_ job: TranscodeJob) -> Binding<Bool> {
        Binding(
            get: { job.mediaKind == .movie },
            set: { store.setMovie($0, jobID: job.id) }
        )
    }

    private func metadataStatusText(_ job: TranscodeJob) -> String {
        switch job.metadataState {
        case .none: "未开始"
        case .searching: "匹配中…"
        case .needsReview: "待确认"
        case .confirmed: "已确认"
        case .failed: "匹配失败"
        }
    }

    private func metadataStatusColor(_ job: TranscodeJob) -> Color {
        switch job.metadataState {
        case .confirmed: Theme.success
        case .failed: Theme.warning
        case .searching, .needsReview: Theme.textPrimary
        case .none: Theme.textSecondary
        }
    }

    // MARK: 输出

    @ViewBuilder
    private func outputSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "输出") {
            InspectorRow(label: "预设", value: job.preset.name)
            InspectorRow(label: "容器", value: job.preset.container.displayName)
            InspectorRow(label: "编码", value: job.preset.videoCodec.displayName)
            InspectorRow(label: "分辨率", value: resolutionLabel(job))
            InspectorRow(label: "帧率", value: frameRateLabel(job))
            if let dims = targetDimensions(job) {
                InspectorRow(label: "码率", value: bitrateLabel(job, dims: dims))
            }
            if !job.preset.videoCodec.isProRes {
                InspectorRow(label: "关键帧", value: job.preset.keyframeInterval.displayName)
            }
            if job.preset.videoCodec == .h264, job.preset.profile != .auto {
                InspectorRow(label: "Profile", value: job.preset.profile.displayName)
            }
            InspectorRow(
                label: "音频",
                value: "\(job.preset.audio.codecLabel) · \(job.preset.audio.channelLabel)"
            )
            if let info = job.mediaInfo {
                // 预计大小（设计文档 §7.8）：有试编码实测时优先用实测外推并标注来源
                if let probe = job.probeResult {
                    let estimate = probe.estimatedBytes(forFullDuration: info.durationSeconds)
                    InspectorRow(label: "预计大小", value: "≈ \(Fmt.bytes(estimate))（试编码实测）")
                } else if let dims = targetDimensions(job) {
                    let estimate = job.preset.estimatedBytes(
                        durationSeconds: info.durationSeconds,
                        videoWidth: dims.width,
                        videoHeight: dims.height,
                        frameRate: info.video?.frameRate ?? 30
                    )
                    InspectorRow(label: "预计大小", value: "≈ \(Fmt.bytes(estimate))（按参数估算）")
                }

                // 试编码精确估算（设计文档 §7.8）：手动触发，仅排队中；探测中禁止重复
                if job.isProbing {
                    InspectorRow(label: "试编码", value: job.probeProgressText ?? "进行中…")
                } else if job.state == .queued {
                    TextButton(
                        title: job.probeResult == nil ? "试编码精确估算" : "重新试编码",
                        tint: Theme.accent
                    ) {
                        store.runProbe(jobID: job.id)
                    }
                }
                if let probe = job.probeResult {
                    InspectorRow(
                        label: "实测码率",
                        value: "\(Fmt.mbps(probe.averageBitrate)) · \(probe.segmentBitrates.count) 段 / \(String(format: "%.1f", probe.sampledSeconds)) 秒"
                    )
                }
            }
            InspectorRow(
                label: "输出文件",
                value: job.outputURL?.lastPathComponent ?? "开始时生成（重名加 -1）"
            )
            if job.state == .completed, let outputURL = job.outputURL {
                HStack {
                    TextButton(title: "在 Finder 中显示") {
                        store.revealInFinder(outputURL)
                    }
                    TextButton(title: "A/B 对比", tint: Theme.accent) {
                        if let context = store.compareContext(for: job.id) {
                            openCompare(context)
                        }
                    }
                }
            }
            if !job.notes.isEmpty {
                ForEach(job.notes, id: \.self) { note in
                    Text("· \(note)")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: 输出辅助（P3.5 / P4）

    /// 码率口径行：平均码率 / 质量优先 / 目标大小 / ProRes 标称。
    private func bitrateLabel(_ job: TranscodeJob, dims: (width: Int, height: Int)) -> String {
        let preset = job.preset
        if preset.videoCodec.isProRes {
            let rate = preset.averageBitrate(
                videoWidth: dims.width,
                videoHeight: dims.height,
                frameRate: job.mediaInfo?.video?.frameRate ?? 30
            )
            return "ProRes 标称 \(Fmt.mbps(rate))"
        }
        switch preset.bitrateMode {
        case .targetBitrate:
            let bitrate = preset.averageBitrate(videoWidth: dims.width, videoHeight: dims.height)
            return "\(Fmt.mbps(bitrate))（按像素缩放）"
        case .quality:
            return "质量优先 \(String(format: "%.2f", preset.quality))"
        case .targetSize:
            return "目标 ≈ \(preset.targetSizeMB) MB / 文件"
        }
    }

    /// 目标输出尺寸（短边匹配、只缩不放；画质修复 = 源 ×2）；无媒体信息时返回 nil。
    private func targetDimensions(_ job: TranscodeJob) -> (width: Int, height: Int)? {
        guard let video = job.mediaInfo?.video else { return nil }
        if job.enhancement != nil {
            return (video.displayWidth * 2, video.displayHeight * 2)
        }
        if let target = job.preset.resolution.renderSize(
            sourceWidth: video.displayWidth,
            sourceHeight: video.displayHeight
        ) {
            return (Int(target.width), Int(target.height))
        }
        return (video.displayWidth, video.displayHeight)
    }

    private func resolutionLabel(_ job: TranscodeJob) -> String {
        guard let video = job.mediaInfo?.video else { return job.preset.resolution.displayName }
        if job.enhancement != nil {
            return "\(video.displayWidth * 2)×\(video.displayHeight * 2)（画质修复 ×2）"
        }
        if let target = job.preset.resolution.renderSize(
            sourceWidth: video.displayWidth,
            sourceHeight: video.displayHeight
        ) {
            return "\(Int(target.width))×\(Int(target.height))（\(job.preset.resolution.displayName)）"
        }
        return "与源一致（不放大）"
    }

    private func frameRateLabel(_ job: TranscodeJob) -> String {
        guard let video = job.mediaInfo?.video else { return job.preset.frameRate.displayName }
        let fps = job.preset.frameRate.effectiveFrameRate(sourceFPS: video.frameRate)
        if job.preset.frameRate == .source {
            return "\(String(format: "%.0f", fps)) fps（保持源）"
        }
        return "\(String(format: "%.0f", fps)) fps"
    }

    // MARK: 音频响度（设计文档 §7.11）

    /// 响度标准化分区：排队中可编辑（开关 + 三档）；运行后只读。
    @ViewBuilder
    private func loudnessSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "音频响度") {
            if job.state == .queued {
                HStack(spacing: Theme.Spacing.s2) {
                    Toggle("响度标准化", isOn: Binding(
                        get: { job.loudness != nil },
                        set: { enabled in
                            store.setLoudness(
                                enabled ? (job.loudness ?? LoudnessSetting()) : nil,
                                jobID: job.id
                            )
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(Theme.TextStyle.body)
                    Spacer()
                }

                if let setting = job.loudness {
                    Picker("目标", selection: Binding(
                        get: { setting.target },
                        set: { newValue in
                            var updated = setting
                            updated.target = newValue
                            store.setLoudness(updated, jobID: job.id)
                        }
                    )) {
                        ForEach(LoudnessTarget.allCases) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(Theme.TextStyle.caption)
                    Text("转码时自动测量全片响度并拉齐到目标；增益受真峰上限 \(String(format: "%.0f", setting.peakCeilingDb)) dBTP 约束。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                InspectorRow(
                    label: "响度标准化",
                    value: job.loudness.map { "开启 · \($0.target.displayName)" } ?? "关闭"
                )
            }
        }
    }

    // MARK: 帧混合（设计文档 §7.12）

    /// 降帧感知分区：排队中可编辑；不降帧时提示开关不生效。
    @ViewBuilder
    private func frameBlendingSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "帧混合") {
            if job.state == .queued {
                Toggle("降帧时混合相邻帧", isOn: Binding(
                    get: { job.frameBlending },
                    set: { store.setFrameBlending($0, jobID: job.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.TextStyle.body)
                if !dropsFrames(job) {
                    Text("当前帧率档位不降帧，开关不生效。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("降帧时按时间位置加权混合窗口内相邻帧，减少运动卡顿感；体积可能略增。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                InspectorRow(label: "帧混合", value: job.frameBlending ? "开启" : "关闭")
            }
        }
    }

    /// 该任务是否真的在降帧（输出帧率 < 源帧率）。
    private func dropsFrames(_ job: TranscodeJob) -> Bool {
        guard let video = job.mediaInfo?.video else { return false }
        return job.preset.frameRate.effectiveFrameRate(sourceFPS: video.frameRate) < video.frameRate - 0.01
    }

    // MARK: 画质修复（设计文档 §7.6 / §8）

    /// 画质修复分区：排队中可编辑；运行后只读展示。
    @ViewBuilder
    private func enhancementSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "画质修复") {
            if job.state == .queued {
                HStack(spacing: Theme.Spacing.s2) {
                    Toggle("开启", isOn: Binding(
                        get: { job.enhancement != nil },
                        set: { enabled in
                            store.setEnhancement(
                                enabled ? (job.enhancement ?? .defaultNeural) : nil,
                                jobID: job.id
                            )
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(Theme.TextStyle.body)
                    Spacer()
                }

                if let setting = job.enhancement {
                    HStack(spacing: Theme.Spacing.s2) {
                        Picker("模式", selection: Binding(
                            get: { setting.mode },
                            set: { newValue in
                                var updated = setting
                                updated.mode = newValue
                                store.setEnhancement(updated, jobID: job.id)
                            }
                        )) {
                            Text(EnhancementMode.neural.displayName).tag(EnhancementMode.neural)
                            Text(EnhancementMode.filter.displayName).tag(EnhancementMode.filter)
                        }
                        .labelsHidden()
                        .fixedSize()

                        if setting.isNeural {
                            Picker("模型", selection: Binding(
                                get: { setting.neuralModel },
                                set: { newValue in
                                    var updated = setting
                                    updated.neuralModel = newValue
                                    store.setEnhancement(updated, jobID: job.id)
                                }
                            )) {
                                ForEach(NeuralUpscalerModel.allCases, id: \.self) { model in
                                    Text(model.shortName).tag(model)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Picker("强度", selection: Binding(
                            get: { setting.strength },
                            set: { newValue in
                                var updated = setting
                                updated.strength = newValue
                                store.setEnhancement(updated, jobID: job.id)
                            }
                        )) {
                            ForEach(EnhancementStrength.allCases, id: \.self) { strength in
                                Text(strength.displayName).tag(strength)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                    }

                    Text("输出 \(targetDimensions(job).map { "\(Int($0.width))×\(Int($0.height))" } ?? "源 ×2")；\(setting.speedHint)")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if setting.isNeural, let video = job.mediaInfo?.video,
                       max(video.displayWidth, video.displayHeight) >= 3840 {
                        Text("4K→8K 超分很慢（快速档约 0.03–0.04x 实时），请留意预计耗时。")
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            } else if let setting = job.enhancement {
                InspectorRow(label: "模式", value: setting.summary)
                InspectorRow(label: "管线", value: setting.pipelineDescription)
            } else {
                InspectorRow(label: "画质修复", value: "关闭")
            }
        }
    }

    // MARK: 硬件

    @ViewBuilder
    private func hardwareSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "硬件") {
            HStack(spacing: Theme.Spacing.s1) {
                if let encoder = store.capabilities?.hardwareEncoder(for: job.preset.videoCodec) {
                    AcceleratorBadge(kind: .hardware)
                    Text(encoder.name)
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    AcceleratorBadge(kind: .software)
                    Text("没有可用的硬件编码器")
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.warning)
                }
            }
            Text("强制硬件编码（RequireHardwareAcceleratedVideoEncoder），不做静默软件回退。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: 错误

    @ViewBuilder
    private func errorSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "错误") {
            if let error = job.errorText {
                Text(error)
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.error)
                    .textSelection(.enabled)
                TextButton(title: "复制详情") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(error, forType: .string)
                }
            } else {
                InspectorRow(label: "状态", value: idleStatusText(job))
            }

            if !job.verificationIssues.isEmpty {
                ForEach(job.verificationIssues, id: \.self) { issue in
                    Text("· \(issue)")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.warning)
                        .textSelection(.enabled)
                }
            }

            if job.state.isRetryable {
                TextButton(title: "重试任务", tint: Theme.accent) {
                    store.retryJob(job.id)
                }
            }
        }
    }

    /// 无错误文本时的状态说明（取消/中断都可重试）。
    private func idleStatusText(_ job: TranscodeJob) -> String {
        switch job.state {
        case .interrupted: "已中断（可重试）"
        case .cancelled: "已取消（可重试）"
        default: "无"
        }
    }
}

/// 检查器分区：标题 11px 大写 Secondary（设计文档 §8.6）。
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
            Text(title.uppercased())
                .font(Theme.TextStyle.inspectorHeader)
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondary)
            content
        }
    }
}

/// 键值行：标签 11px Secondary、值 13px Primary。
struct InspectorRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s2) {
            Text(label)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(Theme.TextStyle.body)
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
