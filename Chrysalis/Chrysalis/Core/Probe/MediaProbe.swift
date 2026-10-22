@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

// MARK: - 视频体检报告（设计文档 §7.10，灵感 5）
// 只读排障工具：任意 AVFoundation 可读格式；不修改源文件、不落盘、无网络。

/// 转码结论三色（设计文档 §7.10）：绿可转 / 黄可读但受限 / 红不可转。
enum ProbeVerdict: String, Codable, Equatable, Sendable {
    case ready
    case restricted
    case blocked

    var displayName: String {
        switch self {
        case .ready: "可以转码"
        case .restricted: "可读，但转码受限"
        case .blocked: "无法转码"
        }
    }
}

/// 深度探测统计（抽样解码产物）。
struct SampleStatistics: Codable, Equatable, Sendable {
    /// min / 平均 / max 分布。
    struct Distribution: Codable, Equatable, Sendable {
        var min: Int
        var average: Int
        var max: Int

        static func make(_ values: [Int]) -> Distribution? {
            guard let first = values.min(), let last = values.max(), !values.isEmpty else { return nil }
            let average = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
            return Distribution(min: first, average: average, max: last)
        }
    }

    var sampledSegments: Int
    var sampledSeconds: Double
    /// 段级总码率分布（视频，bps）。
    var segmentBitrates: Distribution?
    /// 关键帧间隔（GOP 帧数）分布。
    var gopSizes: Distribution?
    /// 疑似可变帧率（帧间隔 max ÷ avg > 1.5）。
    var isVFR: Bool
    var frameIntervalRatio: Double?
    var averageFrameInterval: Double?
}

/// 一次体检的完整报告（快速 + 可选深度；可导出 Markdown / JSON）。
struct MediaProbeReport: Codable, Equatable, Sendable {
    var verdict: ProbeVerdict
    var verdictMessage: String

    var fileName: String
    var containerLabel: String
    var fileSizeBytes: Int64
    var durationSeconds: Double
    var createdAt: Date?
    var modifiedAt: Date?

    var video: VideoStreamInfo?
    /// 色彩标签（BT.601 / BT.709 / BT.2020；HDR 附 PQ / HLG）。
    var colorLabel: String?
    var audioTracks: [AudioStreamInfo]
    var isPlayable: Bool
    var isProtected: Bool
    /// moov 前置（快启动）；仅 MP4 / MOV / M4V 检测，其他容器 nil。
    var isMoovAtFront: Bool?
    /// 容器元数据（有值才收录）。
    var metadata: [String: String]

    var deep: SampleStatistics?
    var deepError: String?
    var deepScannedAt: Date?
    /// 假 4K 检测结论（§7.14；深度探测时顺带执行）。
    var upscale: UpscaleDetector.Verdict?
    /// 内容复杂度热力图（§7.16；深度探测时顺带执行，失败为 nil）。
    var complexity: ComplexityAnalyzer.Report? = nil
    var quickScannedAt: Date
}

// MARK: - 服务

