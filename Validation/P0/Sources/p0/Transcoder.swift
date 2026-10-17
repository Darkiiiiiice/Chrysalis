@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

// MARK: - 设置与事件

struct TranscodeSettings {
    var codec: AVVideoCodecType
    var fileType: AVFileType
    var outputSize: CGSize
    /// 平均码率；ProRes 传 nil。
    var bitrate: Int?
    /// 目标帧时长；nil 表示保持源帧率。
    var frameDuration: CMTime?
    /// 强制硬件编码（设计文档硬性要求，默认 true）。
    var requireHardware: Bool = true
    /// 指定 VideoToolbox 编码器 ID（来自能力矩阵）；nil 表示让系统选择。
    var encoderID: String?
    /// 是否给 ProRes 也带上编码器指定（实测用）。
    var useEncoderSpecificationForProRes: Bool = true
    var metadata: [AVMetadataItem]?
    var allowUpscale: Bool = false
}

struct TranscodeProgress {
    var fraction: Double
    var processedSeconds: Double
    var speed: Double
    var etaSeconds: Double?
}

struct TranscodeReport: Codable {
    var outputPath: String
    var durationSeconds: Double
    var wallSeconds: Double
    var speed: Double
    var avgCPUPercent: Double
    var peakFootprintBytes: Int64
    var outputBytes: Int64
    var usedComposition: Bool
    var verify: VerifyResult
    var notes: [String]
}

struct VerifyResult: Codable {
    var durationSeconds: Double
    var videoCodecFourCC: String
    var width: Int
    var height: Int
    var audioTrackCount: Int
    var metadataItemCount: Int
    var issues: [String]
}

enum TranscodeError: Error, CustomStringConvertible {
    case cancelled
    case failed(String)

    var description: String {
        switch self {
        case .cancelled: return "已取消"
        case .failed(let message): return message
        }
    }
}

/// 线程安全取消标记。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - 几何

enum VideoGeometry {
    /// preferredTransform 之后的显示尺寸。
    static func orientedSize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// 计算“适应（fit）”变换：preferredTransform → 等比缩放 → 居中；默认不放大。
    static func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize,
        allowUpscale: Bool
    ) -> CGAffineTransform {
        let oriented = orientedSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        guard oriented.width > 0, oriented.height > 0 else { return .identity }
        var scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        if !allowUpscale { scale = min(scale, 1) }
        let scaled = CGSize(width: oriented.width * scale, height: oriented.height * scale)
        let dx = (renderSize.width - scaled.width) / 2
        let dy = (renderSize.height - scaled.height) / 2
        let scaledTransform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let bbox = CGRect(origin: .zero, size: naturalSize).applying(scaledTransform)
        return scaledTransform.concatenating(
            CGAffineTransform(translationX: dx - bbox.minX, y: dy - bbox.minY)
        )
    }

    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(2, (Int(size.width.rounded()) / 2) * 2),
            height: max(2, (Int(size.height.rounded()) / 2) * 2)
        )
    }
}

// MARK: - 转码

enum Transcoder {
    /// 硬件编码器规格字典（设计文档第 7 节）。
    static func encoderSpecification(encoderID: String?, requireHardware: Bool) -> [String: Any]? {
        var spec: [String: Any] = [:]
        if let encoderID {
            spec[kVTVideoEncoderSpecification_EncoderID as String] = encoderID
        }
        if requireHardware {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        return spec.isEmpty ? nil : spec
    }

    static func videoCompressionProperties(codec: AVVideoCodecType, bitrate: Int?, fps: Double) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let bitrate {
            properties[AVVideoAverageBitRateKey] = bitrate
            properties[AVVideoMaxKeyFrameIntervalKey] = Int(fps * 2)
            properties[AVVideoExpectedSourceFrameRateKey] = Int(fps)
        }
        switch codec {
        case .h264:
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        default:
            break
        }
        return properties
    }

