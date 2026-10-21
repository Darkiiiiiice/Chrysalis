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
        // 键盘可达（设计文档 §8.7「全键盘可达」）：Tab 可聚焦到任务行，回车打开检查器。
        .focusable(true)
        .onKeyPress(.return) {
            store.selectedJobID = job.id
            store.openInspector(for: job.id)
            return .handled
        }
        .contextMenu {
            if job.mediaKind == .movie, !job.metadataState.isConfirmed {
                Button("确认元数据…") {
                    store.confirmMovieContext = ConfirmMovieContext(id: job.id)
                }
                Divider()
            }
            if job.state.isRetryable {
                Button("重试") {
                    store.retryJob(job.id)
                }
            }
            if job.state.isActive || job.state == .queued {
                Button("取消任务") {
                    store.cancelJob(job.id)
                }
            }
            if job.state == .completed, let outputURL = job.outputURL {
                Button("在 Finder 中显示") {
                    store.revealInFinder(outputURL)
                }
            }
            if job.state.isTerminal {
                Divider()
                Button("移除任务") {
                    store.removeJob(job.id)
                }
            }
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
        // VoiceOver：读出文件名 + 状态 + 进度 + 速度 + 错误（设计文档 §8.7）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(job.displayName)
        .accessibilityValue(accessibilitySummary)
    }

    /// VoiceOver 摘要：状态、进度、速度、剩余时间、错误原因。
    private var accessibilitySummary: String {
        var parts: [String] = ["预设 \(job.preset.name)", accessibilityStateText]

        switch job.state {
        case .running:
            if let progress = job.progress {
                parts.append("进度 \(Fmt.percent(progress.fraction))")
                parts.append("速度 \(Fmt.speed(progress.speed))")
                if let eta = progress.etaSeconds {
                    parts.append("剩余 \(Fmt.duration(seconds: eta))")
                }
            }
        case .failed(let message):
            parts.append("错误：\(message)")
        default:
            break
        }

        if job.mediaKind == .movie {
            parts.append(movieAccessibilityText)
        }
        return parts.joined(separator: "，")
    }

    private var accessibilityStateText: String {
        switch job.state {
        case .queued: "排队中"
        case .preparing: "准备中"
        case .running: "转码中"
        case .finishing: "写入中"
        case .cancelling: "取消中"
        case .completed: "已完成"
        case .cancelled: "已取消，可重试"
        case .interrupted: "已中断，可重试"
        case .failed: "失败"
        }
    }

    private var movieAccessibilityText: String {
        switch job.metadataState {
        case .confirmed:
            if let metadata = job.movieMetadata {
                let year = metadata.year.map { "（\($0)）" } ?? ""
                return "电影，已确认《\(metadata.title)》\(year)"
            }
            return "电影，元数据已确认"
        case .searching:
            return "电影，匹配元数据中"
        case .needsReview:
            return "电影，元数据待确认"
        case .failed:
            return "电影，匹配失败"
        case .none:
            return "电影，未开始匹配"
        }
    }

    private var secondaryLine: String {
        if job.state == .queued, job.mediaKind == .movie {
            switch job.metadataState {
            case .searching: return "电影 · 匹配元数据中…"
            case .confirmed:
                if let metadata = job.movieMetadata {
                    let year = metadata.year.map { "（\($0)）" } ?? ""
                    return "电影 · 已确认《\(metadata.title)》\(year)"
                }
                return "电影 · \(job.metaLine)"
            case .failed:
                if let summary = store.matchedSummary(jobID: job.id) {
                    return "电影 · \(matchedLabel(summary))，确认后可转码"
                }
                return "电影 · 匹配失败，可手动填写"
            case .needsReview, .none:
                if let summary = store.matchedSummary(jobID: job.id) {
                    return "电影 · \(matchedLabel(summary))"
                }
                return "电影 · 元数据待确认"
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

    private func matchedLabel(_ summary: TMDBMovieSummary) -> String {
        let year = summary.year.map { "（\($0)）" } ?? ""
        return "已匹配《\(summary.title)》\(year)（待确认）"
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
                .accessibilityHidden(true)
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

            if job.state.isTerminal {
                IconButton(systemImage: "trash", help: "移除任务") {
                    store.removeJob(job.id)
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
