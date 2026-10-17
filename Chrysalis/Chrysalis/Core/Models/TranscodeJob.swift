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
            case .completed, .cancelled, .failed: true
            default: false
            }
        }
    }

    let id: UUID
    let inputURL: URL
    var mediaInfo: MediaInfo?
    var preset: TranscodePreset
    var state: State
    var progress: TranscodeProgress?
    var outputURL: URL?
    var outputBytes: Int64?
    var errorText: String?
    var verificationIssues: [String]

    init(inputURL: URL, preset: TranscodePreset = .defaultPreset) {
        self.id = UUID()
        self.inputURL = inputURL
        self.preset = preset
        self.state = .queued
        self.verificationIssues = []
    }

    var displayName: String { inputURL.lastPathComponent }

    /// 队列行第二行：`1920×1080 · HEVC · 00:01:23`。
    var metaLine: String {
        guard let mediaInfo, let video = mediaInfo.video else { return "读取中…" }
        return "\(mediaInfo.dimensionsLabel) · \(video.codecName) · \(mediaInfo.durationLabel)"
    }
}
