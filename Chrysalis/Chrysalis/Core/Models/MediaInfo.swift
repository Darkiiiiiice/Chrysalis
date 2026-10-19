import CoreMedia
import Foundation

/// 输入媒体信息快照（值类型，跨隔离域安全传递；设计文档 §6.1 预检的产物）。
struct MediaInfo: Sendable, Equatable, Codable {
    /// 容器显示名（MP4 / MOV / M4V）。
    var containerLabel: String
    var fileSizeBytes: Int64
    var durationSeconds: Double
    var video: VideoStreamInfo?
    var audio: AudioStreamInfo?
    var isHDR: Bool
    /// HDR 形态描述，如 “HDR10（PQ）”“HLG”。
    var hdrLabel: String?
    var hasProtectedContent: Bool

    var dimensionsLabel: String {
        guard let video else { return "—" }
        return "\(video.displayWidth)×\(video.displayHeight)"
    }

    var durationLabel: String { Fmt.duration(seconds: durationSeconds) }
}

/// 视频轨信息。
struct VideoStreamInfo: Sendable, Equatable, Codable {
    var codecFourCC: String
    var codecName: String
    var displayWidth: Int
    var displayHeight: Int
    var frameRate: Double
    var bitrate: Int?
    var hardwareDecodeSupported: Bool
}

/// 音频轨信息。
struct AudioStreamInfo: Sendable, Equatable, Codable {
    var codecFourCC: String
    var codecName: String
    var channelCount: Int
    var sampleRate: Double
    var bitrate: Int?
}