enum MediaProbeService {
    /// 快速体检（秒级）：头信息 + 解码健康度 + 转码结论 + moov 前置。
    ///
    /// 宽松读取：不受转码支持矩阵限制——读得到多少就报告多少（设计文档 §7.10）。
    static func quickReport(url: URL) async -> MediaProbeReport {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        let ext = url.pathExtension.lowercased()
        let containerLabel = MediaInspector.containerLabel(forExtension: ext)

        var report = MediaProbeReport(
            verdict: .blocked,
            verdictMessage: "",
            fileName: url.lastPathComponent,
            containerLabel: containerLabel,
            fileSizeBytes: 0,
            durationSeconds: 0,
            createdAt: nil,
            modifiedAt: nil,
            video: nil,
            colorLabel: nil,
            audioTracks: [],
            isPlayable: false,
            isProtected: false,
            isMoovAtFront: isMoovAtFront(fileURL: url),
            metadata: [:],
            deep: nil,
            deepError: nil,
            deepScannedAt: nil,
            upscale: nil,
            complexity: nil,
            quickScannedAt: Date()
        )

        guard exists else {
            report.verdictMessage = "文件不存在或路径不可访问。"
            return report
        }
        report.fileSizeBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        report.createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        report.modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let protected = (try? await asset.load(.hasProtectedContent)) ?? false
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let tracks = (try? await asset.load(.tracks)) ?? []

        report.isPlayable = playable
        report.isProtected = protected
        report.durationSeconds = duration.isFinite && duration > 0 ? duration : 0

        guard !tracks.isEmpty else {
            report.verdictMessage = "AVFoundation 无法读取该文件：可能已损坏，或容器格式不受支持。"
            return report
        }

        let videoTrack = tracks.first(where: { $0.mediaType == .video })
        let audioTracks = tracks.filter { $0.mediaType == .audio }

        // 视频轨（尽力而为）
        var videoInfo: VideoStreamInfo?
        var colorLabel: String?
        var hardwareDecode = false
        var isHDR = false
        var hdrLabel: String?
        if let track = videoTrack {
            let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let nominalFPS = Double((try? await track.load(.nominalFrameRate)) ?? 0)
            let estimatedRate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
            let format = (try? await track.load(.formatDescriptions))?.first
            let fourCCValue = format.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let fourCC = VideoToolboxCapabilities.fourCCString(fourCCValue)
            hardwareDecode = fourCCValue != 0 ? VTIsHardwareDecodeSupported(fourCCValue) : false
            (isHDR, hdrLabel) = MediaInspector.detectHDR(format: format)
            colorLabel = Self.colorLabel(for: format, isHDR: isHDR, hdrLabel: hdrLabel)

            let oriented = VideoGeometry.orientedSize(naturalSize: naturalSize, preferredTransform: transform)
            videoInfo = VideoStreamInfo(
                codecFourCC: fourCC,
                codecName: MediaInspector.videoCodecDisplayName(fourCC: fourCC),
                displayWidth: Int(oriented.width.rounded()),
                displayHeight: Int(oriented.height.rounded()),
                frameRate: nominalFPS > 0 ? nominalFPS : 0,
                bitrate: estimatedRate > 0 ? Int(estimatedRate) : nil,
                hardwareDecodeSupported: hardwareDecode
            )
        }
        report.video = videoInfo
        report.colorLabel = colorLabel

        // 音轨（多轨全列）
        for track in audioTracks {
            let format = (try? await track.load(.formatDescriptions))?.first
            let rate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
            var channels = 0
            var sampleRate: Double = 0
            if let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                channels = Int(asbd.pointee.mChannelsPerFrame)
                sampleRate = asbd.pointee.mSampleRate
            }
            let formatID = format.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            report.audioTracks.append(
                AudioStreamInfo(
                    codecFourCC: formatID != 0 ? VideoToolboxCapabilities.fourCCString(formatID) : "",
                    codecName: MediaInspector.audioCodecDisplayName(formatID: formatID),
                    channelCount: channels,
                    sampleRate: sampleRate,
                    bitrate: rate > 0 ? Int(rate) : nil
                )
            )
        }

        // 容器元数据完整性（有值才收录；不写日志）
        let items = (try? await asset.load(.metadata)) ?? []
        for identifier in [
            AVMetadataIdentifier.commonIdentifierTitle,
            AVMetadataIdentifier.commonIdentifierArtist,
            AVMetadataIdentifier.commonIdentifierCreationDate,
            AVMetadataIdentifier.commonIdentifierDescription,
        ] {
            if let item = items.first(where: { $0.identifier == identifier }),
               let value = try? await item.load(.stringValue), !value.isEmpty {
                report.metadata[metadataKey(identifier)] = value
            }
        }

