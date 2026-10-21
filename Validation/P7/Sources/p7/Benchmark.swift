import CoreML
import CoreVideo
import Foundation

struct TileOrigin {
    let x: Int
    let y: Int
    let overlapX: Int
    let overlapY: Int
}

struct BenchResult {
    let modelName: String
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let tile: Int
    let tileHeight: Int
    let overlap: Int
    let columns: Int
    let rows: Int
    let frameCount: Int
    let modelLoadSeconds: Double
    let firstPredictionSeconds: Double
    let averageInferenceSeconds: Double
    let averagePrepareSeconds: Double
    let averageCompositeSeconds: Double
    let averageFrameSeconds: Double
    let framesPerSecond: Double
    let realtimeFactor: Double
    let baselineFootprint: UInt64
    let footprintAfterLoad: UInt64
    let peakFootprint: UInt64
}

enum Benchmark {
    static func axisOrigins(length: Int, tile: Int, overlap: Int) throws -> [(offset: Int, overlapWithPrevious: Int)] {
        guard tile > 0, overlap >= 0, overlap < tile else {
            throw P7Error.message("非法 tile/overlap：\(tile)/\(overlap)")
        }
        guard length >= tile else {
            throw P7Error.message("源尺寸 \(length) 小于 tile \(tile)，整帧路径不在本次基准范围")
        }
        let step = tile - overlap
        var result: [(Int, Int)] = []
        var offset = 0
        var previous = -1
        while true {
            let overlapWithPrevious = previous >= 0 ? previous + tile - offset : 0
            result.append((offset, overlapWithPrevious))
            if offset + tile >= length { break }
            previous = offset
            offset = min(offset + step, length - tile)
        }
        return result
    }

