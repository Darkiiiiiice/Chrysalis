import CoreGraphics
import SwiftUI

/// 任务行（设计文档 §8.4）：64px、hover/选中 surface、选中左侧 2px accent 竖线、底部 2px 进度线。
struct JobRowView: View {
    @Environment(QueueStore.self) private var store

    let job: TranscodeJob
    let thumbnail: CGImage?

    @State private var isHovered = false

    private var isSelected: Bool { store.selectedJobID == job.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s2) {
                thumbnailView
                titleAndMeta
                Spacer(minLength: Theme.Spacing.s1)
                trailingCluster
            }
            .padding(.horizontal, Theme.Size.contentInset)
            .frame(height: Theme.Size.queueRowHeight)
            .background(rowBackground)

            progressSection
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedJobID = job.id
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(Theme.Motion.hover, value: isHovered)
    }

    // MARK: 缩略图

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.surface
                    Image(systemName: "film")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
            }
        }
        .frame(width: Theme.Size.thumbnailWidth, height: Theme.Size.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    // MARK: 标题

    private var titleAndMeta: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.displayName)
                .font(Theme.TextStyle.bodyEmphasized)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(secondaryLine)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var secondaryLine: String {
        if job.state == .queued, job.mediaKind == .movie {
            switch job.metadataState {
            case .searching: return "电影 · 匹配元数据中…"
            case .confirmed: return "电影 · \(job.metaLine)"
            case .failed: return "电影 · 匹配失败，可手动填写"
            case .needsReview, .none: return "电影 · 元数据待确认"
            }
        }
        switch job.state {
        case .preparing: return "准备中…"
        case .cancelling: return "取消中…"
        case .interrupted: return "已中断（可重试）"
        case .failed(let message): return "失败：\(message)"
        default: return job.metaLine
        }
    }

    private var secondaryColor: Color {
        if case .failed = job.state { return Theme.error }
        if job.state == .interrupted { return Theme.warning }
        if job.state == .queued, job.mediaKind == .movie, !job.metadataState.isConfirmed {
            return Theme.warning
        }
        return Theme.textSecondary
    }

    // MARK: 右侧信息簇

    private var trailingCluster: some View {
        HStack(spacing: Theme.Spacing.s1) {
            StatusDot(color: dotColor, breathing: job.state.isActive)
            PresetChip(title: job.preset.name)
            acceleratorBadge
            statusNumbers

            if job.state.isRetryable {
                IconButton(systemImage: "arrow.clockwise", help: "重试") {
                    store.retryJob(job.id)
                }
            }

            if shouldShowCancel {
                IconButton(systemImage: "xmark.circle", help: "取消任务") {
                    store.cancelJob(job.id)
                }
            }

            IconButton(systemImage: "info.circle", help: "查看详情（检查器）") {
                store.openInspector(for: job.id)
            }
        }
    }

    @ViewBuilder
    private var acceleratorBadge: some View {
        if let capabilities = store.capabilities,
           capabilities.hardwareEncoder(for: job.preset.videoCodec) != nil {
            AcceleratorBadge(kind: .hardware)
        }
    }

    @ViewBuilder
    private var statusNumbers: some View {
        switch job.state {
        case .running:
            Text(Fmt.percent(job.progress?.fraction ?? 0))
                .font(Theme.TextStyle.numeric)
                .foregroundStyle(Theme.textPrimary)
            if let progress = job.progress {
                Text(Fmt.speed(progress.speed))
                    .font(Theme.TextStyle.numericSmall)
                    .foregroundStyle(Theme.textSecondary)
                if let eta = progress.etaSeconds {
                    Text(Fmt.duration(seconds: eta))
                        .font(Theme.TextStyle.numericSmall)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        case .completed:
            if let bytes = job.outputBytes {
                Text(Fmt.bytes(bytes))
                    .font(Theme.TextStyle.numericSmall)
                    .foregroundStyle(Theme.textSecondary)
            }
        default:
            EmptyView()
        }
    }

    private var shouldShowCancel: Bool {
        (job.state.isActive || job.state == .queued) && isHovered
    }

    private var dotColor: Color {
        switch job.state {
        case .queued, .preparing, .running, .finishing: Theme.accent
        case .cancelling: Theme.warning
        case .completed: Theme.success
        case .cancelled: Theme.textSecondary
        case .interrupted: Theme.warning
        case .failed: Theme.error
        }
    }

    private var rowBackground: Color {
        (isHovered || isSelected) ? Theme.surface : .clear
    }

    // MARK: 进度线

    @ViewBuilder
    private var progressSection: some View {
        switch job.state {
        case .queued, .preparing:
            EmptyView()
        case .running:
            ProgressLine(fraction: job.progress?.fraction ?? 0, color: Theme.accent)
        case .finishing, .cancelling:
            ProgressLine(fraction: 1, color: Theme.accent)
        case .completed:
            ProgressLine(fraction: 1, color: Theme.success)
        case .cancelled:
            ProgressLine(fraction: 1, color: Theme.textSecondary)
        case .interrupted:
            ProgressLine(fraction: job.progress?.fraction ?? 1, color: Theme.warning)
        case .failed:
            ProgressLine(fraction: 1, color: Theme.error)
        }
    }
}
