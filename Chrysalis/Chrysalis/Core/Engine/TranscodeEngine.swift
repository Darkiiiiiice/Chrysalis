@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import VideoToolbox

// MARK: - 几何（设计文档 §6.2）

/// 朝向、缩放、居中的纯函数工具。
enum VideoGeometry {
    /// preferredTransform 之后的显示尺寸。
    static func orientedSize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// 计算「适应（fit）」变换：preferredTransform → 等比缩放 → 居中；默认不放大。
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

    /// H.264/HEVC 宽高取偶数（设计文档 §6.2）。
    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(2, (Int(size.width.rounded()) / 2) * 2),
            height: max(2, (Int(size.height.rounded()) / 2) * 2)
        )
    }
}

// MARK: - 取消标记

/// 线程安全取消标记：可从任意隔离域调用。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 引擎

/// 转码引擎（设计文档 §5 架构 / §12 风险表）：
/// 整个执行体隔离在**专用串行队列**上；事件只传简单值类型。
actor TranscodeEngine {
    nonisolated private let executor: DispatchSerialQueue
    private let cancelFlag = CancelFlag()

    init(label: String = "dev.chrysalis.transcode") {
        self.executor = DispatchSerialQueue(label: label, qos: .userInitiated)
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// 从任意线程请求取消（下一次轮询 / 落盘前生效）。
    nonisolated func cancel() {
        cancelFlag.cancel()
    }

    /// 单个轨泵的收尾统计（跨并发任务传递的值类型）。
    private struct PumpStats: Sendable {
        var frames = 0
        var processedSeconds = 0.0
        var emaSpeed = 0.0
    }

    /// 执行一次转码：写同目录临时文件 → 成功后原子移动到最终路径。
    func run(
        _ request: TranscodeRequest,
        progress: @escaping @Sendable (TranscodeProgress) -> Void
    ) async throws -> TranscodeOutcome {
        try await Self.transcode(request: request, cancelFlag: cancelFlag, progress: progress)
    }

    // MARK: 转码主体

    private static func transcode(
        request: TranscodeRequest,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (TranscodeProgress) -> Void
    ) async throws -> TranscodeOutcome {
        let fm = FileManager.default
        let outputDirectory = request.outputURL.deletingLastPathComponent()

        if cancelFlag.isCancelled { throw TranscodeEngineError.cancelled }

        // 预检（设计文档 §6.1）
        let info = try await MediaInspector.inspect(url: request.inputURL)
        if let reason = MediaInspector.blockingReason(for: info) {
            throw TranscodeEngineError.failed(reason)
        }
        guard info.video != nil else { throw TranscodeEngineError.noVideoTrack }
        if request.requireHardware, request.encoderID == nil {
            throw TranscodeEngineError.hardwareEncoderUnavailable(request.videoCodec.displayName)
        }

        // 磁盘空间：估算值 + 200 MB 缓冲（设计文档 §6.1 第 9 条）
        let bitrateSum = Int64(request.averageBitrate ?? 12_000_000) + Int64(request.audioBitrate)
        let estimatedBytes = bitrateSum / 8 * Int64(max(info.durationSeconds, 0)) + 200 * 1_048_576
        try checkDiskSpace(directory: outputDirectory, requiredBytes: estimatedBytes)

        let asset = AVURLAsset(url: request.inputURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw TranscodeEngineError.noVideoTrack
        }
        let audioTrack = tracks.first(where: { $0.mediaType == .audio })

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let mediaFPS = nominalFPS > 0 ? nominalFPS : 30

        // 保持源分辨率与帧率；仅旋转（preferredTransform 非单位阵）走合成慢路径。
        let oriented = VideoGeometry.orientedSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let renderSize = VideoGeometry.evenSize(oriented)
        let needsComposition = preferredTransform != .identity

        var notes: [String] = []

        // MARK: 读取端
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscodeEngineError.readerSetupFailed(errorText(error))
        }

        let videoOutput: AVAssetReaderOutput
        if needsComposition {
            // macOS 26 起 AVMutable* 系列弃用，改用 Configuration 值类型（部署目标 27.0）
            var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(trackID: videoTrack.trackID)
            layerConfiguration.setTransform(
                VideoGeometry.fitTransform(
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    renderSize: renderSize,
                    allowUpscale: false
                ),
                at: .zero
            )
            let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)
            let instructionConfiguration = AVVideoCompositionInstruction.Configuration(
                backgroundColor: nil,
                enablePostProcessing: false,
                layerInstructions: [layerInstruction],
                requiredSourceSampleDataTrackIDs: [videoTrack.trackID],
                timeRange: CMTimeRange(start: .zero, duration: duration)
            )
            let instruction = AVVideoCompositionInstruction(configuration: instructionConfiguration)
            var compositionConfiguration = AVVideoComposition.Configuration()
            compositionConfiguration.renderSize = renderSize
            compositionConfiguration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(mediaFPS.rounded(), 1)))
            compositionConfiguration.instructions = [instruction]
            let composition = AVVideoComposition(configuration: compositionConfiguration)

            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
            )
            output.videoComposition = composition
            videoOutput = output
            notes.append("旋转/变换：走 AVVideoComposition 慢路径")
        } else {
            videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
            )
        }
        guard reader.canAdd(videoOutput) else {
            throw TranscodeEngineError.readerSetupFailed("无法添加视频输出")
        }

        // 音频：解码为 LPCM，稍后统一编码 AAC（设计文档 §6.3）
        var audioOutput: AVAssetReaderTrackOutput?
        var sourceAudioChannels = 0
        var sourceAudioSampleRate: Double = 0
        if let audioTrack {
            if let format = (try? await audioTrack.load(.formatDescriptions))?.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                sourceAudioChannels = Int(asbd.pointee.mChannelsPerFrame)
                sourceAudioSampleRate = asbd.pointee.mSampleRate
            }
            let decodeSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decodeSettings)
            if reader.canAdd(output) {
                audioOutput = output
            } else {
                notes.append("音频轨无法解码，本次跳过音频")
            }
        }

        // MARK: 写入端
        let tempURL = OutputPlanner.makeTempURL(in: outputDirectory)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tempURL, fileType: request.container.avFileType)
        } catch {
            throw TranscodeEngineError.writerSetupFailed(errorText(error))
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(request: request, size: renderSize, fps: mediaFPS)
        )
        guard writer.canAdd(videoInput) else {
            throw TranscodeEngineError.writerSetupFailed("无法添加视频写入器（可能是硬件编码器不可用）")
        }

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let channels = min(
                max(sourceAudioChannels > 0 ? sourceAudioChannels : 2, 1),
                max(request.audioMaxChannels, 1)
            )
            var sampleRate = request.audioSampleRate ?? (sourceAudioSampleRate > 0 ? sourceAudioSampleRate : 48_000)
            sampleRate = min(max(sampleRate, 8_000), 48_000)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: request.audioBitrate,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            if writer.canAdd(input) {
                audioInput = input
            } else {
                notes.append("音频编码器不可用，本次跳过音频")
                audioOutput = nil
            }
        }

        // 输入接收端（macOS 27 新 API：inputReceiver 取代 writer.add，必须在 start() 之前注册）
        let videoReceiver = writer.inputReceiver(for: videoInput)
        let audioReceiver = audioInput.map { writer.inputReceiver(for: $0) }

        // 启动（RequireHardware 标志在此被接受或拒绝，设计文档 §7）
        do {
            try writer.start()
        } catch {
            if isPermissionError(error) || isPermissionError(writer.error) {
                throw TranscodeEngineError.writerSetupFailed(
                    "无法写入输出文件夹（沙盒权限不足）：请在工具栏重新选择输出文件夹后再试"
                )
            }
            let hint = request.requireHardware ? "（通常是没有可用的硬件编码器）" : ""
            throw TranscodeEngineError.writerSetupFailed("启动写入失败\(hint)：\(errorText(error))")
        }
        writer.startSession(atSourceTime: .zero)

        // 输出读取端（outputProvider 取代 reader.add，必须在 start() 之前注册）
        let videoProvider = reader.outputProvider(for: videoOutput)
        let audioProvider = audioOutput.map { reader.outputProvider(for: $0) }

        do {
            try reader.start()
        } catch {
            writer.cancelWriting()
            try? fm.removeItem(at: tempURL)
            throw TranscodeEngineError.readerSetupFailed(errorText(error))
        }

        // 转码期间防止系统休眠（设计文档 §7 并发与功耗）
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "转码 \(request.inputURL.lastPathComponent)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // MARK: 读写循环（每轨一个异步泵；背压由 receiver.append 挂起处理）
        let started = Date.now
        let durationSeconds = duration.seconds.isFinite ? duration.seconds : 0

        do {
            let finalStats = try await withThrowingTaskGroup(of: PumpStats.self) { group in
                group.addTask {
                    var stats = PumpStats()
                    var lastReport = started
                    while let ready = try await videoProvider.next() {
                        if Task.isCancelled || cancelFlag.isCancelled { throw TranscodeEngineError.cancelled }
                        try await videoReceiver.append(ready)
                        stats.frames += 1
                        let pts = ready.presentationTimeStamp.seconds
                        if pts.isFinite { stats.processedSeconds = max(stats.processedSeconds, pts) }

                        let now = Date.now
                        if now.timeIntervalSince(lastReport) >= 0.1 {
                            lastReport = now
                            let wall = max(now.timeIntervalSince(started), 0.0001)
                            let instantaneous = stats.processedSeconds / wall
                            stats.emaSpeed = stats.emaSpeed == 0
                                ? instantaneous
                                : stats.emaSpeed * 0.85 + instantaneous * 0.15
                            let fraction = durationSeconds > 0 ? min(stats.processedSeconds / durationSeconds, 1.0) : 0
                            let eta = stats.emaSpeed > 0 && durationSeconds > 0
                                ? max(durationSeconds - stats.processedSeconds, 0) / stats.emaSpeed
                                : nil
                            progress(TranscodeProgress(
                                fraction: fraction,
                                processedSeconds: stats.processedSeconds,
                                speed: stats.emaSpeed,
                                etaSeconds: eta
                            ))
                        }
                    }
                    videoReceiver.finish()
                    return stats
                }

                if let audioProvider, let audioReceiver {
                    group.addTask {
                        while let ready = try await audioProvider.next() {
                            if Task.isCancelled || cancelFlag.isCancelled { throw TranscodeEngineError.cancelled }
                            try await audioReceiver.append(ready)
                        }
                        audioReceiver.finish()
                        return PumpStats()
                    }
                }

                var videoStats = PumpStats()
                for try await stats in group {
                    if stats.frames > videoStats.frames { videoStats = stats }
                }
                return videoStats
            }

            if cancelFlag.isCancelled { throw TranscodeEngineError.cancelled }
            progress(TranscodeProgress(
                fraction: durationSeconds > 0 ? 1 : 0,
                processedSeconds: durationSeconds,
                speed: finalStats.emaSpeed,
                etaSeconds: durationSeconds > 0 ? 0 : nil
            ))
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw TranscodeEngineError.readWriteFailed("收尾写入失败：\(errorText(writer.error))")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? fm.removeItem(at: tempURL)
            throw error
        }

        // 取消在收尾期间生效：不留残留文件（设计文档 §6.4）
        if cancelFlag.isCancelled {
            try? fm.removeItem(at: tempURL)
            throw TranscodeEngineError.cancelled
        }

        // MARK: 原子落盘
        let finalURL: URL
        do {
            let target = fm.fileExists(atPath: request.outputURL.path)
                ? OutputPlanner.uniqueOutputURL(
                    directory: outputDirectory,
                    baseName: request.outputURL.deletingPathExtension().lastPathComponent,
                    fileExtension: request.outputURL.pathExtension
                )
                : request.outputURL
            try fm.moveItem(at: tempURL, to: target)
            finalURL = target
        } catch {
            try? fm.removeItem(at: tempURL)
            throw TranscodeEngineError.failed("移动输出文件失败：\(errorText(error))")
        }

        let wallSeconds = Date.now.timeIntervalSince(started)
        let size = (((try? fm.attributesOfItem(atPath: finalURL.path))?[.size]) as? Int64) ?? 0
        let verificationIssues = await verifyOutput(
            url: finalURL,
            expectedDuration: durationSeconds,
            expectedCodec: request.videoCodec,
            expectedSize: renderSize
        )

        return TranscodeOutcome(
            outputURL: finalURL,
            bytes: size,
            durationSeconds: durationSeconds,
            wallSeconds: wallSeconds,
            averageSpeed: durationSeconds / max(wallSeconds, 0.0001),
            usedComposition: needsComposition,
            verificationIssues: verificationIssues
        )
    }

    // MARK: - 输出设置

    private static func videoOutputSettings(request: TranscodeRequest, size: CGSize, fps: Double) -> [String: Any] {
        let even = VideoGeometry.evenSize(size)
        var output: [String: Any] = [
            AVVideoCodecKey: request.videoCodec.avCodecType,
            AVVideoWidthKey: Int(even.width),
            AVVideoHeightKey: Int(even.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]

        var compression: [String: Any] = [:]
        if let bitrate = request.averageBitrate, !request.videoCodec.isProRes {
            compression[AVVideoAverageBitRateKey] = bitrate
            compression[AVVideoMaxKeyFrameIntervalKey] = Int(fps.rounded()) * 2
            compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded())
        }
        switch request.videoCodec {
        case .h264:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        default:
            break
        }
        if !compression.isEmpty {
            output[AVVideoCompressionPropertiesKey] = compression
        }

        if let specification = encoderSpecification(
            encoderID: request.encoderID,
            requireHardware: request.requireHardware
        ) {
            output[AVVideoEncoderSpecificationKey] = specification
        }
        return output
    }

    /// 硬件编码器规格字典（设计文档 §7 强制硬件）。
    private static func encoderSpecification(encoderID: String?, requireHardware: Bool) -> [String: Any]? {
        var spec: [String: Any] = [:]
        if let encoderID {
            spec[kVTVideoEncoderSpecification_EncoderID as String] = encoderID
        }
        if requireHardware {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        return spec.isEmpty ? nil : spec
    }

    // MARK: - 输出自检（设计文档 §6.5）

    private static func verifyOutput(
        url: URL,
        expectedDuration: Double,
        expectedCodec: VideoCodec,
        expectedSize: CGSize
    ) async -> [String] {
        var issues: [String] = []
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let tracks = (try? await asset.load(.tracks)) ?? []

        var codecFourCC = ""
        var width = 0
        var height = 0
        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            if let format = (try? await videoTrack.load(.formatDescriptions))?.first {
                codecFourCC = VideoToolboxCapabilities.fourCCString(CMFormatDescriptionGetMediaSubType(format))
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                width = Int(dimensions.width)
                height = Int(dimensions.height)
            }
        } else {
            issues.append("输出缺少视频轨")
        }

        if abs(duration - expectedDuration) > 0.25 {
            issues.append("时长偏差 \(String(format: "%.2f", duration))s（期望 \(String(format: "%.2f", expectedDuration))s）")
        }
        if width != Int(expectedSize.width) || height != Int(expectedSize.height) {
            issues.append("分辨率 \(width)×\(height)（期望 \(Int(expectedSize.width))×\(Int(expectedSize.height))）")
        }
        if !codecFourCC.isEmpty, codecFourCC != expectedCodec.fourCC {
            issues.append("编码为 \(codecFourCC)（期望 \(expectedCodec.fourCC)）")
        }
        return issues
    }

    // MARK: - 工具

    private static func checkDiskSpace(directory: URL, requiredBytes: Int64) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        if available < requiredBytes {
            throw TranscodeEngineError.lowDiskSpace(requiredBytes: requiredBytes, availableBytes: available)
        }
    }

    /// 判断是否为权限类错误（沙盒无写入权限等），用于给出可操作的中文提示。
    private static func isPermissionError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSCocoaErrorDomain, underlying.code == NSFileWriteNoPermissionError {
                return true
            }
            if underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EACCES) {
                return true
            }
        }
        return false
    }

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "无错误详情" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }
}
