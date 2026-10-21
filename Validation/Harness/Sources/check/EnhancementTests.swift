import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - P7.4 画质修复验收（设计文档 §7.6 验收清单）

enum EnhancementTests {
    /// 自然感合成帧（渐变 + 斜纹 + 噪点，P0 同款负载）：纯渐变对超分模型是分布外输入，会诱发边缘幻觉。
    static func naturalFrame(width: Int, height: Int, t: Double = 0.4) throws -> CVPixelBuffer {
        let buffer = try EnhancementSupport.makeBuffer(width: width, height: height)
        let context = CIContext(options: [.cacheIntermediates: false])
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: width, y: height)
        gradient.color0 = CIColor(red: 0.15, green: 0.25, blue: 0.45)
        gradient.color1 = CIColor(red: 0.85, green: 0.8, blue: 0.7)
        var image = (gradient.outputImage ?? CIImage.empty()).cropped(to: rect)

        let stripes = CIFilter.stripesGenerator()
        stripes.center = CGPoint(x: Double(width) * 0.45, y: Double(height) / 2)
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.2)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = Float(max(width / 24, 2))
        stripes.sharpness = 1.0
        if let stripesImage = stripes.outputImage {
            image = stripesImage.transformed(by: CGAffineTransform(translationX: CGFloat(t * 40), y: 0))
                .cropped(to: rect)
                .composited(over: image)
        }

        if let noise = CIFilter.randomGenerator().outputImage?
            .transformed(by: CGAffineTransform(translationX: CGFloat(t * 91), y: CGFloat(t * 57)))
            .cropped(to: rect) {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = noise
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.08)
            if let grain = matrix.outputImage {
                image = grain.composited(over: image)
            }
        }

        context.render(
            image,
            to: buffer,
            bounds: rect,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return buffer
    }

    /// 把两档模型复制进 harness 可执行目录，使神经模式可真实推理。
    /// 仓库内模型：`Validation/Models/build/`（App Resources 同源资产）。
    static func setupModels() throws {
        let repositoryRoot = Artifacts.root
            .deletingLastPathComponent()  // Validation/Harness
            .deletingLastPathComponent()  // Validation
            .deletingLastPathComponent()  // 仓库根
        let buildDirectory = repositoryRoot
            .appendingPathComponent("Validation", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
        guard let resources = Bundle.main.resourceURL else {
            throw SkipReason(message: "harness 可执行包没有资源目录，无法注入模型")
        }
        let fileManager = FileManager.default
        for model in NeuralUpscalerModel.allCases {
            guard let name = model.resourceName.split(separator: ".").last.map(String.init) else { continue }
            let source = buildDirectory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            let destination = resources.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else {
                throw SkipReason(message: "缺少模型 \(name).mlmodelc（先在 Validation/Models 跑转换）")
            }
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    /// 采样输出帧某一列的平均通道值（接缝检测用）。
    static func columnAverage(_ output: CVReadOnlyPixelBuffer, x: Int) -> Double {
        output.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var total = 0.0
            for y in 0..<height {
                let index = y * stride + x * 4
                total += Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])
            }
            return total / Double(height * 3)
        }
    }

    /// 同步裸推理（同步函数内 async 重载不可见，避免歧义）。
    static func bareTilePrediction(_ model: MLModel, tile: CVPixelBuffer) throws {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "frame": MLFeatureValue(pixelBuffer: tile),
        ])
        _ = try model.prediction(from: provider)
    }
}

// MARK: - 验收用例（在 runIntegrationTests 末尾调用）

