import SwiftUI

/// 队列主内容：头部、横幅、任务列表 / 空状态、底部状态栏、全局进度线（设计文档 §8.3 / §8.6）。
struct QueueContentView: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            if let banner = store.banner {
                InlineBanner(kind: banner.kind, message: banner.message) {
                    store.dismissBanner()
                }
                Rectangle().fill(Theme.border).frame(height: 1)
            }

            content
            Rectangle().fill(Theme.border).frame(height: 1)
            statusBar

            // 窗口底部 2px 全局进度线，只在批量运行时出现
            if let fraction = store.aggregateProgress {
                ProgressLine(fraction: fraction, color: Theme.accent)
            }
        }
        .background(Theme.bg)
        .dropDestination(for: URL.self) { urls, _ in
            store.prepareAdd(urls)
            return true
        } isTargeted: { targeted in
            store.isDropTargeted = targeted
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("队列")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)

            if !store.jobs.isEmpty {
                Text("\(store.jobs.count) 个任务")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            TextButton(title: "清除已结束", isEnabled: store.finishedCount > 0) {
                store.clearFinished()
            }
        }
        .padding(.horizontal, Theme.Size.contentInset)
        .frame(height: 44)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var content: some View {
        if store.jobs.isEmpty {
            DropZoneView()
                .padding(Theme.Size.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            QueueList()
        }
    }

    private var statusBar: some View {
        HStack(spacing: Theme.Spacing.s2) {
            Button {
                store.openOutputFolderInFinder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(store.outputDirectoryDisplayPath ?? "未选择输出文件夹")
                }
                .font(Theme.TextStyle.caption)
                .foregroundStyle(store.outputDirectory == nil ? Theme.warning : Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.outputDirectory?.path ?? "点击选择输出文件夹")
            .disabled(store.outputDirectory == nil)

            Spacer()

            if let fraction = store.aggregateProgress {
                Text(Fmt.percent(fraction))
                    .font(Theme.TextStyle.numericSmall)
                    .foregroundStyle(Theme.textPrimary)
            }
            if store.runningCount > 0 {
                Text("\(store.runningCount) 个进行中")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Size.contentInset)
        .frame(height: 32)
        .background(Theme.surface)
    }
}

/// 任务列表：保持添加顺序、行间 1px 分隔线、不用圆角卡片（设计文档 §8.4 / §8.6）。
struct QueueList: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.jobs) { job in
                    JobRowView(job: job, thumbnail: store.thumbnails[job.id])

                    if job.id != store.jobs.last?.id {
                        Rectangle()
                            .fill(Theme.border)
                            .frame(height: 1)
                            .padding(.leading, Theme.Size.contentInset)
                    }
                }
            }
        }
        .background(Theme.bg)
    }
}
