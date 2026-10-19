import Foundation
import os

/// TMDB 请求编排（设计文档 §7.5）：请求串行化 + 300ms 最小间隔 + 7 天缓存 + 海报缓存。
/// actor 隔离天然串行化；测试可注入 mock transport 与临时缓存目录。
actor MovieMetadataService {
    struct MatchResult: Sendable {
        var parsed: ParsedTitle
        var candidates: [MovieCandidate]
    }

    private var credential: TMDBCredential?
    private let transport: TMDBClient.Transport
    private let cache: MetadataCache
    private var lastRequestAt: ContinuousClock.Instant?
    /// 请求最小间隔（防抖）。
    private let minimumInterval: Duration = .milliseconds(300)
    /// 元数据语言（设计文档默认 zh-CN）。
    var language = "zh-CN"

    init(
        cache: MetadataCache = MetadataCache(),
        transport: @escaping TMDBClient.Transport = TMDBClient.liveTransport()
    ) {
        self.cache = cache
        self.transport = transport
    }

    var isConfigured: Bool { credential != nil }

    func setCredential(_ credential: TMDBCredential?) {
        self.credential = credential
    }

    /// 验证凭据（不落库）。
    func validate(_ credential: TMDBCredential) async throws {
        try await client(for: credential).validateCredential()
    }

    /// 文件名 → 解析 → 搜索（标题+年份 → 仅标题 → 备选标题）→ 评分前 5。
    func match(filename: String) async throws -> MatchResult {
        let parsed = TitleParser.parse(filename: filename)
        var results = try await search(query: parsed.primaryTitle, year: parsed.year)
        if results.isEmpty {
            results = try await search(query: parsed.primaryTitle, year: nil)
        }
        if results.isEmpty, let alternative = parsed.alternativeTitle, !alternative.isEmpty {
            results = try await search(query: alternative, year: nil)
        }
        return MatchResult(parsed: parsed, candidates: MovieMatcher.rank(results, parsed: parsed))
    }

    func search(query: String, year: Int?) async throws -> [TMDBMovieSummary] {
        let key = "search|\(language)|\(query.lowercased())|\(year.map(String.init) ?? "-")"
        if let cached: [TMDBMovieSummary] = cache.read([TMDBMovieSummary].self, key: key) {
            return cached
        }
        let client = try requireClient()
        try await throttle()
        let results = try await client.searchMovies(query: query, year: year)
        // 空结果不缓存，便于稍后重试
        if !results.isEmpty {
            cache.write(results, key: key)
        }
        return results
    }

    func detail(id: Int) async throws -> TMDBMovieDetail {
        let key = "detail|\(language)|\(id)"
        if let cached: TMDBMovieDetail = cache.read(TMDBMovieDetail.self, key: key) {
            return cached
        }
        let client = try requireClient()
        try await throttle()
        let detail = try await client.movieDetail(id: id)
        cache.write(detail, key: key)
        return detail
    }

    /// 海报数据：优先本地缓存，未命中则下载并缓存；失败返回 nil（不阻塞）。
    func posterData(path: String) async -> Data? {
        if let data = cache.posterData(forPath: path) { return data }
        guard let url = TMDBClient.posterURL(path: path),
              let client = credential.map({ client(for: $0) }) else { return nil }
        do {
            try await throttle()
            let data = try await client.fetchData(url: url)
            cache.storePoster(data: data, path: path)
            return data
        } catch {
            Log.tmdb.info("海报下载失败（\(error.localizedDescription, privacy: .public)）")
            return nil
        }
    }

    func clearCache() {
        cache.clear()
    }

    // MARK: - 私有

    private func client(for credential: TMDBCredential) -> TMDBClient {
        TMDBClient(credential: credential, language: language, transport: transport)
    }

    private func requireClient() throws -> TMDBClient {
        guard let credential else { throw TMDBError.notConfigured }
        return client(for: credential)
    }

    private func throttle() async throws {
        let now = ContinuousClock.now
        if let lastRequestAt {
            let elapsed = now - lastRequestAt
            if elapsed < minimumInterval {
                try await Task.sleep(for: minimumInterval - elapsed)
            }
        }
        lastRequestAt = ContinuousClock.now
    }
}
