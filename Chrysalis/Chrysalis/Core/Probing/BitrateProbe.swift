import CoreMedia
import Foundation

// MARK: - 样片试编码服务（设计文档 §7.8）

/// 一次试编码的实测结果（持久化到队列归档）。
struct BitrateProbeResult: Sendable, Equatable, Codable {
    /// 实测总码率（视频 + 音频，bps）。
    var averageBitrate: Int
    /// 实际采样的源时长（秒）。
    var sampledSeconds: Double
    /// 各段独立码率（诊断展示）。
    var segmentBitrates: [Int]
    var createdAt: Date

    /// 全片估算体积（字节）= 实测总码率 ÷ 8 × 全片时长。
    func estimatedBytes(forFullDuration duration: Double) -> Int64 {
        guard duration > 0 else { return 0 }
        return Int64(Double(averageBitrate) / 8.0 * duration)
    }
}

/// 试编码执行器：抽段 → 逐段以最终参数真实编码（复用引擎）→ 实测码率外推全片。
enum BitrateProbeService {
    /// 抽段方案：均匀 3 段、各 4 秒，避开片头片尾各 5%；
    /// 源不足 15 秒时缩段（`min(4, 可用区间 ÷ 3)`）；不足 5 秒改单段 = 时长 ×0.5。
    static func segments(forDuration duration: Double, count: Int = 3, length: Double = 4) -> [(start: Double, length: Double)] {
        guard duration.isFinite, duration > 0.5 else { return [] }
        let margin = duration * 0.05
        let available = max(duration - margin * 2, 0)
        // 超短源（<5 秒）：单段 = 时长 ×0.5（居中）
        let singleSegment = (start: (duration - duration * 0.5) / 2, length: duration * 0.5)
        guard duration >= 5 else { return [singleSegment] }
        let effectiveLength = min(length, available / Double(count))
        guard effectiveLength >= 0.5 else { return [singleSegment] }
        var result: [(start: Double, length: Double)] = []
        for index in 0..<count {
            let start = margin + (available - effectiveLength) * Double(index) / Double(max(count - 1, 1))
            result.append((start: start, length: effectiveLength))
        }
        return result
    }

    /// 对一份转码参数执行试编码，返回实测码率。
    ///
    /// - Parameters:
    ///   - request: 正式任务的完整参数（含画质修复等，试编码按拍板同样跑超分）。
    ///   - sourceDuration: 源总时长（秒，抽段定位用）。
    ///   - progress: 每段完成回调（段序号 / 总段数 / 段码率）。
    static func run(
        request: TranscodeRequest,
        sourceDuration: Double,
        progress: (@Sendable (Int, Int, Int) -> Void)? = nil
    ) async throws -> BitrateProbeResult {
        let segments = segments(forDuration: sourceDuration)
        guard !segments.isEmpty else {
            throw ProbeError.tooShort
        }

        let fileManager = FileManager.default
        let probeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("chrysalis-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        // 探测结束（含失败/取消）清空整个临时目录
        defer { try? fileManager.removeItem(at: probeDirectory) }

        var segmentBitrates: [Int] = []
        var sampledSeconds = 0.0

        for (position, segment) in segments.enumerated() {
            let outputURL = probeDirectory.appendingPathComponent("segment-\(position).\(request.container.fileExtension)")
            var segmentRequest = request
            segmentRequest.outputURL = outputURL
            segmentRequest.sourceTimeRange = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                duration: CMTime(seconds: segment.length, preferredTimescale: 600)
            )
            segmentRequest.isProbe = true

            let engine = TranscodeEngine()
            let outcome = try await engine.run(segmentRequest) { _ in }

            guard outcome.durationSeconds > 0.05 else {
                throw ProbeError.emptySegment(position: position)
            }
            let bitrate = Int((Double(outcome.bytes) * 8) / outcome.durationSeconds)
            guard bitrate > 0 else {
                throw ProbeError.emptySegment(position: position)
            }
            segmentBitrates.append(bitrate)
            sampledSeconds += outcome.durationSeconds
            progress?(position, segments.count, bitrate)
        }

        let average = segmentBitrates.reduce(0, +) / max(segmentBitrates.count, 1)
        guard average > 0 else {
            throw ProbeError.emptySegment(position: 0)
        }
        return BitrateProbeResult(
            averageBitrate: average,
            sampledSeconds: sampledSeconds,
            segmentBitrates: segmentBitrates,
            createdAt: Date()
        )
    }

    enum ProbeError: LocalizedError, Sendable {
        case tooShort
        case emptySegment(position: Int)

        var errorDescription: String? {
            switch self {
            case .tooShort:
                "源时长太短，无法抽取试编码样片。"
            case .emptySegment(let position):
                "第 \(position + 1) 段试编码没有产出有效数据。"
            }
        }
    }
}
