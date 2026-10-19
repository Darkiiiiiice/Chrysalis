import SwiftUI

/// 设置页（设计文档 §8.6）：P2 先提供「硬件」分组（能力矩阵只读）。
struct SettingsScreen: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                    hardwareSection
                }
                .padding(Theme.Size.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("设置")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("硬件能力（只读）")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Size.contentInset)
        .frame(height: 44)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var hardwareSection: some View {
        InspectorSection(title: "硬件") {
            if let capabilities = store.capabilities {
                encoderRow(family: "H.264", codec: .h264, capabilities: capabilities)
                encoderRow(family: "HEVC", codec: .hevc, capabilities: capabilities)
                encoderRow(family: "ProRes", codec: .proRes422, capabilities: capabilities)
                decoderRow(capabilities.h264HardwareDecode)

                Text("转码强制硬件编码（RequireHardwareAcceleratedVideoEncoder）；没有对应硬件编码器时任务在准备阶段失败，不做静默软件回退。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在检测硬件能力…")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func encoderRow(family: String, codec: VideoCodec, capabilities: HardwareCapabilities) -> some View {
        HStack(spacing: Theme.Spacing.s1) {
            StatusDot(color: capabilities.hardwareEncoder(for: codec) != nil ? Theme.success : Theme.textSecondary)
            Text(family)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text(capabilities.hardwareEncoder(for: codec)?.name ?? "无硬件编码器")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func decoderRow(_ supported: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s1) {
            StatusDot(color: supported ? Theme.success : Theme.textSecondary)
            Text("解码")
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text(supported ? "H.264 硬件解码可用" : "无 H.264 硬件解码")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}
