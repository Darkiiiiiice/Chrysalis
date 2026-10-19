import AppKit
import SwiftUI

/// 检查器（设计文档 §8.6）：304px、surfaceElevated、左侧 1px border；
/// 分区：输入 / 输出 / 硬件 / 错误。
struct InspectorView: View {
    @Environment(QueueStore.self) private var store

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
            if let info = job.mediaInfo, let dims = targetDimensions(job) {
                let estimate = job.preset.estimatedBytes(
                    durationSeconds: info.durationSeconds,
                    videoWidth: dims.width,
                    videoHeight: dims.height,
                    frameRate: info.video?.frameRate ?? 30
                )
                InspectorRow(label: "预计大小", value: "≈ \(Fmt.bytes(estimate))")
            }
            InspectorRow(
                label: "输出文件",
                value: job.outputURL?.lastPathComponent ?? "开始时生成（重名加 -1）"
            )
            if job.state == .completed, let outputURL = job.outputURL {
                TextButton(title: "在 Finder 中显示") {
                    store.revealInFinder(outputURL)
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

    /// 目标输出尺寸（短边匹配、只缩不放）；无媒体信息时返回 nil。
    private func targetDimensions(_ job: TranscodeJob) -> (width: Int, height: Int)? {
        guard let video = job.mediaInfo?.video else { return nil }
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
