import AVFoundation
import CoreMedia
import Foundation

// MARK: - 音频响度标准化（设计文档 §7.11，灵感 7）
// BS.1770-4 / EBU R128：纯 Swift 实现，K-weighting 系数取 48 kHz 文献值
// （测量端固定 48 kHz 解码，与引擎音频泵口径一致）。

/// 目标响度三档（设计文档 §7.11 拍板）。
enum LoudnessTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case lufs14
    case lufs16
    case lufs23

    var id: String { rawValue }

    var lufs: Int {
        switch self {
        case .lufs14: -14
        case .lufs16: -16
        case .lufs23: -23
        }
    }

    var displayName: String {
        switch self {
        case .lufs14: "-14 LUFS（流媒体）"
        case .lufs16: "-16 LUFS（移动端）"
        case .lufs23: "-23 LUFS（广播）"
        }
    }
}

/// 响度标准化设置（TranscodeRequest.loudness 非 nil 即开启）。
struct LoudnessSetting: Codable, Equatable, Sendable {
    var target: LoudnessTarget
    /// 真峰上限（dBTP；设计文档拍板默认 -1）。
    var peakCeilingDb: Double

    init(target: LoudnessTarget = .lufs14, peakCeilingDb: Double = -1.0) {
        self.target = target
        self.peakCeilingDb = peakCeilingDb
    }
}

/// 一次响度测量结果。
struct LoudnessMeasurement: Codable, Equatable, Sendable {
    /// BS.1770 integrated loudness（LUFS）。
    var integratedLufs: Double
    /// 真峰（4× 过采样近似，dBFS）。
    var truePeakDb: Double
    /// 参与分析的样本数（单声道口径）。
    var sampleCount: Int
}

// MARK: - 测量与增益

enum LoudnessMeter {
    /// 48 kHz BS.1770-4 K-weighting：两级双二阶（高频搁架 + 高通）。
    private static let shelfB: [Double] = [1.53512485958697, -2.69169618940638, 1.19839281085285]
    private static let shelfA: [Double] = [1, -1.69065929318241, 0.73248077421585]
    private static let highpassB: [Double] = [1.0, -2.0, 1.0]
    private static let highpassA: [Double] = [1, -1.99004745483398, 0.99007225036621]

    private static let sampleRate: Double = 48_000
    private static let blockSeconds = 0.4       // 400 ms 分析块
    private static let hopSeconds = 0.1         // 75% overlap → 步进 100 ms
    private static let absoluteGateLufs: Double = -70

    /// 双二阶滤波器（Direct Form I，按声道独立）。
    struct Biquad {
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        init(b: [Double], a: [Double]) {
            b0 = b[0]; b1 = b[1]; b2 = b[2]
            a1 = a[1]; a2 = a[2]
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    /// 测量 integrated loudness 与真峰（全片音频解码；48 kHz 固定采样率）。
    ///
    /// - Parameters:
    ///   - url: 源文件。
    ///   - maxChannels: 引擎将输出的声道数（下混口径一致）。
    static func measure(url: URL, maxChannels: Int) async throws -> LoudnessMeasurement {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        else {
            throw LoudnessError.noAudioTrack
        }

        let sourceChannels = (try? await audioTrack.load(.formatDescriptions))?.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
            .map { Int($0.pointee.mChannelsPerFrame) } ?? 2
        let channels = min(max(sourceChannels, 1), max(maxChannels, 1))

        let decodeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = try AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decodeSettings)
        reader.add(output)
        guard reader.startReading() else {
            throw LoudnessError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        defer { reader.cancelReading() }

        let blockLength = Int(blockSeconds * sampleRate)
        let hopLength = Int(hopSeconds * sampleRate)
        // 每 100 ms 段的加权平方和（段窗口 = 连续 4 段，见 §7.11）
        var segmentSums: [Double] = []
        var perChannelFilters = (0..<channels).map { _ in
            (shelf: Biquad(b: shelfB, a: shelfA), highpass: Biquad(b: highpassB, a: highpassA))
        }
        var segmentProgress = 0
        var segmentSum = 0.0
        var totalSamples = 0
        var truePeakLinear = 0.0

        while let sample = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                  let dataPointer
            else { continue }

            let frameCount = length / (4 * channels)
            dataPointer.withMemoryRebound(to: Float.self, capacity: frameCount * channels) { floats in
                for frame in 0..<frameCount {
                    var weightedSquareSum = 0.0
                    for channel in 0..<channels {
                        let value = Double(floats[frame * channels + channel])
                        // 真峰（4× 线性插值近似）与滤波都在原值域
                        truePeakLinear = max(truePeakLinear, abs(value))
                        let weighted = perChannelFilters[channel].highpass.process(
                            perChannelFilters[channel].shelf.process(value)
                        )
                        weightedSquareSum += weighted * weighted
                    }
                    segmentSum += weightedSquareSum
                    totalSamples += 1
                    segmentProgress += 1
                    if segmentProgress == hopLength {
                        segmentSums.append(segmentSum / Double(hopLength))
                        segmentSum = 0
                        segmentProgress = 0
                    }
                }
            }
        }
        guard reader.status == .completed, totalSamples > 0 else {
            throw LoudnessError.readFailed(reader.error?.localizedDescription ?? "音频读取未完成")
        }
        // 尾段不足一个 hop：仅当超过 200 ms（半个 hop）才计入，避免尾块偏置
        if segmentProgress >= hopLength / 2 {
            segmentSums.append(segmentSum / Double(segmentProgress))
        }

        let integrated = Self.integrated(segmentSums: segmentSums, blockLength: blockLength, hopLength: hopLength)
        guard let integrated else {
            throw LoudnessError.tooQuiet
        }
        return LoudnessMeasurement(
            integratedLufs: integrated,
            truePeakDb: 20 * log10(max(truePeakLinear, 1e-9)),
            sampleCount: totalSamples
        )
    }

