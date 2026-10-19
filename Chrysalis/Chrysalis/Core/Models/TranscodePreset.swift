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

    /// 自定义预设可选的音频码率（设计文档 §6.6）。
    static let bitrateChoices = [96_000, 128_000, 192_000, 256_000]

    /// 立体声 AAC 默认策略。
    static func stereoAAC(bitrate: Int) -> AudioPolicy {
        AudioPolicy(bitrate: bitrate, sampleRateOverride: nil, maxChannels: 2)
    }
}

/// 转码预设（设计文档 §6.6）：内置只读；自定义可「复制为自定义」后编辑/删除。
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

    /// 内置种类；nil 表示自定义预设。
    var builtInKind: Kind?
    /// 稳定标识：内置用 `kind.rawValue`；自定义用 `custom-<UUID>`。
    var id: String
    var name: String
    var videoCodec: VideoCodec
    var container: MediaContainer
    var audio: AudioPolicy
    /// 1080p 基准平均码率（bps）；按输出像素数缩放并夹取到 `bitrateRange`。
    var bitrate1080p: Int
    /// 平均码率夹取范围（bps）；自定义预设继承来源预置的范围并随基准码率等比缩放。
    var bitrateRange: ClosedRange<Int>

    var isBuiltIn: Bool { builtInKind != nil }

    private init(
        id: String,
        builtInKind: Kind?,
        name: String,
        videoCodec: VideoCodec,
        container: MediaContainer,
        audio: AudioPolicy,
        bitrate1080p: Int,
        bitrateRange: ClosedRange<Int>
    ) {
        self.id = id
        self.builtInKind = builtInKind
        self.name = name
        self.videoCodec = videoCodec
        self.container = container
        self.audio = audio
        self.bitrate1080p = bitrate1080p
        self.bitrateRange = bitrateRange
    }

    private static func builtIn(
        _ kind: Kind,
        videoCodec: VideoCodec,
        audioBitrate: Int,
        bitrate1080p: Int,
        bitrateRange: ClosedRange<Int>
    ) -> TranscodePreset {
        TranscodePreset(
            id: kind.rawValue,
            builtInKind: kind,
            name: kind.displayName,
            videoCodec: videoCodec,
            container: .mp4,
            audio: .stereoAAC(bitrate: audioBitrate),
            bitrate1080p: bitrate1080p,
            bitrateRange: bitrateRange
        )
    }

    /// 由现有预设复制为自定义（同编码/容器/音频/码率与夹取范围）。
    static func copy(of preset: TranscodePreset, name: String) -> TranscodePreset {
        TranscodePreset(
            id: "custom-\(UUID().uuidString)",
            builtInKind: nil,
            name: name,
            videoCodec: preset.videoCodec,
            container: preset.container,
            audio: preset.audio,
            bitrate1080p: preset.bitrate1080p,
            bitrateRange: preset.bitrateRange
        )
    }

    // MARK: - 内置预设（设计文档 §6.6）

    static let compatible = builtIn(
        .compatible,
        videoCodec: .h264,
        audioBitrate: 192_000,
        bitrate1080p: 8_000_000,
        bitrateRange: 2_500_000...12_000_000
    )

    static let balanced = builtIn(
        .balanced,
        videoCodec: .hevc,
        audioBitrate: 192_000,
        bitrate1080p: 6_000_000,
        bitrateRange: 2_000_000...16_000_000
    )

    static let compact = builtIn(
        .compact,
        videoCodec: .h264,
        audioBitrate: 128_000,
        bitrate1080p: 3_000_000,
        bitrateRange: 1_500_000...6_000_000
    )

    static let highQuality = builtIn(
        .highQuality,
        videoCodec: .hevc,
        audioBitrate: 256_000,
        bitrate1080p: 12_000_000,
        bitrateRange: 4_000_000...40_000_000
    )

    /// P2 内置列表（「剪辑用 ProRes」随 P4 的 ProRes + MOV 支持加入）。
    static let builtIns: [TranscodePreset] = [.compatible, .balanced, .compact, .highQuality]

    /// 默认预设：兼容优先。
    static let defaultPreset = TranscodePreset.compatible

    // MARK: - 展示与估算

    var summary: String {
        "\(videoCodec.displayName) · \(container.displayName) · AAC \(audio.bitrate / 1000) kbps"
    }

    /// 基准码率行，如 “基准 8 Mbps @1080p”。
    var bitrateLabel: String {
        "基准 \(Fmt.mbps(bitrate1080p)) @1080p"
    }

    /// 夹取范围行，如 “2.5–12 Mbps”。
    var bitrateRangeLabel: String {
        "\(Fmt.mbpsNumber(bitrateRange.lowerBound))–\(Fmt.mbps(bitrateRange.upperBound))"
    }

    /// 预计输出大小（字节）；仅估算，接受 ±20%（设计文档 §12）。
    func estimatedBytes(durationSeconds: Double, videoWidth: Int, videoHeight: Int) -> Int64 {
        let videoBits = Double(averageBitrate(videoWidth: videoWidth, videoHeight: videoHeight)) * durationSeconds
        let audioBits = Double(audio.bitrate) * durationSeconds
        return Int64((videoBits + audioBits) / 8.0 * 1.05)
    }

    /// 预设卡片的估算基准：1080p · 1 小时。
    var hourly1080pEstimateLabel: String {
        let bytes = estimatedBytes(durationSeconds: 3600, videoWidth: 1920, videoHeight: 1080)
        return "1080p · 1 小时 ≈ \(Fmt.bytes(bytes))"
    }

    /// 按输出像素数估算平均码率（1080p 为基准，按预设范围夹取）。
    func averageBitrate(videoWidth: Int, videoHeight: Int) -> Int {
        let pixels = Double(max(videoWidth, 2) * max(videoHeight, 2))
        let scale = pixels / (1920.0 * 1080.0)
        let raw = Double(bitrate1080p) * scale
        return Int(min(max(raw, Double(bitrateRange.lowerBound)), Double(bitrateRange.upperBound)))
    }
}
