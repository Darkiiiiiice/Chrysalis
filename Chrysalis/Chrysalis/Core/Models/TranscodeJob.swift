import Foundation

/// 队列中的一个转码任务（设计文档 §5 任务状态机）。
struct TranscodeJob: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable {
        case queued
        case preparing
        case running
        case finishing
        case cancelling
        case completed
        case cancelled
        /// 应用退出/崩溃时未写完的任务（启动恢复），可重试（设计文档 §5）。
        case interrupted
        /// 人话错误（失败原因）。
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .running, .finishing, .cancelling: true
            default: false
            }
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .cancelled, .interrupted, .failed: true
            default: false
            }
        }

        /// 失败 / 取消 / 中断的任务可重试。
        var isRetryable: Bool {
            switch self {
            case .cancelled, .interrupted, .failed: true
            default: false
            }
        }
    }

    let id: UUID
    var inputURL: URL
    /// 输入文件的 App Scope 安全书签（重启恢复队列用，设计文档 §9）。
    var inputBookmark: Data?
    var mediaInfo: MediaInfo?
    var preset: TranscodePreset
    var state: State
    var progress: TranscodeProgress?
    var outputURL: URL?
    var outputBytes: Int64?
    var errorText: String?
    var verificationIssues: [String]
    /// 处理过程提示（引擎 notes，检查器展示）。
    var notes: [String]
    /// 任务类型（设计文档 §7.5）：电影任务转码前必须人工确认元数据。
    var mediaKind: MediaKind = .video
    /// 电影元数据状态（none → searching → needsReview → confirmed / failed）。
    var metadataState: MovieMetadataState = .none
    /// 已确认的电影元数据快照（转码时写入容器）。
    var movieMetadata: MovieMetadata?

    init(id: UUID = UUID(), inputURL: URL, preset: TranscodePreset = .defaultPreset) {
        self.id = id
        self.inputURL = inputURL
        self.preset = preset
        self.state = .queued
        self.verificationIssues = []
        self.notes = []
    }

    var displayName: String { inputURL.lastPathComponent }

    /// 队列行第二行：`1920×1080 · HEVC · 00:01:23`。
    var metaLine: String {
        guard let mediaInfo, let video = mediaInfo.video else { return "读取中…" }
        return "\(mediaInfo.dimensionsLabel) · \(video.codecName) · \(mediaInfo.durationLabel)"
    }

    /// 电影任务是否需要先确认元数据（转码前置校验，设计文档 §7.5）。
    var needsMetadataConfirmation: Bool {
        mediaKind == .movie && !metadataState.isConfirmed
    }
}
