import Foundation

/// 引擎输入参数（值类型；引擎据此构建 reader/writer）。
struct TranscodeRequest: Sendable {
    var inputURL: URL
    /// 最终输出路径；已由 OutputPlanner 消解重名。
    var outputURL: URL
    var videoCodec: VideoCodec
    var container: MediaContainer
    /// 平均码率（bps）；ProRes 传 nil。
    var averageBitrate: Int?
    var audioBitrate: Int
    var audioMaxChannels: Int
    /// 目标采样率；nil 表示保持源采样率。
    var audioSampleRate: Double?
    /// 强制硬件编码（设计文档硬性要求，默认 true）。
    var requireHardware: Bool
    /// 指定硬件编码器 ID；nil 表示由系统选择（仍带 Require 标志）。
    var encoderID: String?
}

/// 进度事件（简单值类型，设计文档 §12 风险表）。
struct TranscodeProgress: Sendable, Equatable {
    var fraction: Double
    var processedSeconds: Double
    var speed: Double
    var etaSeconds: Double?
}

/// 一次成功转码的结果。
struct TranscodeOutcome: Sendable {
    var outputURL: URL
    var bytes: Int64
    var durationSeconds: Double
    var wallSeconds: Double
    var averageSpeed: Double
    var usedComposition: Bool
    var verificationIssues: [String]
}

/// 引擎错误（人话描述；覆盖设计文档 §6.1 预检与 §7 硬件要求）。
enum TranscodeEngineError: LocalizedError, Sendable, Equatable {
    case cancelled
    case unsupportedContainer(String)
    case noVideoTrack
    case notPlayable
    case protectedContent
    case hdrUnsupported(String)
    case hardwareDecodeUnavailable(String)
    case hardwareEncoderUnavailable(String)
    case lowDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case readerSetupFailed(String)
    case writerSetupFailed(String)
    case readWriteFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "已取消"
        case .unsupportedContainer(let ext):
            "不支持的输入格式（.\(ext)）：v1 仅支持 MP4 / MOV / M4V。"
        case .noVideoTrack:
            "输入没有视频轨。"
        case .notPlayable:
            "该文件无法解码播放，可能已损坏或格式不完整。"
        case .protectedContent:
            "输入包含受保护内容（DRM），无法转码。"
        case .hdrUnsupported(let label):
            "检测到 \(label) 视频：v1 暂不支持 HDR，已拒绝以避免输出偏色。"
        case .hardwareDecodeUnavailable(let codec):
            "源视频编码 \(codec) 没有硬件解码器；v1 不会静默软件解码，已拒绝。"
        case .hardwareEncoderUnavailable(let codec):
            "未找到 \(codec) 的硬件编码器：任务在 preparing 阶段失败（硬件加速为硬性要求）。"
        case .lowDiskSpace(let required, let available):
            "磁盘空间不足：预计需要 \(Fmt.bytes(required))，当前可用 \(Fmt.bytes(available))。"
        case .readerSetupFailed(let message):
            "读取端初始化失败：\(message)"
        case .writerSetupFailed(let message):
            "写入端初始化失败：\(message)"
        case .readWriteFailed(let message):
            "转码过程中出错：\(message)"
        case .failed(let message):
            message
        }
    }
}
