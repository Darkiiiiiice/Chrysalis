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
}

/// 硬件编码器门槛（缺则跳过用例）。
func requireHardwareEncoder(_ codec: VideoCodec = .h264) throws {
    guard VideoToolboxCapabilities.probe().hardwareEncoder(for: codec) != nil else {
        throw SkipReason(message: "本机没有 \(codec.displayName) 硬件编码器")
    }
}
