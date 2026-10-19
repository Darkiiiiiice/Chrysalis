import Foundation

/// TMDB 凭据：v3 API Key 或 v4 Read Access Token（设计文档 §7.5）。
struct TMDBCredential: Sendable, Equatable {
    enum Kind: String, Sendable, Codable {
        case v3Key
        case v4Token
    }

    var kind: Kind
    var value: String

    /// 按格式猜测：v4 token 为 JWT（含“.”）；v3 key 为十六进制串。
    static func detect(_ raw: String) -> TMDBCredential {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".") {
            return TMDBCredential(kind: .v4Token, value: trimmed)
        }
        return TMDBCredential(kind: .v3Key, value: trimmed)
    }
}

/// TMDB 错误分类（设计文档 §7.5：每种都要有可执行下一步）。
enum TMDBError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidKey
    case rateLimited(retryAfterSeconds: Int?)
    case timedOut
    case network(String)
    case decodingFailed(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "未配置 TMDB API Key。可在设置中填写，或手动填写元数据。"
        case .invalidKey:
            "API Key 无效或已过期（401）：请检查设置中的凭据。"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "请求过于频繁（429）：请 \(retryAfter) 秒后重试。"
            } else {
                "请求过于频繁（429）：请稍后重试。"
            }
        case .timedOut:
            "请求超时：请检查网络后重试，或手动填写元数据。"
        case .network(let message):
            "网络错误：\(message)"
        case .decodingFailed(let message):
            "TMDB 返回的数据无法解析：\(message)"
        case .invalidURL:
            "无法构建 TMDB 请求。"
        }
    }
}

// MARK: - 响应模型

/// 搜索响应。
struct TMDBMovieSearchResponse: Codable, Sendable, Equatable {
    var results: [TMDBMovieSummary]
}

/// 搜索结果条目。
struct TMDBMovieSummary: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var title: String
    var originalTitle: String?
    var releaseDate: String?
    var overview: String?
    var posterPath: String?
    var popularity: Double?
    var voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
    }

    var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

/// 详情响应（append_to_response=credits）。
struct TMDBMovieDetail: Codable, Sendable, Equatable {
    var id: Int
    var title: String
    var originalTitle: String?
    var releaseDate: String?
    var overview: String?
    var posterPath: String?
    var voteAverage: Double?
    var imdbID: String?
    var genres: [TMDBGenre]?
    var credits: TMDBMovieCredits?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, genres, credits
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case imdbID = "imdb_id"
    }

    var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    /// 转成应用内元数据（source = .tmdb）。
    var movieMetadata: MovieMetadata {
        let directors = (credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
        return MovieMetadata(
            title: title,
            originalTitle: originalTitle,
            year: year,
            releaseDate: releaseDate,
            overview: overview,
            genres: (genres ?? []).map(\.name),
            director: directors.isEmpty ? nil : directors.joined(separator: ", "),
            cast: (credits?.cast ?? []).prefix(10).map(\.name),
            tmdbID: id,
            imdbID: imdbID,
            posterPath: posterPath,
            source: .tmdb
        )
    }
}

struct TMDBGenre: Codable, Sendable, Equatable {
    var id: Int?
    var name: String
}

struct TMDBMovieCredits: Codable, Sendable, Equatable {
    var cast: [TMDBPerson] = []
    var crew: [TMDBPerson] = []
}

struct TMDBPerson: Codable, Sendable, Equatable {
    var name: String
    var job: String?
    var order: Int?
}

/// 空响应占位（v3 凭据验证用 /3/configuration）。
private struct TMDBEmptyResponse: Decodable {}

// MARK: - 客户端

/// TMDB API 客户端（设计文档 §7.5）：URLSession + Codable，零第三方依赖。
/// 传输层可注入（测试用 mock），生产用 `liveTransport()`（按代理设置构建会话）。
struct TMDBClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    var credential: TMDBCredential
    var language: String
    var transport: Transport

    init(credential: TMDBCredential, language: String = "zh-CN", transport: @escaping Transport) {
        self.credential = credential
        self.language = language
        self.transport = transport
    }

    // MARK: 端点

    /// 验证凭据：v3 调 `/3/configuration`；v4 调 `/3/movie/550`（设计文档 §7.5）。
    func validateCredential() async throws {
        switch credential.kind {
        case .v3Key:
            let _: TMDBEmptyResponse = try await get(path: "/configuration")
        case .v4Token:
            let _: TMDBMovieSummary = try await get(path: "/movie/550", query: ["language": language])
        }
    }

    func searchMovies(query: String, year: Int?) async throws -> [TMDBMovieSummary] {
        var parameters: [String: String] = [
            "query": query,
            "language": language,
            "include_adult": "false",
        ]
        if let year { parameters["year"] = String(year) }
        let response: TMDBMovieSearchResponse = try await get(path: "/search/movie", query: parameters)
        return response.results
    }

    func movieDetail(id: Int) async throws -> TMDBMovieDetail {
        try await get(
            path: "/movie/\(id)",
            query: ["language": language, "append_to_response": "credits"]
        )
    }

    /// 下载任意数据（海报图片；image.tmdb.org 无需鉴权）。
    func fetchData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, http) = try await perform(request)
        try Self.validateStatus(http)
        return data
    }

    /// 海报图片 URL，如 `https://image.tmdb.org/t/p/w342/abc.jpg`。
    static func posterURL(path: String, width: Int = 342) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "image.tmdb.org"
        components.path = "/t/p/w\(width)\(path)"
        return components.url
    }

    /// 生产传输：URLSession（按代理设置构建/复用会话，设计文档 §7.5）；
    /// 错误统一在 `get`/`fetchData` 里归类。
    static func liveTransport(
        provider: ProxySessionProvider = ProxySessionProvider()
    ) -> Transport {
        { request in
            let (data, response) = try await provider.session().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TMDBError.network("响应格式无效")
            }
            return (data, http)
        }
    }

    // MARK: 请求

    private func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        guard var components = URLComponents(string: "https://api.themoviedb.org/3\(path)") else {
            throw TMDBError.invalidURL
        }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        if credential.kind == .v3Key {
            items.append(URLQueryItem(name: "api_key", value: credential.value))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw TMDBError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credential.kind == .v4Token {
            request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        }

        let (data, http) = try await perform(request)
        try Self.validateStatus(http)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingFailed("字段解析失败")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch let error as TMDBError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut { throw TMDBError.timedOut }
            throw TMDBError.network(error.localizedDescription)
        } catch {
            throw TMDBError.network(error.localizedDescription)
        }
    }

    private static func validateStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw TMDBError.invalidKey
        case 429:
            throw TMDBError.rateLimited(
                retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            )
        default:
            throw TMDBError.network("TMDB 返回状态码 \(http.statusCode)")
        }
    }
}
