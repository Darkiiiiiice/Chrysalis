import AVFoundation
import Foundation
import VideoToolbox

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

/// 输出分辨率档位（设计文档 P3.5）：短边匹配、只缩不放、偶数对齐。
enum ResolutionSetting: String, Sendable, Codable, CaseIterable {
    case source
    case r2160
    case r1440
    case r1080
    case r720
    case r480

    var displayName: String {
        switch self {
        case .source: "保持源"
        case .r2160: "2160p"
        case .r1440: "1440p"
        case .r1080: "1080p"
        case .r720: "720p"
        case .r480: "480p"
        }
    }

    /// 目标短边（像素）；`source` 为 nil。
    var targetShortSide: Int? {
        switch self {
        case .source: nil
        case .r2160: 2160
        case .r1440: 1440
        case .r1080: 1080
        case .r720: 720
        case .r480: 480
        }
    }

    /// 源显示尺寸 → 输出尺寸：短边匹配、只缩不放、偶数对齐；
    /// 源不比目标大（无需缩放）时返回 nil。
    func renderSize(sourceWidth: Int, sourceHeight: Int) -> CGSize? {
        guard let target = targetShortSide, sourceWidth > 0, sourceHeight > 0 else { return nil }
        let shortSide = min(sourceWidth, sourceHeight)
        guard shortSide > target else { return nil }
        let scale = Double(target) / Double(shortSide)
        let width = max(2, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(2, Int((Double(sourceHeight) * scale).rounded()))
        return CGSize(width: width - width % 2, height: height - height % 2)
    }

    /// 估算基准尺寸（「预计大小」按所选档位缩放）：保持源按 1080p 计。
    var estimateDimensions: (width: Int, height: Int) {
        switch self {
        case .source, .r1080: (1920, 1080)
        case .r2160: (3840, 2160)
        case .r1440: (2560, 1440)
        case .r720: (1280, 720)
        case .r480: (854, 480)
        }
    }

    /// 估算基准描述（如「1080p 基准」）。
    var estimateBasisLabel: String {
        self == .source ? "1080p 基准" : displayName
    }

    /// 摘要短名（“保持源” → “源分辨率”）。
    var summaryLabel: String {
        self == .source ? "源分辨率" : displayName
    }
}

/// 输出帧率档位（设计文档 P3.5）：只降不升。
enum FrameRateSetting: String, Sendable, Codable, CaseIterable {
    case source
    case fps60
    case fps30
    case fps24
    case fps15

    var displayName: String {
        switch self {
        case .source: "保持源"
        case .fps60: "60 fps"
        case .fps30: "30 fps"
        case .fps24: "24 fps"
        case .fps15: "15 fps"
        }
    }

    /// 摘要短名（“保持源” → “源帧率”）。
    var summaryLabel: String {
        self == .source ? "源帧率" : displayName
    }

    /// 目标帧率；`source` 为 nil。
    var targetFPS: Double? {
        switch self {
        case .source: nil
        case .fps60: 60
        case .fps30: 30
        case .fps24: 24
        case .fps15: 15
        }
    }

    /// 实际输出帧率：目标高于源帧率时保持源（只降不升）。
    func effectiveFrameRate(sourceFPS: Double) -> Double {
        guard let target = targetFPS else { return sourceFPS }
        guard sourceFPS > 0 else { return target }
        return min(target, sourceFPS)
    }
}

/// 码率控制方式（设计文档 P4）。
enum BitrateMode: String, Sendable, Codable, CaseIterable {
    /// 平均码率（P2/P3.5 行为）：按 1080p 基准缩放并夹取。
    case targetBitrate
    /// 质量优先：`AVVideoQualityKey`，编码器按内容分配码率（体积浮动）。
    case quality
    /// 目标大小：每个输出文件约 N MB，按时长与音频扣除换算码率。
    case targetSize

