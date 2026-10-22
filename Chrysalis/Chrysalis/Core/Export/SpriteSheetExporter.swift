@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 缩略图雪碧图导出（设计文档 §7.18，灵感 14）
// 均匀 N 段取段中点 → AVAssetImageGenerator 批量抽帧 → CGContext 网格拼接 → JPEG。
// 衍生品导出：不进转码队列、不经视频硬件编码器要求（ImageIO 软件路径）。

/// 雪碧图网格档位（设计文档 §7.18 拍板：单帧宽 320 等比、JPEG 输出）。
enum SpriteLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 5×4 = 20 帧（进度条预览用）。
    case grid5x4
    /// 8×6 = 48 帧（缩略图墙）。
    case grid8x6

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grid5x4: "5×4（20 帧）"
        case .grid8x6: "8×6（48 帧）"
        }
    }

    var columns: Int {
        switch self {
        case .grid5x4: 5
        case .grid8x6: 8
        }
    }

    var rows: Int {
        switch self {
        case .grid5x4: 4
        case .grid8x6: 6
        }
    }

    /// 单帧宽度（等比缩放目标）。
    static let tileWidth: Int = 320

    /// JPEG 质量。
    static let jpegQuality: Double = 0.85
}

enum SpriteExportError: LocalizedError, Equatable, Sendable {
    case noVideoTrack
    case frameFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "该文件没有视频轨，无法生成雪碧图。"
        case .frameFailed(let message):
            "抽帧失败：\(message)"
        case .writeFailed(let message):
            "雪碧图写入失败：\(message)"
        }
    }
}

enum SpriteSheetExporter {
    /// 取点时间序列：均匀 N 段取段中点，短源 clamp 到时长内（harness 可测）。
    static func sampleTimes(durationSeconds: Double, count: Int) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0, count > 0 else { return [] }
        return (0..<count).map { index in
            let midpoint = durationSeconds * (Double(index) + 0.5) / Double(count)
            return min(max(midpoint, 0), max(durationSeconds - 0.05, 0))
        }
    }

    /// 画布尺寸：单帧宽 320 等比（高由源长宽比取整），全帧同尺寸。
    static func canvasSize(sourceWidth: Int, sourceHeight: Int, layout: SpriteLayout) -> CGSize? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = CGFloat(SpriteLayout.tileWidth) / CGFloat(sourceWidth)
        let tileHeight = max((CGFloat(sourceHeight) * scale).rounded(), 2)
        return CGSize(
            width: CGFloat(layout.columns * SpriteLayout.tileWidth),
            height: tileHeight * CGFloat(layout.rows)
        )
    }

    /// 导出雪碧图：批量抽帧 → 网格拼接 → JPEG，原子落盘到 outputURL。
    ///
    /// - Returns: 最终输出 URL。
    @discardableResult
    static func export(
        url: URL,
        layout: SpriteLayout,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              tracks.contains(where: { $0.mediaType == .video })
        else {
            throw SpriteExportError.noVideoTrack
        }
        let duration = ((try? await asset.load(.duration))?.seconds ?? 0)
        let count = layout.columns * layout.rows
        let times = sampleTimes(durationSeconds: duration, count: count).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        guard !times.isEmpty else {
            throw SpriteExportError.frameFailed("时长无效")
        }

        // 批量抽帧（preferredTransform 摆正朝向；首帧确定画布长宽比；单帧失败容忍跳过）
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var tiles: [CGImage] = []
        var canvas: CGSize?
        for (index, time) in times.enumerated() {
            if let result = try? await generator.image(at: time) {
                let frame = result.image
                if canvas == nil {
                    canvas = canvasSize(sourceWidth: frame.width, sourceHeight: frame.height, layout: layout)
                }
                if let size = canvas, size.width > 0, size.height > 0 {
                    let tileHeight = size.height / CGFloat(layout.rows)
                    if let tile = resizedTile(image: frame, width: CGFloat(SpriteLayout.tileWidth), height: tileHeight) {
                        tiles.append(tile)
                    }
                }
            }
            progress(Double(index + 1) / Double(count))
        }
        guard !tiles.isEmpty, let size = canvas else {
            throw SpriteExportError.frameFailed("未能抽取出任何帧")
        }

        // 网格拼接：BGRA 画布逐帧绘制
        let tileWidth = CGFloat(SpriteLayout.tileWidth)
        let tileHeight = size.height / CGFloat(layout.rows)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SpriteExportError.writeFailed("无法创建画布")
        }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        for (index, tile) in tiles.enumerated() {
            let column = index % layout.columns
            let row = index / layout.columns
            // CGContext 位图坐标 y 向上：第 0 行画在画布顶部
            let y = CGFloat(layout.rows - 1 - row) * tileHeight
            context.draw(tile, in: CGRect(
                x: CGFloat(column) * tileWidth,
                y: y,
                width: tileWidth,
                height: tileHeight
            ))
        }
        guard let composited = context.makeImage() else {
            throw SpriteExportError.writeFailed("画布合成失败")
        }

        // JPEG 写盘（原子落盘 + 重名 -1）
        let tempURL = OutputPlanner.makeTempURL(in: outputURL.deletingLastPathComponent())
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SpriteExportError.writeFailed("无法创建 JPEG 写入器")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: SpriteLayout.jpegQuality,
        ]
        CGImageDestinationAddImage(destination, composited, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SpriteExportError.writeFailed("JPEG 编码失败")
        }
        progress(1.0)

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
            throw SpriteExportError.writeFailed("移动输出文件失败：\(errorText(error))")
        }
        return finalURL
    }

    // MARK: - 工具

    /// 等比缩放到目标尺寸（长宽比不一致时填充居中——generator 输出与源同比例，实际等比直达；雪碧图 / 动态壁纸共用）。
    static func resizedTile(image: CGImage, width: CGFloat, height: CGFloat) -> CGImage? {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(width / sourceWidth, height / sourceHeight)
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        guard let context = CGContext(
            data: nil,
            width: Int(width.rounded()),
            height: Int(height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: Int(width.rounded()) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // 居中绘制（同比例时恰好铺满）
        context.draw(image, in: CGRect(
            x: (width - drawWidth) / 2,
            y: (height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        ))
        return context.makeImage()
    }

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "无错误详情" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }
}
