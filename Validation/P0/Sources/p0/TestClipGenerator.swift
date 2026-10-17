@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import VideoToolbox

/// 生成 P0 用的测试片（仅测试用，产物不进入仓库）。
/// 画面：CoreImage 动态渐变 + 移动条纹 + 移动光斑 + 轻微噪点（制造中等编码负载）。
/// 音频：48 kHz 立体声正弦波，AAC 封装。
enum ClipGenerator {
    struct Spec {
        var url: URL
        var size: CGSize
        var codec: AVVideoCodecType
        var bitrate: Int
        var duration: Double
        var fps: Int = 30
        var withAudio: Bool = true
    }

    struct Stats: Codable {
        var url: String
        var width: Int
        var height: Int
        var codec: String
        var durationSeconds: Double
        var wallSeconds: Double
        var bytes: Int64
    }

    static func generate(_ spec: Spec) async throws -> Stats {
        let fm = FileManager.default
        try? fm.removeItem(at: spec.url)

        let writer = try AVAssetWriter(outputURL: spec.url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: Int(spec.size.width),
            AVVideoHeightKey: Int(spec.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: spec.bitrate,
                AVVideoMaxKeyFrameIntervalKey: spec.fps * 2,
                AVVideoExpectedSourceFrameRateKey: spec.fps,
                AVVideoProfileLevelKey: spec.codec == .hevc
                    ? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
                    : AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(spec.size.width),
                kCVPixelBufferHeightKey as String: Int(spec.size.height),
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioSource: SineAudioSource?
        if spec.withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
            audioSource = try SineAudioSource(duration: spec.duration)
        }

        guard writer.startWriting() else {
            throw P0Error.message("生成测试片 startWriting 失败: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let started = MonotonicClock.now
        let context = CIContext(options: [.cacheIntermediates: false])
        let totalFrames = Int((spec.duration * Double(spec.fps)).rounded())
        let frameBounds = CGRect(origin: .zero, size: spec.size)

        var frame = 0
        var audioDone = audioSource == nil
        var lastProgress = 0.0

        while frame < totalFrames || !audioDone {
            var didWork = false

            if frame < totalFrames, videoInput.isReadyForMoreMediaData {
                guard let pixelBuffer = makePixelBuffer(pool: adaptor.pixelBufferPool, size: spec.size) else {
                    throw P0Error.message("创建像素缓冲失败")
                }
                let t = Double(frame) / Double(spec.fps)
                let image = frameImage(t: t, size: spec.size)
                context.render(
                    image,
                    to: pixelBuffer,
                    bounds: frameBounds,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                )
                let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.fps))
                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw P0Error.message("追加视频帧失败: \(writer.error?.localizedDescription ?? "unknown")")
                }
                frame += 1
                didWork = true

                let now = MonotonicClock.now
                if now - lastProgress >= 1.0 {
                    lastProgress = now
                    Console.item("  生成中 \(frame)/\(totalFrames) 帧…")
                }
            }

            if !audioDone, let audioInput, let audioSource {
                if audioInput.isReadyForMoreMediaData {
                    if let buffer = audioSource.nextBuffer() {
                        audioInput.append(buffer)
                    } else {
                        audioInput.markAsFinished()
                        audioDone = true
                    }
                    didWork = true
                }
            }

            if !didWork {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw P0Error.message("生成测试片 finishWriting 失败: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let size = (((try? fm.attributesOfItem(atPath: spec.url.path))?[.size]) as? Int64) ?? 0
        return Stats(
            url: spec.url.path,
            width: Int(spec.size.width),
            height: Int(spec.size.height),
            codec: spec.codec.rawValue,
            durationSeconds: spec.duration,
            wallSeconds: MonotonicClock.now - started,
            bytes: size
        )
    }

    // MARK: - 画面

    private static func frameImage(t: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let clear = CIImage(color: .clear).cropped(to: rect)

        // 背景：随时间旋转色相的线性渐变
        let hue = (t * 0.07).truncatingRemainder(dividingBy: 1.0)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: rect.minX, y: rect.minY)
        gradient.point1 = CGPoint(x: rect.maxX * (0.6 + 0.3 * sin(t * 0.9)), y: rect.maxY)
        gradient.color0 = hslColor(hue: hue, saturation: 0.75, brightness: 0.28)
        gradient.color1 = hslColor(hue: hue + 0.5, saturation: 0.6, brightness: 0.85)
        var image = (gradient.outputImage ?? clear).cropped(to: rect)

        // 斜向移动条纹
        let stripes = CIFilter.stripesGenerator()
        stripes.center = CGPoint(x: rect.midX + cos(t * 1.3) * rect.width * 0.2, y: rect.midY)
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.16)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = Float(max(size.width / 36, 2))
        stripes.sharpness = 1.0
        if let stripesImage = stripes.outputImage {
            let rotated = stripesImage.transformed(by: rotationAroundCenter(CGFloat(t * 0.15), center: CGPoint(x: rect.midX, y: rect.midY)))
            image = rotated.cropped(to: rect).composited(over: image)
        }

        // 移动光斑
        let glow = CIFilter.radialGradient()
        glow.center = CGPoint(
            x: rect.midX + cos(t * 0.8) * rect.width * 0.35,
            y: rect.midY + sin(t * 1.1) * rect.height * 0.35
        )
        glow.radius0 = 0
        glow.radius1 = Float(min(size.width, size.height) * 0.3)
        glow.color0 = CIColor(red: 1.0, green: 0.95, blue: 1.0, alpha: 0.55)
        glow.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let glowImage = glow.outputImage {
            image = glowImage.cropped(to: rect).composited(over: image)
        }

        // 轻微噪点（每帧位移，制造纹理负载）
        let noise = CIFilter.randomGenerator().outputImage?
            .transformed(by: CGAffineTransform(translationX: CGFloat(t * 37), y: CGFloat(t * 23)))
            .cropped(to: rect)
        if let noise {
            let gray = CIFilter.colorControls()
            gray.inputImage = noise
            gray.saturation = 0
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = gray.outputImage
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.06)
            if let grain = matrix.outputImage {
                image = grain.cropped(to: rect).composited(over: image)
            }
        }
        return image
    }