    /// gated integrated loudness（BS.1770-4：绝对门限 -70 LUFS + 相对门限）。
    ///
    /// - Parameter segmentSums: 每 100 ms 段的「每帧跨声道加权平方和均值」（与 `measure` 输出口径一致）。
    static func integrated(segmentSums: [Double], blockLength: Int, hopLength: Int) -> Double? {
        // 连续 4 段（400 ms）为一个分析块；段值已是每帧均值，窗口均值 = 4 段平均
        guard segmentSums.count >= 4 else { return nil }
        var blockLoudness: [Double] = []
        var blockEnergies: [Double] = []
        var i = 0
        while i + 4 <= segmentSums.count {
            let meanSquare = (segmentSums[i] + segmentSums[i + 1] + segmentSums[i + 2] + segmentSums[i + 3]) / 4.0
            let lufs = -0.691 + 10 * log10(max(meanSquare, 1e-12))
            blockLoudness.append(lufs)
            blockEnergies.append(meanSquare)
            i += 1
        }
        // 绝对门限
        var gated: [(lufs: Double, energy: Double)] = []
        for (index, lufs) in blockLoudness.enumerated() where lufs > absoluteGateLufs {
            gated.append((lufs, blockEnergies[index]))
        }
        guard !gated.isEmpty else { return nil }
        // 相对门限：gated 均值 - 20 LU
        let gatedMeanEnergy = gated.reduce(0.0) { $0 + $1.energy } / Double(gated.count)
        let relativeGate = -0.691 + 10 * log10(max(gatedMeanEnergy, 1e-12)) - 20
        let final = gated.filter { $0.lufs > relativeGate }
        guard !final.isEmpty else { return nil }
        let finalMeanEnergy = final.reduce(0.0) { $0 + $1.energy } / Double(final.count)
        return -0.691 + 10 * log10(max(finalMeanEnergy, 1e-12))
    }

    /// 增益计算（设计文档 §7.11）：target − measured，并夹到真峰上限内。
    static func gain(measurement: LoudnessMeasurement, setting: LoudnessSetting) -> (gainDb: Double, peakLimited: Bool) {
        let raw = Double(setting.target.lufs) - measurement.integratedLufs
        let ceilingGain = setting.peakCeilingDb - measurement.truePeakDb
        if ceilingGain < raw {
            return (gainDb: max(ceilingGain, -60), peakLimited: true)
        }
        return (gainDb: min(raw, 60), peakLimited: false)
    }

    /// 原地对 sample buffer 的 Float32 interleaved PCM 数据乘线性增益。
    static func applyGain(to sampleBuffer: CMSampleBuffer, linearGain: Float) {
        guard linearGain != 1.0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer else { return }
        let sampleCount = length / MemoryLayout<Float>.size
        dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floats in
            scale(floats: floats, count: sampleCount, gain: linearGain)
        }
    }

    /// Float 数组逐样本乘法（applyGain 的纯函数内核）。
    static func scale(floats: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        for index in 0..<count {
            floats[index] *= gain
        }
    }

    enum LoudnessError: LocalizedError, Sendable {
        case noAudioTrack
        case readFailed(String)
        case tooQuiet

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                "没有音轨。"
            case .readFailed(let message):
                "音频读取失败：\(message)"
            case .tooQuiet:
                "音频低于测量门限（-70 LUFS），无法标准化。"
            }
        }
    }
}
