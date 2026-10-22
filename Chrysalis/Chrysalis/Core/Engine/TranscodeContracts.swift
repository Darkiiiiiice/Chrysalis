import CoreMedia
import Foundation

/// 引擎输入参数（值类型；引擎据此构建 reader/writer）。
struct TranscodeRequest: Sendable {
    var inputURL: URL
    /// 最终输出路径；已由 OutputPlanner 消解重名。
    var outputURL: URL
    var videoCodec: VideoCodec
    var container: MediaContainer
    /// 输出分辨率档位（设计文档 P3.5：短边匹配 / 只缩不放 / 偶数对齐）。
    var resolution: ResolutionSetting
    /// 输出帧率档位（设计文档 P3.5：只降不升）。
    var frameRate: FrameRateSetting
    /// 平均码率（bps）；质量/目标大小模式或 ProRes 传 nil。
    var averageBitrate: Int?
    /// 码率控制方式（设计文档 P4）。
    var bitrateMode: BitrateMode = .targetBitrate
    /// 质量优先的质量值（0.05–1.0）。
    var quality: Double = 0.65
    /// 目标大小（字节 / 每个输出文件）；仅 `bitrateMode == .targetSize` 生效。
    var targetSizeBytes: Int64?
    /// 平均码率夹取范围（目标大小换算用）。
    var bitrateRange: ClosedRange<Int> = 0...Int.max
    /// 关键帧间隔（H.264 / HEVC）。
    var keyframeInterval: KeyframeIntervalSetting = .auto
    /// H.264 Profile（HEVC / ProRes 仅自动）。
    var profile: VideoProfileSetting = .auto
    var audioBitrate: Int
    var audioMaxChannels: Int
    /// 目标采样率；nil 表示保持源采样率。
    var audioSampleRate: Double?
    /// ProRes 输出的 PCM 位深（16 / 24）；nil 表示 AAC。
    var audioPCMSampleBitDepth: Int?
    /// 强制硬件编码（设计文档硬性要求，默认 true）。
    var requireHardware: Bool
    /// 指定硬件编码器 ID；nil 表示由系统选择（仍带 Require 标志）。
    var encoderID: String?
    /// 已确认的电影元数据（设计文档 §7.5）；nil 表示不写电影元数据。
    var metadata: MovieMetadata?
    /// 海报数据（本地缓存取得；nil 表示跳过海报，不阻塞转码）。
    var posterData: Data?
    /// 画质修复（设计文档 §7.6）；nil 表示关闭。
    ///
    /// 开启时引擎锁定源分辨率，输出尺寸 = 源显示尺寸 ×2。
    var enhancement: EnhancementSetting? = nil
    /// 样片试编码（设计文档 §7.8）：截取源时间轴的片段；nil = 全片。
    ///
    /// 仅试编码使用——输出落在临时目录、编码后即删。
    var sourceTimeRange: CMTimeRange? = nil
    /// 试编码模式：跳过输出自检与元数据写入自检（结果即弃）。
    var isProbe = false
    /// 样片试编码实测总码率（bps，设计文档 §7.8）：磁盘预检优先使用；nil 回退名义值。
    var measuredTotalBitrate: Int? = nil
    /// 音频响度标准化（设计文档 §7.11）；nil = 关闭（默认）。
    var loudness: LoudnessSetting? = nil
    /// 降帧感知混合（设计文档 §7.12）：降帧时窗口内源帧按时间位置加权混合，默认关闭。
    var frameBlending = false
    /// 复古输出彩蛋（设计文档 §7.15）；nil = 关闭（默认）。与画质修复互斥。
    var retroEffect: RetroEffectSetting? = nil
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
    /// 处理过程提示（如多声道下混、旋转慢路径），展示在检查器「输出」区。
    var notes: [String]
}

/// 引擎错误（人话描述；覆盖设计文档 §6.1 预检与 §7 硬件要求）。
enum TranscodeEngineError: LocalizedError, Sendable, Equatable {
    case cancelled
    case unsupportedContainer(String)
    case noVideoTrack
    case notPlayable
    case protectedContent
    case hdrUnsupported(String)
    case proResRequiresMOV
    case hardwareDecodeUnavailable(String)
    case hardwareEncoderUnavailable(String)
    case lowDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case readerSetupFailed(String)
    case writerSetupFailed(String)
    case readWriteFailed(String)
    /// 画质修复模型缺失、损坏或形状不符（不回退滤镜链）。
    case enhancementUnavailable(String)
    /// 画质修复分辨率与「保持源」锁定冲突。
    case enhancementResolutionConflict
    /// 复古输出与画质修复互斥（设计文档 §7.15，引擎兜底；UI 已双向禁用）。
    case retroEnhancementConflict
    /// 目标编码器不支持 8K 输出（不静默降级）。
    case eightKUnsupported(codec: String, width: Int, height: Int)
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
        case .proResRequiresMOV:
            "ProRes 仅支持 QuickTime（MOV）容器；请在预设中选择 MOV。"
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
        case .enhancementUnavailable(let message):
            "画质修复不可用：\(message)"
        case .enhancementResolutionConflict:
            "画质修复开启时输出固定为源尺寸 ×2；请把分辨率档位切回「保持源」。"
        case .retroEnhancementConflict:
            "复古输出与画质修复互斥：请只保留其一。"
        case .eightKUnsupported(let codec, let width, let height):
            "当前 \(codec) 硬件编码器不支持 \(width)×\(height)（8K）输出：请改用 4K 源或关闭画质修复；不会静默降到 4K。"
        case .failed(let message):
            message
        }
    }
}