    var displayName: String {
        switch self {
        case .targetBitrate: "平均码率"
        case .quality: "质量优先"
        case .targetSize: "目标大小"
        }
    }
}

/// 关键帧间隔（设计文档 P4）：折算为「秒 × 输出帧率」。
enum KeyframeIntervalSetting: String, Sendable, Codable, CaseIterable {
    case auto
    case s1
    case s2
    case s5
    case s10

    var displayName: String {
        switch self {
        case .auto: "自动（2 秒）"
        case .s1: "1 秒"
        case .s2: "2 秒"
        case .s5: "5 秒"
        case .s10: "10 秒"
        }
    }

    /// 间隔秒数；`auto` 为 2 秒（P2/P3.5 行为：帧率 × 2）。
    var seconds: Double {
        switch self {
        case .auto, .s2: 2
        case .s1: 1
        case .s5: 5
        case .s10: 10
        }
    }

    /// 摘要短名（“自动（2 秒）”→“关键帧 2 秒”）。
    var summaryLabel: String {
        self == .auto ? "关键帧自动" : "关键帧 \(Int(seconds)) 秒"
    }
}

/// H.264 Profile（设计文档 P4）；HEVC 仅 Main（自动），ProRes 不适用。
enum VideoProfileSetting: String, Sendable, Codable, CaseIterable {
    case auto
    case baseline
    case main
    case high

    var displayName: String {
        switch self {
        case .auto: "自动"
        case .baseline: "Baseline"
        case .main: "Main"
        case .high: "High"
        }
    }

    /// 该编码可选的 Profile 档位（HEVC 与 ProRes 只有「自动」）。
    static func choices(for codec: VideoCodec) -> [VideoProfileSetting] {
        codec == .h264 ? allCases : [.auto]
    }

    /// 写入 `AVVideoProfileLevelKey` 的值；ProRes 不适用返回 nil。
    func profileLevel(for codec: VideoCodec) -> String? {
        switch codec {
        case .h264:
            switch self {
            case .auto, .high: AVVideoProfileLevelH264HighAutoLevel
            case .main: AVVideoProfileLevelH264MainAutoLevel
            case .baseline: AVVideoProfileLevelH264BaselineAutoLevel
            }
        case .hevc:
            kVTProfileLevel_HEVC_Main_AutoLevel as String
        default:
            nil
        }
    }
}

/// 音频策略：MP4/MOV 统一转 AAC-LC（设计文档 §6.3）；ProRes MOV 用 PCM。
struct AudioPolicy: Sendable, Equatable, Codable {
    /// AAC 码率（bps）。
    var bitrate: Int
    /// 目标采样率；nil 表示保持源采样率。
    var sampleRateOverride: Double?
    /// v1 只输出单声道/立体声（5.1 下混留待 v1.1）。
    var maxChannels: Int
    /// ProRes 输出的 PCM 位深（16 / 24）；nil 表示 AAC（按 `bitrate` 编码）。
    var pcmBitDepth: Int? = nil

    /// 自定义预设可选的音频码率（设计文档 §6.3 / §6.6；320 为系统编码器上限）。
    static let bitrateChoices = [96_000, 128_000, 192_000, 256_000, 320_000]

    /// 可覆盖的采样率（设计文档 P3.5）：44.1 / 48 kHz；其他源采样率规整到 48 kHz。
    static let sampleRateChoices: [Double] = [44_100, 48_000]

    /// ProRes 可选的 PCM 位深（设计文档 §6.3）。
    static let pcmBitDepthChoices = [16, 24]

    /// 是否输出 PCM（ProRes）。
    var isPCM: Bool { pcmBitDepth != nil }

    /// 编码口径文案，如 “AAC 192 kbps” / “PCM 16-bit”。
    var codecLabel: String {
        if let pcmBitDepth { return "PCM \(pcmBitDepth)-bit" }
        return "AAC \(bitrate / 1000) kbps"
    }

    /// 估算/磁盘预检用音频码率（bps）；PCM 未指定采样率时按 48 kHz 基准。
    func estimatedBitsPerSecond() -> Int {
        guard let pcmBitDepth else {
            return Self.effectiveBitrate(bitrate, channels: maxChannels)
        }
        return BitratePlanner.pcmBitrate(
            sampleRate: sampleRateOverride ?? 48_000,
            channels: maxChannels,
            bitDepth: pcmBitDepth
        )
    }

