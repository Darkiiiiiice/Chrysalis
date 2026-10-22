import Foundation

// MARK: - 内容复杂度热力图（设计文档 §7.16，灵感 12）
// 编码难度按时间轴的分布：运动分（相邻帧差分）+ 细节分（单帧梯度能量）双维合成。
// 只读分析：复用体检共享抽帧器，单 reader 一次扫描；失败静默降级（报告字段 nil）。

enum ComplexityAnalyzer {
    /// 分级（按段综合分均值）。
    enum Level: String, Codable, Sendable, CaseIterable {
        case low
        case medium
        case high

        var displayName: String {
            switch self {
            case .low: "低"
            case .medium: "中"
            case .high: "高"
            }
        }

        /// 人话结论（体检报告 / Markdown 共用）。
        var summary: String {
            switch self {
            case .low: "低复杂度内容：静态画面为主，较低码率即可保持质量，质量优先模式收益大。"
            case .medium: "中等复杂度：常规转码参数即可。"
            case .high: "高复杂度内容：大量运动或高细节，建议更高码率或质量优先模式。"
            }
        }
    }

    struct Stats: Codable, Equatable, Sendable {
        var min: Double
        var average: Double
        var max: Double
        var p90: Double
    }

    struct Segment: Codable, Equatable, Sendable {
        /// 段起点（秒）。
        var start: Double
        /// 帧间运动分（0–1）；配对失败时 nil（变速 / 丢帧降级）。
        var motion: Double?
        /// 空间细节分（0–1）。
        var detail: Double
        /// 综合分（0–1）；运动缺失时 = 0.45 权重重归一后的细节分。
        var score: Double
    }

    struct Report: Codable, Equatable, Sendable {
        var sampledPoints: Int
        var motion: Stats?
        var detail: Stats?
        var score: Stats?
        var level: Level
        var segments: [Segment]
    }

    // MARK: - 常量（标定口径见 §7.16）

    /// 采样时间点数。
    static let samplePoints = 12
    /// 运动分上限：相邻帧差均值 ≥ 0.15 视为大运动（0–1 灰度域）。
    static let motionCeiling = 0.15
    /// 细节分上限：梯度能量均值 ≥ 0.08 视为高细节。
    static let detailCeiling = 0.08
    /// 综合分权重：运动主导码率，细节次之。
    static let motionWeight = 0.55
    static let detailWeight = 0.45
    /// 分级阈值。
    static let lowThreshold = 0.25
    static let highThreshold = 0.55

    // MARK: - 分析入口

    /// 对视频执行复杂度分析：均匀 12 点各抓连续两帧（共享抽帧器单次扫描）。
    static func analyze(
        url: URL,
        frameRate: Double,
        sourceDuration: Double
    ) async -> Report? {
        guard sourceDuration > 0.5, frameRate > 0 else { return nil }
        let margin = sourceDuration * 0.05
        let usableStart = margin
        let usableEnd = max(sourceDuration - margin, usableStart + 0.1)
        let step = (usableEnd - usableStart) / Double(samplePoints)
        // 每点两个目标：t 与 t + 1/帧率（抓相邻帧对；抽帧器按序各消费一个目标）
        let frameInterval = 1.0 / frameRate
        var times: [Double] = []
        for i in 0..<samplePoints {
            let t = usableStart + step * (Double(i) + 0.5)
            times.append(t)
            times.append(t + frameInterval)
        }
        let frames: [GrayFrame]
        do {
            frames = try await ProbeFrameGrabber.grabGrayFrames(url: url, at: times, sourceDuration: sourceDuration)
        } catch {
            return nil
        }
        guard frames.count >= 2 else { return nil }

        // 配对：捕获顺序 = 目标顺序（t, t', …）；PTS 差 ≤ 1.5 帧间隔才算相邻帧对
        var segments: [Segment] = []
        var index = 0
        while index + 1 < frames.count {
            let first = frames[index]
            let second = frames[index + 1]
            let isPair = second.pts - first.pts > 0 && second.pts - first.pts <= frameInterval * 1.5
            let detail = Self.detail(gray: first.luma, width: first.width, height: first.height)
            if isPair {
                let motionValue = Self.motion(first: first.luma, second: second.luma)
                segments.append(
                    Segment(
                        start: first.pts,
                        motion: motionValue,
                        detail: detail,
                        score: Self.score(motion: motionValue, detail: detail)
                    )
                )
            } else {
                // 配对失败（错位 / 丢帧）：只保留细节维，综合分按细节权重重归一
                segments.append(
                    Segment(
                        start: first.pts,
                        motion: nil,
                        detail: detail,
                        score: min(detail / detailCeiling, 1.0)
                    )
                )
            }
            index += isPair ? 2 : 1
        }
        guard !segments.isEmpty else { return nil }

        let motions = segments.compactMap(\.motion)
        let details = segments.map(\.detail)
        let scores = segments.map(\.score)
        let averageScore = scores.reduce(0, +) / Double(scores.count)
        return Report(
            sampledPoints: segments.count,
            motion: stats(motions),
            detail: stats(details),
            score: stats(scores),
            level: level(averageScore: averageScore),
            segments: segments
        )
    }

    // MARK: - 纯函数（harness 可测）

    /// 运动分：相邻帧逐像素差均值 → 0–1（motionCeiling 为大运动上限）。
    static func motion(first: [Float], second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var sum = 0.0
        for i in first.indices {
            sum += Double(abs(first[i] - second[i]))
        }
        let mean = sum / Double(first.count)
        return min(mean / motionCeiling, 1.0)
    }

    /// 细节分：逐像素与右 / 下邻居差的绝对值均值 → 0–1（detailCeiling 为高细节上限）。
    static func detail(gray: [Float], width: Int, height: Int) -> Double {
        guard width >= 2, height >= 2, gray.count >= width * height else { return 0 }
        var sum = 0.0
        var count = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let value = gray[row + x]
                if x + 1 < width { sum += Double(abs(value - gray[row + x + 1])) }
                if y + 1 < height { sum += Double(abs(value - gray[row + x + width])) }
                count += (x + 1 < width ? 1 : 0) + (y + 1 < height ? 1 : 0)
            }
        }
        guard count > 0 else { return 0 }
        return min(sum / Double(count) / detailCeiling, 1.0)
    }

    /// 综合分：运动缺失时按细节权重重归一（÷ detailWeight），保证值域仍为 0–1。
    static func score(motion: Double, detail: Double) -> Double {
        min(motionWeight * motion + detailWeight * detail, 1.0)
    }

    /// 分布统计：min / avg / max / p90（线性插值分位）。
    static func stats(_ values: [Double]) -> Stats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let average = values.reduce(0, +) / Double(values.count)
        return Stats(
            min: sorted[0],
            average: average,
            max: sorted[sorted.count - 1],
            p90: percentile(sorted, 0.9)
        )
    }

    /// 线性插值分位数（有序数组；n=1 直接返回）。
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// 分级映射。
    static func level(averageScore: Double) -> Level {
        if averageScore < lowThreshold { return .low }
        if averageScore < highThreshold { return .medium }
        return .high
    }
}
