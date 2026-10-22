import Foundation

/// 体检报告 Markdown 导出（设计文档 §7.10）：纯函数，harness 可测。
enum ProbeReportMarkdown {
    static func generate(_ report: MediaProbeReport) -> String {
        var lines: [String] = []
        lines.append("# 视频体检报告：\(report.fileName)")
        lines.append("")

        // 转码结论（置顶）
        let icon: String
        switch report.verdict {
        case .ready: icon = "🟢"
        case .restricted: icon = "🟡"
        case .blocked: icon = "🔴"
        }
        lines.append("## 转码结论")
        lines.append("")
        lines.append("**\(icon) \(report.verdict.displayName)** —— \(report.verdictMessage)")
        lines.append("")

        // 容器与文件
        lines.append("## 容器与文件")
        lines.append("")
        lines.append("- 容器：\(report.containerLabel)")
        lines.append("- 大小：\(Fmt.bytes(report.fileSizeBytes))")
        lines.append("- 时长：\(Fmt.duration(seconds: report.durationSeconds))")
        if let createdAt = report.createdAt {
            lines.append("- 创建时间：\(Fmt.dateTime(createdAt))")
        }
        if let modifiedAt = report.modifiedAt {
            lines.append("- 修改时间：\(Fmt.dateTime(modifiedAt))")
        }
        if let moov = report.isMoovAtFront {
            lines.append("- moov 前置（快启动）：\(moov ? "是" : "否（网络播放需先下载全片或重新封装）")")
        }
        lines.append("")

        // 视频轨
        lines.append("## 视频轨")
        lines.append("")
        if let video = report.video {
            lines.append("- 编码：\(video.codecName)（\(video.codecFourCC)）")
            lines.append("- 分辨率：\(video.displayWidth)×\(video.displayHeight)")
            if video.frameRate > 0 {
                lines.append("- 帧率（标称）：\(String(format: "%.2f", video.frameRate)) fps")
            }
            if let bitrate = video.bitrate, bitrate > 0 {
                lines.append("- 码率（标称）：\(Fmt.mbps(bitrate))")
            }
            if let color = report.colorLabel {
                lines.append("- 色彩：\(color)")
            }
        } else {
            lines.append("（无视频轨或未读到）")
        }
        lines.append("")

        // 音轨
        lines.append("## 音轨（\(report.audioTracks.count) 条）")
        lines.append("")
        if report.audioTracks.isEmpty {
            lines.append("（无音轨）")
        } else {
            for (index, audio) in report.audioTracks.enumerated() {
                var parts = ["#\(index + 1) \(audio.codecName)"]
                if audio.sampleRate > 0 {
                    parts.append("\(Int(audio.sampleRate)) Hz")
                }
                parts.append("\(audio.channelCount) 声道")
                if let bitrate = audio.bitrate, bitrate > 0 {
                    parts.append(Fmt.mbps(bitrate))
                }
                lines.append("- \(parts.joined(separator: " · "))")
            }
        }
        lines.append("")

        // 解码健康度
        lines.append("## 解码健康度")
        lines.append("")
        lines.append("- 可播放：\(report.isPlayable ? "是" : "否")")
        lines.append("- 受保护内容（DRM）：\(report.isProtected ? "是" : "否")")
        if let video = report.video {
            lines.append("- 硬件解码：\(video.hardwareDecodeSupported ? "可用" : "不可用（v1 不做软件回退）")")
        }
        lines.append("")

        // 元数据
        lines.append("## 元数据完整性")
        lines.append("")
        if report.metadata.isEmpty {
            lines.append("（无容器元数据）")
        } else {
            let keys = report.metadata.keys.sorted()
            for key in keys {
                lines.append("- \(key)：\(report.metadata[key] ?? "")")
            }
        }
        lines.append("")

        // 深度探测
        lines.append("## 深度探测")
        lines.append("")
        if let deep = report.deep {
            lines.append("- 采样：\(deep.sampledSegments) 段 / \(String(format: "%.1f", deep.sampledSeconds)) 秒")
            if let bitrate = deep.segmentBitrates {
                lines.append(
                    "- 段码率分布：\(Fmt.mbps(bitrate.min)) ~ \(Fmt.mbps(bitrate.average))（峰 \(Fmt.mbps(bitrate.max))）"
                )
            }
            if let gop = deep.gopSizes {
                lines.append("- 关键帧间隔（GOP）：\(gop.min) ~ \(gop.average) 帧（最大 \(gop.max)）")
            }
            if let ratio = deep.frameIntervalRatio {
                lines.append(
                    "- 帧间隔均匀性：max/avg = \(String(format: "%.2f", ratio)) → \(deep.isVFR ? "疑似可变帧率（VFR）" : "恒定帧率")"
                )
            }
        } else if let error = report.deepError {
            lines.append("深度探测失败：\(error)")
        } else {
            lines.append("（未执行；点「深度探测」抽样解码获取码率分布 / 关键帧间隔 / VFR 判定）")
        }
        lines.append("")
        lines.append("---")
        lines.append("由蝉蜕（Chrysalis）生成 · \(Fmt.dateTime(report.quickScannedAt))")
        return lines.joined(separator: "\n")
    }
}