    static func videoOutputSettings(
        settings: TranscodeSettings,
        size: CGSize,
        fps: Double
    ) -> [String: Any] {
        let even = VideoGeometry.evenSize(size)
        var output: [String: Any] = [
            AVVideoCodecKey: settings.codec,
            AVVideoWidthKey: Int(even.width),
            AVVideoHeightKey: Int(even.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let compression = videoCompressionProperties(codec: settings.codec, bitrate: settings.bitrate, fps: fps)
        if !compression.isEmpty {
            output[AVVideoCompressionPropertiesKey] = compression
        }
        let isProRes = settings.codec.rawValue.hasPrefix("apc")
        if !isProRes || settings.useEncoderSpecificationForProRes {
            if let spec = encoderSpecification(encoderID: settings.encoderID, requireHardware: settings.requireHardware) {
                output[AVVideoEncoderSpecificationKey] = spec
            }
        }
        return output
    }

    /// 执行一次转码：写同目录临时文件 → 成功后原子移动到最终路径。
    /// progress 回调在调用线程同步触发（P0 命令行工具，无需跳队列）。
    static func run(
        input: URL,
        settings: TranscodeSettings,
        outputURL: URL,
        cancelFlag: CancelFlag?,
        progress: ((TranscodeProgress) -> Void)?
    ) async throws -> TranscodeReport {
        var notes: [String] = []
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw TranscodeError.failed("输入没有视频轨")
        }
        let audioTrack = tracks.first(where: { $0.mediaType == .audio })

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        _ = naturalSize
        _ = preferredTransform
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let mediaFPS = nominalFPS > 0 ? nominalFPS : 30

        let effectiveFPS: Double = settings.frameDuration.map { 1.0 / $0.seconds } ?? mediaFPS
        let renderSize = settings.outputSize

        // 是否需要走 AVVideoComposition 慢路径
        let oriented = VideoGeometry.orientedSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let identityTransform = preferredTransform == .identity
        let sizeMatches = VideoGeometry.evenSize(oriented) == VideoGeometry.evenSize(renderSize)
        let fpsChange = settings.frameDuration.map { abs(1.0 / $0.seconds - mediaFPS) > 0.01 } ?? false
        let needsComposition = !identityTransform || !sizeMatches || fpsChange

        let reader = try AVAssetReader(asset: asset)
        var videoOutput: AVAssetReaderOutput
        if needsComposition {
            let composition = AVMutableVideoComposition()
            composition.renderSize = VideoGeometry.evenSize(renderSize)
            let fps = settings.frameDuration.map { 1.0 / $0.seconds } ?? effectiveFPS
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(
                VideoGeometry.fitTransform(
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    renderSize: composition.renderSize,
                    allowUpscale: settings.allowUpscale
                ),
                at: .zero
            )
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]

            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
            )
            output.videoComposition = composition
            videoOutput = output
            notes.append("走 AVVideoComposition 慢路径（缩放/旋转/变帧率）")
        } else {
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
            )
            videoOutput = output
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscodeError.failed("无法添加视频输出") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil) // 直通
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            } else {
                notes.append("音频轨无法直通，本次跳过音频")
            }
        }

        let fm = FileManager.default
        let outputDirectory = outputURL.deletingLastPathComponent()
        let tempURL = OutputPlanner.makeTempURL(in: outputDirectory)
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: settings.fileType)
        if let metadata = settings.metadata {
            writer.metadata = metadata
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(settings: settings, size: renderSize, fps: effectiveFPS)
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TranscodeError.failed("无法添加视频写入器") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let hint = (try? await audioTrack.load(.formatDescriptions))?.first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw TranscodeError.failed("startWriting 失败: \(errorText(writer.error))")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            try? fm.removeItem(at: tempURL)
            throw TranscodeError.failed("startReading 失败: \(errorText(reader.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let sampler = ResourceSampler()
        sampler.start()

        let started = MonotonicClock.now
        let durationSeconds = duration.seconds
        var processed = 0.0
        var emaSpeed = 0.0
        var videoDone = false
        var audioDone = (audioOutput == nil)
        var lastReport = 0.0

        func report(force: Bool) {
            guard let progress else { return }
            let now = MonotonicClock.now
            if !force && now - lastReport < 0.25 { return }
            lastReport = now
            let wall = max(now - started, 0.0001)
            let instantaneous = processed / wall
            emaSpeed = emaSpeed == 0 ? instantaneous : emaSpeed * 0.85 + instantaneous * 0.15
            let fraction = durationSeconds > 0 ? min(processed / durationSeconds, 1.0) : 0
            let eta = emaSpeed > 0 && durationSeconds > 0 ? max(durationSeconds - processed, 0) / emaSpeed : nil
            progress(TranscodeProgress(
                fraction: fraction,
                processedSeconds: processed,
                speed: emaSpeed,
                etaSeconds: eta
            ))
        }

        do {
            while true {
                if cancelFlag?.isCancelled == true {
                    throw TranscodeError.cancelled
                }
                var appended = false

                if !videoDone {
                    if videoInput.isReadyForMoreMediaData {
                        if let buffer = videoOutput.copyNextSampleBuffer() {
                            guard videoInput.append(buffer) else {
                                throw TranscodeError.failed("视频帧写入失败: \(errorText(writer.error))")
                            }
                            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                            processed = max(processed, pts)
                            report(force: false)
                            appended = true
                        } else {
                            videoInput.markAsFinished()
                            videoDone = true
                        }
                    }
                }

                if !audioDone {
                    if audioInput?.isReadyForMoreMediaData == true, let output = audioOutput {
                        if let buffer = output.copyNextSampleBuffer() {
                            guard audioInput?.append(buffer) == true else {
                                throw TranscodeError.failed("音频写入失败: \(errorText(writer.error))")
                            }
                            appended = true
                        } else {
                            audioInput?.markAsFinished()
                            audioDone = true
                        }
                    }
                }

                if videoDone && audioDone { break }
                if !appended { usleep(1500) }
            }

            processed = durationSeconds
            report(force: true)
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw TranscodeError.failed("finishWriting 失败: \(errorText(writer.error))")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? fm.removeItem(at: tempURL)
            _ = sampler.stop()
            throw error
        }

        let metrics = sampler.stop()

        // 原子落盘：临时文件 → 最终路径
        let finalURL = fm.fileExists(atPath: outputURL.path)
            ? OutputPlanner.uniqueOutputURL(
                directory: outputDirectory,
                baseName: outputURL.deletingPathExtension().lastPathComponent,
                fileExtension: outputURL.pathExtension
            )
            : outputURL
        try fm.moveItem(at: tempURL, to: finalURL)

        let size = (((try? fm.attributesOfItem(atPath: finalURL.path))?[.size]) as? Int64) ?? 0
        let verify = await verifyOutput(
            url: finalURL,
            expectedDuration: durationSeconds,
            expectedCodec: settings.codec,
            expectedSize: VideoGeometry.evenSize(renderSize)
        )

        return TranscodeReport(
            outputPath: finalURL.path,
            durationSeconds: durationSeconds,
            wallSeconds: metrics.wallSeconds,
            speed: durationSeconds / max(metrics.wallSeconds, 0.0001),
            avgCPUPercent: metrics.avgCPUPercent,
            peakFootprintBytes: metrics.peakFootprintBytes,
            outputBytes: size,
            usedComposition: needsComposition,
            verify: verify,
            notes: notes
        )
    }

    // MARK: - 输出自检

    static func verifyOutput(
        url: URL,
        expectedDuration: Double,
        expectedCodec: AVVideoCodecType,
        expectedSize: CGSize
    ) async -> VerifyResult {
        var issues: [String] = []
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let tracks = (try? await asset.load(.tracks)) ?? []
        let metadataItems = (try? await asset.load(.metadata)) ?? []

        var codecFourCC = ""
        var width = 0
        var height = 0
        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            if let format = (try? await videoTrack.load(.formatDescriptions))?.first {
                let codec = CMFormatDescriptionGetMediaSubType(format)
                codecFourCC = fourCCString(codec)
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                width = Int(dimensions.width)
                height = Int(dimensions.height)
            }
        } else {
            issues.append("输出缺少视频轨")
        }
        let audioCount = tracks.filter { $0.mediaType == .audio }.count

        if abs(duration - expectedDuration) > 0.1 {
            issues.append("时长偏差 \(String(format: "%.3f", duration))s（期望 \(String(format: "%.3f", expectedDuration))s）")
        }
        if width != Int(expectedSize.width) || height != Int(expectedSize.height) {
            issues.append("分辨率 \(width)x\(height)（期望 \(Int(expectedSize.width))x\(Int(expectedSize.height))）")
        }
        let expectedFourCC = codecFourCCFor(expectedCodec)
        if !expectedFourCC.isEmpty && codecFourCC != expectedFourCC {
            issues.append("编码为 \(codecFourCC)（期望 \(expectedFourCC)）")
        }

        return VerifyResult(
            durationSeconds: duration,
            videoCodecFourCC: codecFourCC,
            width: width,
            height: height,
            audioTrackCount: audioCount,
            metadataItemCount: metadataItems.count,
            issues: issues
        )
    }

    static func codecFourCCFor(_ codec: AVVideoCodecType) -> String {
        switch codec {
        case .h264: return "avc1"
        case .hevc: return "hvc1"
        case .proRes422: return "apcn"
        case .proRes422HQ: return "apch"
        case .proRes422LT: return "apcs"
        case .proRes422Proxy: return "apco"
        case .proRes4444: return "ap4h"
        default: return ""
        }
    }

    static func errorText(_ error: Error?) -> String {
        guard let error else { return "无错误详情" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}
