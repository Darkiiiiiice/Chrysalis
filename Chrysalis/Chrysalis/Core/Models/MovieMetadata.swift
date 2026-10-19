import Foundation

/// 任务类型（设计文档 §7.5）：电影任务转码前必须人工确认元数据。
enum MediaKind: String, Sendable, Codable {
    case video
    case movie
}

/// 电影元数据状态机（设计文档 §7.5）：
/// none → searching → needsReview → confirmed；失败进入 failed，可重试或手动填写。
enum MovieMetadataState: Sendable, Equatable, Codable {
    case none
    case searching
    case needsReview
    case confirmed
    case failed(String)

    var isConfirmed: Bool { self == .confirmed }

    var displayName: String {
        switch self {
        case .none: "未启用"
        case .searching: "匹配中…"
        case .needsReview: "待确认"
        case .confirmed: "已确认"
        case .failed: "匹配失败"
        }
    }

    /// 失败原因（UI 展示与手动填写入口）。
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// 元数据获取失败（携带可读中文文案，供 UI 直接展示）。
struct MetadataError: LocalizedError, Equatable, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// 电影元数据（设计文档 §7.5）：任务快照，人工确认后写入输出容器。
struct MovieMetadata: Sendable, Equatable, Codable {
    enum Source: String, Sendable, Codable {
        /// TMDB 自动匹配。
        case tmdb
        /// 人工填写或修改。
        case manual
    }

    var title: String
    var originalTitle: String?
    var year: Int?
    /// 上映日期（`YYYY-MM-DD`）。
    var releaseDate: String?
    var overview: String?
    var genres: [String] = []
    /// 导演（多人以「, 」连接）。
    var director: String?
    /// 演员（TMDB 前 10 位；写入容器取前 5）。
    var cast: [String] = []
    var tmdbID: Int?
    var imdbID: String?
    /// TMDB 海报相对路径（如 `/abc.jpg`）。
    var posterPath: String?
    var source: Source = .manual

    /// 校验（设计文档 §7.5）：标题非空；年份 1888…当前+2；日期为 YYYY-MM-DD。
    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "标题不能为空。"
        }
        if let year {
            let upperBound = Calendar.current.component(.year, from: .now) + 2
            if !(1888...upperBound).contains(year) {
                return "年份需在 1888–\(upperBound) 之间。"
            }
        }
        if let releaseDate, !releaseDate.isEmpty {
            let parts = releaseDate.split(separator: "-")
            let valid = parts.count == 3
                && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
                && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            if !valid {
                return "上映日期需为 YYYY-MM-DD 格式。"
            }
        }
        return nil
    }
}