    /// 立体声 AAC 默认策略。
    static func stereoAAC(bitrate: Int) -> AudioPolicy {
        AudioPolicy(bitrate: bitrate, sampleRateOverride: nil, maxChannels: 2)
    }

    /// 声道文案（v1 只输出单声道/立体声）。
    var channelLabel: String { maxChannels == 1 ? "单声道" : "立体声" }

    /// 采样率文案（「保持源」或被覆盖的值）。
    var sampleRateLabel: String {
        guard let sampleRateOverride else { return "保持源" }
        return sampleRateOverride == 44_100 ? "44.1 kHz" : "48 kHz"
    }

    /// 编码器实际可用码率：单声道上限 256 kbps（实测 320 被系统 AAC 编码器拒绝）。
    static func effectiveBitrate(_ bitrate: Int, channels: Int) -> Int {
        channels == 1 ? min(bitrate, 256_000) : bitrate
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
    /// 输出分辨率档位（设计文档 P3.5；默认保持源、不放大）。
    var resolution: ResolutionSetting
    /// 输出帧率档位（设计文档 P3.5；默认保持源）。
    var frameRate: FrameRateSetting
    var audio: AudioPolicy
    /// 1080p 基准平均码率（bps）；按输出像素数缩放并夹取到 `bitrateRange`。
    var bitrate1080p: Int
    /// 平均码率夹取范围（bps）；自定义预设继承来源预置的范围并随基准码率等比缩放。
    var bitrateRange: ClosedRange<Int>
    /// 码率控制方式（P4）；ProRes 不适用（固定为编码档位码率）。
    var bitrateMode: BitrateMode = .targetBitrate
    /// 质量优先的质量值（0.05–1.0；仅 `bitrateMode == .quality` 生效）。
    var quality: Double = 0.65
    /// 目标大小（MB / 每个输出文件；仅 `bitrateMode == .targetSize` 生效）。
    var targetSizeMB: Int = 700
    /// 关键帧间隔（H.264 / HEVC；ProRes 帧内编码不适用）。
    var keyframeInterval: KeyframeIntervalSetting = .auto
    /// H.264 Profile；HEVC / ProRes 仅「自动」。
    var profile: VideoProfileSetting = .auto

    var isBuiltIn: Bool { builtInKind != nil }

    private enum CodingKeys: String, CodingKey {
        case builtInKind, id, name, videoCodec, container, resolution, frameRate
        case audio, bitrate1080p, bitrateRange
        case bitrateMode, quality, targetSizeMB, keyframeInterval, profile
    }

    /// 向后兼容解码：P3.5 之前的 presets.json 没有 resolution / frameRate，缺省「保持源」；
    /// P4 之前的没有码率模式/关键帧/Profile，缺省「平均码率 / 自动 / 自动」。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        builtInKind = try values.decodeIfPresent(Kind.self, forKey: .builtInKind)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        videoCodec = try values.decode(VideoCodec.self, forKey: .videoCodec)
        container = try values.decode(MediaContainer.self, forKey: .container)
        resolution = try values.decodeIfPresent(ResolutionSetting.self, forKey: .resolution) ?? .source
        frameRate = try values.decodeIfPresent(FrameRateSetting.self, forKey: .frameRate) ?? .source
        audio = try values.decode(AudioPolicy.self, forKey: .audio)
        bitrate1080p = try values.decode(Int.self, forKey: .bitrate1080p)
        bitrateRange = try values.decode(ClosedRange<Int>.self, forKey: .bitrateRange)
        bitrateMode = try values.decodeIfPresent(BitrateMode.self, forKey: .bitrateMode) ?? .targetBitrate
        quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? 0.65
        targetSizeMB = try values.decodeIfPresent(Int.self, forKey: .targetSizeMB) ?? 700
        keyframeInterval = try values.decodeIfPresent(KeyframeIntervalSetting.self, forKey: .keyframeInterval) ?? .auto
        profile = try values.decodeIfPresent(VideoProfileSetting.self, forKey: .profile) ?? .auto
    }

