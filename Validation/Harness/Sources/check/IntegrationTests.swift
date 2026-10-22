@preconcurrency import AVFoundation
import Foundation

// MARK: - 集成测试（真实编码；设计文档 §11 集成测试清单）
// 用 AVAssetWriter 现场生成 2 秒测试片，仓库不放大文件；无硬件编码器时整段跳过。

@MainActor
func runIntegrationTests() async {
    let h = Harness.shared

    // 环境门槛：无硬件 H.264/HEVC 编码器时跳过全部真实编码用例（对齐 §11「无硬件编码器 → 期望错误/跳过」）
    let capabilities = VideoToolboxCapabilities.probe()
    guard capabilities.hardwareEncoder(for: .h264) != nil else {
        h.markSkipped("集成测试（本机没有 H.264 硬件编码器，真实编码用例无法执行）")
        return
    }
    let hevcAvailable = capabilities.hardwareEncoder(for: .hevc) != nil

    let directory = try! Artifacts.subdirectory("integration")
    let outputs = directory.appendingPathComponent("outputs", isDirectory: true)
    try! FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)

    func sourceClip(_ name: String, spec: (URL) throws -> ClipFactory.Spec) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try await ClipFactory.generate(try spec(url))
        }
        return url
    }

    func makeRequest(input: URL, output: URL, codec: VideoCodec, container: MediaContainer) -> TranscodeRequest {
        // 引擎要求显式编码器 ID（requireHardware = true 时；应用由 QueueStore 传入，harness 自己探测）
        let encoderID = VideoToolboxCapabilities.probe().hardwareEncoder(for: codec)?.encoderID
        var request = TranscodeRequest(
            inputURL: input,
            outputURL: output,
            videoCodec: codec,
            container: container,
            resolution: .source,
            frameRate: .source,
            averageBitrate: codec.isProRes ? nil : 8_000_000,
            audioBitrate: 192_000,
            audioMaxChannels: 2,
            audioSampleRate: nil,
            audioPCMSampleBitDepth: codec.isProRes ? 16 : nil,
            requireHardware: true,
            encoderID: encoderID,
            metadata: nil,
            posterData: nil
        )
        request.bitrateRange = codec.isProRes ? 40_000_000...400_000_000 : 2_500_000...12_000_000
        return request
    }

    func run(_ request: TranscodeRequest) async throws -> TranscodeOutcome {
        let engine = TranscodeEngine()
        return try await engine.run(request) { _ in }
    }

    func assertNoTempFiles(in directory: URL) throws {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix(OutputPlanner.tempPrefix) && $0.hasSuffix(OutputPlanner.tempSuffix) } ?? []
        try expect(leftovers.isEmpty, "不应残留临时文件：\(leftovers)")
    }

    func makeQualityRequest(_ quality: Double, name: String) -> TranscodeRequest {
        var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent(name), codec: .h264, container: .mp4)
        request.averageBitrate = nil
        request.bitrateMode = .quality
        request.quality = quality
        return request
    }

    let h264Source = try! await sourceClip("源-1080p-h264.mp4") { url in
        ClipFactory.Spec(url: url, size: CGSize(width: 1920, height: 1080), codec: .h264, bitrate: 6_000_000)
    }
    let hevcSource = hevcAvailable
        ? try! await sourceClip("源-1080p-hevc.mp4") { url in
            ClipFactory.Spec(url: url, size: CGSize(width: 1920, height: 1080), codec: .hevc, bitrate: 5_000_000)
        }
        : h264Source
    let portraitSource = try! await sourceClip("源-竖屏-h264.mp4") { url in
        var spec = ClipFactory.Spec(url: url, size: CGSize(width: 1280, height: 720), codec: .h264, bitrate: 4_000_000)
        spec.transform = CGAffineTransform(rotationAngle: .pi / 2)
        return spec
    }
    let silentSource = try! await sourceClip("源-无音轨.mp4") { url in
        var spec = ClipFactory.Spec(url: url, size: CGSize(width: 1280, height: 720), codec: .h264, bitrate: 4_000_000)
        spec.withAudio = false
        return spec
    }
    let taggedSource = try! await sourceClip("源-带元数据.mp4") { url in
        var spec = ClipFactory.Spec(url: url, size: CGSize(width: 1280, height: 720), codec: .h264, bitrate: 4_000_000)
        spec.metadata = try ClipFactory.sourceMetadata(
            title: "源标题测试", artist: "源作者测试", creationDate: "2025-01-02", overview: "源简介测试"
        )
        return spec
    }

    await h.suite("集成：H.264 + AAC → MP4") {
        await h.runAsync("真实编码成功，规格读回一致") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-h264.mp4")
            let request = makeRequest(input: h264Source, output: output, codec: .h264, container: .mp4)
            let outcome = try await run(request)
            try expect(FileManager.default.fileExists(atPath: output.path), "输出文件存在")
            try expect(outcome.bytes > 100_000, "输出有实际内容：\(outcome.bytes) 字节")
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            let info = try await OutputProbe.info(of: output)
            try expectEqual(info.video?.codecFourCC, "avc1", "输出编码 H.264")
            try expectEqual(info.audio?.codecFourCC.trimmingCharacters(in: .whitespaces), "aac", "输出音频 AAC")
            try expect(abs(info.durationSeconds - 2.0) < 0.5, "时长约 2 秒：\(info.durationSeconds)")
            try expectEqual(info.video?.displayWidth, 1920, "宽度保持")
            try expectEqual(info.audio?.channelCount, 2, "立体声")
            try assertNoTempFiles(in: outputs)
        }
    }

    await h.suite("集成：HEVC + AAC → MP4") {
        await h.runAsync("真实编码成功，HEVC 读回") {
            try requireHardwareEncoder(.hevc)
            guard hevcAvailable else { throw SkipReason(message: "本机无 HEVC 硬件编码器") }
            let output = outputs.appendingPathComponent("out-hevc.mp4")
            let request = makeRequest(input: hevcSource, output: output, codec: .hevc, container: .mp4)
            let outcome = try await run(request)
            try expect(FileManager.default.fileExists(atPath: output.path), "输出文件存在")
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警")
            let info = try await OutputProbe.info(of: output)
            try expectEqual(info.video?.codecFourCC, "hvc1", "输出编码 HEVC")
            try expectEqual(info.audio?.codecFourCC.trimmingCharacters(in: .whitespaces), "aac", "音频 AAC")
        }
    }

    await h.suite("集成：ProRes 422 + PCM → MOV") {
        await h.runAsync("PCM 16-bit 写入并读回") {
            try requireHardwareEncoder(.proRes422)
            let output = outputs.appendingPathComponent("out-prores16.mov")
            var request = makeRequest(input: h264Source, output: output, codec: .proRes422, container: .mov)
            request.audioPCMSampleBitDepth = 16
            request.averageBitrate = nil
            let outcome = try await run(request)
            try expect(FileManager.default.fileExists(atPath: output.path), "输出文件存在")
            try expect(outcome.bytes > 1_000_000, "ProRes 输出体积应可观：\(outcome.bytes) 字节")
            try expectEqual(try await OutputProbe.audioFourCC(of: output), "lpcm", "音频 LPCM")
            try expectEqual(try await OutputProbe.pcmBitDepth(of: output), 16, "16-bit 位深")
        }
        await h.runAsync("PCM 24-bit 写入并读回") {
            try requireHardwareEncoder(.proRes422)
            let output = outputs.appendingPathComponent("out-prores24.mov")
            var request = makeRequest(input: h264Source, output: output, codec: .proRes422, container: .mov)
            request.audioPCMSampleBitDepth = 24
            request.averageBitrate = nil
            _ = try await run(request)
            try expectEqual(try await OutputProbe.pcmBitDepth(of: output), 24, "24-bit 位深")
        }
    }

    await h.suite("集成：旋转竖屏") {
        await h.runAsync("90° transform 摆正，提示旋转慢路径") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-portrait.mp4")
            let request = makeRequest(input: portraitSource, output: output, codec: .h264, container: .mp4)
            let outcome = try await run(request)
            try expect(outcome.usedComposition, "旋转应走合成慢路径")
            try expect(outcome.notes.contains { $0.contains("旋转") }, "提示旋转：\(outcome.notes)")
            let info = try await OutputProbe.info(of: output)
            try expectEqual(info.video?.displayWidth, 720, "显示宽 720")
            try expectEqual(info.video?.displayHeight, 1280, "显示高 1280")
        }
    }

    await h.suite("集成：质量优先") {
        await h.runAsync("体积随质量单调（0.9 > 0.15）") {
            try requireHardwareEncoder()
            async let high = run(makeQualityRequest(0.9, name: "out-quality-high.mp4"))
            async let low = run(makeQualityRequest(0.15, name: "out-quality-low.mp4"))
            let (highOutcome, lowOutcome) = try await (high, low)
            try expect(highOutcome.bytes > lowOutcome.bytes, "0.9 体积 \(highOutcome.bytes) 应大于 0.15 体积 \(lowOutcome.bytes)")
        }
    }

    await h.suite("集成：目标大小") {
        await h.runAsync("正常换算成功") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-target-ok.mp4"), codec: .h264, container: .mp4)
            request.averageBitrate = nil
            request.bitrateMode = .targetSize
            request.targetSizeBytes = 2_000_000
            let outcome = try await run(request)
            try expect(FileManager.default.fileExists(atPath: outcome.outputURL.path), "输出存在")
            try expect(outcome.bytes > 200_000 && outcome.bytes < 8_000_000, "体积在合理区间：\(outcome.bytes) 字节")
        }
        await h.runAsync("极小目标触发夹取提示") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-target-clamp.mp4"), codec: .h264, container: .mp4)
            request.averageBitrate = nil
            request.bitrateMode = .targetSize
            request.targetSizeBytes = 50_000
            let outcome = try await run(request)
            try expect(outcome.notes.contains { $0.contains("超出预设范围") }, "应有夹取提示：\(outcome.notes)")
        }
    }

    await h.suite("集成：磁盘预检") {
        await h.runAsync("5 TB 目标 → lowDiskSpace，且不落临时文件") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-disk.mp4"), codec: .h264, container: .mp4)
            request.averageBitrate = nil
            request.bitrateMode = .targetSize
            request.targetSizeBytes = 5_000_000_000_000
            do {
                _ = try await run(request)
                throw TestFailure(message: "应因磁盘空间不足失败", file: #filePath, line: #line)
            } catch let error as TranscodeEngineError {
                guard case .lowDiskSpace = error else {
                    throw TestFailure(message: "应为 lowDiskSpace：\(error)", file: #filePath, line: #line)
                }
                try expect(error.errorDescription?.contains("磁盘空间不足") == true, "人话提示")
            }
            try expect(!FileManager.default.fileExists(atPath: outputs.appendingPathComponent("out-disk.mp4").path), "不应有输出")
            try assertNoTempFiles(in: outputs)
        }
    }

    await h.suite("集成：无音轨源") {
        await h.runAsync("输出成功且无音轨") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-silent.mp4")
            let outcome = try await run(makeRequest(input: silentSource, output: output, codec: .h264, container: .mp4))
            try expect(FileManager.default.fileExists(atPath: output.path), "输出存在")
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            let info = try await OutputProbe.info(of: output)
            try expect(info.audio == nil, "输出无音轨")
            try expect(info.video != nil, "视频轨正常")
        }
    }

    await h.suite("集成：取消与清理") {
        await h.runAsync("启动即取消：无输出、无临时文件") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-cancel.mp4")
            let request = makeRequest(input: h264Source, output: output, codec: .h264, container: .mp4)
            let engine = TranscodeEngine()
            let task = Task.detached(priority: .userInitiated) {
                try await engine.run(request) { _ in }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            engine.cancel()
            do {
                _ = try await task.value
                throw TestFailure(message: "取消后应抛出 cancelled", file: #filePath, line: #line)
            } catch let error as TranscodeEngineError {
                try expectEqual(error, TranscodeEngineError.cancelled, "取消错误")
            }
            try expect(!FileManager.default.fileExists(atPath: output.path), "不应有输出文件")
            try assertNoTempFiles(in: outputs)
        }
    }

    await h.suite("集成：重名保护") {
        await h.runAsync("已存在的输出不被覆盖（-1 由 planner 保证）") {
            try requireHardwareEncoder()
            let existing = outputs.appendingPathComponent("dup.mp4")
            FileManager.default.createFile(atPath: existing.path, contents: Data([0xFF]))
            let planned = OutputPlanner.uniqueOutputURL(directory: outputs, baseName: "dup", fileExtension: "mp4")
            try expectEqual(planned.lastPathComponent, "dup-1.mp4", "规划到 -1")
            _ = try await run(makeRequest(input: h264Source, output: planned, codec: .h264, container: .mp4))
            let original = try? Data(contentsOf: existing)
            try expectEqual(original?.count, 1, "原文件未被覆盖")
            try expect(FileManager.default.fileExists(atPath: planned.path), "新文件写到 -1")
        }
    }

    await h.suite("集成：电影元数据写入") {
        let movieMetadata = MovieMetadata(
            title: "测试电影",
            originalTitle: "A Test Movie",
            year: 2024,
            releaseDate: "2024-05-17",
            overview: "这是一部用于验证的电影。",
            genres: ["科幻", "剧情"],
            director: "张三",
            cast: ["李四", "王五"],
            tmdbID: 12_345,
            imdbID: "tt1234567",
            posterPath: nil,
            source: .tmdb
        )
        await h.runAsync("写入 MP4（itsk），读回标题/日期/类型") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-movie-mp4.mp4")
            var request = makeRequest(input: h264Source, output: output, codec: .h264, container: .mp4)
            request.metadata = movieMetadata
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "写入自检无告警：\(outcome.verificationIssues)")
            try expectEqual(
                try await OutputProbe.metadataString(.iTunesMetadataSongName, of: output),
                "测试电影",
                "标题读回"
            )
            try expectEqual(
                try await OutputProbe.metadataString(.iTunesMetadataReleaseDate, of: output),
                "2024-05-17",
                "上映日期读回"
            )
            try expectEqual(
                try await OutputProbe.metadataString(.iTunesMetadataUserGenre, of: output),
                "科幻 / 剧情",
                "类型读回"
            )
            let overview = try await OutputProbe.metadataString(.iTunesMetadataDescription, of: output)
            try expect(overview?.contains("验证") == true, "简介读回：\(String(describing: overview))")
        }
        await h.runAsync("写入 MOV（QuickTime），读回标题/简介") {
            try requireHardwareEncoder(.proRes422)
            let output = outputs.appendingPathComponent("out-movie-mov.mov")
            var request = makeRequest(input: h264Source, output: output, codec: .proRes422, container: .mov)
            request.audioPCMSampleBitDepth = 16
            request.averageBitrate = nil
            request.metadata = movieMetadata
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "写入自检无告警：\(outcome.verificationIssues)")
            try expectEqual(
                try await OutputProbe.metadataString(.quickTimeMetadataTitle, of: output),
                "测试电影",
                "QuickTime 标题读回"
            )
            let overview = try await OutputProbe.metadataString(.quickTimeMetadataDescription, of: output)
            try expect(overview?.contains("验证") == true, "简介读回")
        }
        await h.runAsync("组合参数：720p + 关键帧 5 秒 + 元数据") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-movie-combo.mp4")
            var request = makeRequest(input: h264Source, output: output, codec: .h264, container: .mp4)
            request.resolution = .r720
            request.keyframeInterval = .s5
            request.metadata = movieMetadata
            let outcome = try await run(request)
            try expect(FileManager.default.fileExists(atPath: output.path), "输出存在")
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            let info = try await OutputProbe.info(of: output)
            try expectEqual(info.video?.displayWidth, 1280, "缩放到 720p")
            try expectEqual(info.video?.displayHeight, 720, "高度")
            try expectEqual(
                try await OutputProbe.metadataString(.iTunesMetadataSongName, of: output),
                "测试电影",
                "元数据与缩放参数同时生效"
            )
        }
    }

    await h.suite("集成：非电影元数据保留") {
        // 注：AVFoundation 的 commonMetadata 归一不映射 itsk/©day（创建日期），
        // 因此 MP4 源的可读集合为标题/作者/简介；引擎按可读字段保留（读不到就不写、不告警）。
        await h.runAsync("MP4 → MP4：itsk 保留标题/作者/简介") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-keep-mp4.mp4")
            let outcome = try await run(makeRequest(input: taggedSource, output: output, codec: .h264, container: .mp4))
            try expectEqual(outcome.verificationIssues.count, 0, "保留自检无告警：\(outcome.verificationIssues)")
            try expectEqual(
                try await OutputProbe.metadataString(.iTunesMetadataSongName, of: output),
                "源标题测试",
                "标题保留"
            )
            try expectEqual(
                try await OutputProbe.metadataString(.iTunesMetadataArtist, of: output),
                "源作者测试",
                "作者保留"
            )
            let description = try await OutputProbe.metadataString(.iTunesMetadataDescription, of: output)
            try expect(description?.contains("源简介") == true, "简介保留：\(String(describing: description))")
        }
        await h.runAsync("MP4 → MOV：QuickTime 写法保留") {
            try requireHardwareEncoder()
            let output = outputs.appendingPathComponent("out-keep-mov.mov")
            var request = makeRequest(input: taggedSource, output: output, codec: .proRes422, container: .mov)
            request.audioPCMSampleBitDepth = 16
            request.averageBitrate = nil
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "保留自检无告警：\(outcome.verificationIssues)")
            try expectEqual(
                try await OutputProbe.metadataString(.quickTimeMetadataTitle, of: output),
                "源标题测试",
                "QuickTime 标题保留"
            )
            let description = try await OutputProbe.metadataString(.quickTimeMetadataDescription, of: output)
            try expect(description?.contains("源简介") == true, "QuickTime 简介保留")
        }
    }

    await h.suite("集成：预检拒绝") {
        await h.runAsync(".txt → unsupportedContainer") {
            let textFile = directory.appendingPathComponent("not-video.txt")
            try Data("这不是视频".utf8).write(to: textFile)
            try await Harness.expectError(TranscodeEngineError.unsupportedContainer("txt")) {
                _ = try await run(makeRequest(input: textFile, output: outputs.appendingPathComponent("out-none.mp4"), codec: .h264, container: .mp4))
            }
        }
        await h.runAsync("纯音频 → noVideoTrack") {
            let audioOnly = directory.appendingPathComponent("audio-only.mp4")
            try await ClipFactory.generate(ClipFactory.Spec(
                url: audioOnly, size: .zero, duration: 1, audioOnly: true
            ))
            try await Harness.expectError(TranscodeEngineError.noVideoTrack) {
                _ = try await run(makeRequest(input: audioOnly, output: outputs.appendingPathComponent("out-novideo.mp4"), codec: .h264, container: .mp4))
            }
        }
        await h.runAsync("ProRes + MP4 容器兜底拒绝") {
            try requireHardwareEncoder()
            try await Harness.expectError(TranscodeEngineError.proResRequiresMOV) {
                _ = try await run(makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-pr-mp4.mp4"), codec: .proRes422, container: .mp4))
            }
        }
    }

    await h.suite("集成：画质修复（P7.2 冒烟，§7.6）") {
        // 分辨率锁定：开启增强但选了缩放档位 → 明确失败
        await h.runAsync("增强 + 非保持源 → enhancementResolutionConflict") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-enh-lock.mp4"), codec: .h264, container: .mp4)
            request.resolution = .r720
            request.enhancement = EnhancementSetting.defaultNeural
            try await Harness.expectError(TranscodeEngineError.enhancementResolutionConflict) {
                _ = try await run(request)
            }
        }
        // 滤镜链端到端：360p → 2x = 720p 输出（GPU 路径，快）
        await h.runAsync("滤镜链端到端：360p → 2x 输出 720p") {
            try requireHardwareEncoder()
            let smallSource = try await sourceClip("源-360p.mp4") { url in
                ClipFactory.Spec(url: url, size: CGSize(width: 640, height: 360), codec: .h264, bitrate: 1_500_000)
            }
            var request = makeRequest(input: smallSource, output: outputs.appendingPathComponent("out-enhance-filter.mp4"), codec: .h264, container: .mp4)
            request.enhancement = EnhancementSetting.defaultFilter
            let outcome = try await run(request)
            try expect(FileManager.default.fileExists(atPath: outcome.outputURL.path), "输出存在")
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expectEqual(info.video?.displayWidth, 1280, "输出宽 = 源 ×2")
            try expectEqual(info.video?.displayHeight, 720, "输出高 = 源 ×2")
            try assertNoTempFiles(in: outputs)
        }
        // 神经模式：模型在 harness 包内不存在 → 明确失败不静默回退；
        // 若未来把模型放进 harness 包，则退化为真实端到端断言（两档通用）。
        await h.runAsync("神经模式：模型缺失明确失败 / 有模型则端到端") {
            try requireHardwareEncoder()
            let smallSource = try await sourceClip("源-360p.mp4") { url in
                ClipFactory.Spec(url: url, size: CGSize(width: 640, height: 360), codec: .h264, bitrate: 1_500_000)
            }
            var request = makeRequest(input: smallSource, output: outputs.appendingPathComponent("out-enhance-neural.mp4"), codec: .h264, container: .mp4)
            request.enhancement = EnhancementSetting.defaultNeural
            let modelAvailable = Bundle.main.url(
                forResource: NeuralUpscalerModel.fast.resourceName, withExtension: "mlmodelc"
            ) != nil
            if modelAvailable {
                let outcome = try await run(request)
                let info = try await OutputProbe.info(of: outcome.outputURL)
                try expectEqual(info.video?.displayWidth, 1280, "神经超分输出宽 ×2")
                try expectEqual(info.video?.displayHeight, 720, "神经超分输出高 ×2")
            } else {
                do {
                    _ = try await run(request)
                    throw TestFailure(message: "模型缺失时应失败", file: #filePath, line: #line)
                } catch let error as TranscodeEngineError {
                    guard case .enhancementUnavailable = error else {
                        throw TestFailure(message: "应为 enhancementUnavailable：\(error)", file: #filePath, line: #line)
                    }
                }
            }
        }
    }

    // P7.4 画质修复验收（单帧 / tile 接缝 / 端到端 / 吞吐；设计文档 §7.6）
    await runEnhancementAcceptance()

    await h.suite("集成：样片试编码（§7.8）") {
        // 引擎 sourceTimeRange 截取：段时长 ≈ 请求时长，音视频同步输出
        await h.runAsync("引擎 sourceTimeRange：中段截取 4 秒") {
            try requireHardwareEncoder()
            let longSource = try await sourceClip("源-10秒-360p.mp4") { url in
                ClipFactory.Spec(
                    url: url, size: CGSize(width: 640, height: 360),
                    codec: .h264, bitrate: 1_500_000, duration: 10
                )
            }
            var request = makeRequest(input: longSource, output: outputs.appendingPathComponent("out-range.mp4"), codec: .h264, container: .mp4)
            request.sourceTimeRange = CMTimeRange(
                start: CMTime(seconds: 3, preferredTimescale: 600),
                duration: CMTime(seconds: 4, preferredTimescale: 600)
            )
            let outcome = try await run(request)
            try expect(abs(outcome.durationSeconds - 4.0) < 0.6, "段时长应 ≈ 4 秒：\(outcome.durationSeconds)")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expect(abs(info.durationSeconds - 4.0) < 0.6, "读回时长 ≈ 4 秒：\(info.durationSeconds)")
            try expect(info.audio != nil, "音频轨随段截取输出（同步）")
        }

        // 端到端 probe：16 秒 360p 片 → 3 段实测 → 码率合理、临时输出清理
        await h.runAsync("端到端 probe：3 段实测 + 临时清理") {
            try requireHardwareEncoder()
            let longSource = try await sourceClip("源-16秒-360p.mp4") { url in
                ClipFactory.Spec(
                    url: url, size: CGSize(width: 640, height: 360),
                    codec: .h264, bitrate: 1_500_000, duration: 16
                )
            }
            let request = makeRequest(input: longSource, output: outputs.appendingPathComponent("unused.mp4"), codec: .h264, container: .mp4)
            let counter = LockedCounter()
            let result = try await BitrateProbeService.run(request: request, sourceDuration: 16) { _, _, _ in
                counter.increment()
            }
            try expectEqual(counter.value, 3, "每段一次进度回调")
            try expectEqual(result.segmentBitrates.count, 3, "3 段码率")
            try expect(result.segmentBitrates.allSatisfy { $0 > 100_000 && $0 < 30_000_000 }, "段码率在合理区间：\(result.segmentBitrates)")
            try expect(abs(result.sampledSeconds - 12.0) < 1.5, "采样总时长 ≈ 12 秒：\(result.sampledSeconds)")
            try expect(result.averageBitrate > 100_000, "平均码率 > 100 kbps：\(result.averageBitrate)")
            let estimate = result.estimatedBytes(forFullDuration: 16)
            try expect(estimate > 0, "全片外推体积 > 0：\(estimate)")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("chrysalis-probe-") } ?? []
            try expect(leftovers.isEmpty, "探测临时目录应清理：\(leftovers)")
        }

        // 探测结果驱动磁盘预检：注入超大实测码率 → lowDiskSpace
        await h.runAsync("实测码率驱动磁盘预检：超大值触发 lowDiskSpace") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-probe-disk.mp4"), codec: .h264, container: .mp4)
            request.measuredTotalBitrate = 1_000_000_000_000_000  // 1 Pbps → 预计 250 TB
            do {
                _ = try await run(request)
                throw TestFailure(message: "应因实测码率外推体积超出磁盘空间失败", file: #filePath, line: #line)
            } catch let error as TranscodeEngineError {
                guard case .lowDiskSpace = error else {
                    throw TestFailure(message: "应为 lowDiskSpace：\(error)", file: #filePath, line: #line)
                }
            }
        }
    }

    await h.suite("集成：视频体检（§7.10）") {
        // 快速体检：测试片字段断言（读得到即报；结论映射走预检口径）
        await h.runAsync("quickReport：规格 / 音轨 / 结论 / moov 检测") {
            try requireHardwareEncoder()
            let report = await MediaProbeService.quickReport(url: h264Source)
            try expectEqual(report.verdict, ProbeVerdict.ready, "1080p H.264 测试片应绿灯：\(report.verdictMessage)")
            try expectEqual(report.video?.codecFourCC, "avc1", "编码 fourCC")
            try expectEqual(report.video?.displayWidth, 1920, "宽度")
            try expect(abs(report.durationSeconds - 2.0) < 0.5, "时长 ≈ 2 秒：\(report.durationSeconds)")
            try expectEqual(report.audioTracks.count, 1, "单音轨")
            try expectEqual(report.audioTracks.first?.codecName, "AAC", "音轨 AAC")
            try expectEqual(report.isPlayable, true, "可播放")
            try expectEqual(report.isProtected, false, "无 DRM")
            try expect(report.isMoovAtFront != nil, "MP4 容器应执行 moov 检测")
            try expect(report.video?.hardwareDecodeSupported == true, "H.264 硬解可用")
            try expect(report.fileSizeBytes > 0, "文件大小")
        }

        // 深度探测：16 秒片 → 3 段抽样 → 码率分布 / GOP / 恒定帧率不误报 VFR
        await h.runAsync("deepScan：段码率分布 + GOP + VFR 不误报") {
            try requireHardwareEncoder()
            let longSource = try await sourceClip("源-16秒-360p.mp4") { url in
                ClipFactory.Spec(
                    url: url, size: CGSize(width: 640, height: 360),
                    codec: .h264, bitrate: 1_500_000, duration: 16
                )
            }
            let report = await MediaProbeService.quickReport(url: longSource)
            try expect(report.durationSeconds > 15, "深度探测前置：时长足够")
            let deep = await MediaProbeService.deepScan(url: longSource, report: report)
            try expect(deep != nil, "深度探测应有结果")
            guard let stats = deep else { return }
            try expectEqual(stats.sampledSegments, 3, "3 段抽样")
            try expect(stats.sampledSeconds > 4, "采样时长 > 4 秒：\(stats.sampledSeconds)")
            try expect(stats.segmentBitrates != nil, "段码率分布应有值")
            guard let bitrates = stats.segmentBitrates else { return }
            try expect(bitrates.min > 0 && bitrates.max < 30_000_000, "段码率合理区间：\(bitrates)")
            try expect(stats.gopSizes != nil, "GOP 分布应有值")
            guard let gop = stats.gopSizes else { return }
            try expect(gop.average > 0 && gop.average <= 120, "GOP 合理（ClipFactory maxKeyFrame = 2×fps）：\(gop)")
            try expectEqual(stats.isVFR, false, "恒定 30fps 测试片不应误报 VFR：ratio=\(String(describing: stats.frameIntervalRatio)) avg=\(String(describing: stats.averageFrameInterval))")
            try expect(stats.frameIntervalRatio != nil, "帧间隔比值应有值")
            guard let ratio = stats.frameIntervalRatio else { return }
            try expect(ratio < 1.5, "比值低于阈值：\(ratio)")
        }

        // Markdown 导出包含深度统计与 moov 行
        await h.runAsync("Markdown：含深度统计与 moov 行") {
            try requireHardwareEncoder()
            let longSource = try await sourceClip("源-16秒-360p.mp4") { url in
                ClipFactory.Spec(
                    url: url, size: CGSize(width: 640, height: 360),
                    codec: .h264, bitrate: 1_500_000, duration: 16
                )
            }
            var report = await MediaProbeService.quickReport(url: longSource)
            report.deep = await MediaProbeService.deepScan(url: longSource, report: report)
            let markdown = ProbeReportMarkdown.generate(report)
            try expect(markdown.contains("段码率分布"), "含码率分布行")
            try expect(markdown.contains("关键帧间隔（GOP）"), "含 GOP 行")
            try expect(markdown.contains("moov 前置"), "含 moov 行")
        }

        // 假 4K（§7.14）：真 4K 不检出
        await h.runAsync("假 4K：真 4K 不检出") {
            try requireHardwareEncoder()
            let real4K = try await sourceClip("源-真4k.mp4") { url in
                var spec = ClipFactory.Spec(
                    url: url, size: CGSize(width: 3840, height: 2160),
                    codec: .h264, bitrate: 20_000_000, duration: 2, fps: 24
                )
                spec.detailBoost = true
                return spec
            }
            let report = await MediaProbeService.quickReport(url: real4K)
            let verdict = try await UpscaleDetector.detect(
                url: real4K, sourceWidth: 3840, sourceHeight: 2160,
                sourceDuration: report.durationSeconds
            )
            try expect(!verdict.suspected, "真 4K 不应检出：\(verdict)")
        }

        // 假 4K（§7.14）：伪 4K（360p 放大）检出 + 建议档位
        await h.runAsync("假 4K：伪 4K 检出 + 建议档位") {
            try requireHardwareEncoder()
            let fake4K = try await sourceClip("源-伪4k.mp4") { url in
                var spec = ClipFactory.Spec(
                    url: url, size: CGSize(width: 3840, height: 2160),
                    codec: .h264, bitrate: 20_000_000, duration: 2, fps: 24
                )
                spec.upscaleFrom = CGSize(width: 640, height: 360)
                return spec
            }
            let report = await MediaProbeService.quickReport(url: fake4K)
            try expect(report.durationSeconds > 1, "伪 4K 片时长正常：\(report.durationSeconds) verdict=\(report.verdict)")
            let verdict = try await UpscaleDetector.detect(
                url: fake4K, sourceWidth: 3840, sourceHeight: 2160,
                sourceDuration: report.durationSeconds
            )
            try expect(verdict.suspected, "伪 4K 应检出：\(verdict)")
            try expect(verdict.suggestedLevel != nil, "应有建议档位：\(String(describing: verdict.suggestedLevel))")
        }

        // 去重（§7.14）：同内容不同尺寸（转码产物）互认（16 秒片保证 5 段抽帧）
        await h.runAsync("去重：同内容不同尺寸互认") {
            try requireHardwareEncoder()
            let source720 = try await sourceClip("源-720p-16秒.mp4") { url in
                ClipFactory.Spec(
                    url: url, size: CGSize(width: 1280, height: 720),
                    codec: .h264, bitrate: 3_000_000, duration: 16
                )
            }
            var request = makeRequest(input: source720, output: outputs.appendingPathComponent("out-dedup-480.mp4"), codec: .h264, container: .mp4)
            request.resolution = .r480
            let outcome = try await run(request)
            let original = try await VideoFingerprint.fingerprint(url: source720, fileName: "720", sourceDuration: 16)
            let downscaled = try await VideoFingerprint.fingerprint(url: outcome.outputURL, fileName: "480", sourceDuration: 16)
            try expect(original.frameHashes.count == 5, "original 5 帧指纹：\(original.frameHashes.count)")
            try expect(downscaled.frameHashes.count == 5, "downscaled 5 帧指纹：\(downscaled.frameHashes.count)")
            try expect(VideoFingerprint.isNearDuplicate(original, downscaled), "同内容不同尺寸应互认")
            try expect(VideoFingerprint.isNearDuplicate(downscaled, original), "对称互认")
        }
    }

    await h.suite("集成：音频响度标准化（§7.11）") {
        // 测量：ClipFactory 音频 = 440 Hz 正弦 0.25 幅度立体声，解析值 ≈ -12.7 LUFS
        await h.runAsync("measure：合成正弦响度符合解析值") {
            let measurement = try await LoudnessMeter.measure(url: h264Source, maxChannels: 2)
            try expect(abs(measurement.integratedLufs - -12.73) < 1.0, "440 Hz 0.25 幅度立体声 ≈ -12.7 LUFS：\(measurement.integratedLufs)")
            try expect(measurement.truePeakDb > -14 && measurement.truePeakDb < -10, "真峰 ≈ 0.25 幅度（-12 dBFS）：\(measurement.truePeakDb)")
            try expect(measurement.sampleCount > 80_000, "2 秒 48 kHz 样本量充足：\(measurement.sampleCount)")
        }

        // 端到端：目标 -14 LUFS → 输出实测命中 ±1 LU
        await h.runAsync("端到端：目标 -14 LUFS 输出实测命中") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-loudness.mp4"), codec: .h264, container: .mp4)
            request.loudness = LoudnessSetting(target: .lufs14)
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            try expect(outcome.notes.contains { $0.contains("响度实测") }, "notes 记录实测：\(outcome.notes)")
            let after = try await LoudnessMeter.measure(url: outcome.outputURL, maxChannels: 2)
            try expect(abs(after.integratedLufs - -14.0) < 1.0, "输出响度应命中 -14 ±1：\(after.integratedLufs)")
            try assertNoTempFiles(in: outputs)
        }

        // 默认关闭：行为不变
        await h.runAsync("关闭时不加响度 notes") {
            try requireHardwareEncoder()
            let request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-noloudness.mp4"), codec: .h264, container: .mp4)
            let outcome = try await run(request)
            try expect(!outcome.notes.contains { $0.contains("响度实测") }, "关闭时无响度记录")
        }
    }

    await h.suite("集成：语音转字幕（§7.13）") {
        // 设备端支持语言列表可查询（无需识别授权；数量随系统配置）
        await h.runAsync("设备端支持语言列表可查询") {
            let locales = SpeechTranscriber.supportedLocales()
            try expect(!locales.isEmpty, "本机应有至少一个设备端识别语言：\(locales.count)")
            try expect(locales.allSatisfy { !$0.identifier.isEmpty }, "locale 标识非空")
        }
    }

    await h.suite("集成：降帧感知帧混合（§7.12）") {
        let source60 = try! await sourceClip("源-60fps-360p.mp4") { url in
            ClipFactory.Spec(
                url: url, size: CGSize(width: 640, height: 360),
                codec: .h264, bitrate: 3_000_000, duration: 4, fps: 60
            )
        }

        // 混合降帧：60 → 30，输出帧率与时长正确、notes 有记录
        await h.runAsync("混合降帧：60→30 输出帧率与时长正确") {
            try requireHardwareEncoder()
            var request = makeRequest(input: source60, output: outputs.appendingPathComponent("out-blend.mp4"), codec: .h264, container: .mp4)
            request.frameRate = .fps30
            request.frameBlending = true
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            try expect(outcome.notes.contains { $0.contains("降帧混合") }, "notes 记录混合：\(outcome.notes)")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expect(abs((info.video?.frameRate ?? 0) - 30) < 1.0, "输出帧率 ≈ 30：\(String(describing: info.video?.frameRate))")
            try expect(abs(info.durationSeconds - 4.0) < 0.5, "时长 ≈ 4 秒：\(info.durationSeconds)")
            try expect(info.audio != nil, "音频不受影响")
            try assertNoTempFiles(in: outputs)
        }

        // 回归：关闭混合走丢帧路径（行为不变）
        await h.runAsync("关闭混合：丢帧路径回归") {
            try requireHardwareEncoder()
            var request = makeRequest(input: source60, output: outputs.appendingPathComponent("out-drop.mp4"), codec: .h264, container: .mp4)
            request.frameRate = .fps30
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            try expect(!outcome.notes.contains { $0.contains("降帧混合") }, "关闭时无混合记录")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expect(abs((info.video?.frameRate ?? 0) - 30) < 1.0, "输出帧率 ≈ 30：\(String(describing: info.video?.frameRate))")
        }

        // 不降帧场景：开关不生效（60fps 源保持帧率）
        await h.runAsync("保持帧率：开关无影响") {
            try requireHardwareEncoder()
            var request = makeRequest(input: source60, output: outputs.appendingPathComponent("out-noblend.mp4"), codec: .h264, container: .mp4)
            request.frameRate = .source
            request.frameBlending = true
            let outcome = try await run(request)
            try expect(outcome.notes.allSatisfy { !$0.contains("降帧混合") }, "不降帧时不记录混合：\(outcome.notes)")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expect(abs((info.video?.frameRate ?? 0) - 60) < 1.0, "帧率保持 60：\(String(describing: info.video?.frameRate))")
        }
    }

    await h.suite("集成：复古输出彩蛋（§7.15）") {
        // VHS：转码成功、规格不变、notes 记录
        await h.runAsync("VHS：转码成功且规格不变") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-vhs.mp4"), codec: .h264, container: .mp4)
            request.retroEffect = RetroEffectSetting(style: .vhs)
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            try expect(outcome.notes.contains { $0.contains("复古输出") }, "notes 记录复古输出：\(outcome.notes)")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expect(abs(info.durationSeconds - 2.0) < 0.5, "时长不变：\(info.durationSeconds)")
            try expectEqual(info.video?.displayWidth, 1920, "宽度不变")
            try expectEqual(info.video?.codecFourCC, "avc1", "编码不变")
            try assertNoTempFiles(in: outputs)
        }

        // 老 DV：转码成功、notes 记录时间戳
        await h.runAsync("老 DV：转码成功且记录时间戳") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-dv.mp4"), codec: .h264, container: .mp4)
            request.retroEffect = RetroEffectSetting(style: .dv)
            let outcome = try await run(request)
            try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
            try expect(outcome.notes.contains { $0.contains("老 DV") }, "notes 记录老 DV：\(outcome.notes)")
            let info = try await OutputProbe.info(of: outcome.outputURL)
            try expect(abs(info.durationSeconds - 2.0) < 0.5, "时长不变：\(info.durationSeconds)")
            try assertNoTempFiles(in: outputs)
        }

        // 互斥：复古 + 画质修复 → preparing 失败（引擎兜底）
        await h.runAsync("互斥：与画质修复同时开启报错") {
            try requireHardwareEncoder()
            var request = makeRequest(input: h264Source, output: outputs.appendingPathComponent("out-retro-conflict.mp4"), codec: .h264, container: .mp4)
            request.retroEffect = RetroEffectSetting(style: .vhs)
            request.enhancement = EnhancementSetting.defaultFilter
            do {
                _ = try await run(request)
                try expect(false, "应抛出互斥错误")
            } catch let error as TranscodeEngineError {
                try expect(error == .retroEnhancementConflict, "互斥错误：\(error)")
            }
        }

        // VHS 扫描线生效：直接处理测试帧，断言偶/奇行亮度差显著（40 行平均抵消噪点波动）
        await h.runAsync("VHS 扫描线：处理帧行间亮度差显著") {
            var pixelBuffer: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, 640, 360,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &pixelBuffer
            )
            try expect(status == kCVReturnSuccess, "测试帧创建成功")
            guard let source = pixelBuffer else { return }
            CVPixelBufferLockBaseAddress(source, [])
            if let base = CVPixelBufferGetBaseAddressOfPlane(source, 0) {
                memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * CVPixelBufferGetHeightOfPlane(source, 0))
            }
            if let base = CVPixelBufferGetBaseAddressOfPlane(source, 1) {
                memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * CVPixelBufferGetHeightOfPlane(source, 1))
            }
            CVPixelBufferUnlockBaseAddress(source, [])

            let filter = RetroFilter(
                style: .vhs, width: 640, height: 360,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                osdBaseDate: nil
            )
            let processed = try filter.process(pixelBuffer: source, pts: 1.0)

            CVPixelBufferLockBaseAddress(processed, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(processed, .readOnly) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(processed, 0)
            let base = CVPixelBufferGetBaseAddressOfPlane(processed, 0)!
            func rowAverage(_ y: Int) -> Double {
                let row = base.advanced(by: y * stride)
                var sum = 0
                for x in 0..<640 { sum += Int(row.load(fromByteOffset: x, as: UInt8.self)) }
                return Double(sum) / 640
            }
            var evenSum = 0.0
            var oddSum = 0.0
            for y in 40..<80 {
                let value = rowAverage(y)
                if y % 2 == 0 { evenSum += value } else { oddSum += value }
            }
            let even = evenSum / 20
            let odd = oddSum / 20
            try expect(abs(even - odd) > 2.0, "偶/奇行均值差应显著（扫描线）：even=\(String(format: "%.1f", even)) odd=\(String(format: "%.1f", odd))")
        }

        // 老 DV OSD 生效：处理帧右上角区域出现文本亮块（灰底 + 白字 → 亮度抬升）
        await h.runAsync("老 DV OSD：右上角出现文本亮块") {
            var pixelBuffer: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, 640, 360,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &pixelBuffer
            )
            try expect(status == kCVReturnSuccess, "测试帧创建成功")
            guard let source = pixelBuffer else { return }
            CVPixelBufferLockBaseAddress(source, [])
            if let base = CVPixelBufferGetBaseAddressOfPlane(source, 0) {
                memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * CVPixelBufferGetHeightOfPlane(source, 0))
            }
            if let base = CVPixelBufferGetBaseAddressOfPlane(source, 1) {
                memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * CVPixelBufferGetHeightOfPlane(source, 1))
            }
            CVPixelBufferUnlockBaseAddress(source, [])

            let filter = RetroFilter(
                style: .dv, width: 640, height: 360,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                osdBaseDate: Date(timeIntervalSince1970: 1_792_636_800)
            )
            let processed = try filter.process(pixelBuffer: source, pts: 1.0)

            CVPixelBufferLockBaseAddress(processed, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(processed, .readOnly) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(processed, 0)
            let base = CVPixelBufferGetBaseAddressOfPlane(processed, 0)!
            // OSD 区域：右上角 margin 4% ≈ 26px，文本块约 250×60；采样 (300..614, 24..84)
            func regionMax() -> UInt8 {
                var maxValue: UInt8 = 0
                for y in 24..<84 {
                    let row = base.advanced(by: y * stride)
                    for x in 300..<614 {
                        let value = row.load(fromByteOffset: x, as: UInt8.self)
                        if value > maxValue { maxValue = value }
                    }
                }
                return maxValue
            }
            let peak = regionMax()
            try expect(peak > 170, "OSD 区域应有亮色文本（灰底 128 + 白字）：peak=\(peak)")
        }
    }

    await h.suite("集成：内容复杂度热力图（§7.16）") {
        let staticSource = try! await sourceClip("源-静态场景.mp4") { url in
            ClipFactory.Spec(
                url: url, size: CGSize(width: 640, height: 360),
                codec: .h264, bitrate: 2_000_000, duration: 4, fps: 30,
                staticScene: true
            )
        }
        let busySource = try! await sourceClip("源-高细节场景.mp4") { url in
            ClipFactory.Spec(
                url: url, size: CGSize(width: 640, height: 360),
                codec: .h264, bitrate: 4_000_000, duration: 4, fps: 30,
                detailBoost: true
            )
        }

        // 链路：quickReport → analyze（与 ProbeStore 深度探测同口径）
        await h.runAsync("分析链路：12 采样点、分数在 [0,1]") {
            let report = await MediaProbeService.quickReport(url: busySource)
            try expect((report.video?.frameRate ?? 0) > 0, "帧率读回正常")
            let complexity = await ComplexityAnalyzer.analyze(
                url: busySource,
                frameRate: report.video?.frameRate ?? 30,
                sourceDuration: report.durationSeconds
            )
            try expect(complexity != nil, "复杂度分析有结果")
            guard let complexity else { return }
            try expectEqual(complexity.sampledPoints, 12, "12 个采样点")
            try expectEqual(complexity.segments.count, 12, "12 个分段")
            for segment in complexity.segments {
                try expect(segment.detail >= 0 && segment.detail <= 1, "细节分在 [0,1]：\(segment.detail)")
                try expect(segment.score >= 0 && segment.score <= 1, "综合分在 [0,1]：\(segment.score)")
                if let motion = segment.motion {
                    try expect(motion >= 0 && motion <= 1, "运动分在 [0,1]：\(motion)")
                }
            }
            try expect(complexity.segments.contains { $0.motion != nil }, "正常片源应有配对成功的运动分")
        }

        // 区分度：高细节片 detail 显著高于静态片；静态片运动分接近 0
        await h.runAsync("区分度：高细节 vs 静态") {
            let busy = await ComplexityAnalyzer.analyze(url: busySource, frameRate: 30, sourceDuration: 4)
            let still = await ComplexityAnalyzer.analyze(url: staticSource, frameRate: 30, sourceDuration: 4)
            try expect(busy != nil && still != nil, "两片分析成功")
            guard let busy, let still else { return }
            let busyDetail = busy.detail?.average ?? 0
            let stillDetail = still.detail?.average ?? 0
            try expect(busyDetail > stillDetail * 2.0, "高细节片 detail 均值应 ≥ 静态片 2 倍：\(String(format: "%.3f", busyDetail)) vs \(String(format: "%.3f", stillDetail))")
            let stillMotion = still.motion?.average ?? 1
            try expect(stillMotion < 0.1, "静态片运动分应接近 0（仅编码噪声）：\(String(format: "%.4f", stillMotion))")
        }
    }

    await h.suite("集成：音频提取（§7.17）") {
        // 波形分析：轨道信息正确、正弦包络非全零
        await h.runAsync("波形分析：非全零且轨道信息正确") {
            let analysis = try await AudioExtractor.analyze(url: h264Source)
            try expect(analysis != nil, "有音轨片分析成功")
            guard let analysis else { return }
            try expectEqual(analysis.channels, 2, "立体声")
            try expect(abs(analysis.sampleRate - 48_000) < 1, "48 kHz")
            try expect(abs(analysis.durationSeconds - 2.0) < 0.3, "时长 ≈ 2s：\(analysis.durationSeconds)")
            try expect(!analysis.envelope.isSilent, "正弦非静音")
            let peak = analysis.envelope.maxima.max() ?? 0
            try expect(peak > 0.15, "0.25 幅度正弦峰值应 > 0.15：\(peak)")
        }

        await h.runAsync("无音轨片返回 nil") {
            let analysis = try await AudioExtractor.analyze(url: silentSource)
            try expect(analysis == nil, "无音轨返回 nil")
        }

        // M4A：AAC 编码、时长一致、无视频轨（不走 MediaInspector.inspect——那是转码输入矩阵，不含音频容器）
        await h.runAsync("提取 M4A：读回 AAC、时长一致") {
            let output = outputs.appendingPathComponent("extract-audio.m4a")
            let final = try await AudioExtractor.extract(url: h264Source, format: .m4a, outputURL: output)
            try expect(FileManager.default.fileExists(atPath: final.path), "输出存在")
            let fourCC = try await OutputProbe.audioFourCC(of: final)
            try expectEqual(fourCC.trimmingCharacters(in: .whitespaces), "aac", "AAC 编码")
            let asset = AVURLAsset(url: final)
            let duration = (try await asset.load(.duration)).seconds
            try expect(abs(duration - 2.0) < 0.4, "时长 ≈ 源：\(duration)")
            let tracks = try await asset.load(.tracks)
            try expect(tracks.allSatisfy { $0.mediaType != .video }, "无视频轨")
            try assertNoTempFiles(in: outputs)
        }

        // WAV：LPCM 16-bit
        await h.runAsync("提取 WAV：读回 PCM 16-bit") {
            let output = outputs.appendingPathComponent("extract-audio.wav")
            let final = try await AudioExtractor.extract(url: h264Source, format: .wav, outputURL: output)
            let fourCC = try await OutputProbe.audioFourCC(of: final)
            try expectEqual(fourCC.trimmingCharacters(in: .whitespaces), "lpcm", "LPCM")
            let depth = try await OutputProbe.pcmBitDepth(of: final)
            try expectEqual(depth, 16, "16-bit PCM")
            try assertNoTempFiles(in: outputs)
        }

        // 重名：连续提取同格式不覆盖（-1 后缀）
        await h.runAsync("重名：连续提取同格式不覆盖") {
            let output = outputs.appendingPathComponent("extract-dup.m4a")
            let first = try await AudioExtractor.extract(url: h264Source, format: .m4a, outputURL: output)
            let second = try await AudioExtractor.extract(url: h264Source, format: .m4a, outputURL: output)
            try expect(first.lastPathComponent == "extract-dup.m4a", "首取原名：\(first.lastPathComponent)")
            try expect(second.lastPathComponent == "extract-dup-1.m4a", "重名 -1：\(second.lastPathComponent)")
            try expect(FileManager.default.fileExists(atPath: first.path), "首文件未被覆盖")
        }
    }
}

/// 硬件编码器门槛（缺则跳过用例）。
func requireHardwareEncoder(_ codec: VideoCodec = .h264) throws {
    guard VideoToolboxCapabilities.probe().hardwareEncoder(for: codec) != nil else {
        throw SkipReason(message: "本机没有 \(codec.displayName) 硬件编码器")
    }
}

/// 线程安全计数器（@Sendable 闭包内累加用）。
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
