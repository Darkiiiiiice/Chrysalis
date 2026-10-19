import SwiftUI

/// 电影元数据确认 Sheet（设计文档 §7.5 勘误 UI）：720px。
/// 左列 TMDB 候选（海报 / 标题 / 年份 / 简介），右列可编辑表单；
/// 自动匹配永不静默写入，必须在这里确认后才允许转码。
struct ConfirmMovieSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let jobID: UUID

    // 搜索
    @State private var query = ""
    @State private var yearQuery = ""
    @State private var isSearching = false
    @State private var searchMessage: String?
    @State private var loadingDetailID: Int?
    @State private var overwriteCandidate: MovieCandidate?

    // 表单
    @State private var title = ""
    @State private var originalTitle = ""
    @State private var year = ""
    @State private var releaseDate = ""
    @State private var overview = ""
    @State private var genres = ""
    @State private var director = ""
    @State private var cast = ""
    @State private var tmdbID = ""
    @State private var imdbID = ""
    @State private var posterPath: String?
    @State private var source: MovieMetadata.Source = .manual
    /// 表单快照基线（判断「已手动修改」；程序化填充时刷新）。
    @State private var baseline = ""
    @State private var didLoad = false

    private var job: TranscodeJob? {
        store.jobs.first { $0.id == jobID }
    }

    private var candidates: [MovieCandidate] {
        store.movieCandidates[jobID] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            HStack(alignment: .top, spacing: 0) {
                candidatesColumn
                    .frame(width: 300)
                Rectangle().fill(Theme.border).frame(width: 1)
                formColumn
            }
            divider
            footer
        }
        .frame(width: 720)
        .background(Theme.bg)
        .onAppear(perform: loadOnce)
        .confirmationDialog(
            "用此候选覆盖当前内容？",
            isPresented: Binding(
                get: { overwriteCandidate != nil },
                set: { if !$0 { overwriteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("覆盖", role: .destructive) {
                if let candidate = overwriteCandidate {
                    overwriteCandidate = nil
                    Task { await apply(candidate) }
                }
            }
            Button("取消", role: .cancel) {
                overwriteCandidate = nil
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("电影元数据")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("\(job?.displayName ?? "") · 确认后才允许转码")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            IconButton(systemImage: "xmark", help: "关闭") {
                dismiss()
            }
        }
        .padding(.leading, Theme.Spacing.s3)
        .padding(.trailing, Theme.Spacing.s2)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s2) {
            if let validationMessage = builtMetadata.validationMessage {
                Text(validationMessage)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
            } else {
                Text("确认后把标题 / 简介 / 类型 / 导演 / 海报等写入输出容器。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.s2)
            TextButton(title: "清空") {
                clearForm()
            }
            TextButton(title: "取消") {
                dismiss()
            }
            PrimaryButton(title: "确认并用于转码", isEnabled: builtMetadata.validationMessage == nil) {
                confirm()
            }
        }
        .padding(.horizontal, Theme.Spacing.s3)
        .frame(height: 56)
    }

    // MARK: - 候选列

    private var candidatesColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            Text("TMDB 候选（前 5 个）")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: Theme.Spacing.s1) {
                TextField("标题关键词", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                TextField("年份", text: $yearQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit { search() }
                IconButton(systemImage: "magnifyingglass", help: "搜索") {
                    search()
                }
            }

            if isSearching {
                HStack(spacing: Theme.Spacing.s1) {
                    ProgressView().controlSize(.small)
                    Text("搜索中…")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let searchMessage {
                Text(searchMessage)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if candidates.isEmpty, !isSearching, searchMessage == nil {
                Text(store.isTMDBConfigured
                    ? "暂无候选：点「搜索」或直接手动填写。"
                    : "未配置 TMDB API Key：可在设置中填写，或直接手动填写。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.s1) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .frame(minHeight: 220)

            Text("点击候选填入右侧表单；确认前不会写入任何内容。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.s3)
    }

    private func candidateRow(_ candidate: MovieCandidate) -> some View {
        let summary = candidate.summary
        return Button {
            choose(candidate)
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s2) {
                posterThumb(path: summary.posterPath)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
                        Text(summary.title)
                            .font(Theme.TextStyle.bodyEmphasized)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let year = summary.year {
                            Text(String(year))
                                .font(Theme.TextStyle.numericSmall)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if loadingDetailID == candidate.id {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    if let overview = summary.overview, !overview.isEmpty {
                        Text(overview)
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(Theme.Spacing.s1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func posterThumb(path: String?) -> some View {
        Group {
            if let path, let url = TMDBClient.posterURL(path: path, width: 92) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        posterPlaceholder
                    }
                }
            } else {
                posterPlaceholder
            }
        }
        .frame(width: 46, height: 69)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var posterPlaceholder: some View {
        ZStack {
            Theme.surface
            Image(systemName: "film")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
    }

    // MARK: - 表单列

    private var formColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                HStack(alignment: .top, spacing: Theme.Spacing.s3) {
                    posterPreview
                    VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
                        formRow("标题", text: $title)
                        formRow("原名", text: $originalTitle)
                        HStack(spacing: Theme.Spacing.s2) {
                            formRow("年份", text: $year, width: 72)
                            formRow("上映日期", text: $releaseDate, width: 120)
                        }
                        formRow("类型", text: $genres)
                    }
                }
                formRow("导演", text: $director)
                formRow("演员", text: $cast)
                HStack(spacing: Theme.Spacing.s2) {
                    formRow("TMDB ID", text: $tmdbID, width: 100)
                    formRow("IMDb ID", text: $imdbID, width: 140)
                }
                formRow("简介", text: $overview, axis: .vertical, lines: 3...6)
                Text("类型 / 演员用「、」或「,」分隔；所有字段都可手动修改。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                if isEdited {
                    Text("已手动修改")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(Theme.Spacing.s3)
        }
    }

    private var posterPreview: some View {
        Group {
            if let posterPath, let url = TMDBClient.posterURL(path: posterPath, width: 185) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        posterPlaceholder
                    }
                }
            } else {
                posterPlaceholder
            }
        }
        .frame(width: 92, height: 138)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func formRow(
        _ label: String,
        text: Binding<String>,
        width: CGFloat? = nil,
        axis: Axis = .horizontal,
        lines: ClosedRange<Int> = 1...1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            TextField("", text: text, axis: axis)
                .textFieldStyle(.roundedBorder)
                .lineLimit(lines)
                .frame(width: width)
        }
    }

    // MARK: - 数据流

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true

        guard let job else { return }
        let parsed = TitleParser.parse(filename: job.displayName)
        query = parsed.primaryTitle
        yearQuery = parsed.year.map(String.init) ?? ""
        if let metadata = job.movieMetadata {
            fill(metadata)
            source = metadata.source
            // 已确认为人工填写的内容：候选覆盖前必须确认
            baseline = metadata.source == .manual ? "" : snapshot
        }
        searchMessage = job.metadataState.failureMessage
    }

    private func search() {
        guard !isSearching else { return }
        isSearching = true
        searchMessage = nil
        Task {
            let error = await store.searchMovieCandidates(
                jobID: jobID,
                query: query,
                year: Int(yearQuery.trimmingCharacters(in: .whitespaces))
            )
            isSearching = false
            searchMessage = error
        }
    }

    private func choose(_ candidate: MovieCandidate) {
        if isEdited {
            overwriteCandidate = candidate
        } else {
            Task { await apply(candidate) }
        }
    }

    private func apply(_ candidate: MovieCandidate) async {
        loadingDetailID = candidate.id
        searchMessage = nil
        let result = await store.movieDetail(id: candidate.id)
        loadingDetailID = nil
        switch result {
        case .success(let metadata):
            fill(metadata)
            source = .tmdb
        case .failure(let error):
            searchMessage = error.message
        }
    }

    private func confirm() {
        var metadata = builtMetadata
        metadata.source = isEdited ? .manual : source
        store.commitMovieMetadata(jobID: jobID, metadata: metadata)
        dismiss()
    }

    private func clearForm() {
        title = ""
        originalTitle = ""
        year = ""
        releaseDate = ""
        overview = ""
        genres = ""
        director = ""
        cast = ""
        tmdbID = ""
        imdbID = ""
        posterPath = nil
        source = .manual
        baseline = ""
    }

    private func fill(_ metadata: MovieMetadata) {
        title = metadata.title
        originalTitle = metadata.originalTitle ?? ""
        year = metadata.year.map(String.init) ?? ""
        releaseDate = metadata.releaseDate ?? ""
        overview = metadata.overview ?? ""
        genres = metadata.genres.joined(separator: "、")
        director = metadata.director ?? ""
        cast = metadata.cast.joined(separator: "、")
        tmdbID = metadata.tmdbID.map(String.init) ?? ""
        imdbID = metadata.imdbID ?? ""
        posterPath = metadata.posterPath
        baseline = snapshot
    }

    // MARK: - 表单值

    private var builtMetadata: MovieMetadata {
        MovieMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            originalTitle: trimmedOrNil(originalTitle),
            year: Int(year.trimmingCharacters(in: .whitespaces)),
            releaseDate: trimmedOrNil(releaseDate),
            overview: trimmedOrNil(overview),
            genres: splitList(genres),
            director: trimmedOrNil(director),
            cast: splitList(cast),
            tmdbID: Int(tmdbID.trimmingCharacters(in: .whitespaces)),
            imdbID: trimmedOrNil(imdbID),
            posterPath: posterPath,
            source: source
        )
    }

    private var snapshot: String {
        [title, originalTitle, year, releaseDate, overview, genres, director, cast, tmdbID, imdbID]
            .joined(separator: "·")
    }

    private var isEdited: Bool {
        snapshot != baseline
    }

    private func trimmedOrNil(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func splitList(_ string: String) -> [String] {
        string.split(whereSeparator: { "，,、;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