    static func describeModel(_ model: MLModel) {
        print("")
        print("== 模型 I/O ==")
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            if let image = description.imageConstraint {
                print("输入 \(name)：图像 \(image.pixelsWide)x\(image.pixelsHigh)，格式 \(image.pixelFormatType)")
            } else {
                print("输入 \(name)：\(description.type)")
            }
        }
        for (name, description) in model.modelDescription.outputDescriptionsByName {
            if let image = description.imageConstraint {
                print("输出 \(name)：图像 \(image.pixelsWide)x\(image.pixelsHigh)，格式 \(image.pixelFormatType)")
            } else {
                print("输出 \(name)：\(description.type)")
            }
        }
    }

    static func inputSize(_ model: MLModel) throws -> (width: Int, height: Int, scale: Int) {
        guard let input = model.modelDescription.inputDescriptionsByName["frame"]?.imageConstraint else {
            throw P7Error.message("模型没有名为 frame 的图像输入")
        }
        guard let output = model.modelDescription.outputDescriptionsByName["out"]?.imageConstraint else {
            throw P7Error.message("模型没有名为 out 的图像输出")
        }
        guard input.pixelFormatType == kCVPixelFormatType_32BGRA else {
            throw P7Error.message("输入像素格式不是 32BGRA：\(input.pixelFormatType)")
        }
        guard output.pixelFormatType == kCVPixelFormatType_32BGRA else {
            throw P7Error.message("输出像素格式不是 32BGRA：\(output.pixelFormatType)")
        }
        let scale = output.pixelsWide / input.pixelsWide
        guard scale * input.pixelsWide == output.pixelsWide,
              scale * input.pixelsHigh == output.pixelsHigh else {
            throw P7Error.message("输出尺寸不是输入的整数倍")
        }
        return (input.pixelsWide, input.pixelsHigh, scale)
    }

    static func verify(
        model: MLModel,
        modelName: String,
        referenceDirectory: URL
    ) throws {
        let inputURL = referenceDirectory.appendingPathComponent("validation-input.rgb")
        let referenceURL = referenceDirectory.appendingPathComponent("validation-reference.rgb")
        guard let inputData = try? Data(contentsOf: inputURL),
              let referenceData = try? Data(contentsOf: referenceURL) else {
            throw P7Error.message("缺少验证数据：\(inputURL.path) / \(referenceURL.path)")
        }

        let inputSize = try inputSize(model)
        let pixelCount = inputSize.width * inputSize.height
        guard inputData.count == pixelCount * 3 else {
            throw P7Error.message("验证输入大小不符：\(inputData.count) bytes")
        }
        let referenceCount = (inputSize.width * inputSize.scale) * (inputSize.height * inputSize.scale) * 3
        guard referenceData.count == referenceCount else {
            throw P7Error.message("参考输出大小不符：\(referenceData.count) bytes")
        }

        let buffer = try PixelBuffer.make(width: inputSize.width, height: inputSize.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        inputData.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<inputSize.height {
                let row = pixels + y * stride
                for x in 0..<inputSize.width {
                    let index = (y * inputSize.width + x) * 3
                    let pixel = row + x * 4
                    pixel[0] = source[index + 2] // B
                    pixel[1] = source[index + 1] // G
                    pixel[2] = source[index]     // R
                    pixel[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["frame": MLFeatureValue(pixelBuffer: buffer)]
        )
        let output = try model.prediction(from: provider)
        guard let outputBuffer = output.featureValue(for: "out")?.imageBufferValue else {
            throw P7Error.message("预测没有返回 out 图像")
        }

        CVPixelBufferLockBaseAddress(outputBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw P7Error.message("输出缓冲区没有基地址")
        }
        let stride = CVPixelBufferGetBytesPerRow(outputBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let width = inputSize.width * inputSize.scale
        let height = inputSize.height * inputSize.scale
        var totalDifference = 0.0
        var maximumDifference = 0
        var squaredDifference = 0.0

        referenceData.withUnsafeBytes { raw in
            let reference = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = pixels + y * stride
                for x in 0..<width {
                    let referenceIndex = (y * width + x) * 3
                    // 输出 CVPixelBuffer 是 BGRA；参考数据是 RGB。
                    let channelMap = [2, 1, 0]
                    for channel in 0..<3 {
                        let difference = abs(Int(row[x * 4 + channelMap[channel]]) - Int(reference[referenceIndex + channel]))
                        totalDifference += Double(difference)
                        squaredDifference += Double(difference * difference)
                        maximumDifference = max(maximumDifference, difference)
                    }
                }
            }
        }

        let samples = Double(width * height * 3)
        let mean = totalDifference / samples
        let mse = squaredDifference / samples
        let psnr = mse == 0 ? Double.infinity : 10.0 * log10(255.0 * 255.0 / mse)
        print("")
        print("== 编译模型数值复核 ==")
        print("模型：\(modelName)")
        print(
            String(
                format: "输出 %dx%d，平均绝对误差 %.3f，最大 %d，PSNR %.2f dB",
                width,
                height,
                mean,
                maximumDifference,
                psnr
            )
        )
        if mean > 1.0 || maximumDifference > 4 {
            throw P7Error.message("编译模型输出与 PyTorch 参考差异过大，疑似通道顺序或精度问题")
        }
    }

    static func run(
        model: MLModel,
        modelName: String,
        options: Options,
        saveFrame: URL?,
        baselineFootprint: UInt64,
        footprintAfterLoad: UInt64,
        modelLoadSeconds: Double
    ) throws -> BenchResult {
        let inputSize = try inputSize(model)
        let tile = inputSize.width
        let tileHeight = inputSize.height
        let scale = inputSize.scale
        if let requestedHeight = options.tileHeight {
            guard options.tile == tile, requestedHeight == tileHeight else {
                throw P7Error.message(
                    "模型输入 tile 为 \(tile)x\(tileHeight)，但参数指定 \(options.tile)x\(requestedHeight)"
                )
            }
        } else {
            guard options.tile == tile, tile == tileHeight else {
                throw P7Error.message(
                    "模型输入 tile 为 \(tile)x\(tileHeight)；非方形模型请用 --tile \(tile) --tile-height \(tileHeight)"
                )
            }
        }

        let xOrigins = try axisOrigins(length: options.width, tile: tile, overlap: options.overlap)
        let yOrigins = try axisOrigins(length: options.height, tile: tileHeight, overlap: options.overlap)
        var origins: [TileOrigin] = []
        for (row, y) in yOrigins.enumerated() {
            for (column, x) in xOrigins.enumerated() {
                origins.append(
                    TileOrigin(
                        x: x.offset,
                        y: y.offset,
                        overlapX: column > 0 ? x.overlapWithPrevious : 0,
                        overlapY: row > 0 ? y.overlapWithPrevious : 0
                    )
                )
            }
        }

        print("")
        print("== Tile 基准 ==")
        print("源 \(options.width)x\(options.height) → 输出 \(options.width * scale)x\(options.height * scale)")
        print("tile \(tile)x\(tileHeight)，重叠 \(options.overlap)px，网格 \(xOrigins.count)x\(yOrigins.count) = \(origins.count) tiles")
        print("warmup \(options.warmup) 帧，测量 \(options.frames) 帧（重用同一张合成图，不含解码/编码）")
        print("预测方式：\(options.batch ? "批量（MLArrayBatchProvider，一次 \(origins.count) 个 tile）" : "逐 tile 同步预测")")

        let source = try PixelBuffer.make(width: options.width, height: options.height)
        PixelBuffer.fillPattern(source)
        let tileBuffer = try PixelBuffer.make(width: tile, height: tileHeight)
        let output = try PixelBuffer.make(width: options.width * scale, height: options.height * scale)

        let peakBefore = Memory.peak()
        var batchBuffers: [CVPixelBuffer] = []
        if options.batch {
            batchBuffers = try origins.map { _ in
                try PixelBuffer.make(width: tile, height: tileHeight)
            }
        }

        var firstPredictionSeconds = 0.0
        var firstPredictionRecorded = false

        func processFrame() throws -> (inference: Double, prepare: Double, composite: Double, total: Double) {
            let frameStart = now()
            var inference = 0.0
            var prepare = 0.0
            var composite = 0.0

            if options.batch {
                var mark = now()
                for (index, origin) in origins.enumerated() {
                    try PixelBuffer.copyTile(
                        from: source,
                        x: origin.x,
                        y: origin.y,
                        width: tile,
                        height: tileHeight,
                        into: batchBuffers[index]
                    )
                }
                prepare = seconds(since: mark)

                mark = now()
                let providers = try batchBuffers.map {
                    try MLDictionaryFeatureProvider(
                        dictionary: ["frame": MLFeatureValue(pixelBuffer: $0)]
                    )
                }
                let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
                inference = seconds(since: mark)
                if !firstPredictionRecorded {
                    firstPredictionSeconds = inference
                    firstPredictionRecorded = true
                }

                mark = now()
                for (index, origin) in origins.enumerated() {
                    guard let tileOutput = results.features(at: index)
                        .featureValue(for: "out")?.imageBufferValue else {
                        throw P7Error.message("批量预测第 \(index) 个结果没有 out 图像")
                    }
                    try PixelBuffer.composite(
                        tile: tileOutput,
                        into: output,
                        x: origin.x * scale,
                        y: origin.y * scale,
                        overlapX: origin.overlapX,
                        overlapY: origin.overlapY,
                        scale: scale
                    )
                }
                composite = seconds(since: mark)
                return (inference, prepare, composite, seconds(since: frameStart))
            }

            for origin in origins {
                var mark = now()
                try PixelBuffer.copyTile(
                    from: source,
                    x: origin.x,
                    y: origin.y,
                    width: tile,
                    height: tileHeight,
                    into: tileBuffer
                )
                prepare += seconds(since: mark)

                mark = now()
                let provider = try MLDictionaryFeatureProvider(
                    dictionary: ["frame": MLFeatureValue(pixelBuffer: tileBuffer)]
                )
                let result = try model.prediction(from: provider)
                guard let tileOutput = result.featureValue(for: "out")?.imageBufferValue else {
                    throw P7Error.message("预测没有返回 out 图像")
                }
                let prediction = seconds(since: mark)
                inference += prediction
                if !firstPredictionRecorded {
                    firstPredictionSeconds = prediction
                    firstPredictionRecorded = true
                }

                mark = now()
                try PixelBuffer.composite(
                    tile: tileOutput,
                    into: output,
                    x: origin.x * scale,
                    y: origin.y * scale,
                    overlapX: origin.overlapX,
                    overlapY: origin.overlapY,
                    scale: scale
                )
                composite += seconds(since: mark)
            }
            return (inference, prepare, composite, seconds(since: frameStart))
        }

        var warmupTotal = 0.0
        for _ in 0..<max(options.warmup, 0) {
            warmupTotal += try processFrame().total
        }

        var totals = (inference: 0.0, prepare: 0.0, composite: 0.0, total: 0.0)
        for _ in 0..<max(options.frames, 1) {
            let frame = try processFrame()
            totals.inference += frame.inference
            totals.prepare += frame.prepare
            totals.composite += frame.composite
            totals.total += frame.total
        }

        let frames = Double(max(options.frames, 1))
        let averageFrame = totals.total / frames
        let fps = averageFrame > 0 ? 1.0 / averageFrame : 0
        let peak = Memory.peak()
        let footprint = Memory.footprint()

        if let saveFrame {
            try PixelBuffer.savePNG(output, to: saveFrame)
            print("输出帧已写入 \(saveFrame.path)")
        }

        let result = BenchResult(
            modelName: modelName,
            inputWidth: options.width,
            inputHeight: options.height,
            outputWidth: options.width * scale,
            outputHeight: options.height * scale,
            tile: tile,
            tileHeight: tileHeight,
            overlap: options.overlap,
            columns: xOrigins.count,
            rows: yOrigins.count,
            frameCount: options.frames,
            modelLoadSeconds: modelLoadSeconds,
            firstPredictionSeconds: firstPredictionSeconds,
            averageInferenceSeconds: totals.inference / frames,
            averagePrepareSeconds: totals.prepare / frames,
            averageCompositeSeconds: totals.composite / frames,
            averageFrameSeconds: averageFrame,
            framesPerSecond: fps,
            realtimeFactor: fps / 30.0,
            baselineFootprint: baselineFootprint,
            footprintAfterLoad: footprintAfterLoad,
            peakFootprint: max(peak, peakBefore)
        )

        print("")
        print("== 结果 ==")
        print("模型加载：\(Fmt.seconds(modelLoadSeconds))；加载后 footprint：\(Fmt.bytes(footprintAfterLoad))")
        print("warmup 总耗时：\(Fmt.seconds(warmupTotal))")
        print("首个 tile 首次推理：\(Fmt.seconds(firstPredictionSeconds))（含首次编译/调度开销）")
        print("每帧推理：\(Fmt.ms(result.averageInferenceSeconds))；拷贝：\(Fmt.ms(result.averagePrepareSeconds))；合成：\(Fmt.ms(result.averageCompositeSeconds))")
        print("每帧总耗时：\(Fmt.ms(result.averageFrameSeconds))")
        print(String(format: "吞吐：%.2f fps（%.3fx 实时，目标 ≥ 0.10x）", fps, result.realtimeFactor))
        print("峰值内存（进程 maxrss）：\(Fmt.bytes(result.peakFootprint))；当前 footprint：\(Fmt.bytes(footprint))")
        return result
    }

    static func writeJSON(
        _ result: BenchResult,
        plan: ComputePlanReport.Summary?,
        to url: URL
    ) throws {
        var object: [String: Any] = [
            "model": result.modelName,
            "input": "\(result.inputWidth)x\(result.inputHeight)",
            "output": "\(result.outputWidth)x\(result.outputHeight)",
            "tile": result.tile,
            "tile_height": result.tileHeight,
            "overlap": result.overlap,
            "grid": "\(result.columns)x\(result.rows)",
            "frames": result.frameCount,
            "average_inference_ms": result.averageInferenceSeconds * 1000,
            "average_prepare_ms": result.averagePrepareSeconds * 1000,
            "average_composite_ms": result.averageCompositeSeconds * 1000,
            "average_frame_ms": result.averageFrameSeconds * 1000,
            "fps": result.framesPerSecond,
            "realtime_factor": result.realtimeFactor,
            "first_prediction_seconds": result.firstPredictionSeconds,
            "peak_memory_bytes": result.peakFootprint,
            "baseline_footprint_bytes": result.baselineFootprint,
        ]
        if let plan {
            object["compute_plan"] = [
                "operations": plan.operationCount,
                "device_counts": plan.deviceCounts,
                "device_cost_share": plan.deviceCosts,
                "supported_devices": Array(plan.supportedDevices),
            ]
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
        print("JSON 已写入 \(url.path)")
    }
}
