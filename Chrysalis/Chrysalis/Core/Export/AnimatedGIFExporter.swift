@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - GIF 动图导出（设计文档 §7.18，灵感 14）
// 衍生品导出：不进转码队列、不经视频硬件编码器要求；
// AVAssetReader 顺序扫描按 PTS 匹配目标帧（体检抽帧同模式）→ CIImage 缩放 →
// CGImageDestination（com.compuserve.gif，ImageIO 自动 256 色量化）。

/// GIF 宽度三档（设计文档 §7.18 拍板：帧率固定 12fps、无限循环）。
enum GifWidth: Int, CaseIterable, Codable, Sendable, Identifiable {
    case w240 = 240
    case w360 = 360
    case w480 = 480

    var id: Int { rawValue }

    var displayName: String { "\(rawValue) px" }

    /// 帧率固定 12fps（拍板默认）。
    static let frameRate: Double = 12

    /// 超过该时长提示体积（不硬拦）。
    static let longClipSeconds: Double = 60

    var frameDelay: Double { 1.0 / Double(Self.frameRate) }
}

enum GIFExportError: LocalizedError, Equatable, Sendable {
    case noVideoTrack
    case tooShort
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "该文件没有视频轨，无法导出 GIF。"
        case .tooShort:
            "视频太短（不足一帧间隔），无法导出 GIF。"
        case .readFailed(let message):
            "视频读取失败：\(message)"
        case .writeFailed(let message):
            "GIF 写入失败：\(message)"
        }
    }
}

enum AnimatedGIFExporter {
    /// 目标帧时间序列：时长按 12fps 均匀切分（harness 可测；短源 clamp 防空序列）。
    static func targetTimes(durationSeconds: Double, frameRate: Double = GifWidth.frameRate) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0, frameRate > 0 else { return [] }
        let count = Int((durationSeconds * frameRate).rounded(.down))
        guard count > 0 else { return [] }
        let interval = durationSeconds / Double(count)
        return (0..<count).map { Double($0) * interval }
    }

    /// 导出 GIF：顺序扫描 + PTS 匹配目标帧，原子落盘到 outputURL（重名 `-1` 由调用方语义兜底）。
    ///
    /// - Returns: 最终输出 URL。
    @discardableResult
    static func export(
        url: URL,
        width: GifWidth,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let videoTrack = tracks.first(where: { $0.mediaType == .video })
        else {
            throw GIFExportError.noVideoTrack
        }
        let duration = ((try? await asset.load(.duration))?.seconds ?? 0)
        let times = targetTimes(durationSeconds: duration)
        guard !times.isEmpty else {
            throw GIFExportError.tooShort
        }

        // 读取端：BGRA（CIImage 直接消费）
        let reader = try AVAssetReader(asset: asset)
        let output = try AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        // 从片头读（起点落 GOP 中间会输出异常截断——§7.14 实测）；循环内按目标点顺序匹配
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(duration, 0), preferredTimescale: 600)
        )

        // 写入端：GIF destination（无限循环 + 每帧延时）
        let tempURL = OutputPlanner.makeTempURL(in: outputURL.deletingLastPathComponent())
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.gif.identifier as CFString,
            times.count,
            nil
        ) else {
            throw GIFExportError.writeFailed("无法创建 GIF 写入器")
        }
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,  // 无限循环
            ],
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: width.frameDelay,
            ],
        ]

        let context = CIContext(options: [.cacheIntermediates: false])
        let halfInterval = 0.5 / GifWidth.frameRate

        // provider 在 start 前注册（macOS 27 新 API；内部会注册 output，勿再 reader.add）
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw GIFExportError.readFailed(errorText(error))
        }
        defer { reader.cancelReading() }

        var frames: [CGImage] = []
        var targetIndex = 0
        while let sample = try await provider.next() {
            if targetIndex >= times.count { break }
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite else { continue }
            guard let readOnly = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { continue }
            // 目标点匹配：第一个 PTS ≥ 目标 − 半帧间隔的帧（±1 帧误差可接受）
            if pts >= times[targetIndex] - halfInterval {
                let image = try readOnly.content.withUnsafeBuffer { buffer in
                    scaledCGImage(pixelBuffer: buffer, width: width.rawValue, context: context)
                }
                if let image {
                    frames.append(image)
                }
                targetIndex += 1
                progress(Double(targetIndex) / Double(times.count))
            }
        }
        guard !frames.isEmpty else {
            try? FileManager.default.removeItem(at: tempURL)
            throw GIFExportError.readFailed("未能解码出任何帧")
        }
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw GIFExportError.writeFailed("GIF 编码失败")
        }
        progress(1.0)

        // 原子落盘：重名加 `-1` 不覆盖
        let finalURL: URL
        do {
            let fileManager = FileManager.default
            let target = fileManager.fileExists(atPath: outputURL.path)
                ? OutputPlanner.uniqueOutputURL(
                    directory: outputURL.deletingLastPathComponent(),
                    baseName: outputURL.deletingPathExtension().lastPathComponent,
                    fileExtension: outputURL.pathExtension
                )
                : outputURL
            try fileManager.moveItem(at: tempURL, to: target)
            finalURL = target
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw GIFExportError.writeFailed("移动输出文件失败：\(errorText(error))")
        }
        return finalURL
    }

    // MARK: - 纯函数与工具

    /// 帧等比缩放到目标宽度（高取整），渲染为 CGImage。
    static func scaledCGImage(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        context: CIContext
    ) -> CGImage? {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceWidth = input.extent.width
        guard sourceWidth > 0 else { return nil }
        let scale = CGFloat(width) / sourceWidth
        let scaled = input
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(
                x: 0, y: 0,
                width: CGFloat(width),
                height: (input.extent.height * scale).rounded()
            ))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "无错误详情" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }
}
