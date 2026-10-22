import SwiftUI
import UniformTypeIdentifiers

/// 字幕模块（设计文档 §7.7 / §8）：文件列表 + 质检报告 + 修复确认流。
struct SubtitlesScreen: View {
    @Environment(SubtitleStore.self) private var store
    @State private var isImporterPresented = false
    @State private var isTranscribeImporterPresented = false
    @State private var isTranscribeSheetPresented = false
    @State private var transcribeVideoURL: URL?
    @State private var selectedRules: Set<SubtitleRule> = []
    @State private var insightsSession = SubtitleInsightsSession()
    @State private var insightsAvailability: SubtitleInsightAvailability = .deviceUnsupported
    @State private var exportedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            if store.items.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(Theme.bg)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.subtitleTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                store.load(urls: urls)
            case .failure(let error):
                print("选择字幕失败：\(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $isTranscribeImporterPresented,
            allowedContentTypes: [.movie, .mpeg4Movie, .video]
        ) { result in
            switch result {
            case .success(let url):
                transcribeVideoURL = url
                isTranscribeSheetPresented = true
            case .failure(let error):
                print("选择视频失败：\(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $isTranscribeSheetPresented) {
            if let url = transcribeVideoURL {
                TranscribeSheet(videoURL: url)
            }
        }
        .onAppear {
            syncSelectedRules()
            insightsAvailability = SubtitleInsightAvailability.current()
        }
        .onChange(of: store.selection) { _, _ in
            syncSelectedRules()
        }
    }

    /// 字幕文件类型（ass/ssa/srt/vtt + 纯文本兜底）。
    private static var subtitleTypes: [UTType] {
        var types: [UTType] = [.plainText]
        for ext in ["ass", "ssa", "srt", "vtt"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s2) {
            Text("字幕")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("质检与适配（静态规则，不承诺播放器像素级渲染一致）")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            IconButton(systemImage: "waveform.badge.mic", help: "语音转字幕") {
                isTranscribeImporterPresented = true
            }
            IconButton(systemImage: "plus", help: "添加字幕文件") {
                isImporterPresented = true
            }
        }
        .padding(.horizontal, Theme.Spacing.s3)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.s3) {
            Image(systemName: "text.quote")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
            VStack(spacing: Theme.Spacing.s1) {
                Text("拖入或添加字幕文件")
                    .font(Theme.TextStyle.section)
                    .foregroundStyle(Theme.textPrimary)
                Text("支持 ASS / SSA / SRT / VTT；自动检测时间轴、双语对齐、样式字体与定位问题，修复会生成 -fixed 副本，不覆盖原文件。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            PrimaryButton(title: "添加字幕文件", systemImage: "plus") {
                isImporterPresented = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            fileList
                .frame(width: 320)
            Rectangle().fill(Theme.border).frame(width: 1)
            detailPane
        }
    }

    // MARK: 文件列表

    private var fileList: some View {
        @Bindable var store = store
        return List(selection: $store.selection) {
            ForEach(store.items) { item in
                HStack(spacing: Theme.Spacing.s2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName)
                            .font(Theme.TextStyle.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(listSubtitle(item))
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if item.isFixed {
                        PresetChip(title: "已修复")
                    }
                }
                .tag(item.id)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    if let item = store.items[safe: index] {
                        store.remove(id: item.id)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func listSubtitle(_ item: SubtitleItem) -> String {
        if let error = item.errorText { return error }
        return "\(item.document.format.displayName) · \(item.report.cueCount) 条 · 错误 \(item.report.errorCount) / 警告 \(item.report.warningCount)"
    }

    // MARK: 详情与修复

    @ViewBuilder
    private var detailPane: some View {
        ScrollView {
            if let item = store.selectedItem {
                VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                    if let error = item.errorText {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.TextStyle.body)
                            .foregroundStyle(Theme.error)
                    } else {
                        if item.isTranscribed {
                            transcribedBanner(item)
                        }
                        overviewSection(item)
                        reportSection(item)
                        fixSection(item)
                        insightsSection(item)
                    }
                    HStack {
                        if item.isTranscribed {
                            TextButton(title: "导出 SRT", isEnabled: !item.document.cues.isEmpty) {
                                exportedPath = store.exportTranscript(itemID: item.id, format: .srt)?.path
                            }
                            TextButton(title: "导出 ASS", isEnabled: !item.document.cues.isEmpty) {
                                exportedPath = store.exportTranscript(itemID: item.id, format: .ass)?.path
                            }
                        }
                        TextButton(title: "在 Finder 中显示") {
                            store.revealInFinder(item.url)
                        }
                        TextButton(title: "移除") {
                            store.remove(id: item.id)
                        }
                        Spacer()
                    }
                }
                .padding(Theme.Spacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 语音识别结果条目顶部提示（内存态 + 导出说明）。
    private func transcribedBanner(_ item: SubtitleItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
            Label("语音识别结果（设备端处理，未保存到磁盘）——预览确认后导出 SRT / ASS", systemImage: "waveform.badge.mic")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.accent)
            if item.document.cues.isEmpty {
                Text("未识别到语音内容：确认音轨含清晰人声，且选择了正确的语言。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func overviewSection(_ item: SubtitleItem) -> some View {
        InspectorSection(title: "概览") {
            InspectorRow(label: "文件", value: item.url.lastPathComponent)
            InspectorRow(label: "格式", value: item.document.format.displayName)
            InspectorRow(label: "编码", value: item.document.encoding)
            InspectorRow(label: "条目", value: "\(item.report.cueCount)")
            if item.isFixed {
                InspectorRow(label: "状态", value: "已修复副本（原文件未改动）")
            }
        }
    }

    private func reportSection(_ item: SubtitleItem) -> some View {
        InspectorSection(title: "质检报告") {
            if item.report.issues.isEmpty {
                Text("未发现任何问题。")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.success)
            } else {
                ForEach(item.report.issues) { issue in
                    HStack(alignment: .top, spacing: Theme.Spacing.s2) {
                        StatusDot(color: severityColor(issue.severity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(issue.severity.displayName) · \(issue.rule.displayName)")
                                .font(Theme.TextStyle.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Text(issue.message)
                                .font(Theme.TextStyle.body)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fixSection(_ item: SubtitleItem) -> some View {
        let autoFixableIssues = item.report.issues.filter(\.autoFixable)
        if item.stateAllowsFix, !autoFixableIssues.isEmpty {
            InspectorSection(title: "自动修复") {
                let grouped = Dictionary(grouping: autoFixableIssues, by: \.rule)
                ForEach(grouped.keys.map { $0 }.sorted { $0.displayName < $1.displayName }, id: \.self) { rule in
                    Toggle(
                        "\(rule.displayName)（\(grouped[rule]!.count) 处）",
                        isOn: Binding(
                            get: { selectedRules.contains(rule) },
                            set: { enabled in
                                if enabled {
                                    selectedRules.insert(rule)
                                } else {
                                    selectedRules.remove(rule)
                                }
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(Theme.TextStyle.body)
                }
                PrimaryButton(title: "修复并生成 -fixed 副本") {
                    store.applyFixes(itemID: item.id, rules: selectedRules)
                    syncSelectedRules()
                }
                Text("修复写入副本文件，原文件不会被修改；修复后会自动重新质检。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func syncSelectedRules() {
        guard let item = store.selectedItem, item.errorText == nil else {
            selectedRules = []
            return
        }
        selectedRules = Set(item.report.issues.filter(\.autoFixable).map(\.rule))
    }

    // MARK: 内容理解（P8.4，Foundation Models 本地推理）

    @ViewBuilder
    private func insightsSection(_ item: SubtitleItem) -> some View {
        InspectorSection(title: "内容理解（本地 AI）") {
            switch insightsAvailability {
            case .available:
                if let insights = item.insights {
                    Text(insights.summary)
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)

                    if !insights.quotes.isEmpty {
                        Text("金句")
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(insights.quotes, id: \.text) { quote in
                            Text("\(quote.timeRange)｜\(quote.text)（\(quote.kind)）")
                                .font(Theme.TextStyle.body)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                    if !insights.speakerStats.isEmpty {
                        Text("对白统计")
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(insights.speakerStats.sorted { $0.value > $1.value }
                            .map { "\($0.key)：\($0.value) 条" }
                            .joined(separator: " · "))
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    HStack {
                        TextButton(title: "复制 Markdown") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                insights.markdown(fileName: item.fileName), forType: .string
                            )
                        }
                        TextButton(title: "导出 Markdown") {
                            exportedPath = store.exportMarkdown(itemID: item.id)?.path
                        }
                        Spacer()
                    }
                    if let exportedPath {
                        Text("已导出：\(exportedPath)")
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.success)
                            .textSelection(.enabled)
                    }
                } else if insightsSession.isRunning {
                    HStack(spacing: Theme.Spacing.s2) {
                        ProgressView()
                            .controlSize(.small)
                        Text(insightsSession.progressText.isEmpty ? "生成中…" : insightsSession.progressText)
                            .font(Theme.TextStyle.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    PrimaryButton(title: "生成内容理解（摘要 / 金句 / 对白统计）") {
                        Task {
                            await insightsSession.run(document: item.document, fileName: item.fileName)
                            if let insights = insightsSession.insights {
                                store.attachInsights(itemID: item.id, insights: insights)
                            }
                        }
                    }
                    Text("全程本地推理，无任何网络请求。")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if let error = insightsSession.errorText {
                        Text(error)
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.error)
                    }
                }
            case .appleIntelligenceDisabled:
                Text(SubtitleInsightAvailability.appleIntelligenceDisabled.guidance)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            case .deviceUnsupported:
                Text(SubtitleInsightAvailability.deviceUnsupported.guidance)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func severityColor(_ severity: SubtitleSeverity) -> Color {
        switch severity {
        case .error: Theme.error
        case .warning: Theme.warning
        case .hint: Theme.textSecondary
        }
    }
}

private extension SubtitleItem {
    /// 修复仅对成功解析且未处于修复副本回退错误的文件可用。
    var stateAllowsFix: Bool { errorText == nil }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 语音转字幕 Sheet（设计文档 §7.13）：选语言 → 设备端识别进度 → 完成提示。
struct TranscribeSheet: View {
    @Environment(SubtitleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let videoURL: URL

    @State private var selectedLocaleID: String?
    @State private var hasStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
            Text("语音转字幕")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("\(videoURL.lastPathComponent) · 设备端识别，完全离线")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)

            if store.supportedLocales.isEmpty {
                Label("本机没有支持设备端识别的语言，无法使用此功能。", systemImage: "exclamationmark.triangle")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
            } else if !hasStarted {
                Picker("识别语言", selection: $selectedLocaleID) {
                    ForEach(store.supportedLocales, id: \.identifier) { locale in
                        Text(SpeechTranscriber.displayName(for: locale)).tag(Optional(locale.identifier))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("识别耗时约与视频时长相当；嘈杂场景与音乐段落效果有限。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if store.isTranscribing {
                VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
                    ProgressView(value: max(store.transcribeProgress, 0.02))
                    Text("识别中…（进度按已识别到的位置估算）")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let message = store.transcribeMessage {
                Text(message)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(store.isTranscribing ? Theme.textSecondary : Theme.textPrimary)
            }

            HStack {
                Spacer()
                if !hasStarted {
                    PrimaryButton(title: "开始识别", isEnabled: selectedLocaleID != nil) {
                        if let id = selectedLocaleID,
                           let locale = store.supportedLocales.first(where: { $0.identifier == id }) {
                            hasStarted = true
                            store.startTranscription(videoURL: videoURL, locale: locale)
                        }
                    }
                } else {
                    TextButton(title: store.isTranscribing ? "后台等待" : "完成") {
                        dismiss()
                    }
                }
            }
        }
        .padding(Theme.Spacing.s3)
        .frame(width: 440)
        .onAppear {
            // 默认语言：系统首选语言与设备端支持列表的匹配（无则取第一个）
            let preferred = Locale.current.language.languageCode?.identifier
            selectedLocaleID = store.supportedLocales.first {
                $0.language.languageCode?.identifier == preferred
            }?.identifier ?? store.supportedLocales.first?.identifier
        }
    }
}
