import SwiftUI
import UniformTypeIdentifiers

/// 视频体检页（设计文档 §7.10）：拖入 / 选择文件 → 双档报告（快速 + 深度探测）。
struct ProbeScreen: View {
    @Environment(ProbeStore.self) private var store
    @Environment(QueueStore.self) private var queueStore
    @State private var isImporterPresented = false
    @State private var isDedupImporterPresented = false
    @State private var isDedupSheetPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let report = store.report {
                reportView(report)
            } else {
                emptyState
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $isDedupSheetPresented) {
            DedupSheet()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .mpeg4Movie, .video]
        ) { result in
            if case .success(let url) = result {
                Task { await store.probe(url: url) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await store.probe(url: url) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .fileImporter(
            isPresented: $isDedupImporterPresented,
            allowedContentTypes: [.movie, .mpeg4Movie, .video],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                isDedupSheetPresented = true
                store.runDedup(urls: urls)
            case .failure(let error):
                print("选择去重文件失败：\(error.localizedDescription)")
            default:
                break
            }
        }
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("视频体检")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("拖入任意视频文件（不限于 MP4 / MOV / M4V），\n体检结论告诉你它能不能转、值不值得转、有什么坑。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            TextButton(title: "选择文件…") {
                isImporterPresented = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(16)
            }
        }
    }

    // MARK: 报告

    private func reportView(_ report: MediaProbeReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                verdictBanner(report)
                toolRow(report)
                containerSection(report)
                videoSection(report)
                audioSection(report)
                healthSection(report)
                metadataSection(report)
                deepSection(report)
            }
            .padding(Theme.Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if let message = store.message {
                Text(message)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceElevated, in: Capsule())
                    .padding(.bottom, 12)
                    .onTapGesture { store.clearMessage() }
            }
        }
    }

    private var verdictColor: Color {
        switch store.report?.verdict {
        case .ready: Theme.success
        case .restricted: Theme.warning
        case .blocked, nil: Theme.error
        }
    }

    private func verdictBanner(_ report: MediaProbeReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(verdictColor)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.verdict.displayName)
                    .font(Theme.TextStyle.section)
                    .foregroundStyle(Theme.textPrimary)
                Text(report.verdictMessage)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            Spacer()
            TextButton(title: "重新体检", isEnabled: !store.isScanning) {
                if let url = store.currentURL {
                    Task { await store.probe(url: url) }
                }
            }
        }
        .padding(Theme.Spacing.s3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toolRow(_ report: MediaProbeReport) -> some View {
        HStack(spacing: Theme.Spacing.s2) {
            TextButton(title: "加入转码队列", isEnabled: store.canEnqueue) {
                store.enqueueToQueue(queueStore)
            }
            TextButton(title: "跨文件去重…") {
                isDedupImporterPresented = true
            }
            TextButton(title: "导出 Markdown") {
                _ = store.exportMarkdown()
            }
            TextButton(title: "导出 JSON") {
                _ = store.exportJSON()
            }
            Spacer()
        }
    }

    // MARK: 分区

    private func containerSection(_ report: MediaProbeReport) -> some View {
        InspectorSection(title: "容器与文件") {
            InspectorRow(label: "文件", value: report.fileName)
            InspectorRow(label: "容器", value: report.containerLabel)
            InspectorRow(label: "大小", value: Fmt.bytes(report.fileSizeBytes))
            InspectorRow(label: "时长", value: report.durationSeconds > 0 ? Fmt.duration(seconds: report.durationSeconds) : "—")
            if let createdAt = report.createdAt {
                InspectorRow(label: "创建时间", value: Fmt.dateTime(createdAt))
            }
            if let modifiedAt = report.modifiedAt {
                InspectorRow(label: "修改时间", value: Fmt.dateTime(modifiedAt))
            }
            if let moov = report.isMoovAtFront {
                InspectorRow(label: "moov 前置", value: moov ? "是（快启动）" : "否（网络播放前需下载全片）")
            }
        }
    }

    private func videoSection(_ report: MediaProbeReport) -> some View {
        InspectorSection(title: "视频轨") {
            if let video = report.video {
                InspectorRow(label: "编码", value: "\(video.codecName)（\(video.codecFourCC)）")
                InspectorRow(label: "分辨率", value: "\(video.displayWidth)×\(video.displayHeight)")
                if video.frameRate > 0 {
                    InspectorRow(label: "帧率（标称）", value: String(format: "%.2f fps", video.frameRate))
                }
                if let bitrate = video.bitrate, bitrate > 0 {
                    InspectorRow(label: "码率（标称）", value: Fmt.mbps(bitrate))
                }
                if let color = report.colorLabel {
                    InspectorRow(label: "色彩", value: color)
                }
            } else {
                Text("无视频轨或未读到")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func audioSection(_ report: MediaProbeReport) -> some View {
        InspectorSection(title: "音轨（\(report.audioTracks.count) 条）") {
            if report.audioTracks.isEmpty {
                Text("无音轨")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(report.audioTracks.enumerated()), id: \.offset) { index, audio in
                    InspectorRow(label: "#\(index + 1)", value: Self.audioSummary(audio))
                }
            }
        }
    }

    /// 音轨规格行：`AAC · 48000 Hz · 2 声道 · 192 kbps`。
    private static func audioSummary(_ audio: AudioStreamInfo) -> String {
        var parts = ["\(audio.codecName)"]
        if audio.sampleRate > 0 { parts.append("\(Int(audio.sampleRate)) Hz") }
        parts.append("\(audio.channelCount) 声道")
        if let bitrate = audio.bitrate, bitrate > 0 { parts.append(Fmt.mbps(bitrate)) }
        return parts.joined(separator: " · ")
    }

    private func healthSection(_ report: MediaProbeReport) -> some View {
        InspectorSection(title: "解码健康度") {
            InspectorRow(label: "可播放", value: report.isPlayable ? "是" : "否")
            InspectorRow(label: "受保护内容（DRM）", value: report.isProtected ? "是" : "否")
            if let video = report.video {
                InspectorRow(label: "硬件解码", value: video.hardwareDecodeSupported ? "可用" : "不可用（v1 不做软件回退）")
            }
        }
    }

    private func metadataSection(_ report: MediaProbeReport) -> some View {
        InspectorSection(title: "元数据完整性") {
            if report.metadata.isEmpty {
                Text("无容器元数据")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(report.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    InspectorRow(label: key, value: value)
                }
            }
        }
    }

    private func deepSection(_ report: MediaProbeReport) -> some View {
        InspectorSection(title: "深度探测") {
            if let deep = report.deep {
                InspectorRow(
                    label: "采样",
                    value: "\(deep.sampledSegments) 段 / \(String(format: "%.1f", deep.sampledSeconds)) 秒"
                )
                if let bitrate = deep.segmentBitrates {
                    InspectorRow(
                        label: "段码率分布",
                        value: "\(Fmt.mbps(bitrate.min)) ~ \(Fmt.mbps(bitrate.average))（峰 \(Fmt.mbps(bitrate.max))）"
                    )
                }
                if let gop = deep.gopSizes {
                    InspectorRow(label: "关键帧间隔", value: "\(gop.min) ~ \(gop.average) 帧（最大 \(gop.max)）")
                }
                if let ratio = deep.frameIntervalRatio {
                    InspectorRow(
                        label: "帧间隔均匀性",
                        value: "max/avg = \(String(format: "%.2f", ratio)) → \(deep.isVFR ? "疑似 VFR" : "恒定帧率")"
                    )
                }
                if let upscale = store.report?.upscale, upscale.sampledFrames > 0 {
                    if upscale.suspected {
                        InspectorRow(
                            label: "假 4K 检测",
                            value: "疑似放大（置信度 \(Int(upscale.confidence * 100))%）\(upscale.suggestedLevel.map { " · 建议 \($0)" } ?? "")"
                        )
                    } else {
                        InspectorRow(
                            label: "假 4K 检测",
                            value: "未检出放大迹象（置信度 \(Int(upscale.confidence * 100))%）"
                        )
                    }
                }
                if store.isDeepScanning {
                    Text("深度探测中…")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    TextButton(title: "重新深度探测") {
                        Task { await store.runDeepScan() }
                    }
                }
            } else if let error = report.deepError {
                Text("深度探测失败：\(error)")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
                TextButton(title: "重试深度探测", isEnabled: !store.isDeepScanning) {
                    Task { await store.runDeepScan() }
                }
            } else {
                Text("尚未探测：深度探测抽样解码 3 段各 2 秒，给出码率分布 / 关键帧间隔 / VFR 判定。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                TextButton(title: "深度探测", isEnabled: !store.isDeepScanning) {
                    Task { await store.runDeepScan() }
                }
            }
        }
    }
}

/// 跨文件去重面板（设计文档 §7.14）：指纹计算进度 + 近重复分组结果；仅内存不落盘。
struct DedupSheet: View {
    @Environment(ProbeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
            Text("跨文件去重")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("感知哈希（pHash）比对同源内容：不同编码 / 尺寸的同一段素材会被归为一组；指纹仅内存现算，不落盘。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)

            if store.dedup.isRunning {
                VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
                    ProgressView(value: max(store.dedup.progress, 0.02))
                    Text("计算指纹中…（每片抽 5 帧，约几秒）")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let error = store.dedup.errorText {
                Text(error)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
            }

            if !store.dedup.groups.isEmpty {
                ForEach(Array(store.dedup.groups.enumerated()), id: \.offset) { index, group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
                        Text("第 \(index + 1) 组（\(group.indices.count) 个近重复）")
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.accent)
                        ForEach(group.indices, id: \.self) { fingerprintIndex in
                            if store.dedup.fingerprints.indices.contains(fingerprintIndex) {
                                Text("· \(store.dedup.fingerprints[fingerprintIndex].fileName)")
                                    .font(Theme.TextStyle.caption)
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
            } else if !store.dedup.isRunning, store.dedup.progress >= 1 {
                Text("未发现近重复文件。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textPrimary)
            }

            HStack {
                Spacer()
                TextButton(title: "关闭") { dismiss() }
            }
        }
        .padding(Theme.Spacing.s3)
        .frame(width: 460)
    }
}
