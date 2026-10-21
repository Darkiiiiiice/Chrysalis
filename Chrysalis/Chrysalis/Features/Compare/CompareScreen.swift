import SwiftUI

/// A/B 质量对比窗口（设计文档 §7.9）：规格条 + 双模式画布 + 播放控制。
struct CompareScreen: View {
    @State private var store: CompareStore
    /// 进度条拖动中的临时值（松手才 seek）。
    @State private var scrubbingSeconds: Double?
    @State private var isScrubbing = false

    init(context: CompareContext) {
        _store = State(initialValue: CompareStore(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.sourceAvailable || !store.outputAvailable {
                degradedBanner
            }
            specBar
            playerArea
            controlBar
        }
        .background(Theme.bg)
        .frame(minWidth: 920, minHeight: 600)
        .navigationTitle(store.context.title)
        .task { await store.setup() }
        .onDisappear { store.teardown() }
    }

    // MARK: 规格条

    private var specBar: some View {
        HStack(alignment: .top, spacing: 0) {
            specColumn(
                tag: "A 原片",
                name: store.sourceInfo.map { _ in store.context.sourceURL.lastPathComponent },
                info: store.sourceInfo,
                accent: false
            )
            Divider()
                .frame(height: 34)
                .padding(.horizontal, 14)
            specColumn(
                tag: "B 输出",
                name: store.outputInfo.map { _ in store.context.outputURL.lastPathComponent },
                info: store.outputInfo,
                accent: true
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    private func specColumn(tag: String, name: String?, info: MediaInfo?, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tag)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(accent ? Theme.accent : Theme.textSecondary)
                if let name {
                    Text(name)
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            if let info {
                Text(CompareSpecs.summaryLine(info))
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            } else {
                Text("规格不可用")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: 画布

    private var playerArea: some View {
        GeometryReader { proxy in
            ZStack {
                if store.sourcePlayer == nil && store.outputPlayer == nil {
                    emptyState
                } else {
                    ComparePlayerView(store: store)
                    badges
                    if store.mode == .wipe {
                        wipeHandle(size: proxy.size)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }

    /// A / B 角标（wipe 左右各一；并排两半各一）。
    private var badges: some View {
        VStack {
            HStack(alignment: .top) {
                badge("A 原片")
                Spacer()
                badge("B 输出")
            }
            Spacer()
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
    }

    /// wipe 分割线（全高）与拖动把手（垂直居中）。
    private func wipeHandle(size: CGSize) -> some View {
        let x = size.width * store.splitPosition
        return ZStack {
            Rectangle()
                .fill(Theme.accent.opacity(0.9))
                .frame(width: 1.5, height: size.height)
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                )
        }
        .frame(width: 28, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    store.splitPosition = max(0.05, min(0.95, value.location.x / max(size.width, 1)))
                }
        )
        .position(x: x, y: size.height / 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Theme.warning)
            Text("原片与输出均不可访问")
                .foregroundStyle(Theme.textPrimary)
            Text("文件可能已被移动或删除。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: 控制条

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                store.togglePlay()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(store.sourcePlayer == nil && store.outputPlayer == nil)

            Text(Fmt.duration(seconds: scrubSeconds))
                .font(Theme.TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 108, alignment: .leading)

            Slider(
                value: Binding(
                    get: { scrubSeconds },
                    set: { scrubbingSeconds = $0 }
                ),
                in: 0...max(store.durationSeconds, 0.1)
            ) { editing in
                isScrubbing = editing
                if !editing {
                    store.seek(toFraction: (scrubbingSeconds ?? 0) / max(store.durationSeconds, 0.1))
                    scrubbingSeconds = nil
                }
            }
            .disabled(store.durationSeconds <= 0)

            Picker("模式", selection: Binding(
                get: { store.mode },
                set: { store.setMode($0) }
            )) {
                ForEach(CompareStore.Mode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("音源", selection: Binding(
                get: { store.audioSource },
                set: { store.setAudioSource($0) }
            )) {
                ForEach(CompareStore.AudioSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    /// 拖动中优先展示临时值。
    private var scrubSeconds: Double {
        isScrubbing ? (scrubbingSeconds ?? store.currentSeconds) : store.currentSeconds
    }

    // MARK: 降级

    private var degradedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(degradedMessage)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated)
    }

    private var degradedMessage: String {
        switch (store.sourceAvailable, store.outputAvailable) {
        case (false, true): "原片不可访问（可能已被移动或删除）：仅显示输出。"
        case (true, false): "输出文件不可访问（可能已被清理）：仅显示原片。"
        default: ""
        }
    }
}
