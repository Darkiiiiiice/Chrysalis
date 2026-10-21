import SwiftUI

/// 侧边栏导航项（P1 只有「队列」可用，其余为占位）。
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case queue
    case presets
    case subtitles
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: "队列"
        case .presets: "预设"
        case .subtitles: "字幕"
        case .history: "历史"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .queue: "rectangle.stack"
        case .presets: "slider.horizontal.3"
        case .subtitles: "text.quote"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// 侧边栏：导航 + 底部固定硬件状态（设计文档 §8.3）。
struct SidebarView: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.sidebarSelection) {
            ForEach(SidebarItem.allCases) { item in
                row(for: item)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HardwareStatusFooter()
        }
        .navigationSplitViewColumnWidth(Theme.Size.sidebarWidth)
    }

    @ViewBuilder
    private func row(for item: SidebarItem) -> some View {
        if item == .queue, !store.jobs.isEmpty {
            Label(item.title, systemImage: item.systemImage)
                .badge(store.jobs.count)
        } else {
            Label(item.title, systemImage: item.systemImage)
        }
    }
}

/// 硬件状态：绿点 + `HW · H.264 / HEVC / ProRes`；不可用时灰点 + 原因（设计文档 §8.3）。
struct HardwareStatusFooter: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        HStack(spacing: Theme.Spacing.s1) {
            StatusDot(color: statusColor)
            Text(statusText)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.s2)
        .padding(.vertical, Theme.Spacing.s1)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .help(statusText)
    }

    private var statusColor: Color {
        store.capabilities?.isReady == true ? Theme.success : Theme.textSecondary
    }

    private var statusText: String {
        guard let capabilities = store.capabilities else { return "正在检测硬件能力…" }
        return capabilities.summaryText
    }
}
