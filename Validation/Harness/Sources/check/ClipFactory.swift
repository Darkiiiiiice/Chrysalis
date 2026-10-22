@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 测试片工厂（仅 harness 用，产物不进仓库；模式沿用 Validation/P0 实测先例）。
/// 画面：CoreImage 动态渐变 + 移动条纹 + 移动光斑 + 噪点（中等编码负载）。
/// 音频：48 kHz 立体声正弦波（AAC 封装）。
enum ClipFactory {
    struct Error: LocalizedError, CustomStringConvertible {
        let message: String
        var errorDescription: String? { message }
        var description: String { message }
    }

    struct Spec {
        var url: URL
        var size: CGSize
        var codec: AVVideoCodecType = .h264
        var bitrate: Int = 6_000_000
        var duration: Double = 2
        var fps: Int = 30
        var withAudio: Bool = true
        /// 仅音频（无视频轨；用于引擎 noVideoTrack 用例）。
        var audioOnly: Bool = false
        /// 视频轨 preferredTransform（竖屏用例：90° 旋转）。
        var transform: CGAffineTransform = .identity
        /// 写入容器的源元数据（非电影保留用例）。
        var metadata: [AVMetadataItem] = []
        var fileType: AVFileType = .mp4
        /// 伪高分辨率样本（§7.14）：画面先按此尺寸渲染再放大到 size（模拟放大伪 4K）。
        var upscaleFrom: CGSize? = nil
        /// 高细节画面（§7.14 真 4K 标定样本）：强噪点 + 细条纹，模拟真实传感器纹理密度。
        var detailBoost = false
        /// 静态场景（§7.16 复杂度标定）：固定渐变，无移动元素与噪点 → 帧间运动 ≈ 0。
        var staticScene = false
    }