@MainActor
func runEnhancementAcceptance() async {
    let h = Harness.shared

    do {
        try EnhancementTests.setupModels()
    } catch let reason as SkipReason {
        h.markSkipped("画质修复验收（\(reason)）")
        return
    } catch {
        h.record(pass: false)
        print("  ✗ 模型注入失败 —— \(error)")
        return
    }

    let directory = try! Artifacts.subdirectory("enhancement")

    await h.suite("验收：画质修复单帧（两档模型）") {
        for model in NeuralUpscalerModel.allCases {
            await h.runAsync("单帧：\(model.shortName)（\(model.modelDisplayName)）输出 = 输入 ×2") {
                try requireHardwareEncoder()
                let input = try EnhancementTests.naturalFrame(width: 640, height: 360)
                let upscaler = try await NeuralUpscaler.load(
                    model: model, strength: .balanced, sourceWidth: 640, sourceHeight: 360
                )
                try Harness.expect(!upscaler.notes.isEmpty, "有管线 notes：\(upscaler.notes)")
                let output = try upscaler.enhance(input)
                let dimensions = output.withUnsafeBuffer {
                    (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0), CVPixelBufferGetPixelFormatType($0))
                }
                try Harness.expectEqual(dimensions.0, 1280, "输出宽 ×2")
                try Harness.expectEqual(dimensions.1, 720, "输出高 ×2")
                try Harness.expectEqual(dimensions.2, kCVPixelFormatType_32BGRA, "输出 BGRA")
            }
        }
    }

    await h.suite("验收：tile 接缝（精细档，双 tile 羽化）") {
        await h.runAsync("水平渐变源在 tile 边界列差平滑（无竖纹）") {
            try requireHardwareEncoder()
            // 自然感源 → 精细档 384 tile 横向两枚（0 / 320），输出 1408×768，接缝列 = 768
            let input = try EnhancementTests.naturalFrame(width: 704, height: 384)
            let upscaler = try await NeuralUpscaler.load(
                model: .fine, strength: .balanced, sourceWidth: 704, sourceHeight: 384
            )
            let output = try upscaler.enhance(input)
            try Harness.expectEqual(
                output.withUnsafeBuffer { CVPixelBufferGetWidth($0) }, 1408, "输出宽 ×2"
            )
            // 自然图像相邻列差本身有波动；判据用「接缝区峰值 vs 全图基线」的比值：
            // 接缝若为硬边，峰值会远高于普通区域；羽化正常时两者同量级。
            var seamPeak = 0.0
            for x in 760...776 {
                let left = EnhancementTests.columnAverage(output, x: x - 1)
                let right = EnhancementTests.columnAverage(output, x: x)
                seamPeak = max(seamPeak, abs(right - left))
            }
            var baselinePeak = 0.0
            for x in 200...600 {
                let left = EnhancementTests.columnAverage(output, x: x - 1)
                let right = EnhancementTests.columnAverage(output, x: x)
                baselinePeak = max(baselinePeak, abs(right - left))
            }
            let ratio = baselinePeak > 0 ? seamPeak / baselinePeak : .infinity
            // 诊断：保存输出 PNG 供肉眼检查；打印接缝两侧列均值
            output.withUnsafeBuffer { buffer in
                var image: CGImage?
                let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
                if status == kCVReturnSuccess, let image {
                    let url = Artifacts.root.appendingPathComponent("seam-output.png")
                    try? FileManager.default.createDirectory(at: Artifacts.root, withIntermediateDirectories: true)
                    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                    if let destination {
                        CGImageDestinationAddImage(destination, image, nil)
                        CGImageDestinationFinalize(destination)
                        print("    接缝输出已保存：\(url.path)")
                    }
                }
            }
            for x in [636, 640, 700, 760, 766, 768, 770, 776, 900] {
                print(String(format: "    列 x=%d 均值 %.2f", x, EnhancementTests.columnAverage(output, x: x)))
            }
            try Harness.expect(
                ratio < 2.0,
                String(format: "接缝峰值 %.2f / 基线峰值 %.2f = %.2f（阈值 2.0，硬边时远超）", seamPeak, baselinePeak, ratio)
            )
        }
    }

    await h.suite("验收：神经超分端到端（两档）") {
        let outputs = directory.appendingPathComponent("outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let source = try! await { () -> URL in
            let url = directory.appendingPathComponent("源-360p.mp4")
            if !FileManager.default.fileExists(atPath: url.path) {
                try await ClipFactory.generate(ClipFactory.Spec(
                    url: url, size: CGSize(width: 640, height: 360), codec: .h264, bitrate: 1_500_000
                ))
            }
            return url
        }()

        func request(named: String, model: NeuralUpscalerModel) -> TranscodeRequest {
            var request = TranscodeRequest(
                inputURL: source,
                outputURL: outputs.appendingPathComponent(named),
                videoCodec: .h264,
                container: .mp4,
                resolution: .source,
                frameRate: .source,
                averageBitrate: 6_000_000,
                audioBitrate: 192_000,
                audioMaxChannels: 2,
                audioSampleRate: nil,
                audioPCMSampleBitDepth: nil,
                requireHardware: true,
                encoderID: VideoToolboxCapabilities.probe().hardwareEncoder(for: .h264)?.encoderID,
                metadata: nil,
                posterData: nil
            )
            request.bitrateRange = 2_500_000...12_000_000
            request.enhancement = EnhancementSetting(mode: .neural, neuralModel: model, strength: .balanced)
            return request
        }

        for model in NeuralUpscalerModel.allCases {
            await h.runAsync("端到端：\(model.shortName) 超分 → 720p，硬编码命中，无残留") {
                try requireHardwareEncoder()
                let engine = TranscodeEngine()
                let outcome = try await engine.run(request(named: "out-\(model.rawValue).mp4", model: model)) { _ in }
                try expect(FileManager.default.fileExists(atPath: outcome.outputURL.path), "输出存在")
                try expectEqual(outcome.verificationIssues.count, 0, "无自检告警：\(outcome.verificationIssues)")
                try expect(outcome.notes.contains { $0.contains("神经超分") }, "notes 有超分管线：\(outcome.notes)")
                let info = try await OutputProbe.info(of: outcome.outputURL)
                try expectEqual(info.video?.displayWidth, 1280, "输出宽 ×2")
                try expectEqual(info.video?.displayHeight, 720, "输出高 ×2")
                let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: outputs.path))?
                    .filter { $0.hasPrefix(OutputPlanner.tempPrefix) && $0.hasSuffix(OutputPlanner.tempSuffix) } ?? []
                try expect(leftovers.isEmpty, "无临时文件残留：\(leftovers)")
            }
        }
    }

    await h.suite("验收：神经超分吞吐（1080p 源，§7.6 预算）") {
        let sourceWidth = 1920
        let sourceHeight = 1080
        let input = try! EnhancementTests.naturalFrame(width: sourceWidth, height: sourceHeight)
        let frames = 8

        for model in NeuralUpscalerModel.allCases {
            await h.runAsync("吞吐：\(model.shortName) @1080p（\(frames) 帧计时）") {
                try requireHardwareEncoder()
                let upscaler = try await NeuralUpscaler.load(
                    model: model, strength: .balanced, sourceWidth: sourceWidth, sourceHeight: sourceHeight
                )
                // 裸 tile 推理对照（隔离管线开销）：单 tile 直接预测（同步辅助函数，避免 async 重载）
                let tile = try EnhancementSupport.makeBuffer(
                    width: upscaler.debugTileWidth, height: upscaler.debugTileHeight
                )
                try EnhancementTests.bareTilePrediction(upscaler.debugModel, tile: tile)  // warmup
                let bareStart = Stopwatch.now
                let bareRuns = 6
                for _ in 0..<bareRuns {
                    try EnhancementTests.bareTilePrediction(upscaler.debugModel, tile: tile)
                }
                let barePerTile = (Stopwatch.now - bareStart) / Double(bareRuns)
                print(String(format: "    裸 tile 推理 %.0f ms/tile（对照 spike ≈38 ms）", barePerTile * 1000))

                // warmup 2 帧（管线首次编译/调度开销不计入）
                for _ in 0..<2 { _ = try upscaler.enhance(input) }
                var perFrame: [Double] = []
                for frame in 0..<frames {
                    let frameStart = Stopwatch.now
                    _ = try upscaler.enhance(input)
                    perFrame.append(Stopwatch.now - frameStart)
                    print(String(format: "    帧 %d：%.2f s", frame, perFrame.last!))
                }
                let wall = perFrame.reduce(0, +)
                let fps = Double(frames) / max(wall, 0.0001)
                let realtime = fps / 30.0
                let label = String(format: "%.1f fps（%.3fx 实时）", fps, realtime)
                switch model {
                case .fast:
                    try Harness.expect(realtime >= 0.1, "快速档 ≥0.1x 实时：\(label)")
                    print("    快速档 \(label)（≥0.1x 达标）")
                case .fine:
                    // 预算表：精细档不承诺 0.1x（M1 Pro 实测 0.060–0.074x）；只做记录
                    print("    精细档 \(label)（记录值，不做硬阈值）")
                }
            }
        }

        await h.runAsync("内存：1080p 精细档峰值 < 1.5 GB") {
            try requireHardwareEncoder()
            let upscaler = try await NeuralUpscaler.load(
                model: .fine, strength: .balanced, sourceWidth: sourceWidth, sourceHeight: sourceHeight
            )
            let sampler = MemorySampler()
            sampler.start()
            for _ in 0..<3 { _ = try upscaler.enhance(input) }
            let metrics = sampler.stop()
            try Harness.expect(
                metrics.peakFootprintBytes < 1_500_000_000,
                "峰值 \(Fmt.bytes(metrics.peakFootprintBytes)) < 1.5 GB"
            )
        }

        await h.runAsync("滤镜链吞吐：1080p ≥1x 实时") {
            let upscaler = FilterUpscaler(
                strength: .balanced, width: sourceWidth * 2, height: sourceHeight * 2
            )
            for _ in 0..<2 { _ = try upscaler.enhance(input) }
            let started = Stopwatch.now
            for _ in 0..<frames { _ = try upscaler.enhance(input) }
            let wall = Stopwatch.now - started
            let fps = Double(frames) / max(wall, 0.0001)
            try Harness.expect(fps >= 30, String(format: "滤镜链 %.1f fps（≥30 fps 即 ≥1x）", fps))
        }
    }
}