    private init(
        id: String,
        builtInKind: Kind?,
        name: String,
        videoCodec: VideoCodec,
        container: MediaContainer,
        resolution: ResolutionSetting = .source,
        frameRate: FrameRateSetting = .source,
        audio: AudioPolicy,
        bitrate1080p: Int,
        bitrateRange: ClosedRange<Int>,
        bitrateMode: BitrateMode = .targetBitrate,
        quality: Double = 0.65,
        targetSizeMB: Int = 700,
        keyframeInterval: KeyframeIntervalSetting = .auto,
        profile: VideoProfileSetting = .auto
    ) {
        self.id = id
        self.builtInKind = builtInKind
        self.name = name
        self.videoCodec = videoCodec
        self.container = container
        self.resolution = resolution
        self.frameRate = frameRate
        self.audio = audio
        self.bitrate1080p = bitrate1080p
        self.bitrateRange = bitrateRange
        self.bitrateMode = bitrateMode
        self.quality = quality
        self.targetSizeMB = targetSizeMB
        self.keyframeInterval = keyframeInterval
        self.profile = profile
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

    /// 由现有预设复制为自定义（同编码/容器/分辨率/帧率/音频/码率与夹取范围）。
    static func copy(of preset: TranscodePreset, name: String) -> TranscodePreset {
        TranscodePreset(
            id: "custom-\(UUID().uuidString)",
            builtInKind: nil,
            name: name,
            videoCodec: preset.videoCodec,
            container: preset.container,
            resolution: preset.resolution,
            frameRate: preset.frameRate,
            audio: preset.audio,
            bitrate1080p: preset.bitrate1080p,
            bitrateRange: preset.bitrateRange,
            bitrateMode: preset.bitrateMode,
            quality: preset.quality,
            targetSizeMB: preset.targetSizeMB,
            keyframeInterval: preset.keyframeInterval,
            profile: preset.profile
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

    /// 「剪辑用 ProRes」（设计文档 §6.6）：ProRes 422 + MOV + PCM 16-bit 48 kHz。
    static let editingProRes = TranscodePreset(
        id: Kind.editingProRes.rawValue,
        builtInKind: .editingProRes,
        name: Kind.editingProRes.displayName,
        videoCodec: .proRes422,
        container: .mov,
        audio: AudioPolicy(
            bitrate: 192_000,
            sampleRateOverride: nil,
            maxChannels: 2,
            pcmBitDepth: 16
        ),
        bitrate1080p: 147_000_000,
        bitrateRange: 40_000_000...400_000_000
    )

    /// P2 内置列表 + P4「剪辑用 ProRes」。
    static let builtIns: [TranscodePreset] = [
        .compatible, .balanced, .compact, .highQuality, .editingProRes,
    ]

    /// 默认预设：兼容优先。
    static let defaultPreset = TranscodePreset.compatible

    // MARK: - 展示与估算

    var summary: String {
        "\(videoCodec.displayName) · \(container.displayName) · \(resolution.summaryLabel) · \(frameRate.summaryLabel)"
    }

    /// 音频口径行，如 “AAC 192 kbps · 立体声 · 保持源” / “PCM 16-bit · 立体声 · 保持源”。
    var audioSummary: String {
        "\(audio.codecLabel) · \(audio.channelLabel) · \(audio.sampleRateLabel)"
    }

    /// 码率口径行：平均码率 / 质量优先 / 目标大小 / ProRes 固定码率。
    var bitrateLabel: String {
        if videoCodec.isProRes {
            return "ProRes 固定码率（1080p30 ≈ \(Fmt.mbps(averageBitrate(videoWidth: 1920, videoHeight: 1080)))）"
        }
        switch bitrateMode {
        case .targetBitrate:
            return "基准 \(Fmt.mbps(bitrate1080p)) @1080p"
        case .quality:
            return "质量 \(String(format: "%.2f", quality))（体积随内容浮动）"
        case .targetSize:
            return "目标大小 ≈ \(targetSizeMB) MB / 文件"
        }
    }

    /// 夹取范围行，如 “2.5–12 Mbps”；ProRes 不适用。
    var bitrateRangeLabel: String {
        if videoCodec.isProRes { return "—" }
        return "\(Fmt.mbpsNumber(bitrateRange.lowerBound))–\(Fmt.mbps(bitrateRange.upperBound))"
    }

    /// 卡片第二行：音频 · 码率口径（非 ProRes 追加夹取范围）。
    var detailLabel: String {
        if videoCodec.isProRes {
            return "\(audioSummary) · \(bitrateLabel)"
        }
        return "\(audioSummary) · \(bitrateLabel) · 夹取 \(bitrateRangeLabel)"
    }

    /// 预计输出大小（字节）；仅估算，接受内容相关偏差（设计文档 §12 / P3.5）。
    func estimatedBytes(
        durationSeconds: Double,
        videoWidth: Int,
        videoHeight: Int,
        frameRate: Double = 30
    ) -> Int64 {
        if videoCodec.isProRes {
            let videoBits = Double(nominalVideoBitrate(
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                frameRate: frameRate
            )) * durationSeconds
            let audioBits = Double(audio.estimatedBitsPerSecond()) * durationSeconds
            return Int64((videoBits + audioBits) / 8.0 * 1.05)
        }
        // 目标大小模式：目标即文件总大小（音频已计入换算），不再叠加码率估算。
        if bitrateMode == .targetSize {
            return Int64(targetSizeMB) * 1_000_000
        }
        let videoBits = Double(nominalVideoBitrate(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            frameRate: frameRate
        )) * durationSeconds
        let audioBits = Double(audio.estimatedBitsPerSecond()) * durationSeconds
        return Int64((videoBits + audioBits) / 8.0 * 1.05)
    }

    /// 预设卡片的估算基准：所选分辨率 · 1 小时（保持源按 1080p 基准估算）。
    var hourlyEstimateLabel: String {
        if !videoCodec.isProRes, bitrateMode == .targetSize {
            return "每个文件 ≈ \(targetSizeMB) MB"
        }
        let dims = resolution.estimateDimensions
        let bytes = estimatedBytes(durationSeconds: 3600, videoWidth: dims.width, videoHeight: dims.height)
        let suffix = bitrateMode == .quality && !videoCodec.isProRes ? "（按质量推测）" : ""
        return "\(resolution.estimateBasisLabel) · 1 小时 ≈ \(Fmt.bytes(bytes))\(suffix)"
    }

    /// 输出视频的名义码率（UI 估算与磁盘预检用；ProRes 按时长外的像素/帧率换算）。
    func nominalVideoBitrate(videoWidth: Int, videoHeight: Int, frameRate: Double = 30) -> Int {
        if videoCodec.isProRes {
            return BitratePlanner.proResDataRate(
                codec: videoCodec,
                width: videoWidth,
                height: videoHeight,
                fps: frameRate
            )
        }
        switch bitrateMode {
        case .targetBitrate, .targetSize:
            return BitratePlanner.scaled(
                base1080p: bitrate1080p,
                range: bitrateRange,
                width: videoWidth,
                height: videoHeight
            )
        case .quality:
            return BitratePlanner.nominalQuality(
                codec: videoCodec,
                quality: quality,
                width: videoWidth,
                height: videoHeight
            )
        }
    }

    /// 按输出像素数估算平均码率（1080p 为基准，按预设范围夹取）；ProRes 返回档位标称数据率。
    func averageBitrate(videoWidth: Int, videoHeight: Int, frameRate: Double = 30) -> Int {
        if videoCodec.isProRes {
            return BitratePlanner.proResDataRate(
                codec: videoCodec,
                width: videoWidth,
                height: videoHeight,
                fps: frameRate
            )
        }
        return BitratePlanner.scaled(
            base1080p: bitrate1080p,
            range: bitrateRange,
            width: videoWidth,
            height: videoHeight
        )
    }
}
