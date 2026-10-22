import SwiftUI
import UniformTypeIdentifiers

/// 音频工具页（设计文档 §7.17，灵感 13）：选视频 → 轨道信息 + 波形预览 → 提取导出。
struct AudioToolsScreen: View {
    @Environment(AudioToolsStore.self) private var store
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
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("音频工具")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("拖入视频文件，预览音轨波形并提取为 M4A 或 WAV。\n提取保持源采样率与声道数，不改画面、不进转码队列。")
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                header
                waveformSection
                exportSection
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
            TextButton(title: "换一个文件…", isEnabled: !store.isExtracting) {
                isImporterPresented = true
            }
        }
    }

    @ViewBuilder
    private var waveformSection: some View {
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
            } else if let message = store.message {
                Text(message)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.error)
            }
        }
    }

    @ViewBuilder
    private var exportSection: some View {
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
                    isEnabled: store.canExtract
                ) {
                    store.extract()
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
