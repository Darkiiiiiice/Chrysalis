import AVFoundation
import Foundation

// MARK: - 单元测试（设计文档 §11 单元测试清单）

@MainActor
func runUnitTests() async {
    let h = Harness.shared

    await h.suite("码率计算（BitratePlanner / AudioPolicy）") {
        h.run("ProRes 标称数据率：1080p30 基准") {
            try expectEqual(
                BitratePlanner.proResDataRate(codec: .proRes422, width: 1920, height: 1080, fps: 30),
                147_000_000,
                "ProRes 422 @1080p30 应为白皮书值"
            )
        }
        h.run("ProRes 标称数据率：像素与帧率线性缩放") {
            let base = BitratePlanner.proResDataRate(codec: .proRes422, width: 1920, height: 1080, fps: 30)
            let fourK = BitratePlanner.proResDataRate(codec: .proRes422, width: 3840, height: 2160, fps: 30)
            let sixty = BitratePlanner.proResDataRate(codec: .proRes422, width: 1920, height: 1080, fps: 60)
            try expect(abs(Double(fourK) / Double(base) - 4.0) < 0.01, "4K 应为 1080p 的 4 倍：\(fourK) vs \(base)")
            try expect(abs(Double(sixty) / Double(base) - 2.0) < 0.01, "60fps 应为 30fps 的 2 倍")
            try expect(
                BitratePlanner.proResDataRate(codec: .h264, width: 1920, height: 1080, fps: 30) == 0,
                "H.264 无 ProRes 数据率（返回 0）"
            )
        }
        h.run("平均码率缩放：1080p 基准按像素缩放") {
            let result = BitratePlanner.scaled(base1080p: 8_000_000, range: 2_500_000...12_000_000, width: 1280, height: 720)
            let expected = 8_000_000.0 * (1280.0 * 720.0) / (1920.0 * 1080.0)
            try expect(abs(Double(result) - expected) < 1000, "720p 应约 \(Int(expected))，实际 \(result)")
        }
        h.run("平均码率缩放：夹取到预设范围") {
            let upper = BitratePlanner.scaled(base1080p: 8_000_000, range: 2_500_000...12_000_000, width: 3840, height: 2160)
            try expectEqual(upper, 12_000_000, "4K 超上限应夹取到 12 Mbps")
            let lower = BitratePlanner.scaled(base1080p: 3_000_000, range: 2_500_000...6_000_000, width: 854, height: 480)
            try expectEqual(lower, 2_500_000, "480p 低于下限应夹取到 2.5 Mbps")
        }
        h.run("质量名义码率：0.65 ≈ 基准") {
            let result = BitratePlanner.nominalQuality(codec: .h264, quality: 0.65, width: 1920, height: 1080)
            try expect(abs(Double(result) / 8_000_000.0 - 1.0) < 0.05, "0.65 应接近 8 Mbps 基准，实际 \(result)")
        }
        h.run("质量名义码率：随质量单调") {
            let low = BitratePlanner.nominalQuality(codec: .h264, quality: 0.2, width: 1920, height: 1080)
            let mid = BitratePlanner.nominalQuality(codec: .h264, quality: 0.65, width: 1920, height: 1080)
            let high = BitratePlanner.nominalQuality(codec: .h264, quality: 0.9, width: 1920, height: 1080)
            try expect(low < mid && mid < high, "0.2 < 0.65 < 0.9 应单调：\(low) < \(mid) < \(high)")
            try expect(BitratePlanner.nominalQuality(codec: .proRes422, quality: 0.65, width: 1920, height: 1080) == 0, "ProRes 不适用")
        }
        h.run("目标大小换算：扣除音频、按时长换算") {
            let result = BitratePlanner.targetSizeVideoBitrate(
                targetBytes: 10_000_000, durationSeconds: 10, audioBitrate: 128_000, range: 2_500_000...12_000_000
            )
            let expected = 10_000_000.0 * 8 / 10 - 128_000.0
            try expect(result != nil, "合法输入应有结果")
            try expect(abs(Double(result!.videoBitrate) - expected) < 1, "应为 \(expected) bps")
            try expectEqual(result!.clamped, false, "范围内不应夹取")
        }
        h.run("目标大小换算：零时长与非法目标返回 nil") {
            try expect(
                BitratePlanner.targetSizeVideoBitrate(targetBytes: 10_000_000, durationSeconds: 0, audioBitrate: 128_000, range: 0...Int.max) == nil,
                "零时长应返回 nil"
            )
            try expect(
                BitratePlanner.targetSizeVideoBitrate(targetBytes: -1, durationSeconds: 10, audioBitrate: 128_000, range: 0...Int.max) == nil,
                "负目标应返回 nil"
            )
            try expect(
                BitratePlanner.targetSizeVideoBitrate(targetBytes: 10_000_000, durationSeconds: .nan, audioBitrate: 128_000, range: 0...Int.max) == nil,
                "NaN 时长应返回 nil"
            )
        }
        h.run("目标大小换算：范围外夹取并置位 clamped") {
            let low = BitratePlanner.targetSizeVideoBitrate(
                targetBytes: 1_000_000, durationSeconds: 10, audioBitrate: 128_000, range: 2_500_000...12_000_000
            )
            try expectEqual(low!.videoBitrate, 2_500_000, "下夹取")
            try expectEqual(low!.clamped, true, "应置位 clamped")
            let high = BitratePlanner.targetSizeVideoBitrate(
                targetBytes: 100_000_000, durationSeconds: 10, audioBitrate: 128_000, range: 2_500_000...12_000_000
            )
            try expectEqual(high!.videoBitrate, 12_000_000, "上夹取")
            try expectEqual(high!.clamped, true, "应置位 clamped")
        }
        h.run("PCM 标称码率：采样率 × 声道 × 位深") {
            try expectEqual(
                BitratePlanner.pcmBitrate(sampleRate: 48000, channels: 2, bitDepth: 16),
                1_536_000,
                "48kHz 立体声 16-bit"
            )
            try expectEqual(
                BitratePlanner.pcmBitrate(sampleRate: 44100, channels: 2, bitDepth: 24),
                2_116_800,
                "44.1kHz 立体声 24-bit"
            )
        }
        h.run("AAC 码率：单声道上限 256 kbps") {
            try expectEqual(AudioPolicy.effectiveBitrate(320_000, channels: 1), 256_000, "单声道应夹到 256k")
            try expectEqual(AudioPolicy.effectiveBitrate(320_000, channels: 2), 320_000, "立体声保持")
        }
        h.run("音频估算口径：AAC 与 PCM") {
            let aac = AudioPolicy.stereoAAC(bitrate: 192_000)
            try expectEqual(aac.estimatedBitsPerSecond(), 192_000, "AAC 立体声")
            let pcm = AudioPolicy(bitrate: 192_000, sampleRateOverride: nil, maxChannels: 2, pcmBitDepth: 16)
            try expectEqual(pcm.estimatedBitsPerSecond(), 1_536_000, "PCM 16-bit 默认 48kHz")
            try expectEqual(pcm.codecLabel, "PCM 16-bit", "PCM 文案")
            try expectEqual(aac.codecLabel, "AAC 192 kbps", "AAC 文案")
        }
    }

    await h.suite("样片试编码抽段（BitrateProbeService，§7.8）") {
        h.run("长片：均匀 3 段各 4 秒，避开片头片尾 5%") {
            let segments = BitrateProbeService.segments(forDuration: 600)
            try expectEqual(segments.count, 3, "默认 3 段")
            try expect(segments.allSatisfy { abs($0.length - 4) < 0.01 }, "每段 4 秒：\(segments)")
            let margin = 600 * 0.05
            try expect(segments.allSatisfy { $0.start >= margin - 0.01 }, "不早于片头 5%：\(segments.map(\.start))")
            try expect(
                segments.allSatisfy { $0.start + $0.length <= 600 - margin + 0.01 },
                "不晚于片尾 5%：\(segments.map { $0.start + $0.length })"
            )
            try expect(segments[0].start < segments[1].start && segments[1].start < segments[2].start, "起点递增")
        }
        h.run("短片（10 秒）：缩段仍 3 段") {
            let segments = BitrateProbeService.segments(forDuration: 10)
            try expectEqual(segments.count, 3, "不足 15 秒缩段但保持 3 段")
            try expect(segments.allSatisfy { $0.length < 4 }, "段长应缩到 4 秒以下：\(segments.map(\.length))")
            try expect(
                segments.allSatisfy { $0.start >= 0 && $0.start + $0.length <= 10 + 0.01 },
                "段不越过片尾：\(segments)"
            )
        }
        h.run("超短源（4 秒）：单段 = 时长 ×0.5 居中") {
            let segments = BitrateProbeService.segments(forDuration: 4)
            try expectEqual(segments.count, 1, "超短源单段")
            try expect(abs(segments[0].length - 2) < 0.01, "段长 = 时长一半：\(segments[0].length)")
            try expect(abs(segments[0].start - 1) < 0.01, "居中起点：\(segments[0].start)")
        }
        h.run("非法时长返回空") {
            try expect(BitrateProbeService.segments(forDuration: 0).isEmpty, "零时长应返回空")
            try expect(BitrateProbeService.segments(forDuration: -5).isEmpty, "负时长应返回空")
            try expect(BitrateProbeService.segments(forDuration: .infinity).isEmpty, "无穷应返回空")
        }
        h.run("estimatedBytes：实测码率 × 全片时长") {
            let result = BitrateProbeResult(
                averageBitrate: 4_000_000,
                sampledSeconds: 12,
                segmentBitrates: [4_000_000, 4_000_000, 4_000_000],
                createdAt: Date()
            )
            try expectEqual(result.estimatedBytes(forFullDuration: 600), Int64(4_000_000 / 8 * 600), "300 MB 外推")
            try expectEqual(result.estimatedBytes(forFullDuration: 0), Int64(0), "零时长为 0")
        }
        h.run("Codable 往返：归档持久化兼容") {
            let original = BitrateProbeResult(
                averageBitrate: 4_567_890,
                sampledSeconds: 12.4,
                segmentBitrates: [4_000_000, 5_100_000, 4_600_000],
                createdAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(BitrateProbeResult.self, from: data)
            try expectEqual(decoded, original, "编码解码应等值")
        }
    }

    await h.suite("A/B 对比（CompareSpecs / CompareContext，§7.9）") {
        h.run("CompareContext：路径往返与标题") {
            let context = CompareContext(
                sourceURL: URL(fileURLWithPath: "/tmp/movie.mov"),
                outputURL: URL(fileURLWithPath: "/out/movie.mp4"),
                sourceBookmark: Data([1, 2, 3])
            )
            try expectEqual(context.sourceURL.path(percentEncoded: false), "/tmp/movie.mov", "源路径")
            try expectEqual(context.outputURL.path(percentEncoded: false), "/out/movie.mp4", "输出路径")
            try expectEqual(context.title, "movie.mov", "标题 = 源文件名")
        }
        h.run("CompareContext：Codable 往返（窗口路由值）") {
            let original = CompareContext(
                sourceURL: URL(fileURLWithPath: "/tmp/a b/片名.mov"),
                outputURL: URL(fileURLWithPath: "/out/片名.mp4")
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CompareContext.self, from: data)
            try expectEqual(decoded, original, "编码解码应等值")
        }
        h.run("summaryLine：分辨率 · 编码 · 码率 · 体积") {
            let info = MediaInfo(
                containerLabel: "MP4",
                fileSizeBytes: 134_217_728,
                durationSeconds: 60,
                video: VideoStreamInfo(
                    codecFourCC: "hvc1", codecName: "hevc",
                    displayWidth: 1920, displayHeight: 1080, frameRate: 30,
                    bitrate: 4_200_000, hardwareDecodeSupported: true
                ),
                audio: nil,
                isHDR: false,
                hdrLabel: nil,
                hasProtectedContent: false
            )
            let line = CompareSpecs.summaryLine(info)
            try expect(line.contains("1920×1080"), "含分辨率：\(line)")
            try expect(line.contains("HEVC"), "含编码大写：\(line)")
            try expect(line.contains("Mbps"), "含码率：\(line)")
            try expect(line.contains("MB"), "含体积：\(line)")
        }
        h.run("summaryLine：无视频轨时不崩溃") {
            let info = MediaInfo(
                containerLabel: "MP4",
                fileSizeBytes: 1024,
                durationSeconds: 1,
                video: nil,
                audio: nil,
                isHDR: false,
                hdrLabel: nil,
                hasProtectedContent: false
            )
            let line = CompareSpecs.summaryLine(info)
            try expect(line.contains("—"), "缺视频轨显示占位：\(line)")
            try expect(line.contains("1 KB"), "体积仍在：\(line)")
        }
    }

    await h.suite("视频体检（MediaProbe，§7.10）") {
        h.run("结论映射：绿灯（矩阵内可转）") {
            let verdict = MediaProbeService.verdict(
                ext: "mp4", isReadable: true, isPlayable: true, isProtected: false,
                hasVideo: true, isHDR: false, hardwareDecode: true
            )
            try expectEqual(verdict.kind, ProbeVerdict.ready, "矩阵内可转应绿灯")
        }
        h.run("结论映射：黄灯（容器不在矩阵 / HDR / 无硬解）") {
            let container = MediaProbeService.verdict(
                ext: "mkv", isReadable: true, isPlayable: true, isProtected: false,
                hasVideo: true, isHDR: false, hardwareDecode: true
            )
            try expectEqual(container.kind, ProbeVerdict.restricted, "容器不在矩阵应黄灯")
            try expect(container.message.contains("mkv"), "人话原因含扩展名：\(container.message)")
            let hdr = MediaProbeService.verdict(
                ext: "mp4", isReadable: true, isPlayable: true, isProtected: false,
                hasVideo: true, isHDR: true, hardwareDecode: true
            )
            try expectEqual(hdr.kind, ProbeVerdict.restricted, "HDR 应黄灯")
            let noHW = MediaProbeService.verdict(
                ext: "mp4", isReadable: true, isPlayable: true, isProtected: false,
                hasVideo: true, isHDR: false, hardwareDecode: false
            )
            try expectEqual(noHW.kind, ProbeVerdict.restricted, "无硬件解码应黄灯")
        }
        h.run("结论映射：红灯（DRM / 无视频轨 / 不可读）") {
            let drm = MediaProbeService.verdict(
                ext: "m4v", isReadable: true, isPlayable: true, isProtected: true,
                hasVideo: true, isHDR: false, hardwareDecode: true
            )
            try expectEqual(drm.kind, ProbeVerdict.blocked, "DRM 应红灯")
            let noVideo = MediaProbeService.verdict(
                ext: "mp4", isReadable: true, isPlayable: true, isProtected: false,
                hasVideo: false, isHDR: false, hardwareDecode: true
            )
            try expectEqual(noVideo.kind, ProbeVerdict.blocked, "无视频轨应红灯")
            let unreadable = MediaProbeService.verdict(
                ext: "mp4", isReadable: false, isPlayable: false, isProtected: false,
                hasVideo: false, isHDR: false, hardwareDecode: false
            )
            try expectEqual(unreadable.kind, ProbeVerdict.blocked, "不可读应红灯")
        }
        h.run("moov 前置：快启动 / 后置 / 非 MP4 容器") {
            let directory = try Artifacts.subdirectory("probe-moov")
            func atom(_ type: String, payload: Int) -> Data {
                var data = Data()
                var size = UInt32(8 + payload).bigEndian
                withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
                data.append(contentsOf: Array(type.utf8))
                data.append(contentsOf: Data(repeating: 0, count: payload))
                return data
            }
            // 快启动：ftyp → moov → mdat
            let fast = directory.appendingPathComponent("fast.mp4")
            try (atom("ftyp", payload: 8) + atom("moov", payload: 8) + atom("mdat", payload: 4))
                .write(to: fast)
            try expectEqual(MediaProbeService.isMoovAtFront(fileURL: fast), true, "moov 在前应判定快启动")
            // 后置：ftyp → mdat → moov
            let slow = directory.appendingPathComponent("slow.mp4")
            try (atom("ftyp", payload: 8) + atom("mdat", payload: 4) + atom("moov", payload: 8))
                .write(to: slow)
            try expectEqual(MediaProbeService.isMoovAtFront(fileURL: slow), false, "moov 在后应判定非快启动")
            // 非 MP4 容器不检测
            let mkv = directory.appendingPathComponent("movie.mkv")
            try Data(repeating: 0, count: 32).write(to: mkv)
            try expectEqual(MediaProbeService.isMoovAtFront(fileURL: mkv), nil, "非 MP4/MOV/M4V 返回 nil")
        }
        h.run("VFR 判定：恒定帧率不误报 / 大间隔触发 / 样本不足") {
            let constant = Array(repeating: 1.0 / 30, count: 60)
            let judge = MediaProbeService.vfrJudgement(frameIntervals: constant)
            try expectEqual(judge.isVFR, false, "恒定间隔不误报")
            var jumpy = constant
            jumpy[10] = 0.2
            let jumpyJudge = MediaProbeService.vfrJudgement(frameIntervals: jumpy)
            try expectEqual(jumpyJudge.isVFR, true, "max/avg > 1.5 应判疑似 VFR")
            let tooFew = MediaProbeService.vfrJudgement(frameIntervals: [1.0 / 30, 1.0 / 30])
            try expectEqual(tooFew.isVFR, false, "样本不足不判定")
        }
        h.run("码率分布：min/avg/max") {
            let distribution = SampleStatistics.Distribution.make([3_000_000, 5_000_000, 7_000_000])
            try expectEqual(distribution?.min, 3_000_000, "最小")
            try expectEqual(distribution?.average, 5_000_000, "平均")
            try expectEqual(distribution?.max, 7_000_000, "最大")
            try expect(SampleStatistics.Distribution.make([]) == nil, "空数组返回 nil")
        }
        h.run("Markdown 生成：结论 / 分区 / 深度占位") {
            let report = MediaProbeReport(
                verdict: .restricted,
                verdictMessage: "输入容器 .mkv 不在 v1 支持矩阵（MP4 / MOV / M4V）：规格仅供参考，蝉蜕 v1 不转码该容器。",
                fileName: "movie.mkv",
                containerLabel: "MKV",
                fileSizeBytes: 134_217_728,
                durationSeconds: 120,
                createdAt: nil,
                modifiedAt: nil,
                video: VideoStreamInfo(
                    codecFourCC: "avc1", codecName: "H.264",
                    displayWidth: 1920, displayHeight: 1080, frameRate: 30,
                    bitrate: 4_000_000, hardwareDecodeSupported: true
                ),
                colorLabel: "BT.709",
                audioTracks: [
                    AudioStreamInfo(codecFourCC: "aac ", codecName: "AAC", channelCount: 2, sampleRate: 48000, bitrate: 192_000)
                ],
                isPlayable: true,
                isProtected: false,
                isMoovAtFront: nil,
                metadata: ["标题": "体检样例"],
                deep: nil,
                deepError: nil,
                deepScannedAt: nil,
                upscale: nil,
                quickScannedAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
            let markdown = ProbeReportMarkdown.generate(report)
            try expect(markdown.contains("# 视频体检报告：movie.mkv"), "标题含文件名")
            try expect(markdown.contains("🟡"), "黄灯图标")
            try expect(markdown.contains("可读，但转码受限"), "结论文案")
            try expect(markdown.contains("1920×1080"), "视频规格")
            try expect(markdown.contains("BT.709"), "色彩标签")
            try expect(markdown.contains("#1 AAC"), "音轨行")
            try expect(markdown.contains("未执行"), "深度探测占位")
            try expect(markdown.contains("标题：体检样例"), "元数据行")
        }
        h.run("报告 Codable 往返（JSON 导出基础）") {
            let report = MediaProbeReport(
                verdict: .ready,
                verdictMessage: "在支持矩阵内，可以加入转码队列。",
                fileName: "a.mp4",
                containerLabel: "MP4",
                fileSizeBytes: 1024,
                durationSeconds: 5,
                createdAt: nil,
                modifiedAt: nil,
                video: nil,
                colorLabel: nil,
                audioTracks: [],
                isPlayable: true,
                isProtected: false,
                isMoovAtFront: true,
                metadata: [:],
                deep: SampleStatistics(
                    sampledSegments: 3, sampledSeconds: 6,
                    segmentBitrates: SampleStatistics.Distribution(min: 1, average: 2, max: 3),
                    gopSizes: nil, isVFR: false, frameIntervalRatio: 1.1, averageFrameInterval: 1.0 / 30
                ),
                deepError: nil,
                deepScannedAt: nil,
                upscale: nil,
                quickScannedAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
            let data = try JSONEncoder().encode(report)
            let decoded = try JSONDecoder().decode(MediaProbeReport.self, from: data)
            try expectEqual(decoded, report, "编码解码应等值")
        }
    }

    await h.suite("音频响度（LoudnessMeter，§7.11）") {
        h.run("integrated：恒定块能量还原目标响度") {
            // -23 LUFS 对应每帧跨声道平方和均值 = 10^((-23+0.691)/10)
            let meanSquare = pow(10.0, (-23.0 + 0.691) / 10.0)
            // 段值口径：每帧跨声道加权平方和均值（measure 输出口径）
            let segments = Array(repeating: meanSquare, count: 200)
            let integrated = LoudnessMeter.integrated(segmentSums: segments, blockLength: 19200, hopLength: 4800)
            try expect(integrated != nil, "恒定能量应有结果")
            guard let value = integrated else { return }
            try expect(abs(value - -23.0) < 0.05, "integrated ≈ -23 LUFS：\(value)")
        }
        h.run("integrated：门限逻辑（静音段被剔除）") {
            // 响块 + 大量低于 -70 LUFS 的静音块 → gated 后 ≈ 响块响度
            let loudMeanSquare = pow(10.0, (-16.0 + 0.691) / 10.0)
            let quietMeanSquare = pow(10.0, (-90.0 + 0.691) / 10.0)
            var segments: [Double] = []
            for _ in 0..<100 { segments.append(loudMeanSquare) }
            for _ in 0..<400 { segments.append(quietMeanSquare) }
            let integrated = LoudnessMeter.integrated(segmentSums: segments, blockLength: 19200, hopLength: 4800)
            try expect(integrated != nil, "应有结果")
            guard let value = integrated else { return }
            try expect(abs(value - -16.0) < 0.1, "静音段应被门限剔除：\(value)")
        }
        h.run("integrated：样本不足返回 nil") {
            try expect(LoudnessMeter.integrated(segmentSums: [1, 2, 3], blockLength: 19200, hopLength: 4800) == nil, "不足 4 段返回 nil")
            try expect(LoudnessMeter.integrated(segmentSums: [], blockLength: 19200, hopLength: 4800) == nil, "空返回 nil")
        }
        h.run("增益：无峰限直拉 / 峰限夹取 / 降增益") {
            let setting = LoudnessSetting(target: .lufs14, peakCeilingDb: -1)
            // 实测 -20 → raw +6 dB；真峰 -10 dBFS → ceilingGain = -1 - (-10) = +9 > +6 → 不限峰
            let free = LoudnessMeter.gain(
                measurement: LoudnessMeasurement(integratedLufs: -20, truePeakDb: -10, sampleCount: 1000),
                setting: setting
            )
            try expect(abs(free.gainDb - 6) < 0.001, "无峰限增益 = +6：\(free.gainDb)")
            try expectEqual(free.peakLimited, false, "未触发峰限")
            // 真峰 0 dBFS → ceilingGain = -1 < +6 → 夹到 -1
            let limited = LoudnessMeter.gain(
                measurement: LoudnessMeasurement(integratedLufs: -20, truePeakDb: 0, sampleCount: 1000),
                setting: setting
            )
            try expect(abs(limited.gainDb - -1) < 0.001, "峰限增益夹到 -1：\(limited.gainDb)")
            try expectEqual(limited.peakLimited, true, "触发峰限")
            // 降增益：实测 -10 → -4 dB
            let down = LoudnessMeter.gain(
                measurement: LoudnessMeasurement(integratedLufs: -10, truePeakDb: -6, sampleCount: 1000),
                setting: setting
            )
            try expect(abs(down.gainDb - -4) < 0.001, "降增益 = -4：\(down.gainDb)")
            try expectEqual(down.peakLimited, false, "降增益不触峰限")
        }
        h.run("Biquad：高通滤除直流 / 冲激有界") {
            var highpass = LoudnessMeter.Biquad(b: [1.0, -2.0, 1.0], a: [1, -1.99004745483398, 0.99007225036621])
            // 恒定直流输入：稳态输出趋近 0
            var tail = 0.0
            for index in 0..<20000 {
                let y = highpass.process(0.5)
                if index >= 19990 { tail = y }
            }
            try expect(abs(tail) < 1e-3, "直流稳态输出应趋近 0：\(tail)")
            // 冲激响应：幅值有界
            var impulse = LoudnessMeter.Biquad(b: [1.0, -2.0, 1.0], a: [1, -1.99004745483398, 0.99007225036621])
            var peak = 0.0
            _ = impulse.process(1.0)
            for index in 1..<2000 {
                let y = impulse.process(0)
                if index > 10 { peak = max(peak, abs(y)) }
            }
            try expect(peak < 0.1, "冲激响应应有界且衰减：\(peak)")
        }
        h.run("LoudnessSetting：Codable 往返") {
            let original = LoudnessSetting(target: .lufs23, peakCeilingDb: -2)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(LoudnessSetting.self, from: data)
            try expectEqual(decoded, original, "编码解码应等值")
        }
        h.run("scale：Float 逐样本乘法") {
            var values: [Float] = [0.1, -0.2, 0.0, 0.25, -0.5]
            try values.withUnsafeMutableBufferPointer { buffer in
                LoudnessMeter.scale(floats: buffer.baseAddress!, count: buffer.count, gain: 2.0)
            }
            try expectEqual(values[0], Float(0.2), "0.1 ×2")
            try expectEqual(values[1], Float(-0.4), "-0.2 ×2")
            try expectEqual(values[2], Float(0.0), "0 ×2")
            try expectEqual(values[3], Float(0.5), "0.25 ×2")
            try expectEqual(values[4], Float(-1.0), "-0.5 ×2")
        }
    }

    await h.suite("帧混合（FrameBlender，§7.12）") {
        h.run("权重：60→30 两帧各 50%") {
            let weights = FrameBlender.weights(
                frameStarts: [0, 1.0 / 60], sourceFPS: 60,
                windowStart: 0, windowDuration: 1.0 / 30
            )
            try expect(weights.count == 2, "两帧参与")
            try expect(abs(weights[0] - 0.5) < 1e-6 && abs(weights[1] - 0.5) < 1e-6, "各 50%：\(weights)")
        }
        h.run("权重：60→24 非均匀（0.4/0.4/0.2）") {
            let weights = FrameBlender.weights(
                frameStarts: [0, 1.0 / 60, 2.0 / 60], sourceFPS: 60,
                windowStart: 0, windowDuration: 1.0 / 24
            )
            try expect(weights.count == 3, "三帧参与")
            try expect(abs(weights[0] - 0.4) < 1e-6, "帧 0：\(weights[0])")
            try expect(abs(weights[1] - 0.4) < 1e-6, "帧 1：\(weights[1])")
            try expect(abs(weights[2] - 0.2) < 1e-6, "帧 2：\(weights[2])")
        }
        h.run("权重：单帧完全覆盖 → 1.0") {
            let weights = FrameBlender.weights(
                frameStarts: [0], sourceFPS: 24,
                windowStart: 0, windowDuration: 1.0 / 24
            )
            try expect(abs(weights[0] - 1.0) < 1e-6, "单帧权重 1：\(weights)")
        }
        h.run("权重：窗口外帧权重 0 / 全零时返回零数组") {
            let outside = FrameBlender.weights(
                frameStarts: [1.0], sourceFPS: 60,
                windowStart: 0, windowDuration: 1.0 / 30
            )
            try expect(abs(outside[0]) < 1e-9, "窗口外帧权重 0：\(outside)")
            let empty = FrameBlender.weights(
                frameStarts: [10.0], sourceFPS: 60,
                windowStart: 0, windowDuration: 1.0 / 30
            )
            try expect(empty.allSatisfy { $0 == 0 }, "无覆盖返回零权重（调用方跳过窗口）")
        }
        h.run("权重：归一化（Σ=1）") {
            let weights = FrameBlender.weights(
                frameStarts: [0, 1.0 / 60, 2.0 / 60, 3.0 / 60], sourceFPS: 60,
                windowStart: 0.5 / 60, windowDuration: 2.0 / 60
            )
            let total = weights.reduce(0, +)
            try expect(abs(total - 1.0) < 1e-6, "权重和为 1：\(total)")
        }
    }

    await h.suite("语音转字幕（SpeechTranscriber，§7.13）") {
        h.run("makeCues：空文本过滤 / 短段过滤 / 时间排序 / 顺序 lineIndex") {
            let cues = SpeechTranscriber.makeCues(from: [
                (start: 2.0, duration: 1.0, text: "第二句"),
                (start: 0.0, duration: 1.5, text: "  第一句  "),
                (start: 5.0, duration: 0.1, text: "过短"),
                (start: 3.5, duration: 0.8, text: "   "),
            ])
            try expectEqual(cues.count, 2, "空文本与 <0.2s 段被过滤：\(cues.count)")
            try expectEqual(cues[0].lineIndex, 0, "顺序 lineIndex")
            try expectEqual(cues[1].lineIndex, 1, "顺序 lineIndex")
            try expect(cues[0].start < cues[1].start, "按时间排序")
            try expectEqual(cues[0].lines, ["第一句"], "文本已去首尾空白")
            try expectEqual(cues[1].end, 3.0, "end = start + duration")
        }
        h.run("SRT 时间戳格式") {
            try expectEqual(SubtitleGenerator.srtTimestamp(0), "00:00:00,000", "零点")
            try expectEqual(SubtitleGenerator.srtTimestamp(3661.5), "01:01:01,500", "1:01:01.5")
            try expectEqual(SubtitleGenerator.srtTimestamp(-1), "00:00:00,000", "负值钳到 0")
        }
        h.run("ASS 时间戳格式") {
            try expectEqual(SubtitleGenerator.assTimestamp(0), "0:00:00.00", "零点")
            try expectEqual(SubtitleGenerator.assTimestamp(3661.5), "1:01:01.50", "百分之一秒")
        }
        h.run("SRT 生成：序号 / 箭头行 / 空行分隔") {
            let cues = [
                SubtitleCue(lineIndex: 0, start: 0, end: 1.5, lines: ["你好"]),
                SubtitleCue(lineIndex: 1, start: 2, end: 3.5, lines: ["世界"]),
            ]
            let srt = SubtitleGenerator.srt(cues: cues)
            try expect(srt.contains("00:00:00,000 --> 00:00:01,500"), "箭头行：\(srt.prefix(120))")
            try expect(srt.contains("你好") && srt.contains("世界"), "包含文本")
            try expect(srt.hasPrefix("1\n"), "以序号开头")
        }
        h.run("ASS 生成：样式表 / Dialogue 行 / 多行 \\N") {
            let cues = [
                SubtitleCue(lineIndex: 0, start: 0, end: 1.5, lines: ["第一行", "第二行"]),
            ]
            let ass = SubtitleGenerator.ass(cues: cues)
            try expect(ass.contains("[Script Info]"), "Script Info 节")
            try expect(ass.contains("Style: Default,"), "默认样式行")
            try expect(ass.contains("Dialogue: 0,0:00:00.00,0:00:01.50,Default,,0,0,0,,第一行\\N第二行"), "Dialogue 行（\\N 拼接）：\(ass.suffix(200))")
        }
    }

    await h.suite("假 4K + 感知哈希（§7.14）") {
        // 伪随机（LCG）：生成可复现噪声帧
        func noiseGray(width: Int, height: Int, seed: UInt64) -> [Float] {
            var state = seed
            var result = [Float](repeating: 0, count: width * height)
            for index in 0..<result.count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                result[index] = Float((state >> 33) % 1000) / 1000.0
            }
            return result
        }

        h.run("residualScore：噪声帧显著高于平滑帧") {
            let width = 128, height = 128
            let noisy = noiseGray(width: width, height: height, seed: 42)
            var smooth = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    smooth[y * width + x] = Float(x) / Float(width) * 0.5 + 0.25
                }
            }
            let noisyScore = UpscaleDetector.residualScore(gray: noisy, width: width, height: height)
            let smoothScore = UpscaleDetector.residualScore(gray: smooth, width: width, height: height)
            try expect(noisyScore > smoothScore * 2, "噪声残差应显著高于平滑：\(noisyScore) vs \(smoothScore)")
        }
        h.run("classify：低分疑似 / 高分未检出") {
            let suspected = UpscaleDetector.classify(score: 0.005)
            try expectEqual(suspected.suspected, true, "低于阈值应疑似")
            try expect(suspected.confidence > 0.5, "越低越确信：\(suspected.confidence)")
            let clear = UpscaleDetector.classify(score: 0.15)
            try expectEqual(clear.suspected, false, "高于阈值未检出")
            try expect(clear.confidence > 0.5, "越高越确信：\(clear.confidence)")
        }
        h.run("suggestedLevel：档位映射") {
            try expectEqual(UpscaleDetector.suggestedLevel(forWidth: 3840, forHeight: 2160), "FHD（1080p）或更低", "4K")
            try expectEqual(UpscaleDetector.suggestedLevel(forWidth: 2560, forHeight: 1440), "HD（720p）", "1440")
            try expectEqual(UpscaleDetector.suggestedLevel(forWidth: 1920, forHeight: 1080), "HD（720p）/ SD", "1080")
            try expect(UpscaleDetector.suggestedLevel(forWidth: 1280, forHeight: 720) == nil, "低档位无建议")
        }
        h.run("hammingDistance / pHash 稳定性") {
            try expectEqual(VideoFingerprint.hammingDistance(0, 0), 0, "相同哈希距离 0")
            try expectEqual(VideoFingerprint.hammingDistance(UInt64.max, 0), 64, "全异距离 64")
            // 恒定灰度：哈希确定（两次一致）
            let constant = [Float](repeating: 0.5, count: 64 * 64)
            let hash1 = VideoFingerprint.pHash(gray: constant, width: 64, height: 64)
            let hash2 = VideoFingerprint.pHash(gray: constant, width: 64, height: 64)
            try expectEqual(hash1, hash2, "确定性输出")
            // 噪声 vs 恒定：距离应大
            let noisy = noiseGray(width: 64, height: 64, seed: 7)
            let noiseHash = VideoFingerprint.pHash(gray: noisy, width: 64, height: 64)
            try expect(VideoFingerprint.hammingDistance(hash1, noiseHash) > 16, "不同画面哈希距离大：\(VideoFingerprint.hammingDistance(hash1, noiseHash))")
        }
        h.run("去重分组：链式 A≈B≈C 归一组") {
            func fingerprint(_ name: String, _ hashes: [UInt64]) -> VideoFingerprint.ClipFingerprint {
                VideoFingerprint.ClipFingerprint(fileName: name, frameHashes: hashes)
            }
            let fingerprints = [
                fingerprint("A", [0b1111, 0b1111, 0b1111]),
                fingerprint("B", [0b1110, 0b1110, 0b1110]),   // 距离 1
                fingerprint("C", [0b1100, 0b1100, 0b1100]),   // 与 B 距离 1（链式）
                fingerprint("D", [0xF0F0_F0F0_F0F0_F0F0, 0xF0F0_F0F0_F0F0_F0F0, 0xF0F0_F0F0_F0F0_F0F0]),  // 远
            ]
            let groups = VideoFingerprint.duplicateGroups(fingerprints: fingerprints)
            try expectEqual(groups.count, 1, "A/B/C 链式归组、D 独立：\(groups)")
            try expectEqual(groups.first?.indices, [0, 1, 2], "组内索引排序")
        }
        h.run("去重：单文件不分组 / 空指纹跳过") {
            let single = VideoFingerprint.duplicateGroups(fingerprints: [
                VideoFingerprint.ClipFingerprint(fileName: "a", frameHashes: [1, 2, 3]),
            ])
            try expect(single.isEmpty, "单文件无分组")
            let empty = VideoFingerprint.duplicateGroups(fingerprints: [
                VideoFingerprint.ClipFingerprint(fileName: "a", frameHashes: []),
                VideoFingerprint.ClipFingerprint(fileName: "b", frameHashes: [1, 2, 3]),
            ])
            try expect(empty.isEmpty, "空指纹不参与比对")
        }
    }

    await h.suite("输出路径（OutputPlanner）") {
        let directory: URL
        let created: Bool
        if let temp = try? Artifacts.subdirectory("unit-output") {
            directory = temp
            created = true
        } else {
            directory = FileManager.default.temporaryDirectory
            created = false
        }
        h.run("前置：临时目录可用") { try expect(created, "临时目录应可创建") }
        h.run("无冲突：直接使用原始名") {
            let url = OutputPlanner.uniqueOutputURL(directory: directory, baseName: "movie-a", fileExtension: "mp4")
            try expectEqual(url.lastPathComponent, "movie-a.mp4", "无冲突不加后缀")
        }
        h.run("重名：加 -1 后缀") {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("movie-b.mp4").path, contents: Data([0]))
            let url = OutputPlanner.uniqueOutputURL(directory: directory, baseName: "movie-b", fileExtension: "mp4")
            try expectEqual(url.lastPathComponent, "movie-b-1.mp4", "重名应加 -1")
        }
        h.run("重名：连续 -1 / -2") {
            let directory = try Artifacts.subdirectory("unit-output-2")
            FileManager.default.createFile(atPath: directory.appendingPathComponent("clip.mov").path, contents: Data([0]))
            FileManager.default.createFile(atPath: directory.appendingPathComponent("clip-1.mov").path, contents: Data([0]))
            let url = OutputPlanner.uniqueOutputURL(directory: directory, baseName: "clip", fileExtension: "mov")
            try expectEqual(url.lastPathComponent, "clip-2.mov", "多个重名应顺延")
        }
        h.run("临时文件命名：前缀与后缀") {
            let url = OutputPlanner.makeTempURL(in: directory)
            try expect(url.lastPathComponent.hasPrefix(OutputPlanner.tempPrefix), "应以 .chrysalis- 开头")
            try expect(url.lastPathComponent.hasSuffix(OutputPlanner.tempSuffix), "应以 .tmp 结尾")
        }
        h.run("残留清理：只删 .chrysalis-*.tmp") {
            let directory = try Artifacts.subdirectory("unit-cleanup")
            let orphan = directory.appendingPathComponent(".chrysalis-DEAD.tmp")
            let keepA = directory.appendingPathComponent("normal.tmp")
            let keepB = directory.appendingPathComponent(".chrysalis-keep.txt")
            FileManager.default.createFile(atPath: orphan.path, contents: Data([0]))
            FileManager.default.createFile(atPath: keepA.path, contents: Data([0]))
            FileManager.default.createFile(atPath: keepB.path, contents: Data([0]))
            let removed = OutputPlanner.cleanupOrphanTemps(in: directory)
            try expectEqual(removed.count, 1, "只应删除孤儿临时文件")
            try expect(removed.first?.lastPathComponent == orphan.lastPathComponent, "删除的应是孤儿临时文件")
            try expect(!FileManager.default.fileExists(atPath: orphan.path), "孤儿文件应被删除")
            try expect(FileManager.default.fileExists(atPath: keepA.path), "normal.tmp 不应被删")
            try expect(FileManager.default.fileExists(atPath: keepB.path), "非 .tmp 不应被删")
        }
    }

    await h.suite("预设解析与 JSON 兼容") {
        h.run("JSON 往返：P4 全字段自定义预设") {
            var preset = TranscodePreset.copy(of: .compatible, name: "自定义测试")
            preset.bitrateMode = .targetSize
            preset.quality = 0.8
            preset.targetSizeMB = 1400
            preset.keyframeInterval = .s5
            preset.profile = .main
            preset.resolution = .r1080
            preset.frameRate = .fps30
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(TranscodePreset.self, from: data)
            try expectEqual(decoded, preset, "往返应完全一致")
            try expect(decoded.isBuiltIn == false, "复制的预设是自定义")
        }
        h.run("旧 JSON 缺省兼容：P4 前的字段缺省") {
            let legacy = """
            {"builtInKind":"compatible","id":"compatible","name":"兼容优先","videoCodec":"h264","container":"mp4",\
            "resolution":"source","frameRate":"source",\
            "audio":{"bitrate":192000,"sampleRateOverride":null,"maxChannels":2},\
            "bitrate1080p":8000000,"bitrateRange":[2500000,12000000]}
            """
            let decoded = try JSONDecoder().decode(TranscodePreset.self, from: Data(legacy.utf8))
            try expectEqual(decoded.bitrateMode, BitrateMode.targetBitrate, "缺省码率模式 = 平均码率")
            try expectEqual(decoded.quality, 0.65, "缺省质量")
            try expectEqual(decoded.targetSizeMB, 700, "缺省目标大小")
            try expectEqual(decoded.keyframeInterval, KeyframeIntervalSetting.auto, "缺省关键帧")
            try expectEqual(decoded.profile, VideoProfileSetting.auto, "缺省 Profile")
        }
        h.run("更旧 JSON 缺省兼容：P3.5 前无分辨率/帧率") {
            let legacy = """
            {"builtInKind":"compact","id":"compact","name":"小体积","videoCodec":"h264","container":"mp4",\
            "audio":{"bitrate":128000,"sampleRateOverride":null,"maxChannels":2},\
            "bitrate1080p":3000000,"bitrateRange":[1500000,6000000]}
            """
            let decoded = try JSONDecoder().decode(TranscodePreset.self, from: Data(legacy.utf8))
            try expectEqual(decoded.resolution, ResolutionSetting.source, "缺省保持源")
            try expectEqual(decoded.frameRate, FrameRateSetting.source, "缺省保持源")
        }
        h.run("内置预设：五套齐全且 id 唯一") {
            try expectEqual(TranscodePreset.builtIns.count, 5, "内置应为 5 套")
            try expect(Set(TranscodePreset.builtIns.map(\.id)).count == 5, "id 应唯一")
            try expect(TranscodePreset.builtIns.allSatisfy(\.isBuiltIn), "内置标记")
        }
        h.run("剪辑用 ProRes：MOV + PCM 16-bit + 平均码率口径") {
            let preset = TranscodePreset.editingProRes
            try expectEqual(preset.container, MediaContainer.mov, "ProRes 强制 MOV")
            try expectEqual(preset.audio.pcmBitDepth, 16, "PCM 16-bit")
            try expectEqual(preset.audio.isPCM, true, "PCM 标记")
            try expectEqual(preset.bitrateMode, BitrateMode.targetBitrate, "ProRes 不适用质量/目标大小")
            try expect(preset.bitrateLabel.contains("ProRes 固定码率"), "码率口径文案：\(preset.bitrateLabel)")
        }
        h.run("估算：目标大小模式直接给目标值") {
            var preset = TranscodePreset.copy(of: .compatible, name: "目标大小")
            preset.bitrateMode = .targetSize
            preset.targetSizeMB = 500
            try expectEqual(preset.estimatedBytes(durationSeconds: 60, videoWidth: 1920, videoHeight: 1080), Int64(500_000_000), "估算 = 目标 MB")
            try expect(preset.hourlyEstimateLabel.contains("500 MB"), "小时估算文案：\(preset.hourlyEstimateLabel)")
        }
        h.run("估算：质量模式标注「按质量推测」") {
            var preset = TranscodePreset.copy(of: .compatible, name: "质量")
            preset.bitrateMode = .quality
            preset.quality = 0.7
            try expect(preset.hourlyEstimateLabel.contains("按质量推测"), "文案：\(preset.hourlyEstimateLabel)")
            try expect(preset.bitrateLabel.contains("质量"), "码率口径：\(preset.bitrateLabel)")
        }
        h.run("分辨率档位：短边匹配 / 只缩不放 / 偶数对齐") {
            try expectEqual(ResolutionSetting.r1080.renderSize(sourceWidth: 3840, sourceHeight: 2160)!.width, 1920, "4K → 1080p")
            let portrait = ResolutionSetting.r720.renderSize(sourceWidth: 1080, sourceHeight: 1920)
            try expectEqual(portrait!.width, 720, "竖屏短边匹配")
            try expectEqual(portrait!.height, 1280, "竖屏长边等比")
            try expect(ResolutionSetting.r720.renderSize(sourceWidth: 640, sourceHeight: 360) == nil, "小于目标不放大")
            let odd = ResolutionSetting.r480.renderSize(sourceWidth: 1281, sourceHeight: 721)
            try expect(Int(odd!.width) % 2 == 0 && Int(odd!.height) % 2 == 0, "偶数对齐：\(odd!)")
            try expect(ResolutionSetting.source.renderSize(sourceWidth: 1920, sourceHeight: 1080) == nil, "保持源不缩放")
        }
        h.run("帧率档位：只降不升") {
            try expectEqual(FrameRateSetting.fps30.effectiveFrameRate(sourceFPS: 60), 30, "60 → 30 降帧")
            try expectEqual(FrameRateSetting.fps60.effectiveFrameRate(sourceFPS: 29.97), 29.97, "29.97 < 60 保持源")
            try expectEqual(FrameRateSetting.source.effectiveFrameRate(sourceFPS: 23.976), 23.976, "保持源")
        }
        h.run("Profile 档位：H.264 可选，HEVC/ProRes 仅自动") {
            try expectEqual(VideoProfileSetting.choices(for: .h264).count, 4, "H.264 四档")
            try expectEqual(VideoProfileSetting.choices(for: .hevc), [.auto], "HEVC 仅自动")
            try expectEqual(VideoProfileSetting.choices(for: .proRes422), [.auto], "ProRes 仅自动")
            try expect(VideoProfileSetting.baseline.profileLevel(for: .h264) != nil, "Baseline 有 profileLevel")
            try expect(VideoProfileSetting.auto.profileLevel(for: .proRes4444) == nil, "ProRes 不适用")
        }
        h.run("关键帧档位：秒数换算") {
            try expectEqual(KeyframeIntervalSetting.auto.seconds, 2, "自动 = 2 秒")
            try expectEqual(KeyframeIntervalSetting.s10.seconds, 10, "10 秒")
        }
    }

    await h.suite("任务状态机与队列持久化") {
        h.run("状态分类：活跃 / 终态 / 可重试") {
            let active: [TranscodeJob.State] = [.preparing, .running, .finishing, .cancelling]
            let terminal: [TranscodeJob.State] = [.completed, .cancelled, .interrupted, .failed("原因")]
            for state in active {
                try expect(state.isActive && !state.isTerminal && !state.isRetryable, "\(state) 应只属于活跃")
            }
            for state in terminal {
                try expect(!state.isActive && state.isTerminal, "\(state) 应属于终态")
            }
            try expect(!TranscodeJob.State.queued.isActive && !TranscodeJob.State.queued.isTerminal, "queued 排队中")
            for state in [.cancelled, .interrupted, TranscodeJob.State.failed("原因")] {
                try expect(state.isRetryable, "\(state) 可重试")
            }
            try expect(!TranscodeJob.State.completed.isRetryable, "完成不可重试")
        }
        h.run("持久化映射：活跃 → interrupted") {
            try expectEqual(QueueArchive.PersistedState(.running).restoredState, TranscodeJob.State.interrupted, "运行中恢复为中断")
            try expectEqual(QueueArchive.PersistedState(.preparing).restoredState, TranscodeJob.State.interrupted, "准备中恢复为中断")
            try expectEqual(QueueArchive.PersistedState(.cancelling).restoredState, TranscodeJob.State.interrupted, "取消中恢复为中断")
            try expectEqual(QueueArchive.PersistedState(.queued).restoredState, TranscodeJob.State.queued, "排队保持排队")
            try expectEqual(QueueArchive.PersistedState(.completed).restoredState, TranscodeJob.State.completed, "完成保持完成")
        }
        h.run("队列归档 JSON 往返") {
            var job = TranscodeJob(inputURL: URL(fileURLWithPath: "/tmp/样片.mp4"))
            job.mediaKind = .movie
            job.metadataState = .confirmed
            job.movieMetadata = MovieMetadata(title: "测试电影", year: 2024)
            let archive = QueueArchive(outputDirectoryBookmark: Data([1, 2, 3]), jobs: [QueueArchive.PersistedJob(job)])
            let data = try JSONEncoder().encode(archive)
            let decoded = try JSONDecoder().decode(QueueArchive.self, from: data)
            try expectEqual(decoded.version, QueueArchive.currentVersion, "版本号写入")
            try expectEqual(decoded.jobs.count, 1, "任务数")
            try expectEqual(decoded.jobs.first?.preset.id, job.preset.id, "预设快照")
            try expectEqual(decoded.jobs.first?.state, QueueArchive.PersistedState(job.state), "状态快照")
        }
        h.run("历史条目 JSON 往返") {
            var job = TranscodeJob(inputURL: URL(fileURLWithPath: "/tmp/历史.mp4"))
            job.state = .completed
            job.outputBytes = 123_456
            let entry = HistoryEntry(job: job, kind: .completed)
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
            try expectEqual(decoded, entry, "历史条目往返一致")
            try expectEqual(decoded.kind.displayName, "成功", "终态文案")
        }
    }

    await h.suite("文件名解析（TitleParser）") {
        func parsed(_ filename: String) throws -> ParsedTitle {
            let result = TitleParser.parse(filename: filename)
            return result
        }
        h.run("英文标题 + 年份 + 发布标记") {
            let result = try parsed("The.Matrix.1999.1080p.BluRay.x264.mkv")
            try expectEqual(result.primaryTitle, "The Matrix", "主标题")
            try expectEqual(result.year, 1999, "年份")
        }
        h.run("中文标题 + 年份") {
            let result = try parsed("流浪地球2.2023.2160p.WEB-DL.x265.mkv")
            try expectEqual(result.primaryTitle, "流浪地球2", "主标题")
            try expectEqual(result.year, 2023, "年份")
        }
        h.run("括号备选标题（中文译名）") {
            let result = try parsed("The.Fifth.Element.1997.(第五元素).BluRay.mkv")
            try expectEqual(result.primaryTitle, "The Fifth Element", "主标题")
            try expectEqual(result.alternativeTitle, "第五元素", "括号备选")
            try expectEqual(result.year, 1997, "年份")
        }
        h.run("发布标记括号不算备选标题") {
            let result = try parsed("Heat.1995.(1080p.BluRay).mkv")
            try expect(result.alternativeTitle == nil, "发布标记括号应被过滤：\(String(describing: result.alternativeTitle))")
        }
        h.run("无年份") {
            let result = try parsed("Heat.1080p.BluRay.x264.mkv")
            try expectEqual(result.primaryTitle, "Heat", "标题")
            try expect(result.year == nil, "无年份")
        }
        h.run("纯年份文件名视为标题") {
            let result = try parsed("2012.mkv")
            try expectEqual(result.primaryTitle, "2012", "文件名即标题")
            try expect(result.year == nil, "不应误判为年份")
        }
        h.run("下划线与点号归一") {
            let result = try parsed("Mad_Max_Fury_Road_2015.mkv")
            try expectEqual(result.primaryTitle, "Mad Max Fury Road", "下划线转空格")
            try expectEqual(result.year, 2015, "年份")
        }
        h.run("发布组开头方括号不进备选") {
            let result = try parsed("[GroupName] Movie 2019.mp4")
            try expect(result.alternativeTitle == nil, "开头方括号是发布组：\(String(describing: result.alternativeTitle))")
            try expectEqual(result.primaryTitle, "Movie", "标题截断发布标记后")
        }
    }

    await h.suite("匹配评分（MovieMatcher）") {
        func summary(id: Int, title: String, original: String? = nil, date: String? = nil, popularity: Double = 0) -> TMDBMovieSummary {
            TMDBMovieSummary(
                id: id, title: title, originalTitle: original, releaseDate: date,
                overview: nil, posterPath: nil, popularity: popularity, voteAverage: nil
            )
        }
        h.run("精确标题 + 年份最高分") {
            let parsed = ParsedTitle(primaryTitle: "Inception", alternativeTitle: nil, year: 2010)
            let exact = summary(id: 1, title: "Inception", date: "2010-07-16", popularity: 50)
            let other = summary(id: 2, title: "Inception", date: "2015-01-01", popularity: 90)
            let ranked = MovieMatcher.rank([other, exact], parsed: parsed)
            try expectEqual(ranked.first?.id, 1, "精确年份应排第一")
            try expect(MovieMatcher.score(exact, parsed: parsed) > MovieMatcher.score(other, parsed: parsed), "同片名不同年应降权")
        }
        h.run("原始标题匹配（外文片）") {
            let parsed = ParsedTitle(primaryTitle: "流浪地球2", alternativeTitle: nil, year: 2023)
            let viaOriginal = summary(id: 1, title: "The Wandering Earth II", original: "流浪地球2", date: "2023-01-22")
            try expect(MovieMatcher.score(viaOriginal, parsed: parsed) >= 90, "原始标题精确匹配应得 90 权重分")
        }
        h.run("归一化：大小写与全半角") {
            try expectEqual(MovieMatcher.normalize("INCEPTION"), "inception", "大小写")
            try expectEqual(MovieMatcher.normalize("Ｉｎｃｅｐｔｉｏｎ"), "inception", "全角")
            try expectEqual(MovieMatcher.normalize("  Inception  "), "inception", "空白收敛")
        }
        h.run("包含关系给中间分") {
            let parsed = ParsedTitle(primaryTitle: "Inception", alternativeTitle: nil, year: nil)
            let containing = summary(id: 1, title: "Inception: The Cobol Job", date: nil)
            let score = MovieMatcher.score(containing, parsed: parsed)
            try expectEqual(score, 65, "包含关系 = 权重 100 - 35")
        }
        h.run("无关结果低分") {
            let parsed = ParsedTitle(primaryTitle: "Inception", alternativeTitle: nil, year: nil)
            let unrelated = summary(id: 1, title: "The Matrix", date: nil)
            let score = MovieMatcher.score(unrelated, parsed: parsed)
            try expect(score < 40, "无关结果应低分：\(score)")
        }
        h.run("rank 只取前 5") {
            let parsed = ParsedTitle(primaryTitle: "Heat", alternativeTitle: nil, year: nil)
            let results = (0..<10).map { summary(id: $0, title: "Heat \($0)", popularity: Double($0)) }
            try expectEqual(MovieMatcher.rank(results, parsed: parsed).count, MovieMatcher.maxCandidates, "只取 5 个候选")
        }
        h.run("同分按热度排序") {
            let parsed = ParsedTitle(primaryTitle: "Heat", alternativeTitle: nil, year: nil)
            let hot = summary(id: 1, title: "X", popularity: 100)
            let cold = summary(id: 2, title: "X", popularity: 1)
            let ranked = MovieMatcher.rank([cold, hot], parsed: parsed)
            try expectEqual(ranked.first?.id, 1, "同分高热度在前")
        }
    }

    await h.suite("电影元数据校验与前置拦截") {
        h.run("合法元数据通过") {
            let metadata = MovieMetadata(title: "测试电影", year: 2024, releaseDate: "2024-05-17")
            try expect(metadata.validationMessage == nil, "合法元数据无提示：\(String(describing: metadata.validationMessage))")
        }
        h.run("空标题拒绝") {
            let metadata = MovieMetadata(title: "   ", year: 2024)
            try expectEqual(metadata.validationMessage, "标题不能为空。", "空标题提示")
        }
        h.run("非法年份拒绝") {
            let metadata = MovieMetadata(title: "A", year: 1800)
            try expect(metadata.validationMessage?.contains("1888") == true, "年份范围提示：\(String(describing: metadata.validationMessage))")
        }
        h.run("非法日期格式拒绝") {
            let metadata = MovieMetadata(title: "A", releaseDate: "2020/01/01")
            try expectEqual(metadata.validationMessage, "上映日期需为 YYYY-MM-DD 格式。", "日期格式提示")
        }
        h.run("元数据状态机文案") {
            try expectEqual(MovieMetadataState.none.displayName, "未启用", "文案")
            try expectEqual(MovieMetadataState.needsReview.displayName, "待确认", "文案")
            try expect(MovieMetadataState.failed("原因").failureMessage == "原因", "失败原因可读")
        }
        h.run("前置拦截：未确认电影任务 needsMetadataConfirmation") {
            var movie = TranscodeJob(inputURL: URL(fileURLWithPath: "/tmp/片名.mp4"))
            movie.mediaKind = .movie
            try expect(movie.needsMetadataConfirmation, "电影任务未确认应拦截")
            movie.metadataState = .searching
            try expect(movie.needsMetadataConfirmation, "匹配中也拦截")
            movie.metadataState = .failed("无结果")
            try expect(movie.needsMetadataConfirmation, "失败也拦截")
            movie.metadataState = .confirmed
            try expect(!movie.needsMetadataConfirmation, "确认后放行")
            var video = TranscodeJob(inputURL: URL(fileURLWithPath: "/tmp/普通.mp4"))
            video.mediaKind = .video
            try expect(!video.needsMetadataConfirmation, "普通视频不拦截")
        }
        h.run("前置拦截：只拦排队中的任务（unconfirmedMovieJobs 语义）") {
            var done = TranscodeJob(inputURL: URL(fileURLWithPath: "/tmp/已完.mp4"))
            done.mediaKind = .movie
            done.state = .completed
            try expect(!QueueStoreStartPredicate.isUnconfirmed(done), "已完成的电影不再拦截")
            var pending = TranscodeJob(inputURL: URL(fileURLWithPath: "/tmp/待转.mp4"))
            pending.mediaKind = .movie
            pending.state = .queued
            try expect(QueueStoreStartPredicate.isUnconfirmed(pending), "排队中未确认应拦截")
        }
    }

    await h.suite("TMDB 客户端（mock transport）") {
        final class RequestBox: @unchecked Sendable {
            var request: URLRequest?
        }
        func transport(status: Int, headers: [String: String] = [:], body: String, box: RequestBox? = nil) -> TMDBClient.Transport {
            { request in
                box?.request = request
                let http = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
                )!
                return (Data(body.utf8), http)
            }
        }
        let okBody = """
        {"page":1,"results":[{"id":27205,"title":"盗梦空间","original_title":"Inception",\
        "release_date":"2010-07-16","overview":"一个梦。" \
        ,"poster_path":"/abc.jpg","popularity":90.5,"vote_average":8.4}],"total_results":1}
        """

        await h.runAsync("搜索成功解码") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "abc123"),
                transport: transport(status: 200, body: okBody)
            )
            let results = try await client.searchMovies(query: "Inception", year: 2010)
            try expectEqual(results.count, 1, "一条结果")
            try expectEqual(results[0].title, "盗梦空间", "标题")
            try expectEqual(results[0].year, 2010, "年份从日期推导")
        }
        await h.runAsync("空结果不报错") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "abc123"),
                transport: transport(status: 200, body: #"{"page":1,"results":[],"total_results":0}"#)
            )
            let results = try await client.searchMovies(query: "无", year: nil)
            try expectEqual(results.count, 0, "空数组")
        }
        await h.runAsync("401 → invalidKey") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "bad"),
                transport: transport(status: 401, body: "{}")
            )
            try await Harness.expectError(TMDBError.invalidKey) {
                _ = try await client.searchMovies(query: "x", year: nil)
            }
        }
        await h.runAsync("429 → rateLimited（带 Retry-After）") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: transport(status: 429, headers: ["Retry-After": "7"], body: "{}")
            )
            do {
                _ = try await client.searchMovies(query: "x", year: nil)
                throw TestFailure(message: "应抛出 429", file: #filePath, line: #line)
            } catch let error as TMDBError {
                try expectEqual(error, TMDBError.rateLimited(retryAfterSeconds: 7), "应带重试秒数")
            }
        }
        await h.runAsync("429 → rateLimited（无 Retry-After）") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: transport(status: 429, body: "{}")
            )
            do {
                _ = try await client.searchMovies(query: "x", year: nil)
                throw TestFailure(message: "应抛出 429", file: #filePath, line: #line)
            } catch let error as TMDBError {
                try expectEqual(error, TMDBError.rateLimited(retryAfterSeconds: nil), "无重试秒数")
            }
        }
        await h.runAsync("500 → network") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: transport(status: 500, body: "{}")
            )
            do {
                _ = try await client.searchMovies(query: "x", year: nil)
                throw TestFailure(message: "应抛出 network", file: #filePath, line: #line)
            } catch let error as TMDBError {
                guard case .network = error else {
                    throw TestFailure(message: "应为 network：\(error)", file: #filePath, line: #line)
                }
            }
        }
        await h.runAsync("坏 JSON → decodingFailed") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: transport(status: 200, body: "<html>not json</html>")
            )
            do {
                _ = try await client.searchMovies(query: "x", year: nil)
                throw TestFailure(message: "应抛出 decodingFailed", file: #filePath, line: #line)
            } catch let error as TMDBError {
                guard case .decodingFailed = error else {
                    throw TestFailure(message: "应为 decodingFailed：\(error)", file: #filePath, line: #line)
                }
            }
        }
        await h.runAsync("超时 → timedOut") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: { _ in throw URLError(.timedOut) }
            )
            do {
                _ = try await client.searchMovies(query: "x", year: nil)
                throw TestFailure(message: "应抛出 timedOut", file: #filePath, line: #line)
            } catch let error as TMDBError {
                try expectEqual(error, TMDBError.timedOut, "超时归类")
            }
        }
        await h.runAsync("连接失败 → network") {
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: { _ in throw URLError(.cannotConnectToHost) }
            )
            do {
                _ = try await client.searchMovies(query: "x", year: nil)
                throw TestFailure(message: "应抛出 network", file: #filePath, line: #line)
            } catch let error as TMDBError {
                guard case .network = error else {
                    throw TestFailure(message: "应为 network：\(error)", file: #filePath, line: #line)
                }
            }
        }
        await h.runAsync("v3 Key：api_key 拼在 query") {
            let box = RequestBox()
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "hex-key"),
                transport: transport(status: 200, body: okBody, box: box)
            )
            _ = try await client.searchMovies(query: "Inception", year: 2010)
            let request = try expectNotNil(box.request, "应有请求记录")
            let query = request.url?.query ?? ""
            try expect(query.contains("api_key=hex-key"), "query 应含 api_key：\(query)")
            try expect(query.contains("year=2010"), "query 应含 year：\(query)")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "v3 不带 Bearer")
        }
        await h.runAsync("v4 Token：Authorization Bearer 头") {
            let box = RequestBox()
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v4Token, value: "eyJtoken.a.b"),
                transport: transport(status: 200, body: okBody, box: box)
            )
            _ = try await client.searchMovies(query: "Inception", year: nil)
            try expectEqual(box.request?.value(forHTTPHeaderField: "Authorization"), "Bearer eyJtoken.a.b", "Bearer 头")
            try expect(!(box.request?.url?.query ?? "").contains("api_key"), "v4 query 不带 api_key")
        }
        h.run("凭据识别：v3 hex / v4 JWT") {
            try expectEqual(TMDBCredential.detect("0123abcd").kind, TMDBCredential.Kind.v3Key, "hex 串为 v3")
            try expectEqual(TMDBCredential.detect("eyJhbG.aBc.deF").kind, TMDBCredential.Kind.v4Token, "含点为 v4 JWT")
        }
        await h.runAsync("详情映射：导演/演员/类型/来源") {
            let detailBody = """
            {"id":27205,"title":"盗梦空间","original_title":"Inception","release_date":"2010-07-16",\
            "overview":"梦。","poster_path":"/abc.jpg","imdb_id":"tt1375666",\
            "genres":[{"id":28,"name":"动作"},{"id":878,"name":"科幻"}],\
            "credits":{"cast":[{"name":"莱昂纳多","order":0},{"name":"约瑟夫","order":1}],\
            "crew":[{"name":"诺兰","job":"Director"},{"name":"其他人","job":"Writer"}]}}
            """
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: transport(status: 200, body: detailBody)
            )
            let detail = try await client.movieDetail(id: 27205)
            let metadata = detail.movieMetadata
            try expectEqual(metadata.title, "盗梦空间", "标题")
            try expectEqual(metadata.director, "诺兰", "导演取 Director")
            try expectEqual(metadata.cast.count, 2, "演员")
            try expectEqual(metadata.genres, ["动作", "科幻"], "类型")
            try expectEqual(metadata.imdbID, "tt1375666", "IMDB")
            try expectEqual(metadata.source, MovieMetadata.Source.tmdb, "来源标记")
        }
        await h.runAsync("详情请求带 credits 附加") {
            let box = RequestBox()
            let client = TMDBClient(
                credential: TMDBCredential(kind: .v3Key, value: "k"),
                transport: transport(status: 200, body: #"{"id":1,"title":"A"}"#, box: box)
            )
            _ = try await client.movieDetail(id: 1)
            try expect((box.request?.url?.query ?? "").contains("append_to_response=credits"), "应附加 credits")
        }
        h.run("海报 URL 构建") {
            let url = TMDBClient.posterURL(path: "/abc.jpg")
            try expectEqual(url?.absoluteString, "https://image.tmdb.org/t/p/w342/abc.jpg", "w342 海报")
            try expect(TMDBClient.posterURL(path: "abc.jpg") == nil, "无前导斜杠非法")
        }
        h.run("错误文案可执行") {
            try expect(TMDBError.notConfigured.errorDescription?.contains("设置") == true, "notConfigured 提示去设置")
            try expect(TMDBError.invalidKey.errorDescription?.contains("401") == true, "invalidKey 提示 401")
            try expect(TMDBError.timedOut.errorDescription?.contains("手动填写") == true, "超时给手动兜底")
        }
    }

    await h.suite("代理设置") {
        h.run("启用 + 合法参数通过") {
            let settings = ProxySettings(isEnabled: true, kind: .http, host: "127.0.0.1", port: 7890)
            try expect(settings.validationMessage == nil, "合法无提示")
            try expect(settings.connectionProxyDictionary != nil, "HTTP 代理字典")
            let socks = ProxySettings(isEnabled: true, kind: .socks5, host: "127.0.0.1", port: 1080)
            try expect(socks.connectionProxyDictionary != nil, "SOCKS5 代理字典")
        }
        h.run("未启用不构建代理") {
            let settings = ProxySettings.default
            try expect(settings.connectionProxyDictionary == nil, "默认关闭无代理")
        }
        h.run("非法主机拒绝") {
            let withScheme = ProxySettings(isEnabled: true, kind: .http, host: "http://127.0.0.1", port: 7890)
            try expect(withScheme.validationMessage?.contains("协议") == true, "带协议拒绝")
            let empty = ProxySettings(isEnabled: true, kind: .http, host: " ", port: 7890)
            try expect(empty.validationMessage?.contains("不能为空") == true, "空主机拒绝")
            let badPort = ProxySettings(isEnabled: true, kind: .http, host: "127.0.0.1", port: 0)
            try expect(badPort.validationMessage?.contains("1–65535") == true, "端口越界拒绝")
        }
        h.run("UserDefaults 往返（隔离 suite）") {
            let suiteName = "dev.chrysalis.harness.proxy"
            let defaults = try expectNotNil(UserDefaults(suiteName: suiteName), "创建隔离 suite")
            defaults.removePersistentDomain(forName: suiteName)
            let settings = ProxySettings(isEnabled: true, kind: .socks5, host: "10.0.0.1", port: 1080)
            ProxySettingsStore.save(settings, to: defaults)
            let loaded = ProxySettingsStore.load(from: defaults)
            try expectEqual(loaded, settings, "往返一致")
            defaults.removePersistentDomain(forName: suiteName)
        }
        h.run("损坏数据回退默认值") {
            let suiteName = "dev.chrysalis.harness.proxy.bad"
            let defaults = try expectNotNil(UserDefaults(suiteName: suiteName), "创建隔离 suite")
            defaults.set(Data("broken".utf8), forKey: ProxySettingsStore.defaultsKey)
            try expectEqual(ProxySettingsStore.load(from: defaults), ProxySettings.default, "损坏回退默认")
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    await h.suite("格式化（Fmt）") {
        h.run("时长：分秒与时分秒") {
            try expectEqual(Fmt.duration(seconds: 59), "00:59", "59 秒")
            try expectEqual(Fmt.duration(seconds: 61), "01:01", "61 秒")
            try expectEqual(Fmt.duration(seconds: 3661), "1:01:01", "1 小时")
            try expectEqual(Fmt.duration(seconds: -5), "—", "负数")
            try expectEqual(Fmt.duration(seconds: .nan), "—", "NaN")
        }
        h.run("大小：非法回退、合法带单位") {
            try expectEqual(Fmt.bytes(0), "—", "零")
            try expectEqual(Fmt.bytes(-1), "—", "负数")
            try expect(Fmt.bytes(1_234_567).contains("MB") || Fmt.bytes(1_234_567).contains("KB"), "带单位：\(Fmt.bytes(1_234_567))")
        }
        h.run("速度 / 百分比") {
            try expectEqual(Fmt.speed(2.34), "2.3x", "一位小数")
            try expectEqual(Fmt.speed(-1), "—", "非法")
            try expectEqual(Fmt.percent(0.5), "50%", "百分比")
            try expectEqual(Fmt.percent(2), "100%", "夹取上限")
            try expectEqual(Fmt.percent(.nan), "—", "NaN")
        }
        h.run("码率文案") {
            try expectEqual(Fmt.bitrate(8_000_000), "8.0 Mbps", "Mbps")
            try expectEqual(Fmt.bitrate(96_000), "96 kbps", "kbps")
            try expectEqual(Fmt.bitrate(0), "—", "非法")
            try expectEqual(Fmt.mbpsNumber(2_500_000), "2.5", "一位小数")
            try expectEqual(Fmt.mbpsNumber(12_000_000), "12", "整数不带小数")
        }
        h.run("路径缩写") {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let abbreviated = Fmt.abbreviatedPath(home.appendingPathComponent("Movies/a.mp4"))
            try expect(abbreviated.hasPrefix("~/"), "家目录缩写：\(abbreviated)")
            let outside = Fmt.abbreviatedPath(URL(fileURLWithPath: "/Volumes/USB/a.mp4"))
            try expectEqual(outside, "/Volumes/USB/a.mp4", "非家目录原样")
        }
        h.run("声道文案") {
            try expectEqual(Fmt.channels(1), "单声道", "单声道")
            try expectEqual(Fmt.channels(2), "立体声", "立体声")
            try expectEqual(Fmt.channels(0), "—", "未知")
        }
    }

    await h.suite("硬件能力探测") {
        h.run("探测本机编码器列表") {
            let capabilities = VideoToolboxCapabilities.probe()
            #if arch(arm64)
            try expect(!capabilities.encoders.isEmpty, "Apple Silicon 应有 VideoToolbox 编码器")
            try expect(capabilities.isReady, "本机应有 H.264 硬件编码器")
            #endif
            try expect(VideoToolboxCapabilities.fourCCString(0x61766331) == "avc1", "fourCC 可读化")
            try expect(!VideoToolboxCapabilities.fourCCString(0).isEmpty, "0 值有兜底文案")
        }
        h.run("编码器匹配：ProRes 家族兜底") {
            let proRes = EncoderInfo(name: "Apple ProRes Encoder", encoderID: "com.apple.prores", isHardwareAccelerated: true, codecFourCC: "apcn", codec: .proRes422)
            let capabilities = HardwareCapabilities(encoders: [proRes], h264HardwareDecode: true)
            try expect(capabilities.hardwareEncoder(for: .proRes4444) != nil, "ProRes 家族共用编码器")
            try expect(capabilities.hardwareEncoder(for: .h264) == nil, "无 H.264 编码器")
            try expect(!capabilities.isReady, "缺 H.264 不算就绪")
            try expect(capabilities.unavailableReason != nil, "有不可用原因")
        }
        h.run("摘要文案") {
            let h264 = EncoderInfo(name: "H264", encoderID: "com.apple.h264", isHardwareAccelerated: true, codecFourCC: "avc1", codec: .h264)
            let capabilities = HardwareCapabilities(encoders: [h264], h264HardwareDecode: true)
            try expectEqual(capabilities.summaryText, "HW · H.264", "摘要含命中编码")
            let none = HardwareCapabilities(encoders: [], h264HardwareDecode: false)
            try expectEqual(none.summaryText, "未检测到硬件编码器", "空列表文案")
        }
    }
}

/// 复刻 `QueueStore.unconfirmedMovieJobs` 的拦截语义（QueueStore 级联 UI，不进 harness；
/// 应用侧实现为 `state == .queued && needsMetadataConfirmation` 的纯过滤，行为以此为准）。
enum QueueStoreStartPredicate {
    static func isUnconfirmed(_ job: TranscodeJob) -> Bool {
        job.state == .queued && job.needsMetadataConfirmation
    }
}

private func expectNotNil<T>(_ value: T?, _ message: String, file: String = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        throw TestFailure(message: message, file: file, line: line)
    }
    return value
}
