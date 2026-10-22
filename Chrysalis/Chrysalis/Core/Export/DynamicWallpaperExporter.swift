@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 动态壁纸导出（设计文档 §7.19，灵感 15）
// macOS 动态壁纸 .heic：16 张 HEVC 编码帧 + 主图 XMP 元数据 apple_desktop:dynamic
// （base64 编码 plist，时间模式随一天时刻切换）。ImageIO 软件路径，不进转码队列。

enum WallpaperExportError: LocalizedError, Equatable, Sendable {
    case noVideoTrack
    case frameFailed(String)
    case heicUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "该文件没有视频轨，无法导出动态壁纸。"
        case .frameFailed(let message):
            "抽帧失败：\(message)"
        case .heicUnavailable:
            "本机不支持 HEIC 图像编码，无法导出动态壁纸。"
        case .writeFailed(let message):
            "动态壁纸写入失败：\(message)"
        }
    }
}

enum DynamicWallpaperExporter {
    /// 状态数（时间模式固定 16 状态）。
    static let stateCount = 16
    /// 一天的分钟数（状态 t 值域 [0, 1439]）。
    static let minutesPerDay = 1440
    /// 壁纸安全宽度上限（超过则等比缩放）。
    static let maxWidth: Int = 5120
    /// HEIC 有损质量。
    static let heicQuality: Double = 0.85

    // MARK: - 纯函数（harness 可测）

    /// 时间模式状态表：16 项，t 均匀映射到一天分钟数（首 0、末 1439）。
    static func states() -> [(index: Int, minute: Int)] {
        guard stateCount > 1 else { return [] }
        return (0..<stateCount).map { index in
            (index: index, minute: Int((Double(index) * Double(minutesPerDay - 1) / Double(stateCount - 1)).rounded()))
        }
    }

    /// 时间模式 plist（XML → Data）：`{"d": [{"i": x, "t": y}, ...]}`。
    static func plistData() -> Data? {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>d</key><array>"
        for state in states() {
            xml += "<dict><key>i</key><integer>\(state.index)</integer><key>t</key><integer>\(state.minute)</integer></dict>"
        }
        xml += "</array></dict></plist>"
        return xml.data(using: .utf8)
    }

    /// plist → base64 字符串（apple_desktop tag 值）。
    static func base64Plist() -> String? {
        plistData().map { $0.base64EncodedString() }
    }

    /// 壁纸帧尺寸：跟随源，宽超 5120 等比缩放（高取整）。
    static func outputSize(sourceWidth: Int, sourceHeight: Int) -> CGSize? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let width = min(sourceWidth, maxWidth)
        let scale = CGFloat(width) / CGFloat(sourceWidth)
        return CGSize(width: CGFloat(width), height: (CGFloat(sourceHeight) * scale).rounded())
    }

    // MARK: - 导出

    /// 导出动态壁纸：16 帧抽帧 → HEIC 序列 + apple_desktop 元数据，原子落盘到 outputURL。
    ///
    /// - Returns: 最终输出 URL。
    @discardableResult
    static func export(
        url: URL,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              tracks.contains(where: { $0.mediaType == .video })
        else {
            throw WallpaperExportError.noVideoTrack
        }
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as NSArray).compactMap { $0 as? String }
        guard identifiers.contains(UTType.heic.identifier) else {
            throw WallpaperExportError.heicUnavailable
        }
        let duration = ((try? await asset.load(.duration))?.seconds ?? 0)
        let times = SpriteSheetExporter.sampleTimes(durationSeconds: duration, count: stateCount)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !times.isEmpty else {
            throw WallpaperExportError.frameFailed("时长无效")
        }

        // 抽帧（preferredTransform 摆正朝向；首帧定尺寸；单帧失败容忍跳过，最终按实收帧数写序列）
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var tiles: [CGImage] = []
        var size: CGSize?
        for (index, time) in times.enumerated() {
            if let result = try? await generator.image(at: time) {
                let frame = result.image
                if size == nil {
                    let computed = outputSize(sourceWidth: frame.width, sourceHeight: frame.height)
                    size = computed
                }
                if let size, size.width > 0, size.height > 0 {
                    if let tile = SpriteSheetExporter.resizedTile(image: frame, width: size.width, height: size.height) {
                        tiles.append(tile)
                    }
                }
            }
            progress(Double(index + 1) / Double(times.count))
        }
        guard !tiles.isEmpty, let size else {
            throw WallpaperExportError.frameFailed("未能抽取出任何帧")
        }

        // HEIC 序列写入（主图携带 apple_desktop:dynamic 元数据）
        let tempURL = OutputPlanner.makeTempURL(in: outputURL.deletingLastPathComponent())
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.heic.identifier as CFString,
            tiles.count,
            nil
        ) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw WallpaperExportError.writeFailed("无法创建 HEIC 写入器")
        }
        let frameProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: heicQuality,
        ]

        let metadata = CGImageMetadataCreateMutable()
        // 自定义前缀必须先注册，SetTagWithPath 才能命中路径
        CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            "http://ns.apple.com/namespace/1.0/" as CFString,
            "apple_desktop" as CFString,
            nil
        )
        guard let base64 = base64Plist(),
              let tag = CGImageMetadataTagCreate(
                "http://ns.apple.com/namespace/1.0/" as CFString,
                "apple_desktop" as CFString,
                "dynamic" as CFString,
                .string,
                base64 as CFString
              ),
              CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:dynamic" as CFString, tag)
        else {
            try? FileManager.default.removeItem(at: tempURL)
            throw WallpaperExportError.writeFailed("无法构建壁纸元数据")
        }

        for (index, tile) in tiles.enumerated() {
            if index == 0 {
                CGImageDestinationAddImageAndMetadata(destination, tile, metadata, frameProperties as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, tile, frameProperties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw WallpaperExportError.writeFailed("HEIC 编码失败")
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
            throw WallpaperExportError.writeFailed("移动输出文件失败：\(errorText(error))")
        }
        return finalURL
    }

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "无错误详情" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }
}
