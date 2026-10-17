import AVFoundation
import Foundation

/// v1 支持的输出视频编码（设计文档 §3 支持矩阵）。
enum VideoCodec: String, Sendable, CaseIterable, Codable {
    case h264
    case hevc
    case proRes422
    case proRes422HQ
    case proRes422LT
    case proRes422Proxy
    case proRes4444

    var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422: "ProRes 422"
        case .proRes422HQ: "ProRes 422 HQ"
        case .proRes422LT: "ProRes 422 LT"
        case .proRes422Proxy: "ProRes 422 Proxy"
        case .proRes4444: "ProRes 4444"
        }
    }

    /// 家族名（用于硬件能力摘要，如 “H.264 / HEVC / ProRes”）。
    var familyLabel: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422, .proRes422HQ, .proRes422LT, .proRes422Proxy, .proRes4444: "ProRes"
        }
    }

    var isProRes: Bool {
        switch self {
        case .proRes422, .proRes422HQ, .proRes422LT, .proRes422Proxy, .proRes4444: true
        case .h264, .hevc: false
        }
    }

    /// 输入侧 fourCC（avc1 / hvc1 / apc*）。
    var fourCC: String {
        switch self {
        case .h264: "avc1"
        case .hevc: "hvc1"
        case .proRes422: "apcn"
        case .proRes422HQ: "apch"
        case .proRes422LT: "apcs"
        case .proRes422Proxy: "apco"
        case .proRes4444: "ap4h"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        case .proRes422HQ: .proRes422HQ
        case .proRes422LT: .proRes422LT
        case .proRes422Proxy: .proRes422Proxy
        case .proRes4444: .proRes4444
        }
    }

    /// 由 fourCC 反查（avc1 / hvc1 / hev1 / apc*）。
    init?(fourCC: String) {
        switch fourCC {
        case "avc1", "avc3": self = .h264
        case "hvc1", "hev1": self = .hevc
        case "apcn": self = .proRes422
        case "apch": self = .proRes422HQ
        case "apcs": self = .proRes422LT
        case "apco": self = .proRes422Proxy
        case "ap4h": self = .proRes4444
        default: return nil
        }
    }
}

/// 输出容器。
enum MediaContainer: String, Sendable, Codable {
    case mp4
    case mov

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "QuickTime（MOV）"
        }
    }

    var avFileType: AVFileType {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        }
    }
}

/// 音频策略：MP4/MOV 统一转 AAC-LC（设计文档 §6.3）。
struct AudioPolicy: Sendable, Equatable, Codable {
    /// AAC 码率（bps）。
    var bitrate: Int
    /// 目标采样率；nil 表示保持源采样率。
    var sampleRateOverride: Double?
    /// v1 只输出单声道/立体声（5.1 下混留待 v1.1）。
    var maxChannels: Int
}

/// 转码预设。P1 只用「兼容优先」；P2 补齐全部内置与自定义（设计文档 §8.6 预设页）。
struct TranscodePreset: Identifiable, Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case compatible
        case balanced
        case compact
        case highQuality
        case editingProRes

        var displayName: String {
            switch self {
            case .compatible: "兼容优先"
            case .balanced: "均衡"
            case .compact: "小体积"
            case .highQuality: "高质量"
            case .editingProRes: "剪辑用 ProRes"
            }
        }
    }

    var kind: Kind
    var videoCodec: VideoCodec
    var container: MediaContainer
    var audio: AudioPolicy
    /// 1080p 基准平均码率（bps）；按输出像素数缩放并夹取。
    var bitrate1080p: Int

    var id: String { kind.rawValue }
    var name: String { kind.displayName }

    /// 「兼容优先」：H.264 + AAC 192 kbps → MP4（P1 单文件 MVP）。
    static let compatible = TranscodePreset(
        kind: .compatible,
        videoCodec: .h264,
        container: .mp4,
        audio: AudioPolicy(bitrate: 192_000, sampleRateOverride: nil, maxChannels: 2),
        bitrate1080p: 8_000_000
    )

    /// P1 默认（也是唯一）预设。
    static let defaultPreset = TranscodePreset.compatible

    var summary: String {
        "\(videoCodec.displayName) · \(container.displayName) · AAC \(audio.bitrate / 1000) kbps"
    }

    /// 按输出像素数估算平均码率（1080p 为基准，2.5–12 Mbps 夹取）。
    func averageBitrate(videoWidth: Int, videoHeight: Int) -> Int {
        let pixels = Double(max(videoWidth, 2) * max(videoHeight, 2))
        let scale = pixels / (1920.0 * 1080.0)
        let raw = Double(bitrate1080p) * scale
        return Int(min(max(raw, 2_500_000), 12_000_000))
    }

    /// 预计输出大小（字节）；仅估算，接受 ±20%（设计文档 §12）。
    func estimatedBytes(durationSeconds: Double, videoWidth: Int, videoHeight: Int) -> Int64 {
        let videoBits = Double(averageBitrate(videoWidth: videoWidth, videoHeight: videoHeight)) * durationSeconds
        let audioBits = Double(audio.bitrate) * durationSeconds
        return Int64((videoBits + audioBits) / 8.0 * 1.05)
    }
}
