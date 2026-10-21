import SwiftUI

/// 历史页（设计文档 §8.6）：原生 Table，行高 36，右键 Finder 定位 / 重新转码 / 编辑元数据 / 删除记录。
struct HistoryScreen: View {
    @Environment(QueueStore.self) private var store

    @State private var selection: Set<HistoryEntry.ID> = []
    @State private var metadataContext: HistoryMetadataContext?
    @State private var pendingDeletion: HistoryEntry?
    @State private var isClearDialogPresented = false

    private var history: HistoryStore { store.history }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            content
        }
        .background(Theme.bg)
        .sheet(item: $metadataContext) { context in
            EditHistoryMetadataSheet(entryID: context.id)
        }
        .confirmationDialog(
            "删除记录「\(pendingDeletion?.inputFileName ?? "")」？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive) {
                if let entry = pendingDeletion {
                    history.remove(id: entry.id)
                    selection.remove(entry.id)
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("只删除这条历史，不影响已生成的输出文件。")
        }
        .confirmationDialog(
            "清空全部历史（\(history.entries.count) 条）？",
            isPresented: $isClearDialogPresented,
            titleVisibility: .visible
        ) {
            Button("清空历史", role: .destructive) {
                history.clearAll()
                selection.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清空历史列表，不影响已生成的输出文件。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("历史")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)

            if !history.isEmpty {
                Text("\(history.entries.count) 条记录")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            TextButton(title: "清空历史", isEnabled: !history.isEmpty) {
                isClearDialogPresented = true
            }
        }
        .padding(.horizontal, Theme.Size.contentInset)
        .frame(height: 44)
        .background(Theme.bg)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if history.isEmpty {
            PlaceholderScreen(
                title: "历史",
                subtitle: "任务结束后会在这里记录，可重新转码或定位输出文件。"
            )
        } else {
            Table(history.entries, selection: $selection) {
                TableColumn("文件") { entry in
                    HStack(spacing: Theme.Spacing.s1) {
                        Text(entry.inputFileName)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if entry.isMovie {
                            MovieMark()
                        }
                    }
                }
                TableColumn("预设") { entry in
                    HStack(spacing: Theme.Spacing.s1) {
                        Text(entry.preset.name)
                            .foregroundStyle(Theme.textSecondary)
                        if let enhancement = entry.enhancement {
                            PresetChip(title: enhancement.badgeText)
                                .accessibilityLabel("画质修复：\(enhancement.summary)")
                        }
                    }
                }
                TableColumn("输出") { entry in
                    Text(entry.outputFileName ?? "—")
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("完成时间") { entry in
                    Text(entry.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                TableColumn("大小") { entry in
                    Text(Fmt.bytes(entry.outputBytes ?? 0))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                TableColumn("状态") { entry in
                    HStack(spacing: Theme.Spacing.s1) {
                        StatusDot(color: statusColor(entry.kind))
                        Text(statusText(entry))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                if let id = ids.first, let entry = history.entries.first(where: { $0.id == id }) {
                    menu(for: entry)
                }
            } primaryAction: { _ in }
        }
    }

    // MARK: - 操作

    @ViewBuilder
    private func menu(for entry: HistoryEntry) -> some View {
        if let output = entry.outputPath, FileManager.default.fileExists(atPath: output) {
            Button("在 Finder 中显示") {
                store.revealInFinder(URL(fileURLWithPath: output))
            }
        }
        Button("重新转码") {
            store.requeueHistory(entry)
        }
        if entry.isMovie {
            Button("编辑元数据…") {
                metadataContext = HistoryMetadataContext(id: entry.id)
            }
        }
        Divider()
        Button("删除记录", role: .destructive) {
            pendingDeletion = entry
        }
    }

    private func statusColor(_ kind: HistoryEntry.Kind) -> Color {
        switch kind {
        case .completed: Theme.success
        case .cancelled: Theme.textSecondary
        case .failed: Theme.error
        case .interrupted: Theme.warning
        }
    }

    private func statusText(_ entry: HistoryEntry) -> String {
        if let message = entry.errorMessage, !message.isEmpty {
            return "\(entry.kind.displayName)：\(message)"
        }
        return entry.kind.displayName
    }
}

/// 「电影」小标记（历史表格内）。
private struct MovieMark: View {
    var body: some View {
        Text("电影")
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
            )
            .fixedSize()
    }
}

/// 历史元数据人工编辑（source 记为 manual；设计文档 §7.5）。
private struct EditHistoryMetadataSheet: View {
    let entryID: UUID

    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var yearText = ""
    @State private var director = ""
    @State private var original: MovieMetadata?
    @State private var didLoad = false

    private var entry: HistoryEntry? {
        store.history.entries.first { $0.id == entryID }
    }

    private var validationMessage: String? {
        let candidate = makeMetadata()
        return candidate.validationMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
            Text("编辑元数据")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("「\(entry?.inputFileName ?? "")」")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Form {
                TextField("标题", text: $title)
                TextField("年份（可选）", text: $yearText)
                TextField("导演（可选）", text: $director)
                LabeledContent("来源") {
                    Text("人工填写")
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.error)
            }

            Spacer()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(Theme.Size.contentInset)
        .frame(width: 420, height: 320)
        .background(Theme.bg)
        .onAppear(perform: loadOnce)
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        guard let metadata = entry?.movieMetadata else { return }
        original = metadata
        title = metadata.title
        yearText = metadata.year.map(String.init) ?? ""
        director = metadata.director ?? ""
    }

    private func makeMetadata() -> MovieMetadata {
        var metadata = original ?? MovieMetadata(title: title)
        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        metadata.director = director.trimmingCharacters(in: .whitespacesAndNewlines)
        if metadata.director?.isEmpty == true {
            metadata.director = nil
        }
        metadata.source = .manual
        return metadata
    }

    private func save() {
        guard let entry else { return }
        store.history.updateMovieMetadata(id: entry.id, metadata: makeMetadata())
        dismiss()
    }
}
