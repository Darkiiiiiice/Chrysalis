@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - 体检共享抽帧器（设计文档 §7.14）
// 假 4K 检测与 pHash 指纹共用：抓取指定时间点的亮度平面（420v）转 Float 灰度。

/// 一张灰度帧（亮度值 0–1，宽高为帧尺寸）。
struct GrayFrame: Sendable {
    var pts: Double
    var width: Int
    var height: Int
    var luma: [Float]
}

enum ProbeFrameGrabber {
    /// 批量抓取多个时间点各一帧：单 reader 覆盖 [最早-0.5s, 最晚+0.5s] 一次扫描，
    /// 每个时间点捕获扫描中第一个 PTS ≥ 时间点 −0.25s 的帧
    /// （B 帧解码序输出使 PTS 交错，且规避连续创建 reader 的不稳定——§7.14）。
    static func grabGrayFrames(
        url: URL,
        at times: [Double],
        sourceDuration: Double
    ) async throws -> [GrayFrame] {
        guard !times.isEmpty else { return [] }
        let sorted = times.sorted()
        let windowStart = max(sorted.first! - 0.5, 0)
        let windowEnd = min(sorted.last! + 0.5, max(sourceDuration, sorted.last! + 0.1))

        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let videoTrack = tracks.first(where: { $0.mediaType == .video }),
              let reader = try? AVAssetReader(asset: asset),
              let output = try? AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              ])
        else { return [] }
        reader.add(output)
        // 从片头开始读（起点落在 GOP 中间会导致解码器输出异常截断——§7.14 实测）；
        // 循环内按 targets 顺序跳过早于目标点的帧
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: windowEnd, preferredTimescale: 600)
        )
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var targets = sorted
        var results: [GrayFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            if !targets.isEmpty, pts >= targets[0] - 0.25 {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                guard let frame = grayFrame(from: pixelBuffer, pts: pts) else { continue }
                results.append(frame)
                targets.removeFirst()
            }
        }
        return results
    }

    /// 抓取单个时间点最近的一帧灰度。
    static func grabGrayFrame(
        url: URL,
        at seconds: Double,
        sourceDuration: Double
    ) async throws -> GrayFrame? {
        let frames = try await grabGrayFrames(url: url, at: [seconds], sourceDuration: sourceDuration)
        return frames.first
    }

    /// CVPixelBuffer（420v）→ 灰度 Float（Y 平面，0–1 归一）。
    static func grayFrame(from pixelBuffer: CVPixelBuffer, pts: Double) -> GrayFrame? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 1
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var luma = [Float](repeating: 0, count: width * height)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let rowStart = row * stride
            for col in 0..<width {
                // video range 16–235 → 0–1（Int 转换防 UInt8 下溢：Y < 16 的像素存在）
                luma[row * width + col] = (Float(pointer[rowStart + col]) - 16.0) / 219.0
            }
        }
        return GrayFrame(pts: pts, width: width, height: height, luma: luma)
    }
}