    private static func rotationAroundCenter(_ angle: CGFloat, center: CGPoint) -> CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
    }

    /// HSL → CIColor（CoreImage 没有 HSL 初始化器）。
    private static func hslColor(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) -> CIColor {
        let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(h) {
        case 0: r = c; g = x
        case 1: r = x; g = c
        case 2: g = c; b = x
        case 3: g = x; b = c
        case 4: r = x; b = c
        default: r = c; b = x
        }
        let m = brightness - c
        return CIColor(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool?, size: CGSize) -> CVPixelBuffer? {
        if let pool {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer {
                return buffer
            }
        }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}

// MARK: - 音频

/// 生成正弦波 PCM 采样缓冲。
final class SineAudioSource {
    let sampleRate: Double = 48000
    let channels = 2
    let framesPerBuffer = 1600

    private let formatDescription: CMAudioFormatDescription
    private var frameIndex = 0
    private let totalFrames: Int

    init(duration: Double) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw P0Error.message("创建音频格式描述失败: OSStatus=\(status)")
        }
        formatDescription = format
        totalFrames = Int(duration * sampleRate)
    }

    func nextBuffer() -> CMSampleBuffer? {
        guard frameIndex < totalFrames else { return nil }
        let frames = min(framesPerBuffer, totalFrames - frameIndex)
        let bytesPerFrame = channels * 2
        let byteCount = frames * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer else { return nil }

        let samples = dataPointer.withMemoryRebound(to: Int16.self, capacity: frames * channels) { $0 }
        let amplitude = 0.25
        for frame in 0..<frames {
            let t = Double(frameIndex + frame) / sampleRate
            let secondsLeft = Double(totalFrames - (frameIndex + frame)) / sampleRate
            let envelope = min(1.0, min(t, secondsLeft) / 0.25)
            let vibrato = sin(t * 2 * .pi * 5) * 3
            let value = sin(2 * .pi * (440 + vibrato) * t) * amplitude * envelope
            let quantized = Int16(clamping: Int(value * 32767))
            samples[frame * 2] = quantized
            samples[frame * 2 + 1] = quantized
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        frameIndex += frames
        return sampleBuffer
    }
}
