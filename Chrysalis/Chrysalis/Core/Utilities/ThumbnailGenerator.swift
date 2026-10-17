@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// 缩略图载荷：CGImage 不可变，跨隔离域安全（仅用于列表展示）。
struct ThumbnailPayload: @unchecked Sendable {
    var image: CGImage
}

/// 任务行缩略图生成（64×36 展示尺寸的 2 倍图）。
enum ThumbnailGenerator {
    static func generate(for url: URL, durationSeconds: Double) async -> ThumbnailPayload? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 128, height: 72)

        // 取片头 10% 处；过短的视频直接取 0 秒。
        let seconds = durationSeconds > 1
            ? min(durationSeconds * 0.1, durationSeconds - 0.1)
            : 0
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)

        guard let result = try? await generator.image(at: time) else { return nil }
        return ThumbnailPayload(image: result.image)
    }
}
