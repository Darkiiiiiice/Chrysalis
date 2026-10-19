import Foundation

/// 码率规划（设计文档 P4）：UI 估算与引擎实际编码共用同一套公式，避免口径漂移。
enum BitratePlanner {
    /// ProRes 在 1920×1080@30 下的标称数据率（bps；Apple ProRes 白皮书口径）。
    static func proResBase1080p(_ codec: VideoCodec) -> Int? {
        switch codec {
        case .proRes422Proxy: 45_000_000
        case .proRes422LT: 102_000_000
        case .proRes422: 147_000_000
        case .proRes422HQ: 220_000_000
        case .proRes4444: 330_000_000
        case .h264, .hevc: nil
        }
    }

    /// ProRes 标称数据率：按输出像素数与帧率线性缩放（ProRes 帧内编码，码率 ∝ 像素 × 帧率）。
    static func proResDataRate(codec: VideoCodec, width: Int, height: Int, fps: Double) -> Int {
        guard let base = proResBase1080p(codec) else { return 0 }
        let pixelScale = Double(max(width, 2) * max(height, 2)) / (1920.0 * 1080.0)
        let fpsScale = max(fps, 1) / 30.0
        return max(Int(Double(base) * pixelScale * fpsScale), 1_000_000)
    }

    /// 平均码率模式：1080p 基准按输出像素数缩放，并夹取到预设范围（P3.5 行为）。
    static func scaled(base1080p: Int, range: ClosedRange<Int>, width: Int, height: Int) -> Int {
        let pixels = Double(max(width, 2) * max(height, 2))
        let scale = pixels / (1920.0 * 1080.0)
        let raw = Double(base1080p) * scale
        return Int(min(max(raw, Double(range.lowerBound)), Double(range.upperBound)))
    }

    /// 质量模式的名义码率（仅估算与磁盘预检；实际编码走 `AVVideoQualityKey`）。
    ///
    /// 口径：以该编码的 1080p 基准（H.264 8 Mbps / HEVC 6 Mbps）为锚点，质量 0.65 ≈ 基准，
    /// 0.2 ≈ 0.32×，0.9 ≈ 1.67×（`factor = 0.25 + 1.75 × q²`）。质量模式下编码器按内容
    /// 分配给码率，实测体积会显著偏离名义值，UI 必须标注「按质量推测」。
    static func nominalQuality(codec: VideoCodec, quality: Double, width: Int, height: Int) -> Int {
        let base1080p: Int
        switch codec {
        case .h264: base1080p = 8_000_000
        case .hevc: base1080p = 6_000_000
        default: return 0
        }
        let q = min(max(quality, 0.05), 1.0)
        let factor = 0.25 + 1.75 * q * q
        let pixels = Double(max(width, 2) * max(height, 2))
        let scaled = Double(base1080p) * factor * (pixels / (1920.0 * 1080.0))
        return Int(max(scaled, 500_000).rounded())
    }

    /// 目标大小换算结果。
    struct TargetSizeResult: Sendable, Equatable {
        var videoBitrate: Int
        /// 按时长换算后的码率是否被预设范围夹取（夹取后实际体积将偏离目标）。
        var clamped: Bool
    }

    /// 目标大小（字节）→ 视频码率（bps）：扣除音频码率、按时长换算、夹取到预设范围。
    /// 时长 ≤ 0 或目标非法时返回 nil（调用方回退到平均码率）；换算值超出范围时夹取并置位 `clamped`。
    static func targetSizeVideoBitrate(
        targetBytes: Int64,
        durationSeconds: Double,
        audioBitrate: Int,
        range: ClosedRange<Int>
    ) -> TargetSizeResult? {
        guard targetBytes > 0, durationSeconds > 0, durationSeconds.isFinite else { return nil }
        let totalBits = Double(targetBytes) * 8
        let raw = totalBits / durationSeconds - Double(audioBitrate)
        guard raw.isFinite else { return nil }
        let clamped = raw < Double(range.lowerBound) || raw > Double(range.upperBound)
        let value = Int(min(max(raw, Double(range.lowerBound)), Double(range.upperBound)))
        return TargetSizeResult(videoBitrate: max(value, 1), clamped: clamped)
    }

    /// PCM 音频的标称码率（bps）：采样率 × 声道 × 位深。
    static func pcmBitrate(sampleRate: Double, channels: Int, bitDepth: Int) -> Int {
        Int(max(sampleRate, 1) * Double(max(channels, 1)) * Double(max(bitDepth, 8)))
    }
}
