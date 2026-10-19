import Foundation

/// 历史记录条目（设计文档 §8.6 / §9）：任务结束（完成/取消/失败/中断）时落一条，
/// 保留预设与电影元数据快照，支持「在 Finder 中显示 / 重新转码 / 编辑元数据 / 删除」。
struct HistoryEntry: Codable, Identifiable, Equatable {
    /// 终态种类。
    enum Kind: String, Codable {
        case completed
        case cancelled
        case failed
        case interrupted

        var displayName: String {
            switch self {
            case .completed: "成功"
            case .cancelled: "已取消"
            case .failed: "失败"
            case .interrupted: "已中断"
            }
        }
    }

    var id: UUID
    /// 结束时间（表格「完成时间」列）。
    var finishedAt: Date
    var kind: Kind
    /// 失败原因（仅失败/中断时可能有）。
    var errorMessage: String?

    var inputFileName: String
    var inputPath: String
    /// 输入文件安全书签快照：重新转码时恢复访问授权（设计文档 §9）。
    var inputBookmark: Data?

    var preset: TranscodePreset

    var outputFileName: String?
    var outputPath: String?
    var outputBytes: Int64?

    /// 电影标记与元数据快照（设计文档 §7.5 / §9）。
    var mediaKind: MediaKind
    var movieMetadata: MovieMetadata?

    var isMovie: Bool { mediaKind == .movie }

    /// 元数据展示：已确认快照 / 「手动」来源标注。
    var metadataSummary: String? {
        guard let metadata = movieMetadata else { return nil }
        let year = metadata.year.map { "（\($0)）" } ?? ""
        return "《\(metadata.title)》\(year)"
    }

    init(
        id: UUID = UUID(),
        finishedAt: Date = Date(),
        kind: Kind,
        errorMessage: String? = nil,
        inputFileName: String,
        inputPath: String,
        inputBookmark: Data?,
        preset: TranscodePreset,
        outputFileName: String? = nil,
        outputPath: String? = nil,
        outputBytes: Int64? = nil,
        mediaKind: MediaKind,
        movieMetadata: MovieMetadata? = nil
    ) {
        self.id = id
        self.finishedAt = finishedAt
        self.kind = kind
        self.errorMessage = errorMessage
        self.inputFileName = inputFileName
        self.inputPath = inputPath
        self.inputBookmark = inputBookmark
        self.preset = preset
        self.outputFileName = outputFileName
        self.outputPath = outputPath
        self.outputBytes = outputBytes
        self.mediaKind = mediaKind
        self.movieMetadata = movieMetadata
    }

    /// 从结束的任务生成历史条目。
    init(job: TranscodeJob, kind: Kind) {
        self.init(
            kind: kind,
            errorMessage: job.errorText,
            inputFileName: job.displayName,
            inputPath: job.inputURL.path(percentEncoded: false),
            inputBookmark: job.inputBookmark,
            preset: job.preset,
            outputFileName: job.outputURL?.lastPathComponent,
            outputPath: job.outputURL?.path(percentEncoded: false),
            outputBytes: job.outputBytes,
            mediaKind: job.mediaKind,
            movieMetadata: job.movieMetadata
        )
    }
}