        let verdict = Self.verdict(
            ext: ext,
            isReadable: true,
            isPlayable: playable,
            isProtected: protected,
            hasVideo: videoTrack != nil,
            isHDR: isHDR,
            hardwareDecode: hardwareDecode
        )
        report.verdict = verdict.kind
        report.verdictMessage = verdict.message
        return report
    }

    /// 深度探测（设计文档 §7.10）：均匀 3 段各 2 秒抽段读原始压缩流（只解封装不解码），
    /// 统计段码率分布 / 关键帧间隔 / VFR；结果合并进报告。
    static func deepScan(url: URL, report: MediaProbeReport) async -> SampleStatistics? {
        guard report.durationSeconds > 4 else { return nil }
        let segments = BitrateProbeService.segments(forDuration: report.durationSeconds, count: 3, length: 2)
        guard !segments.isEmpty else { return nil }

        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let videoTrack = tracks.first(where: { $0.mediaType == .video })
        else { return nil }

        var segmentBitrates: [Int] = []
        var allIntervals: [Double] = []
        var allGOPSizes: [Int] = []
        var totalSyncFrames = 0
        var totalFrames = 0
        var sampledSeconds = 0.0

        for segment in segments {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            guard let output = try? AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil) else { return nil }
            // 只解封装：原始压缩样本自带 PTS / sync 标记 / 压缩字节数。
            // reader.timeRange 按解码序裁剪会在段边界丢帧（B 帧 PTS 超前 DTS），
            // 因此读「段区间 ± 1 秒」的缓冲窗口，循环内按 PTS 精确过滤段内样本。
            let windowStart = max(segment.start - 1.0, 0)
            let windowEnd = min(segment.start + segment.length + 1.0, report.durationSeconds)
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: windowStart, preferredTimescale: 600),
                duration: CMTime(seconds: windowEnd - windowStart, preferredTimescale: 600)
            )
            guard reader.startReading() else { return nil }

            let rangeStart = segment.start
            let rangeEnd = segment.start + segment.length

            var bytes: Int64 = 0
            var samples: [(pts: Double, isSync: Bool)] = []

            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard pts.isFinite else { continue }
                let sync = isSyncSample(sample)
                bytes += Int64(CMSampleBufferGetTotalSampleSize(sample))
                samples.append((pts, sync))
            }
            let readError = reader.status == .failed
            reader.cancelReading()

            guard !readError else { return nil }
            // 段窗口内的样本（PTS 精确过滤；窗口含 ±1 秒缓冲，吸收解码序裁剪丢帧）
            let inRange = samples
                .filter { $0.pts >= rangeStart - 0.0001 && $0.pts < rangeEnd - 0.0001 }
                .sorted { $0.pts < $1.pts }
            guard !inRange.isEmpty,
                  let firstPTS = inRange.first?.pts, let lastPTS = inRange.last?.pts else { return nil }
            let seconds = max(lastPTS - firstPTS, 0.1)
            if bytes > 0 {
                let windowSeconds = max(
                    (samples.map(\.pts).max() ?? 0) - (samples.map(\.pts).min() ?? 0), 0.1
                )
                // 字节按窗口统计，按段/窗口时长占比折算回段码率
                segmentBitrates.append(Int((Double(bytes) * 8) / windowSeconds * (seconds / windowSeconds)))
            }
            // 帧间隔按显示序计算：原始流按解码序输出（B 帧 PTS 交错），先排序再求差
            let sorted = inRange.map(\.pts)
            for (i, pts) in sorted.enumerated() where i > 0 {
                let interval = pts - sorted[i - 1]
                if interval > 0.0001 {
                    allIntervals.append(interval)
                }
            }
            // GOP：段内 IDR 起点到下一 IDR 的帧数（下一 IDR 可在段外，间隔仍完整）；
            // 窗口样本按显示序排列后取相邻 sync 对，起点 IDR 必须落在段窗口内。
            let windowSorted = samples.sorted { $0.pts < $1.pts }
            let syncPositions = windowSorted.indices.filter { windowSorted[$0].isSync }
            for (i, position) in syncPositions.enumerated() where i + 1 < syncPositions.count {
                let startPTS = windowSorted[position].pts
                if startPTS >= rangeStart - 0.0001, startPTS < rangeEnd - 0.0001 {
                    allGOPSizes.append(syncPositions[i + 1] - position)
                }
            }
            totalSyncFrames += syncPositions.count
            totalFrames += inRange.count
            sampledSeconds += seconds
        }

        guard totalFrames > 0, sampledSeconds > 0 else { return nil }
        let vfr = vfrJudgement(frameIntervals: allIntervals)
        return SampleStatistics(
            sampledSegments: segments.count,
            sampledSeconds: sampledSeconds,
            segmentBitrates: SampleStatistics.Distribution.make(segmentBitrates),
            gopSizes: gopStatistics(gopSizes: allGOPSizes, syncFrameCount: totalSyncFrames, totalFrames: totalFrames),
            isVFR: vfr.isVFR,
            frameIntervalRatio: vfr.ratio,
            averageFrameInterval: vfr.averageInterval
        )
    }

    // MARK: - 纯函数（harness 可测）

    /// 转码结论映射（设计文档 §7.10）：红黄绿 + 人话；复用预检口径。
    static func verdict(
        ext: String,
        isReadable: Bool,
        isPlayable: Bool,
        isProtected: Bool,
        hasVideo: Bool,
        isHDR: Bool,
        hardwareDecode: Bool
    ) -> (kind: ProbeVerdict, message: String) {
        guard isReadable else {
            return (.blocked, "AVFoundation 无法读取该文件：可能已损坏，或容器格式不受支持。")
        }
        guard isPlayable else {
            return (.blocked, "该文件无法解码播放，可能已损坏或格式不完整。")
        }
        guard !isProtected else {
            return (.blocked, "包含受保护内容（DRM），无法转码。")
        }
        guard hasVideo else {
            return (.blocked, "没有视频轨，无法转码。")
        }
        guard MediaInspector.supportedExtensions.contains(ext) else {
            return (
                .restricted,
                "输入容器 .\(ext) 不在 v1 支持矩阵（MP4 / MOV / M4V）：规格仅供参考，蝉蜕 v1 不转码该容器。"
            )
        }
        if isHDR {
            return (.restricted, "HDR 视频 v1 暂不支持转码（避免输出偏色）。")
        }
        if !hardwareDecode {
            return (.restricted, "源视频编码没有硬件解码器，v1 不做软件回退。")
        }
        return (.ready, "在支持矩阵内，可以加入转码队列。")
    }

    /// moov 前置检测（快启动）：top-level atom walk 判定 moov 与 mdat 出现顺序；
    /// 仅 MP4 / MOV / M4V 返回判定值，其他容器返回 nil。
    static func isMoovAtFront(fileURL: URL) -> Bool? {
        let containerExtensions: Set<String> = ["mp4", "mov", "m4v"]
        guard containerExtensions.contains(fileURL.pathExtension.lowercased()) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard fileSize > 8 else { return nil }

        var offset: UInt64 = 0
        // 最多遍历 32 个 top-level atom（防损坏文件无限循环）
        for _ in 0..<32 {
            guard offset + 8 <= fileSize else { break }
            handle.seek(toFileOffset: offset)
            let header = handle.readData(ofLength: 8)
            guard header.count == 8 else { break }
            let size32 = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: header.suffix(4), encoding: .ascii) ?? ""

            var size: UInt64
            switch size32 {
            case 0: size = fileSize - offset  // 到文件尾
            case 1:
                let large = handle.readData(ofLength: 8)
                guard large.count == 8 else { return nil }
                size = large.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            default: size = size32
            }
            guard size >= 8 else { break }

            if type == "moov" { return true }
            if type == "mdat" { return false }
            offset += size
        }
        return nil
    }

    /// VFR 判定：帧间隔 max ÷ avg > 1.5 且样本充足（设计文档 §7.10，恒定帧率不误报）。
    static func vfrJudgement(frameIntervals: [Double]) -> (isVFR: Bool, ratio: Double?, averageInterval: Double?) {
        guard frameIntervals.count >= 8 else { return (false, nil, nil) }
        let average = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
        guard average > 0 else { return (false, nil, nil) }
        let maximum = frameIntervals.max() ?? 0
        let ratio = maximum / average
        return (ratio > 1.5, ratio, average)
    }

    /// GOP 分布：段内相邻 sync 帧距离（完整 GOP）；sync 稀疏（GOP 全部跨段）时回退平均口径。
    static func gopStatistics(gopSizes: [Int], syncFrameCount: Int, totalFrames: Int) -> SampleStatistics.Distribution? {
        if !gopSizes.isEmpty, let distribution = SampleStatistics.Distribution.make(gopSizes) {
            return distribution
        }
        guard syncFrameCount >= 1, totalFrames > 0 else { return nil }
        let average = Int((Double(totalFrames) / Double(syncFrameCount)).rounded())
        return SampleStatistics.Distribution(min: average, average: average, max: average)
    }

    /// 色彩标签：矩阵 + HDR 传输函数。
    static func colorLabel(for format: CMFormatDescription?, isHDR: Bool, hdrLabel: String?) -> String? {
        var parts: [String] = []
        if let format,
           let matrix = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix
           ) as? String {
            let label: String?
            if matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String {
                label = "BT.601"
            } else if matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String {
                label = "BT.709"
            } else if matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String {
                label = "BT.2020"
            } else {
                label = nil
            }
            if let label { parts.append(label) }
        }
        if isHDR, let hdrLabel {
            parts.append(hdrLabel)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 私有

    /// 原始流样本是否为关键帧（kCMSampleAttachmentKey_NotSync == false）。
    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let first = CFArrayGetValueAtIndex(array, 0)
        else { return true }
        let dict = unsafeBitCast(first, to: CFDictionary.self) as NSDictionary
        return (dict[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? true) == false
    }

    private static func metadataKey(_ identifier: AVMetadataIdentifier) -> String {
        switch identifier {
        case .commonIdentifierTitle: "标题"
        case .commonIdentifierArtist: "作者"
        case .commonIdentifierCreationDate: "创建时间"
        case .commonIdentifierDescription: "描述"
        default: identifier.rawValue
        }
    }
}
