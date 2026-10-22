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
        // ProRes 仅支持 MOV（设计文档 §3 支持矩阵；预设层已归一，此处兜底）
        if request.videoCodec.isProRes, request.container != .mov {
            throw TranscodeEngineError.proResRequiresMOV
        }

        let asset = AVURLAsset(url: request.inputURL)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.load(.tracks)
        } catch {
            throw TranscodeEngineError.readerSetupFailed("读取媒体失败：\(errorText(error))")
        }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw TranscodeEngineError.noVideoTrack
        }
        let audioTrack = tracks.first(where: { $0.mediaType == .audio })

        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFPS: Double
        do {
            naturalSize = try await videoTrack.load(.naturalSize)
            preferredTransform = try await videoTrack.load(.preferredTransform)
            nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        } catch {
            throw TranscodeEngineError.readerSetupFailed("读取视频轨失败：\(errorText(error))")
        }
        let mediaFPS = nominalFPS > 0 ? nominalFPS : 30

        // 输出尺寸与帧率（设计文档 P3.5）：短边匹配、只缩不放、偶数对齐；帧率只降不升。
        // 旋转 / 偶数对齐 / 缩放 / 帧率任一需要改变时走合成慢路径。
        let oriented = VideoGeometry.orientedSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let sourceSize = VideoGeometry.evenSize(oriented)
        // 画质修复（设计文档 §7.6）：输出固定为源显示尺寸 ×2；分辨率档位必须为「保持源」
        if request.enhancement != nil, request.resolution != .source {
            throw TranscodeEngineError.enhancementResolutionConflict
        }
        // 复古输出（设计文档 §7.15）：与画质修复互斥（UI 已双向禁用，此处引擎兜底）
        if request.enhancement != nil, request.retroEffect != nil {
            throw TranscodeEngineError.retroEnhancementConflict
        }
        let renderSize: CGSize
        if request.enhancement != nil {
            renderSize = CGSize(width: sourceSize.width * 2, height: sourceSize.height * 2)
        } else {
            renderSize = request.resolution.renderSize(
                sourceWidth: Int(oriented.width.rounded()),
                sourceHeight: Int(oriented.height.rounded())
            ) ?? sourceSize
        }
        // 合成慢路径只负责几何（旋转/偶数对齐/几何缩放），不做画质修复的 2x——那是增强层的职责
        let geometrySize = request.enhancement != nil ? sourceSize : renderSize
        let outputFPS = request.frameRate.effectiveFrameRate(sourceFPS: mediaFPS)
        var notes: [String] = []
        var compositionReasons: [String] = []
        if preferredTransform != .identity { compositionReasons.append("旋转") }
        if oriented != sourceSize { compositionReasons.append("偶数对齐") }
        if geometrySize != sourceSize { compositionReasons.append("缩放") }
        // 降帧混合（设计文档 §7.12）：帧率由泵内混合器处理，不触发合成慢路径
        let frameBlendingActive = request.frameBlending && outputFPS < mediaFPS - 0.01
        if abs(outputFPS - mediaFPS) > 0.01, !frameBlendingActive { compositionReasons.append("帧率") }
        if frameBlendingActive {
            notes.append("已启用降帧混合（\(Int(mediaFPS.rounded())) → \(Int(outputFPS.rounded())) fps）")
        }
        let needsComposition = !compositionReasons.isEmpty

        // MARK: 读取端
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscodeEngineError.readerSetupFailed(errorText(error))
        }

        let videoOutput: AVAssetReaderOutput
        // 画质修复路径读 BGRA（模型/滤镜直接消费；写入端编码时由 AVFoundation 自动转回 YUV）
        let readerPixelFormat: OSType = request.enhancement != nil
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if needsComposition {
            // macOS 26 起 AVMutable* 系列弃用，改用 Configuration 值类型（部署目标 27.0）
            var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(trackID: videoTrack.trackID)
            layerConfiguration.setTransform(
                VideoGeometry.fitTransform(
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    renderSize: geometrySize,
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
            compositionConfiguration.renderSize = geometrySize
            // 降帧混合（§7.12）：composition 输出源帧率（不丢帧），降帧由泵内混合器完成
            let compositionFPS = frameBlendingActive ? mediaFPS : outputFPS
            compositionConfiguration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(compositionFPS.rounded(), 1)))
            compositionConfiguration.instructions = [instruction]
            let composition = AVVideoComposition(configuration: compositionConfiguration)

            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat,
                ]
            )
            output.videoComposition = composition
            videoOutput = output
            notes.append("AVVideoComposition 慢路径（\(compositionReasons.joined(separator: " / "))）")
        } else {
            videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat,
                ]
            )
        }
        guard reader.canAdd(videoOutput) else {
            throw TranscodeEngineError.readerSetupFailed("无法添加视频输出")
        }
        // 样片试编码（设计文档 §7.8）：截取源时间轴（PTS 保持源时间，写入端会按段起点开 session）
        if let range = request.sourceTimeRange {
            reader.timeRange = range
        }

        // 音频目标格式（设计文档 §6.3）：解码端直接输出「目标采样率 + 目标声道」的 LPCM，
        // 保证读写两端格式严格一致。AAC 编码器对不同采样率/声道有各自的合法码率上限
        // （实测 22.05 kHz 立体声上限 128 kbps；单声道 320 kbps 被拒、256 可用），
        // 非 44.1/48 kHz 的源统一规整到 48 kHz；多声道源在解码端下混并给出提示。
        var audioOutput: AVAssetReaderTrackOutput?
        var audioTarget: (rate: Double, channels: Int, bitrate: Int)?
        if let audioTrack {
            var sourceChannels = 0
            var sourceRate: Double = 0
            if let format = (try? await audioTrack.load(.formatDescriptions))?.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                sourceChannels = Int(asbd.pointee.mChannelsPerFrame)
                sourceRate = asbd.pointee.mSampleRate
            }

            let channels = min(
                max(sourceChannels > 0 ? sourceChannels : 2, 1),
                max(request.audioMaxChannels, 1)
            )
            if sourceChannels > channels {
                notes.append("多声道音轨（\(sourceChannels) 声道）：v1 下混为 \(channels) 声道")
            }

            var rate = request.audioSampleRate ?? (sourceRate > 0 ? sourceRate : 48_000)
            let roundedRate = Int(rate.rounded())
            if roundedRate != 44_100, roundedRate != 48_000 {
                rate = 48_000
            }
            var bitrate = request.audioBitrate
            if request.audioPCMSampleBitDepth == nil {
                // 单声道 AAC 上限 256 kbps（实测 320 被系统编码器拒绝）；PCM 不按码率编码。
                let clamped = AudioPolicy.effectiveBitrate(request.audioBitrate, channels: channels)
                if clamped != request.audioBitrate {
                    notes.append("单声道音频码率上限 256 kbps，已从 \(request.audioBitrate / 1000) kbps 调整")
                }
                bitrate = clamped
            }
            audioTarget = (rate, channels, bitrate)

            let decodeSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decodeSettings)
            if reader.canAdd(output) {
                audioOutput = output
            } else {
                notes.append("音频轨无法解码，本次跳过音频")
            }
        }

        // 响度标准化（设计文档 §7.11）：preparing 阶段全片测量（48 kHz 口径同音频泵），增益作用于 PCM 帧
        let loudnessGain: Float
        if let setting = request.loudness, audioOutput != nil, let target = audioTarget {
            do {
                let measurement = try await LoudnessMeter.measure(url: request.inputURL, maxChannels: target.channels)
                let result = LoudnessMeter.gain(measurement: measurement, setting: setting)
                loudnessGain = Float(pow(10.0, result.gainDb / 20.0))
                let gainText = result.gainDb >= 0 ? "+" : ""
                notes.append(
                    "响度实测 \(String(format: "%.1f", measurement.integratedLufs)) LUFS → 目标 \(setting.target.lufs)：增益 \(gainText)\(String(format: "%.1f", result.gainDb)) dB"
                )
                if result.peakLimited {
                    notes.append(
                        "已按真峰上限 \(String(format: "%.0f", setting.peakCeilingDb)) dBTP 压低增益（实测真峰 \(String(format: "%.1f", measurement.truePeakDb)) dBFS，按原增益会削波）"
                    )
                }
            } catch {
                loudnessGain = 1.0
                notes.append("响度测量失败，本次跳过标准化：\(errorText(error))")
            }
        } else {
            loudnessGain = 1.0
        }

        // MARK: 码率规划与磁盘预检（设计文档 §6.1 第 9 条 / P4）

        let audioNominalBitrate: Int
        if let target = audioTarget, audioOutput != nil {
            if let depth = request.audioPCMSampleBitDepth {
                audioNominalBitrate = BitratePlanner.pcmBitrate(
                    sampleRate: target.rate,
                    channels: target.channels,
                    bitDepth: depth
                )
            } else {
                audioNominalBitrate = target.bitrate
            }
        } else {
            audioNominalBitrate = 0
        }

        let durationSecondsPre = max(duration.seconds.isFinite ? duration.seconds : 0, 0)
        var effectiveVideoBitrate: Int?
        let nominalVideoBitrate: Int
        if request.videoCodec.isProRes {
            // ProRes 帧内编码：码率由档位与像素/帧率决定，不设码率键。
            effectiveVideoBitrate = nil
            nominalVideoBitrate = BitratePlanner.proResDataRate(
                codec: request.videoCodec,
                width: Int(renderSize.width),
                height: Int(renderSize.height),
                fps: outputFPS
            )
        } else {
            switch request.bitrateMode {
            case .targetBitrate:
                effectiveVideoBitrate = request.averageBitrate
                nominalVideoBitrate = request.averageBitrate ?? 12_000_000
            case .quality:
                // 质量模式：编码器按内容分配码率，只给名义值供预检与提示。
                effectiveVideoBitrate = nil
                nominalVideoBitrate = BitratePlanner.nominalQuality(
                    codec: request.videoCodec,
                    quality: request.quality,
                    width: Int(renderSize.width),
                    height: Int(renderSize.height)
                )
            case .targetSize:
                if let targetBytes = request.targetSizeBytes,
                   let result = BitratePlanner.targetSizeVideoBitrate(
                       targetBytes: targetBytes,
                       durationSeconds: durationSecondsPre,
                       audioBitrate: audioNominalBitrate,
                       range: request.bitrateRange
                   ) {
                    effectiveVideoBitrate = result.videoBitrate
                    nominalVideoBitrate = result.videoBitrate
                    if result.clamped {
                        notes.append("目标大小换算码率超出预设范围，已按 \(Fmt.mbps(result.videoBitrate)) 编码")
                    }
                } else {
                    effectiveVideoBitrate = request.averageBitrate
                    nominalVideoBitrate = request.averageBitrate ?? 12_000_000
                    notes.append("无法按时长换算目标大小，已按平均码率编码")
                }
            }
        }

        // 磁盘预检（设计文档 §6.1 第 9 条 / §7.8）：试编码实测码率优先，否则用名义值；
        // 探测模式按段时长估算（输出即删，不需要全片余量）
        let estimateSeconds = request.sourceTimeRange?.duration.seconds ?? durationSecondsPre
        var requiredBytes: Int64
        if let measured = request.measuredTotalBitrate {
            requiredBytes = Int64(Double(measured) / 8.0 * estimateSeconds)
        } else {
            requiredBytes = Int64(nominalVideoBitrate + audioNominalBitrate) / 8 * Int64(estimateSeconds)
            if request.bitrateMode == .targetSize, !request.videoCodec.isProRes, let targetBytes = request.targetSizeBytes {
                requiredBytes = max(requiredBytes, targetBytes)
            }
        }
        try checkDiskSpace(directory: outputDirectory, requiredBytes: requiredBytes + 200 * 1_048_576)

        // MARK: 画质修复执行器（设计文档 §7.6：模型懒加载；失败即 preparing 失败，不静默回退滤镜链）
        let enhancer: FrameEnhancer?
        if let setting = request.enhancement {
            let made = try await FrameEnhancerFactory.make(
                setting: setting,
                sourceWidth: Int(sourceSize.width),
                sourceHeight: Int(sourceSize.height)
            )
            enhancer = made
            notes.append(contentsOf: made.notes)
        } else {
            enhancer = nil
        }

        // 降帧感知混合器（设计文档 §7.12）：混合在增强前（源分辨率，输出帧少省增强算力）
        let blender: FrameBlender?
        if frameBlendingActive {
            let inputSize = needsComposition ? geometrySize : sourceSize
            blender = FrameBlender(
                outputFPS: outputFPS,
                sourceFPS: mediaFPS,
                width: max(Int(inputSize.width), 2),
                height: max(Int(inputSize.height), 2),
                pixelFormat: readerPixelFormat
            )
        } else {
            blender = nil
        }

        // 复古输出滤镜（设计文档 §7.15）：占据画质修复插槽（两者互斥），在混合器之后、写入端之前
        let retro: RetroFilter?
        if let setting = request.retroEffect {
            var osdBaseDate: Date?
            if setting.style == .dv {
                // DV 时间戳基准（§7.15）：源创建时间 → 文件修改时间；均无则不叠加
                let attrs = try? FileManager.default.attributesOfItem(atPath: request.inputURL.path)
                osdBaseDate = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
                if osdBaseDate == nil {
                    notes.append("未找到源创建时间，未叠加时间戳")
                }
            }
            let inputSize = needsComposition ? geometrySize : sourceSize
            retro = RetroFilter(
                style: setting.style,
                width: max(Int(inputSize.width), 2),
                height: max(Int(inputSize.height), 2),
                pixelFormat: readerPixelFormat,
                osdBaseDate: osdBaseDate
            )
            notes.append(setting.notesText)
        } else {
            retro = nil
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
            outputSettings: videoOutputSettings(
                request: request,
                size: renderSize,
                fps: outputFPS,
                targetBitrate: effectiveVideoBitrate
            )
        )
        guard writer.canAdd(videoInput) else {
            // 8K 超分：明确失败，不静默降级（设计文档 §7.6 / 2026-10-21 拍板）
            if request.enhancement != nil, max(Int(renderSize.width), Int(renderSize.height)) >= 7680 {
                throw TranscodeEngineError.eightKUnsupported(
                    codec: request.videoCodec.displayName,
                    width: Int(renderSize.width),
                    height: Int(renderSize.height)
                )
            }
            throw TranscodeEngineError.writerSetupFailed("无法添加视频写入器（可能是硬件编码器不可用）")
        }

        var audioInput: AVAssetWriterInput?
        if let target = audioTarget, audioOutput != nil {
            let audioSettings: [String: Any]
            if let bitDepth = request.audioPCMSampleBitDepth {
                // ProRes MOV：PCM（设计文档 §6.3）
                audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: target.rate,
                    AVNumberOfChannelsKey: target.channels,
                    AVLinearPCMBitDepthKey: bitDepth,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            } else {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVEncoderBitRateKey: target.bitrate,
                    AVSampleRateKey: target.rate,
                    AVNumberOfChannelsKey: target.channels,
                ]
            }
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

        // 元数据（设计文档 §6.5 / §7.5）：必须在 start() 之前设置
        let preservedMetadata: MetadataWriter.PreservedMetadata?
        if let metadata = request.metadata {
            preservedMetadata = nil
            writer.metadata = MetadataWriter.items(
                container: request.container,
                metadata: metadata,
                posterData: request.posterData
            )
            if metadata.posterPath != nil, request.posterData == nil {
                notes.append("海报未获取，已跳过")
            }
        } else {
            // 非电影任务：保留源标题/作者/创建日期/简介
            let preserved = await MetadataWriter.readPreserved(from: request.inputURL)
            preservedMetadata = preserved
            if !preserved.isEmpty {
                writer.metadata = MetadataWriter.items(container: request.container, preserved: preserved)
            }
        }

        // 启动（RequireHardware 标志在此被接受或拒绝，设计文档 §7）
        // 样片试编码：输出 PTS 保持源时间（reader.timeRange 截取），session 从段起点开启
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
        writer.startSession(atSourceTime: request.sourceTimeRange?.start ?? .zero)

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
        // 样片试编码（§7.8）：截取段的时长是进度 / 速度 / 外推的基准，非全片
        let durationSeconds: Double
        if let range = request.sourceTimeRange {
            durationSeconds = range.duration.seconds.isFinite ? range.duration.seconds : 0
        } else {
            durationSeconds = duration.seconds.isFinite ? duration.seconds : 0
        }

        do {
            let finalStats = try await withThrowingTaskGroup(of: PumpStats.self) { group in
                // 复古滤镜应用（设计文档 §7.15）：帧 → 风格化帧；PTS 用于噪点相位与 DV 时钟
                func applyRetro(
                    _ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>,
                    failureContext: String
                ) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
                    guard let retro else { return sample }
                    guard let readOnly = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else {
                        throw TranscodeEngineError.readWriteFailed("\(failureContext)不是像素内容，无法应用复古滤镜")
                    }
                    let pts = sample.presentationTimeStamp.seconds
                    return try readOnly.content.withUnsafeBuffer { inputBuffer in
                        let processed = try retro.process(pixelBuffer: inputBuffer, pts: pts)
                        let frame = CMReadySampleBuffer(
                            pixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: processed),
                            presentationTimeStamp: sample.presentationTimeStamp,
                            duration: sample.duration
                        )
                        return CMReadySampleBuffer(frame)
                    }
                }

                // 混合输出帧 → [复古滤镜] → [增强] → 写入（局部辅助，混用与冲刷共用）
                func emitBlended(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) async throws {
                    var outgoing = try applyRetro(sample, failureContext: "混合输出帧")
                    if let enhancer {
                        guard let readOnly = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else {
                            throw TranscodeEngineError.readWriteFailed("混合输出帧不是像素内容，无法增强")
                        }
                        outgoing = try readOnly.content.withUnsafeBuffer { inputBuffer in
                            let enhanced = try enhancer.enhance(inputBuffer)
                            let frame = CMReadySampleBuffer(
                                pixelBuffer: enhanced,
                                presentationTimeStamp: sample.presentationTimeStamp,
                                duration: sample.duration
                            )
                            return CMReadySampleBuffer(frame)
                        }
                    }
                    try await videoReceiver.append(outgoing)
                }

                group.addTask {
                    var stats = PumpStats()
                    var lastReport = started
                    while true {
                        // 读取失败与写入失败分开包装，避免原始系统错误直接透传到 UI
                        let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
                        do {
                            ready = try await videoProvider.next()
                        } catch {
                            throw TranscodeEngineError.readWriteFailed("视频读取失败：\(errorText(error))")
                        }
                        guard let ready else { break }
                        if Task.isCancelled || cancelFlag.isCancelled { throw TranscodeEngineError.cancelled }

                        if let blender {
                            // 帧混合分支（设计文档 §7.12）：源帧进混合器，输出 0..n 帧；混合在增强前
                            guard let readOnly = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(ready) else {
                                throw TranscodeEngineError.readWriteFailed("视频帧不是像素内容，无法混合")
                            }
                            let srcPts = ready.presentationTimeStamp.seconds
                            let outputs = try readOnly.content.withUnsafeBuffer { inputPixelBuffer in
                                try blender.ingest(pts: srcPts, source: inputPixelBuffer)
                            }
                            for sample in outputs {
                                try await emitBlended(sample)
                            }
                            stats.frames += 1
                            if srcPts.isFinite { stats.processedSeconds = max(stats.processedSeconds, srcPts) }
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
                            continue
                        }

                        // 复古滤镜（设计文档 §7.15）→ 画质修复层（设计文档 §7.6）：时间戳与音频直通不变
                        var outgoing = try applyRetro(ready, failureContext: "视频帧")
                        if let enhancer {
                            guard let readOnly = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(ready) else {
                                throw TranscodeEngineError.readWriteFailed("视频帧不是像素内容，无法增强")
                            }
                            outgoing = try readOnly.content.withUnsafeBuffer { inputBuffer in
                                let enhanced = try enhancer.enhance(inputBuffer)
                                let format = CMVideoFormatDescription(pixelBuffer: enhanced)
                                let frame = CMReadySampleBuffer(
                                    pixelBuffer: enhanced,
                                    formatDescription: format,
                                    presentationTimeStamp: ready.presentationTimeStamp,
                                    duration: ready.duration
                                )
                                return CMReadySampleBuffer(frame)
                            }
                        }
                        do {
                            try await videoReceiver.append(outgoing)
                        } catch {
                            throw TranscodeEngineError.readWriteFailed("视频写入失败：\(errorText(error))")
                        }
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
                    // 混合模式：源流结束冲刷剩余窗口
                    if let blender {
                        for frame in try blender.finish() {
                            try await emitBlended(frame)
                        }
                    }
                    videoReceiver.finish()
                    return stats
                }

                if let audioProvider, let audioReceiver {
                    group.addTask {
                        while true {
                            let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
                            do {
                                ready = try await audioProvider.next()
                            } catch {
                                throw TranscodeEngineError.readWriteFailed("音频读取失败：\(errorText(error))")
                            }
                            guard let ready else { break }
                            if Task.isCancelled || cancelFlag.isCancelled { throw TranscodeEngineError.cancelled }
                            if loudnessGain != 1.0 {
                                // 响度增益（设计文档 §7.11）：原地作用于 PCM 帧数据
                                try ready.withUnsafeSampleBuffer { sampleBuffer in
                                    LoudnessMeter.applyGain(to: sampleBuffer, linearGain: loudnessGain)
                                }
                            }
                            do {
                                try await audioReceiver.append(ready)
                            } catch {
                                throw TranscodeEngineError.readWriteFailed("音频写入失败：\(errorText(error))")
                            }
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
        // 样片试编码（设计文档 §7.8）：输出即删，跳过全部自检（expectedDuration 是全片时长会误报）
        var verificationIssues: [String] = []
        if !request.isProbe {
            verificationIssues = await verifyOutput(
                url: finalURL,
                expectedDuration: durationSeconds,
                expectedCodec: request.videoCodec,
                expectedSize: renderSize,
                expectedAudioPCMBitDepth: request.audioPCMSampleBitDepth
            )
        }
        if let metadata = request.metadata {
            verificationIssues += await MetadataWriter.verificationIssues(
                url: finalURL,
                container: request.container,
                metadata: metadata,
                expectsArtwork: request.posterData != nil
            )
        } else if let preservedMetadata, !preservedMetadata.isEmpty {
            verificationIssues += await MetadataWriter.preservationIssues(
                url: finalURL,
                container: request.container,
                expected: preservedMetadata
            )
        }

        return TranscodeOutcome(
            outputURL: finalURL,
            bytes: size,
            durationSeconds: durationSeconds,
            wallSeconds: wallSeconds,
            averageSpeed: durationSeconds / max(wallSeconds, 0.0001),
            usedComposition: needsComposition,
            verificationIssues: verificationIssues,
            notes: notes
        )
    }

    // MARK: - 输出设置

    private static func videoOutputSettings(
        request: TranscodeRequest,
        size: CGSize,
        fps: Double,
        targetBitrate: Int?
    ) -> [String: Any] {
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
        if !request.videoCodec.isProRes {
            switch request.bitrateMode {
            case .quality:
                compression[AVVideoQualityKey] = min(max(request.quality, 0.05), 1.0)
            case .targetBitrate, .targetSize:
                if let targetBitrate {
                    compression[AVVideoAverageBitRateKey] = targetBitrate
                }
            }
            let fpsInt = max(Int(fps.rounded()), 1)
            let keyframeFrames = Int((request.keyframeInterval.seconds * Double(fpsInt)).rounded())
            compression[AVVideoMaxKeyFrameIntervalKey] = max(keyframeFrames, 1)
            compression[AVVideoExpectedSourceFrameRateKey] = fpsInt
            if let profileLevel = request.profile.profileLevel(for: request.videoCodec) {
                compression[AVVideoProfileLevelKey] = profileLevel
            }
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
        expectedSize: CGSize,
        expectedAudioPCMBitDepth: Int? = nil
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
        if let expectedAudioPCMBitDepth {
            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                if let format = (try? await audioTrack.load(.formatDescriptions))?.first {
                    let subType = CMFormatDescriptionGetMediaSubType(format)
                    if subType != kAudioFormatLinearPCM {
                        issues.append("音频编码 \(VideoToolboxCapabilities.fourCCString(subType))（期望 PCM）")
                    } else if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                              Int(asbd.mBitsPerChannel) != expectedAudioPCMBitDepth {
                        issues.append("PCM 位深 \(asbd.mBitsPerChannel)（期望 \(expectedAudioPCMBitDepth)）")
                    }
                }
            } else {
                issues.append("输出缺少音频轨（期望 PCM）")
            }
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
