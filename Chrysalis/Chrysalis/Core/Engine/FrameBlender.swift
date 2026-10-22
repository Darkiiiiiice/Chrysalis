import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo

// MARK: - 降帧感知：帧混合器（设计文档 §7.12）
// 输出帧 = 时间窗口内源帧按重叠时长加权混合（CoreImage GPU）；窗口单帧直出零转换。
// 泵内串行使用（@unchecked Sendable 与 CancelFlag 同模式）。

final class FrameBlender: @unchecked Sendable {
    /// 输出帧（Sendable，可跨隔离域交给写入端）。
    typealias OutputSample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

    private let outputFPS: Double
    private let sourceFPS: Double
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let colorSpace: CGColorSpace
    private let context = CIContext(options: [.cacheIntermediates: false])

    private var windowStart = 0.0
    /// 待结算窗口的源帧（自有拷贝；输入 buffer 不能跨调用持有）。
    private var pending: [(pts: Double, buffer: CVPixelBuffer)] = []
    private var lastOutput: CVPixelBuffer?

    init(outputFPS: Double, sourceFPS: Double, width: Int, height: Int, pixelFormat: OSType) {
        self.outputFPS = max(outputFPS, 1)
        self.sourceFPS = max(sourceFPS, 1)
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        if pixelFormat == kCVPixelFormatType_32BGRA {
            self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        } else {
            self.colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    // MARK: - 纯函数（harness 可测）

    /// 窗口 [windowStart, windowStart + duration) 的混合权重：
    /// 帧区间 [start, start + 1/sourceFPS) 与窗口的重叠时长占比，归一化到 Σ=1。
    static func weights(
        frameStarts pts: [Double],
        sourceFPS: Double,
        windowStart: Double,
        windowDuration: Double
    ) -> [Double] {
        let frameDuration = 1.0 / max(sourceFPS, 1)
        let windowEnd = windowStart + windowDuration
        var raw: [Double] = []
        for start in pts {
            let end = start + frameDuration
            let overlap = min(end, windowEnd) - max(start, windowStart)
            raw.append(max(overlap, 0))
        }
        let total = raw.reduce(0, +)
        guard total > 0 else { return Array(repeating: 0, count: pts.count) }
        return raw.map { $0 / total }
    }

    // MARK: - 泵接口

    /// 逐源帧处理（输入 buffer 只读、不能跨调用持有，内部拷贝成自有帧）。
    /// 返回已可输出的输出帧（0..n 个）；输出 PTS = 窗口起点，时长 = 1/输出帧率。
    func ingest(pts: Double, source: CVPixelBuffer) throws -> [OutputSample] {
        let copy = try makeBufferCopy(of: source)
        pending.append((pts: pts, buffer: copy))

        var outputs: [OutputSample] = []
        let windowDuration = 1.0 / outputFPS
        // 结算条件：下一窗口已有帧到达（保证当前窗口帧齐全）
        while let last = pending.last, last.pts >= windowStart + windowDuration - 1e-9 {
            if let frame = try emitWindow(duration: windowDuration) {
                outputs.append(frame)
            }
            windowStart += windowDuration
        }
        return outputs
    }

    /// 源流结束：结算全部剩余窗口。
    func finish() throws -> [OutputSample] {
        var outputs: [OutputSample] = []
        while !pending.isEmpty {
            if let frame = try emitWindow(duration: 1.0 / outputFPS) {
                outputs.append(frame)
            }
            windowStart += 1.0 / outputFPS
        }
        return outputs
    }

    // MARK: - 内部

    /// 结算当前窗口；窗口无帧（gap）时跳过不输出。
    private func emitWindow(duration: Double) throws -> OutputSample? {
        let windowEnd = windowStart + duration
        let frameDuration = 1.0 / sourceFPS

        // 参与窗口的帧：帧区间 [pts, pts + 1/sourceFPS) 与窗口有重叠
        let participants = pending.filter { $0.pts < windowEnd - 1e-9 && $0.pts + frameDuration > windowStart + 1e-9 }
        // 清理不会再被后续窗口用到的帧
        pending.removeAll { $0.pts + frameDuration <= windowEnd + 1e-9 }

        guard !participants.isEmpty else { return nil }
        let weights = Self.weights(
            frameStarts: participants.map(\.pts),
            sourceFPS: sourceFPS,
            windowStart: windowStart,
            windowDuration: duration
        )

        var buffer: CVPixelBuffer
        let nonZero = participants.enumerated().filter { weights[$0.offset] > 0.001 }
        if nonZero.count == 1 {
            // 单帧主导：直出（零转换）
            buffer = nonZero[0].element.buffer
        } else {
            buffer = try blend(participants.map(\.buffer), weights: weights)
        }
        lastOutput = buffer
        let sample = CMReadySampleBuffer(
            pixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: buffer),
            presentationTimeStamp: CMTime(seconds: windowStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        return CMReadySampleBuffer(sample)
    }

    /// CoreImage GPU 加权混合：Σ (frame × weight)，输出同格式 buffer。
    private func blend(_ buffers: [CVPixelBuffer], weights: [Double]) throws -> CVPixelBuffer {
        let output = try makeBuffer()
        var accumulated: CIImage?
        for (frame, weight) in zip(buffers, weights) where weight > 0 {
            let image = CIImage(cvPixelBuffer: frame)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            let w = CGFloat(weight)
            matrix.rVector = CIVector(x: w, y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: w, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: w, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0, y: 0, z: 0)
            guard let weighted = matrix.outputImage?.cropped(to: image.extent) else {
                throw TranscodeEngineError.readWriteFailed("帧混合滤波器输出为空")
            }
            accumulated = accumulated.map { $0.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": weighted]) } ?? weighted
        }
        guard let final = accumulated else {
            throw TranscodeEngineError.readWriteFailed("帧混合输入为空")
        }
        context.render(
            final,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
        return output
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw TranscodeEngineError.readWriteFailed("帧混合缓冲创建失败：\(status)")
        }
        return buffer
    }

    /// 输入帧的自有拷贝（420v / BGRA 逐 plane 内存拷贝，零色彩转换）。
    private func makeBufferCopy(of source: CVPixelBuffer) throws -> CVPixelBuffer {
        let copy = try makeBuffer()
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(copy) else {
                throw TranscodeEngineError.readWriteFailed("帧混合拷贝失败：无法取得缓冲地址")
            }
            memcpy(dst, src, min(CVPixelBufferGetDataSize(source), CVPixelBufferGetDataSize(copy)))
        } else {
            for plane in 0..<planes {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
                else { continue }
                let srcRows = CVPixelBufferGetHeightOfPlane(source, plane)
                let dstRows = CVPixelBufferGetHeightOfPlane(copy, plane)
                let rows = min(srcRows, dstRows)
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                if srcStride == dstStride {
                    memcpy(dst, src, srcStride * rows)
                } else {
                    for row in 0..<rows {
                        memcpy(dst + row * dstStride, src + row * srcStride, min(srcStride, dstStride))
                    }
                }
            }
        }
        return copy
    }
}
