import AVFoundation
import CoreMedia
import Foundation

// MARK: - 音频提取 + 波形图（设计文档 §7.17，灵感 13）
// 音轨抽取工具：AVAssetReader（PCM Float32）→ AVAssetWriter 封装，与主链路同源；
// 不进转码队列、不经视频硬件编码器要求（AAC 为系统音频编码器，WAV 纯封装）。
// 提取保持源采样率与声道数（「抽取」而非「转码」）；输出原子落盘。

/// 导出格式（Writer 设置的单一事实来源）。
enum AudioExportFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    /// M4A 容器 + AAC 192 kbps。
    case m4a
    /// WAV 容器 + PCM 16-bit（无损，剪辑友好）。
    case wav

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .m4a: "M4A（AAC）"
        case .wav: "WAV（PCM 16-bit）"
        }
    }

    var summary: String {
        switch self {
        case .m4a: "有损通用格式，体积小"
        case .wav: "无损 PCM，剪辑友好，体积较大"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a: "m4a"
        case .wav: "wav"
        }
    }

    /// AVAssetWriter 容器类型。
    var avFileType: AVFileType {
        switch self {
        case .m4a: .m4a
        case .wav: .wav
        }
    }

    /// AAC 码率：≤2 声道 192 kbps，多声道按 128 kbps/声道（上限 512）。
    func aacBitrate(channels: Int) -> Int {
        guard channels > 2 else { return 192_000 }
        return min(channels * 128_000, 512_000)
    }
}

/// 波形包络（固定桶数，幅度绝对值 min / max，0–1 域）。
struct WaveformEnvelope: Equatable, Sendable {
    /// 桶数（与时长无关，绘制宽度恒定）。
    static let bucketCount = 600

    var durationSeconds: Double
    /// 每桶最小 / 最大幅度（0–1；静音桶为 0）。
    var minima: [Float]
    var maxima: [Float]

    /// 波形是否全静音（无有效内容）。
    var isSilent: Bool {
        maxima.allSatisfy { $0 <= 0.001 }
    }
}

/// 一次音频分析结果（轨道信息 + 波形）。
struct AudioTrackAnalysis: Sendable {
    var channels: Int
    var sampleRate: Double
    var durationSeconds: Double
    var envelope: WaveformEnvelope
}

enum AudioExtractError: LocalizedError, Equatable, Sendable {
    case noAudioTrack
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "该文件没有音轨，无法提取。"
        case .readFailed(let message):
            "音频读取失败：\(message)"
        case .writeFailed(let message):
            "音频写入失败：\(message)"
        }
    }
}

enum AudioExtractor {
    // MARK: - 波形分析

    /// 分析音轨并计算波形包络（读全片音频 PCM，长片数秒内）；无音轨返回 nil。
    static func analyze(url: URL) async throws -> AudioTrackAnalysis? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        else { return nil }

        let (channels, sampleRate): (Int, Double) = try await audioFormat(of: audioTrack)
        let duration = ((try? await asset.load(.duration))?.seconds ?? 0)
        guard duration > 0, channels > 0, sampleRate > 0 else { return nil }

