import Accelerate
import Foundation

// MARK: - 视频感知哈希指纹与跨文件去重（设计文档 §7.14，灵感 10）
// 每片均匀抽 5 帧 → 32×32 灰度 → vDSP DCT-II → 8×8 低频（去 DC）中位阈值 → 63-bit pHash。
// 仅内存现算（不建库），跨文件两两比对后并查集分组。

enum VideoFingerprint {
    struct ClipFingerprint: Sendable, Equatable {
        var fileName: String
        var frameHashes: [UInt64]
    }

    struct DuplicateGroup: Sendable, Equatable {
        /// 指纹数组的索引（已排序）。
        var indices: [Int]
    }

    /// 每片抽帧数（避开头尾 5%，复用抽段函数取中点）。
    static let framesPerClip = 5

    /// 计算视频指纹。
    static func fingerprint(url: URL, fileName: String, sourceDuration: Double) async throws -> ClipFingerprint {
        // 可抽段的最短时长（§7.8 抽段下限 0.5s）
        guard sourceDuration > 0.5 else {
            return ClipFingerprint(fileName: fileName, frameHashes: [])
        }
        let segments = BitrateProbeService.segments(forDuration: sourceDuration, count: framesPerClip, length: 2)
        let times = segments.map { $0.start + $0.length / 2 }
        let frames = try await ProbeFrameGrabber.grabGrayFrames(url: url, at: times, sourceDuration: sourceDuration)
        let hashes = frames.map { pHash(gray: $0.luma, width: $0.width, height: $0.height) }
        return ClipFingerprint(fileName: fileName, frameHashes: hashes)
    }

    // MARK: - 纯函数（harness 可测）

    /// 经典 pHash：平均池化 32×32 → 行列 DCT-II → 8×8 低频（去 DC）中位阈值 → 63-bit。
    static func pHash(gray: [Float], width: Int, height: Int) -> UInt64 {
        let size = 32
        let small = downsample(gray: gray, width: width, height: height, to: size)
        guard let dct = try? vDSP.DCT(count: size, transformType: .II) else { return 0 }

        // 行 DCT
        var rows = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let line = Array(small[row * size..<(row + 1) * size])
            let output = dct.transform(line)
            for col in 0..<size {
                rows[row * size + col] = output[col]
            }
        }
        // 列 DCT
        var freq = [Float](repeating: 0, count: size * size)
        var column = [Float](repeating: 0, count: size)
        for col in 0..<size {
            for r in 0..<size {
                column[r] = rows[r * size + col]
            }
            let output = dct.transform(column)
            for r in 0..<size {
                freq[r * size + col] = output[r]
            }
        }

        // 8×8 低频（去 DC）→ 中位阈值
        var low: [Float] = []
        for r in 0..<8 {
            for c in 0..<8 where !(r == 0 && c == 0) {
                low.append(freq[r * size + c])
            }
        }
        guard low.count == 63 else { return 0 }
        let sorted = low.sorted()
        let median = (sorted[31] + sorted[32]) / 2

        var hash: UInt64 = 0
        for (index, value) in low.enumerated() where value > median {
            hash |= 1 << UInt64(index)
        }
        return hash
    }

    /// 汉明距离。
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        UInt64(a ^ b).nonzeroBitCount
    }

    /// 两片是否近重复：A 的每帧在 B 中存在距离 ≤ 阈值的帧，占比 ≥ matchRatio。
    static func isNearDuplicate(
        _ a: ClipFingerprint,
        _ b: ClipFingerprint,
        distanceThreshold: Int = 10,
        matchRatio: Double = 0.7
    ) -> Bool {
        guard !a.frameHashes.isEmpty, !b.frameHashes.isEmpty else { return false }
        let matched = a.frameHashes.filter { hash in
            b.frameHashes.contains { hammingDistance(hash, $0) <= distanceThreshold }
        }.count
        return Double(matched) / Double(a.frameHashes.count) >= matchRatio
    }

    /// 跨文件比对：并查集把近重复的文件归组（含链式 A≈B≈C）。
    static func duplicateGroups(
        fingerprints: [ClipFingerprint],
        distanceThreshold: Int = 10,
        matchRatio: Double = 0.7
    ) -> [DuplicateGroup] {
        let count = fingerprints.count
        guard count >= 2 else { return [] }
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var current = x
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        for i in 0..<count {
            for j in (i + 1)..<count
            where isNearDuplicate(fingerprints[i], fingerprints[j], distanceThreshold: distanceThreshold, matchRatio: matchRatio) {
                let rootI = find(i)
                let rootJ = find(j)
                if rootI != rootJ {
                    parent[max(rootI, rootJ)] = min(rootI, rootJ)
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in 0..<count {
            groups[find(index), default: []].append(index)
        }
        return groups.values
            .filter { $0.count >= 2 }
            .map { DuplicateGroup(indices: $0.sorted()) }
            .sorted { $0.indices.first ?? 0 < $1.indices.first ?? 0 }
    }

    // MARK: - 内部

    /// 平均池化下采样到边长 size 的方形（长边对齐再居中裁剪，纵横比差异在池化粒度内可接受）。
    static func downsample(gray: [Float], width: Int, height: Int, to size: Int) -> [Float] {
        guard width > 0, height > 0, gray.count >= width * height else {
            return [Float](repeating: 0, count: size * size)
        }
        let cellW = Double(width) / Double(size)
        let cellH = Double(height) / Double(size)
        var result = [Float](repeating: 0, count: size * size)
        for ty in 0..<size {
            for tx in 0..<size {
                let x0 = Int(Double(tx) * cellW)
                let x1 = min(width, Int(Double(tx + 1) * cellW))
                let y0 = Int(Double(ty) * cellH)
                let y1 = min(height, Int(Double(ty + 1) * cellH))
                guard x1 > x0, y1 > y0 else {
                    result[ty * size + tx] = 0
                    continue
                }
                var sum = 0.0
                for y in y0..<y1 {
                    let rowStart = y * width
                    for x in x0..<x1 {
                        sum += Double(gray[rowStart + x])
                    }
                }
                result[ty * size + tx] = Float(sum / Double((x1 - x0) * (y1 - y0)))
            }
        }
        return result
    }
}