    static func generate(_ spec: Spec) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: spec.url)
        try fm.createDirectory(at: spec.url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: spec.url, fileType: spec.fileType)
        writer.metadata = spec.metadata

        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if !spec.audioOnly {
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
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            input.transform = spec.transform
            let pool = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(spec.size.width),
                    kCVPixelBufferHeightKey as String: Int(spec.size.height),
                ]
            )
            writer.add(input)
            videoInput = input
            adaptor = pool
        }

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
            throw Error(message: "startWriting 失败: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        let totalFrames = spec.audioOnly ? 0 : Int((spec.duration * Double(spec.fps)).rounded())
        let frameBounds = CGRect(origin: .zero, size: spec.size)

        var frame = 0
        var audioDone = audioSource == nil
        while frame < totalFrames || !audioDone {
            var didWork = false

            if frame < totalFrames, let videoInput, let adaptor, videoInput.isReadyForMoreMediaData {
                guard let pixelBuffer = makePixelBuffer(pool: adaptor.pixelBufferPool, size: spec.size) else {
                    throw Error(message: "创建像素缓冲失败")
                }
                let image = frameImage(
                    t: Double(frame) / Double(spec.fps),
                    size: spec.size,
                    upscaleFrom: spec.upscaleFrom,
                    detailBoost: spec.detailBoost,
                    staticScene: spec.staticScene
                )
                context.render(
                    image,
                    to: pixelBuffer,
                    bounds: frameBounds,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                )
                let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.fps))
                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw Error(message: "追加视频帧失败: \(writer.error?.localizedDescription ?? "unknown")")
                }
                frame += 1
                didWork = true
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

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Error(message: "finishWriting 失败: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// 源元数据条目（itsk 容器写法；实测 common keySpace 的 artist 写 MP4 会被丢弃，故直接用 itsk）。
    static func sourceMetadata(title: String, artist: String, creationDate: String, overview: String) throws -> [AVMetadataItem] {
        func item(_ key: String, _ value: String) throws -> AVMetadataItem {
            let mutable = AVMutableMetadataItem()
            mutable.keySpace = .iTunes
            mutable.key = key as NSString
            mutable.value = value as NSString
            guard let metadata = mutable.copy() as? AVMetadataItem else {
                throw Error(message: "构建源元数据失败：\(key)")
            }
            return metadata
        }
        return [
            try item("©nam", title),
            try item("©ART", artist),
            try item("©day", creationDate),
            try item("©des", overview),
        ]
    }

    // MARK: - 画面（与 P0 相同的合成负载）

    private static func frameImage(
        t: Double,
        size: CGSize,
        upscaleFrom: CGSize? = nil,
        detailBoost: Bool = false,
        staticScene: Bool = false
    ) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let clear = CIImage(color: .clear).cropped(to: rect)

        // 静态场景（§7.16）：固定渐变，所有项与时间无关
        if staticScene {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: rect.minX, y: rect.minY)
            gradient.point1 = CGPoint(x: rect.maxX, y: rect.maxY)
            gradient.color0 = hslColor(hue: 0.3, saturation: 0.6, brightness: 0.35)
            gradient.color1 = hslColor(hue: 0.7, saturation: 0.5, brightness: 0.8)
            return (gradient.outputImage ?? clear).cropped(to: rect)
        }

        // 伪高分辨率样本：先按小尺寸渲染（含噪点），再整数比例放大到目标尺寸
        if let smallSize = upscaleFrom {
            var small = frameImage(t: t, size: smallSize, upscaleFrom: nil, detailBoost: false)
            small = small.transformed(
                by: CGAffineTransform(
                    scaleX: size.width / smallSize.width,
                    y: size.height / smallSize.height
                )
            )
            return small.cropped(to: rect)
        }

        let hue = (t * 0.07).truncatingRemainder(dividingBy: 1.0)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: rect.minX, y: rect.minY)
        gradient.point1 = CGPoint(x: rect.maxX * (0.6 + 0.3 * sin(t * 0.9)), y: rect.maxY)
        gradient.color0 = hslColor(hue: hue, saturation: 0.75, brightness: 0.28)
        gradient.color1 = hslColor(hue: hue + 0.5, saturation: 0.6, brightness: 0.85)
        var image = (gradient.outputImage ?? clear).cropped(to: rect)

        let stripes = CIFilter.stripesGenerator()
        stripes.center = CGPoint(x: rect.midX + cos(t * 1.3) * rect.width * 0.2, y: rect.midY)
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.16)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = Float(max(size.width / (detailBoost ? 960 : 36), 2))
        stripes.sharpness = 1.0
        if let stripesImage = stripes.outputImage {
            let rotated = stripesImage.transformed(by: rotationAroundCenter(CGFloat(t * 0.15), center: CGPoint(x: rect.midX, y: rect.midY)))
            image = rotated.cropped(to: rect).composited(over: image)
        }

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

        if let noise = CIFilter.randomGenerator().outputImage?
            .transformed(by: CGAffineTransform(translationX: CGFloat(t * 37), y: CGFloat(t * 23)))
            .cropped(to: rect) {
            let gray = CIFilter.colorControls()
            gray.inputImage = noise
            gray.saturation = 0
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = gray.outputImage
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: detailBoost ? 0.35 : 0.06)
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

// MARK: - 音频（与 P0 相同的正弦波 PCM 源）

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
            throw ClipFactory.Error(message: "创建音频格式描述失败: OSStatus=\(status)")
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
            flags: kCMBlockBufferAssureMemoryNowFlag,
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

// MARK: - 输出读回工具

/// 输出文件读回（集成测试断言用）。
enum OutputProbe {
    /// 读回媒体信息（复用应用预检逻辑）。
    static func info(of url: URL) async throws -> MediaInfo {
        try await MediaInspector.inspect(url: url)
    }

    /// 读回指定 identifier 的字符串值。
    static func metadataString(_ identifier: AVMetadataIdentifier, of url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata)
        guard let item = items.first(where: { $0.identifier == identifier }) else { return nil }
        return try await item.load(.stringValue)
    }

    /// 读回 PCM 位深（ProRes 输出的 LPCM 断言）。
    static func pcmBitDepth(of url: URL) async throws -> Int? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return nil }
        return Int(asbd.pointee.mBitsPerChannel)
    }

    /// 音频编码 fourCC（aac / lpcm 断言）。
    static func audioFourCC(of url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await track.load(.formatDescriptions).first
        else { return "" }
        return VideoToolboxCapabilities.fourCCString(CMFormatDescriptionGetMediaSubType(format))
    }
}