        let reader = try AVAssetReader(asset: asset)
        let output = try AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmDecodeSettings(channels: channels, sampleRate: sampleRate))
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExtractError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        defer { reader.cancelReading() }

        var envelope = WaveformEnvelope(
            durationSeconds: duration,
            minima: [Float](repeating: 1, count: WaveformEnvelope.bucketCount),
            maxima: [Float](repeating: 0, count: WaveformEnvelope.bucketCount)
        )
        let bucketWidth = duration / Double(WaveformEnvelope.bucketCount)

        while let sample = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            let bufferPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard bufferPTS.isFinite else { continue }
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                  let dataPointer
            else { continue }

            let frameCount = length / (4 * channels)
            dataPointer.withMemoryRebound(to: Float.self, capacity: frameCount * channels) { floats in
                Self.updateEnvelope(
                    &envelope,
                    bucketWidth: bucketWidth,
                    bufferPTS: bufferPTS,
                    sampleRate: sampleRate,
                    frames: frameCount,
                    channels: channels,
                    samples: floats
                )
            }
        }
        guard reader.status == .completed else {
            throw AudioExtractError.readFailed(reader.error?.localizedDescription ?? "音频读取未完成")
        }
        // 静音桶 min 归 0（初始 1 仅用于求 min；全静音时 maxima 全 0 亦正确）
        normalizeSilentBuckets(&envelope)
        return AudioTrackAnalysis(
            channels: channels,
            sampleRate: sampleRate,
            durationSeconds: duration,
            envelope: envelope
        )
    }

    // MARK: - 纯函数（harness 可测）

    /// 波形分桶更新：帧时间 = buffer PTS + 帧内偏移，按时间归桶，每桶累计幅度绝对值 min / max。
    static func updateEnvelope(
        _ envelope: inout WaveformEnvelope,
        bucketWidth: Double,
        bufferPTS: Double,
        sampleRate: Double,
        frames: Int,
        channels: Int,
        samples: UnsafePointer<Float>
    ) {
        guard bucketWidth > 0, channels > 0, sampleRate > 0 else { return }
        for frame in 0..<frames {
            let time = bufferPTS + Double(frame) / sampleRate
            let index = min(max(Int(time / bucketWidth), 0), WaveformEnvelope.bucketCount - 1)
            for channel in 0..<channels {
                let magnitude = abs(samples[frame * channels + channel])
                if magnitude < envelope.minima[index] { envelope.minima[index] = magnitude }
                if magnitude > envelope.maxima[index] { envelope.maxima[index] = magnitude }
            }
        }
    }

    /// 静音桶 min 归 0（min 初值 1 仅用于求 min）。
    static func normalizeSilentBuckets(_ envelope: inout WaveformEnvelope) {
        for index in envelope.minima.indices where envelope.maxima[index] <= 0.001 {
            envelope.minima[index] = 0
        }
    }

    // MARK: - 提取导出

    /// 提取音轨：Reader PCM（源采样率 / 声道）→ Writer（M4A AAC / WAV PCM16），原子落盘到 outputURL。
    ///
    /// - Returns: 最终输出 URL（重名已消解为 `-1` 后缀）。
    @discardableResult
    static func extract(
        url: URL,
        format: AudioExportFormat,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        else {
            throw AudioExtractError.noAudioTrack
        }
        let (channels, sampleRate): (Int, Double) = try await audioFormat(of: audioTrack)
        guard channels > 0, sampleRate > 0 else {
            throw AudioExtractError.readFailed("音轨格式信息缺失")
        }
        let duration = ((try? await asset.load(.duration))?.seconds ?? 0)

        let outputDirectory = outputURL.deletingLastPathComponent()
        let tempURL = OutputPlanner.makeTempURL(in: outputDirectory)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tempURL, fileType: format.avFileType)
        } catch {
            throw AudioExtractError.writeFailed(errorText(error))
        }

        let input: AVAssetWriterInput
        switch format {
        case .wav:
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        case .m4a:
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: format.aacBitrate(channels: channels),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ])
        }
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw AudioExtractError.writeFailed("无法添加音频写入器（格式组合不受支持）")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = try AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmDecodeSettings(channels: channels, sampleRate: sampleRate))

        // macOS 27 新 API：inputReceiver / outputProvider 取代 add（outputProvider 内部注册 output），须在 start 之前调用
        let receiver = writer.inputReceiver(for: input)
        let provider = reader.outputProvider(for: output)

        do {
            try writer.start()
        } catch {
            throw AudioExtractError.writeFailed("启动写入失败：\(errorText(error))")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioExtractError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        defer { reader.cancelReading() }

        do {
            var processedSeconds = 0.0
            while let sample = try await provider.next() {
                let pts = sample.presentationTimeStamp.seconds
                if pts.isFinite, pts > processedSeconds { processedSeconds = pts }
                if duration > 0 {
                    progress(min(processedSeconds / duration, 1.0))
                }
                try await receiver.append(sample)
            }
            receiver.finish()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw AudioExtractError.writeFailed("收尾写入失败：\(errorText(writer.error))")
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // 原子落盘：重名加 `-1` 不覆盖（设计文档 §7.17）
        do {
            let target = FileManager.default.fileExists(atPath: outputURL.path)
                ? OutputPlanner.uniqueOutputURL(
                    directory: outputDirectory,
                    baseName: outputURL.deletingPathExtension().lastPathComponent,
                    fileExtension: outputURL.pathExtension
                )
                : outputURL
            try FileManager.default.moveItem(at: tempURL, to: target)
            progress(1.0)
            return target
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioExtractError.writeFailed("移动输出文件失败：\(errorText(error))")
        }
    }

    // MARK: - 私有

    /// 源音轨的声道数与采样率。
    private static func audioFormat(of track: AVAssetTrack) async throws -> (channels: Int, sampleRate: Double) {
        guard let format = (try? await track.load(.formatDescriptions))?.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return (0, 0) }
        return (Int(asbd.pointee.mChannelsPerFrame), asbd.pointee.mSampleRate)
    }

    /// 解码端输出设置：PCM Float32，保持源采样率与声道（「抽取」不做重采样 / 下混）。
    private static func pcmDecodeSettings(channels: Int, sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
    }

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "无错误详情" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }
}
