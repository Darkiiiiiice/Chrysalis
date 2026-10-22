import SwiftUI
import UniformTypeIdentifiers

/// 导出工具页（设计文档 §7.17 / §7.18）：音频提取 / GIF 动图 / 雪碧图三分区，选中文件共享。
struct ExportToolsScreen: View {
    @Environment(ExportToolsStore.self) private var store
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.selectedURL != nil {
                toolView
            } else {
                emptyState
            }
        }
        .background(Theme.bg)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .mpeg4Movie, .video]
        ) { result in
            if case .success(let url) = result {
                store.select(url: url)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.select(url: url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("导出工具")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("拖入视频文件：提取音频（M4A / WAV）、导出 GIF 动图或缩略图雪碧图。\n衍生品导出不进转码队列，只读分析、仅在导出时写盘。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            TextButton(title: "选择文件…") {
                isImporterPresented = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(16)
            }
        }
    }

    // MARK: 工具页

    private var toolView: some View {
        @Bindable var store = store
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                header
                Picker("工具", selection: $store.selectedTab) {
                    ForEach(ExportToolsStore.ToolTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                switch store.selectedTab {
                case .audio:
                    audioSection
                case .gif:
                    gifSection
                case .sprite:
                    spriteSection
                }
            }
            .padding(Theme.Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if let message = store.message {
                Text(message)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceElevated, in: Capsule())
                    .padding(.bottom, 12)
                    .onTapGesture { store.clearMessage() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedURL?.lastPathComponent ?? "")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.selectedURL?.path ?? "")
                if let analysis = store.analysis {
                    Text("\(analysis.channels) 声道 · \(Int(analysis.sampleRate)) Hz · \(Fmt.duration(seconds: analysis.durationSeconds))")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            TextButton(title: "换一个文件…", isEnabled: !store.isBusy) {
                isImporterPresented = true
            }
        }
    }

    // MARK: 音频提取（灵感 13）

    @ViewBuilder
    private var audioSection: some View {
        InspectorSection(title: "波形预览") {
            if store.isAnalyzing {
                Text("计算波形中…（读全片音频，长片需几秒）")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else if let analysis = store.analysis {
                WaveformView(envelope: analysis.envelope)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                if analysis.envelope.isSilent {
                    Text("波形全静音：音轨可能无有效内容。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.warning)
                }
            } else if store.hasNoAudioTrack {
                Text("该文件没有音轨，无法提取。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        InspectorSection(title: "提取导出") {
            HStack(spacing: Theme.Spacing.s2) {
                Picker("格式", selection: Binding(
                    get: { store.format },
                    set: { store.format = $0 }
                )) {
                    ForEach(AudioExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()

                PrimaryButton(
                    title: store.isExtracting ? "提取中…" : "提取音频",
                    systemImage: "arrow.down.doc",
                    isEnabled: store.canExtractAudio
                ) {
                    store.extractAudio()
                }

                if store.isExtracting {
                    ProgressView(value: max(store.progress, 0.02))
                        .frame(maxWidth: 200)
                    Text(Fmt.percent(store.progress))
                        .font(Theme.TextStyle.numeric)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            Text("\(store.format.displayName)：\(store.format.summary)。输出写到源文件所在目录，重名自动加 -1。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            if let exportURL = store.exportURL {
                TextButton(title: "在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([exportURL])
                }
            }
        }
    }

    // MARK: GIF 动图（灵感 14）

    @ViewBuilder
    private var gifSection: some View {
        InspectorSection(title: "GIF 动图") {
            HStack(spacing: Theme.Spacing.s2) {
                Picker("宽度", selection: Binding(
                    get: { store.gifWidth },
                    set: { store.gifWidth = $0 }
                )) {
                    ForEach(GifWidth.allCases) { width in
                        Text(width.displayName).tag(width)
                    }
                }
                .labelsHidden()
                .fixedSize()

                PrimaryButton(
                    title: store.isExportingGif ? "导出中…" : "导出 GIF",
                    systemImage: "film",
                    isEnabled: store.canExportGif
                ) {
                    store.exportGif()
                }

                if store.isExportingGif {
                    ProgressView(value: max(store.gifProgress, 0.02))
                        .frame(maxWidth: 200)
                    Text(Fmt.percent(store.gifProgress))
                        .font(Theme.TextStyle.numeric)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            Text("12 fps · 无限循环 · \(store.gifWidth.displayName)；输出写到源文件所在目录，重名自动加 -1。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            if let duration = gifDuration, duration > GifWidth.longClipSeconds {
                Text("时长超过 60 秒：GIF 体积可能很大，建议选择更短片段的源文件。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
            }
            if let gifExportURL = store.gifExportURL {
                TextButton(title: "在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([gifExportURL])
                }
            }
        }
    }

    private var gifDuration: Double? {
        store.analysis?.durationSeconds
    }

    // MARK: 雪碧图（灵感 14）

    @ViewBuilder
    private var spriteSection: some View {
        InspectorSection(title: "缩略图雪碧图") {
            HStack(spacing: Theme.Spacing.s2) {
                Picker("网格", selection: Binding(
                    get: { store.spriteLayout },
                    set: { store.spriteLayout = $0 }
                )) {
                    ForEach(SpriteLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .labelsHidden()
                .fixedSize()

                PrimaryButton(
                    title: store.isExportingSprite ? "生成中…" : "生成雪碧图",
                    systemImage: "grid",
                    isEnabled: store.canExportSprite
                ) {
                    store.exportSprite()
                }

                if store.isExportingSprite {
                    ProgressView(value: max(store.spriteProgress, 0.02))
                        .frame(maxWidth: 200)
                    Text(Fmt.percent(store.spriteProgress))
                        .font(Theme.TextStyle.numeric)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            Text("单帧宽 320 等比、JPEG 输出；时间点均匀覆盖全片，输出写到源文件所在目录，重名自动加 -1。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            if let spriteExportURL = store.spriteExportURL,
               let image = NSImage(contentsOf: spriteExportURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }
            }
            if let spriteExportURL = store.spriteExportURL {
                TextButton(title: "在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([spriteExportURL])
                }
            }
        }
    }
}

// MARK: - 波形绘制

/// 波形包络图：每桶一根竖线（min→max），单强调色（设计文档 §7.17）。
struct WaveformView: View {
    let envelope: WaveformEnvelope

    var body: some View {
        Canvas { context, size in
            let count = envelope.maxima.count
            guard count > 0 else { return }
            let bucketWidth = size.width / CGFloat(count)
            let barWidth = max(bucketWidth - 1, 1)
            let midY = size.height / 2
            for index in 0..<count {
                let low = CGFloat(envelope.minima[index])
                let high = CGFloat(envelope.maxima[index])
                let top = midY - high * midY
                let bottom = midY + low * midY
                let rect = CGRect(
                    x: CGFloat(index) * bucketWidth,
                    y: top,
                    width: barWidth,
                    height: max(bottom - top, 1)
                )
                context.fill(Path(rect), with: .color(Theme.accent.opacity(0.85)))
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }
}
