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

    // MARK: 输出

    @ViewBuilder
    private func outputSection(_ job: TranscodeJob) -> some View {
        InspectorSection(title: "输出") {
            InspectorRow(label: "预设", value: job.preset.name)
            InspectorRow(label: "容器", value: job.preset.container.displayName)
            InspectorRow(label: "编码", value: job.preset.videoCodec.displayName)
            InspectorRow(label: "分辨率", value: "与源一致（不放大）")
            InspectorRow(label: "帧率", value: "保持源帧率")
            InspectorRow(label: "音频", value: "AAC \(job.preset.audio.bitrate / 1000) kbps")
            if let info = job.mediaInfo, let video = info.video {
                let estimate = job.preset.estimatedBytes(
                    durationSeconds: info.durationSeconds,
                    videoWidth: video.displayWidth,
                    videoHeight: video.displayHeight
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
                InspectorRow(label: "状态", value: "无")
            }

            if !job.verificationIssues.isEmpty {
                ForEach(job.verificationIssues, id: \.self) { issue in
                    Text("· \(issue)")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.warning)
                        .textSelection(.enabled)
                }
            }
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
