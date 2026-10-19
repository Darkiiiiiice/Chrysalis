import Foundation
import os

/// 活动队列持久化（设计文档 §9）：存 `Application Support/Chrysalis/queue.json`；
/// 启动时恢复，运行中（活跃）任务恢复为 `interrupted`，由用户重试。
struct QueueArchive: Codable {
    static let currentVersion = 2

    var version: Int
    var outputDirectoryBookmark: Data?
    var jobs: [PersistedJob]

    init(outputDirectoryBookmark: Data?, jobs: [PersistedJob]) {
        self.version = Self.currentVersion
        self.outputDirectoryBookmark = outputDirectoryBookmark
        self.jobs = jobs
    }

    /// 任务状态快照：活动状态统一记 `.active`，恢复时映射为 `interrupted`。
    enum PersistedState: Codable, Equatable {
        case queued
        case active
        case completed
        case cancelled
        case interrupted
        case failed(String)

        init(_ state: TranscodeJob.State) {
            switch state {
            case .queued: self = .queued
            case .preparing, .running, .finishing, .cancelling: self = .active
            case .completed: self = .completed
            case .cancelled: self = .cancelled
            case .interrupted: self = .interrupted
            case .failed(let message): self = .failed(message)
            }
        }

        /// 恢复后的运行时状态（活跃 → 中断）。
        var restoredState: TranscodeJob.State {
            switch self {
            case .queued: .queued
            case .active: .interrupted
            case .completed: .completed
            case .cancelled: .cancelled
            case .interrupted: .interrupted
            case .failed(let message): .failed(message)
            }
        }
    }

    struct PersistedJob: Codable {
        var id: UUID
        var inputPath: String
        var inputBookmark: Data?
        var preset: TranscodePreset
        var state: PersistedState
        var outputPath: String?
        var outputBytes: Int64?
        var errorText: String?
        var verificationIssues: [String]
        var notes: [String]
        var mediaInfo: MediaInfo?
        /// 电影标记与元数据快照（设计文档 §7.5；v1 队列文件没有这些字段，缺省即普通任务）。
        var mediaKind: MediaKind?
        var metadataState: MovieMetadataState?
        var movieMetadata: MovieMetadata?

        init(_ job: TranscodeJob) {
            self.id = job.id
            self.inputPath = job.inputURL.path(percentEncoded: false)
            self.inputBookmark = job.inputBookmark
            self.preset = job.preset
            self.state = PersistedState(job.state)
            self.outputPath = job.outputURL?.path(percentEncoded: false)
            self.outputBytes = job.outputBytes
            self.errorText = job.errorText
            self.verificationIssues = job.verificationIssues
            self.notes = job.notes
            self.mediaInfo = job.mediaInfo
            self.mediaKind = job.mediaKind
            self.metadataState = job.metadataState
            self.movieMetadata = job.movieMetadata
        }
    }

    init(jobs: [TranscodeJob], outputDirectoryBookmark: Data?) {
        self.init(
            outputDirectoryBookmark: outputDirectoryBookmark,
            jobs: jobs.map(PersistedJob.init)
        )
    }
}

extension QueueArchive {
    static func load() -> QueueArchive? {
        guard let data = try? Data(contentsOf: AppPaths.queueFileURL) else { return nil }
        do {
            return try JSONDecoder().decode(QueueArchive.self, from: data)
        } catch {
            Log.app.error("读取队列失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: AppPaths.queueFileURL, options: .atomic)
        } catch {
            Log.app.error("保存队列失败：\(String(describing: error), privacy: .public)")
        }
    }
}
