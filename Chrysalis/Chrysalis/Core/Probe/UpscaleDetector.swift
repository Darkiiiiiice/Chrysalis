import Foundation

// MARK: - 假 4K 检测（设计文档 §7.14，灵感 10）
// 放大帧缺乏真实像素级细节：下采样 ×0.5 再上采样回原尺寸，
// 与原帧的高频残差（按平均亮度归一）显著低于真实高分辨率帧。

enum UpscaleDetector {
    struct Verdict: Codable, Equatable, Sendable {
        /// 疑似放大。
        var suspected: Bool
        /// 置信度 0–1。
        var confidence: Double
        /// 建议转码档位（仅疑似时给出）。
        var suggestedLevel: String?
        var sampledFrames: Int
        /// 各帧归一化高频残差得分（诊断展示）。
        var frameScores: [Double]
        /// 中位数得分。
        var medianScore: Double
    }

    /// 疑似判定阈值（残差/亮度；以真/伪 4K 合成样本标定：真 4K ≈ 0.021、伪 4K ≈ 0.010，§7.14）。
    static let suspectedThreshold = 0.015

    /// 对视频执行假 4K 检测：3 段各取中间一帧分析。
    static func detect(
        url: URL,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceDuration: Double
    ) async throws -> Verdict {
        // 可抽段的最短时长（§7.8 抽段下限 0.5s）
        guard sourceDuration > 0.5 else {
            return Verdict(suspected: false, confidence: 0, suggestedLevel: nil, sampledFrames: 0, frameScores: [], medianScore: 0)
        }
        let segments = BitrateProbeService.segments(forDuration: sourceDuration, count: 3, length: 4)
        let times = segments.map { $0.start + $0.length / 2 }
        let frames = try await ProbeFrameGrabber.grabGrayFrames(url: url, at: times, sourceDuration: sourceDuration)
        let scores = frames.map { residualScore(gray: $0.luma, width: $0.width, height: $0.height) }
        guard !scores.isEmpty else {
            return Verdict(suspected: false, confidence: 0, suggestedLevel: nil, sampledFrames: 0, frameScores: [], medianScore: 0)
        }
        let median = scores.sorted()[scores.count / 2]
        let (suspected, confidence) = classify(score: median)
        return Verdict(
            suspected: suspected,
            confidence: confidence,
            suggestedLevel: suspected ? suggestedLevel(forWidth: sourceWidth, forHeight: sourceHeight) : nil,
            sampledFrames: scores.count,
            frameScores: scores,
            medianScore: median
        )
    }

    // MARK: - 纯函数（harness 可测）

    /// 高频残差得分：均值池化 ×0.5 → 双线性上采样回原尺寸 → 逐像素差标准差 / 平均亮度。
    static func residualScore(gray: [Float], width: Int, height: Int) -> Double {
        guard width >= 4, height >= 4, gray.count >= width * height else { return 1.0 }
        let halfW = width / 2
        let halfH = height / 2

        // 均值池化下采样
        var small = [Float](repeating: 0, count: halfW * halfH)
        for y in 0..<halfH {
            for x in 0..<halfW {
                let base = (2 * y) * width + 2 * x
                small[y * halfW + x] = (gray[base] + gray[base + 1] + gray[base + width] + gray[base + width + 1]) / 4
            }
        }

        // 双线性上采样 + 残差统计
        var residualSum = 0.0
        var residualSqSum = 0.0
        var meanSum = 0.0
        for y in 0..<height {
            let sy = (Float(y) - 0.5) / 2.0
            let y0 = max(0, min(halfH - 1, Int(sy.rounded(.down))))
            let y1 = min(halfH - 1, y0 + 1)
            let fy = max(0, min(1, sy - Float(y0)))
            for x in 0..<width {
                let sx = (Float(x) - 0.5) / 2.0
                let x0 = max(0, min(halfW - 1, Int(sx.rounded(.down))))
                let x1 = min(halfW - 1, x0 + 1)
                let fx = max(0, min(1, sx - Float(x0)))
                let v = (1 - fy) * (1 - fx) * small[y0 * halfW + x0]
                    + (1 - fy) * fx * small[y0 * halfW + x1]
                    + fy * (1 - fx) * small[y1 * halfW + x0]
                    + fy * fx * small[y1 * halfW + x1]
                let d = Double(gray[y * width + x] - v)
                residualSum += d
                residualSqSum += d * d
                meanSum += Double(gray[y * width + x])
            }
        }
        let count = Double(width * height)
        let variance = residualSqSum / count - (residualSum / count) * (residualSum / count)
        let standardDeviation = sqrt(max(variance, 0))
        let meanLuma = meanSum / count
        guard meanLuma > 0.02 else { return 0 }  // 近黑场无参考价值
        return standardDeviation / meanLuma
    }

    /// 判定与置信度：阈值之下疑似（越低越确信），之上未检出（越高越确信）。
    static func classify(score: Double) -> (suspected: Bool, confidence: Double) {
        if score < suspectedThreshold {
            let confidence = min(1.0, 0.5 + 0.5 * (suspectedThreshold - score) / suspectedThreshold)
            return (true, confidence)
        }
        let confidence = min(1.0, 0.5 + 0.5 * (score - suspectedThreshold) / (suspectedThreshold * 2))
        return (false, confidence)
    }

    /// 建议转码档位（由源显示尺寸推断；仅疑似时调用）。
    static func suggestedLevel(forWidth: Int, forHeight: Int) -> String? {
        let shortEdge = min(forWidth, forHeight)
        if shortEdge >= 2160 { return "FHD（1080p）或更低" }
        if shortEdge >= 1440 { return "HD（720p）" }
        if shortEdge >= 1000 { return "HD（720p）/ SD" }
        return nil  // 已是低档位，无建议价值
    }
}
