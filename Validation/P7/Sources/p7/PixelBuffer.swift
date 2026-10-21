import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

enum PixelBuffer {
    static func make(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw P7Error.message("CVPixelBufferCreate 失败：\(status)")
        }
        return buffer
    }

    static func fillPattern(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = pixels + y * stride
            let green = UInt8((y * 255) / max(height - 1, 1))
            for x in 0..<width {
                let pixel = row + x * 4
                pixel[0] = UInt8((x * 255) / max(width - 1, 1))          // B
                pixel[1] = green                                        // G
                pixel[2] = UInt8((x * 13 + y * 7) & 0xFF)               // R
                pixel[3] = 255
            }
        }
    }

    static func copyTile(
        from source: CVPixelBuffer,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        into destination: CVPixelBuffer
    ) throws {
        guard CVPixelBufferGetWidth(destination) == width,
              CVPixelBufferGetHeight(destination) == height else {
            throw P7Error.message("tile 缓冲区尺寸不是 \(width)x\(height)")
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            throw P7Error.message("像素缓冲区没有基地址")
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = width * 4
        for row in 0..<height {
            memcpy(
                destinationBase + row * destinationStride,
                sourceBase + (y + row) * sourceStride + x * 4,
                rowBytes
            )
        }
    }

    /// 把 tile 输出按羽化 alpha 叠加到输出帧。
    /// 每个 tile 只在「与左侧/上方相邻 tile 的重叠区」做渐变；其余区域直接覆盖。
    static func composite(
        tile: CVPixelBuffer,
        into output: CVPixelBuffer,
        x: Int,
        y: Int,
        overlapX: Int,
        overlapY: Int,
        scale: Int
    ) throws {
        let tileWidth = CVPixelBufferGetWidth(tile)
        let tileHeight = CVPixelBufferGetHeight(tile)
        let outputWidth = CVPixelBufferGetWidth(output)
        let outputHeight = CVPixelBufferGetHeight(output)
        guard x + tileWidth <= outputWidth, y + tileHeight <= outputHeight else {
            throw P7Error.message("tile 越界：\(x),\(y) \(tileWidth)x\(tileHeight) / \(outputWidth)x\(outputHeight)")
        }

        var alphaX = [UInt16](repeating: 255, count: tileWidth)
        let rampX = min(overlapX * scale, tileWidth)
        if rampX > 0 {
            for index in 0..<rampX {
                alphaX[index] = UInt16((Double(index) + 0.5) / Double(rampX) * 255.0)
            }
        }
        var alphaY = [UInt16](repeating: 255, count: tileHeight)
        let rampY = min(overlapY * scale, tileHeight)
        if rampY > 0 {
            for index in 0..<rampY {
                alphaY[index] = UInt16((Double(index) + 0.5) / Double(rampY) * 255.0)
            }
        }

        CVPixelBufferLockBaseAddress(tile, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(tile, .readOnly)
        }
        guard let tileBase = CVPixelBufferGetBaseAddress(tile),
              let outputBase = CVPixelBufferGetBaseAddress(output) else {
            throw P7Error.message("像素缓冲区没有基地址")
        }
        let tileStride = CVPixelBufferGetBytesPerRow(tile)
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        let rowBytes = tileWidth * 4

        alphaX.withUnsafeBufferPointer { alphaX in
            alphaY.withUnsafeBufferPointer { alphaY in
                for row in 0..<tileHeight {
                    let sourceRow = tileBase + row * tileStride
                    let destinationRow = outputBase + (y + row) * outputStride + x * 4
                    let alphaYValue = Int(alphaY[row])
                    if alphaYValue == 255 && rampX == 0 {
                        memcpy(destinationRow, sourceRow, rowBytes)
                        continue
                    }
                    let source = sourceRow.assumingMemoryBound(to: UInt8.self)
                    let destination = destinationRow.assumingMemoryBound(to: UInt8.self)
                    for column in 0..<tileWidth {
                        let alpha = Int(alphaX[column]) * alphaYValue / 255
                        let sourcePixel = source + column * 4
                        let destinationPixel = destination + column * 4
                        if alpha >= 255 {
                            destinationPixel[0] = sourcePixel[0]
                            destinationPixel[1] = sourcePixel[1]
                            destinationPixel[2] = sourcePixel[2]
                            destinationPixel[3] = 255
                        } else if alpha > 0 {
                            let inverse = 255 - alpha
                            destinationPixel[0] = UInt8((Int(sourcePixel[0]) * alpha + Int(destinationPixel[0]) * inverse + 127) / 255)
                            destinationPixel[1] = UInt8((Int(sourcePixel[1]) * alpha + Int(destinationPixel[1]) * inverse + 127) / 255)
                            destinationPixel[2] = UInt8((Int(sourcePixel[2]) * alpha + Int(destinationPixel[2]) * inverse + 127) / 255)
                            destinationPixel[3] = 255
                        }
                    }
                }
            }
        }
    }

    static func savePNG(_ buffer: CVPixelBuffer, to url: URL) throws {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard status == kCVReturnSuccess, let image else {
            throw P7Error.message("VTCreateCGImageFromCVPixelBuffer 失败：\(status)")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw P7Error.message("无法创建 PNG 目标：\(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw P7Error.message("PNG 写入失败：\(url.path)")
        }
    }

    static func resizeIfNeeded(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer {
        // 输入 tile 总是按精确尺寸拷贝；这里仅保留给未来整帧路径。
        buffer
    }
}
