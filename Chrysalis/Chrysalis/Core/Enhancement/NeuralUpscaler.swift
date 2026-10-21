import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation

// MARK: - 神经超分执行器（Real-ESRGAN · Core ML，设计文档 §7.6）

/// Core ML 神经超分：模型懒加载（ANE 优先）+ tile 切分羽化合成 + 强度后处理。
///
/// 串行约定：由引擎帧泵单任务调用，内部缓冲（work / tile）按此复用；tile 合成走 Core Image（GPU）。
final class NeuralUpscaler: FrameEnhancer, @unchecked Sendable {
    let outputWidth: Int
    let outputHeight: Int

    /// 验收/诊断用：模型输入 tile 尺寸与 MLModel 实例。
    var debugTileWidth: Int { tileWidth }
    var debugTileHeight: Int { tileHeight }
    var debugModel: MLModel { model }

    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let neuralModel: NeuralUpscalerModel
    private let strength: EnhancementStrength
    private let acceleratorLabel: String
    /// 模型输入 tile（宽 × 高）与放大倍数（从模型约束读取）。
    private let tileWidth: Int
    private let tileHeight: Int
    private let scale: Int
    /// 快速档：0.5x 预降采样后进 4x 模型（工作帧坐标系）。
    private let preDownscale: Bool
    private let overlap = 32

    /// 工作帧尺寸（进入 tile 切分的尺寸；快速档 = 源的 0.5x）。
    private let workWidth: Int
    private let workHeight: Int

    // 串行复用缓冲
    private var workBuffer: CVPixelBuffer?
    private var tileBuffer: CVPixelBuffer?
    private var xOrigins: [(offset: Int, overlapWithPrevious: Int)] = []
    private var yOrigins: [(offset: Int, overlapWithPrevious: Int)] = []

    static func load(
        model neuralModel: NeuralUpscalerModel,
        strength: EnhancementStrength,
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws -> NeuralUpscaler {
        guard let url = Self.modelURL(named: neuralModel.resourceName) else {
            throw TranscodeEngineError.enhancementUnavailable(
                "找不到模型资源 \(neuralModel.resourceName).mlmodelc：请重新安装应用。"
            )
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model: MLModel
        do {
            model = try await MLModel.load(contentsOf: url, configuration: configuration)
        } catch {
            throw TranscodeEngineError.enhancementUnavailable("模型加载失败：\(error.localizedDescription)")
        }

        // 模型 IO 校验（设计文档：加载时校验形状与格式）
        let inputSize: (width: Int, height: Int, scale: Int)
        do {
            inputSize = try Self.readModelIO(model)
        } catch {
            throw TranscodeEngineError.enhancementUnavailable(error.localizedDescription)
        }

        // 执行设备（MLComputePlan：取估算工作量最大算子的首选设备）
        let accelerator = (try? await Self.dominantDevice(url: url, configuration: configuration)) ?? "ML"
        let preDownscale = neuralModel == .fast
        return NeuralUpscaler(
            model: model,
            neuralModel: neuralModel,
            strength: strength,
            acceleratorLabel: accelerator,
            inputWidth: inputSize.width,
            inputHeight: inputSize.height,
            scale: inputSize.scale,
            preDownscale: preDownscale,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    private init(
        model: MLModel,
        neuralModel: NeuralUpscalerModel,
        strength: EnhancementStrength,
        acceleratorLabel: String,
        inputWidth: Int,
        inputHeight: Int,
        scale: Int,
        preDownscale: Bool,
        sourceWidth: Int,
        sourceHeight: Int
    ) {
        self.model = model
        self.neuralModel = neuralModel
        self.strength = strength
        self.acceleratorLabel = acceleratorLabel
        self.tileWidth = inputWidth
        self.tileHeight = inputHeight
        self.scale = scale
        self.preDownscale = preDownscale
        // 工作帧（tile 切分坐标系）：快速档先 0.5x 预降采样
        let factor = preDownscale ? 2 : 1
        self.workWidth = max(inputWidth, sourceWidth / factor)
        self.workHeight = max(inputHeight, sourceHeight / factor)
        // 对外输出 = 源显示尺寸 ×2（快速档内部 0.5x→4x，精细档 2x）
        self.outputWidth = sourceWidth * 2
        self.outputHeight = sourceHeight * 2
        rebuildOrigins()
    }

    var notes: [String] {
        var items: [String] = []
        switch neuralModel {
        case .fast:
            items.append("神经超分：\(neuralModel.modelDisplayName)（0.5x 预降采样 + 4x）· \(acceleratorLabel)")
        case .fine:
            items.append("神经超分：\(neuralModel.modelDisplayName)（原生 2x）· \(acceleratorLabel)")
        }
        items.append("tile \(xOrigins.count)×\(yOrigins.count)（\(tileWidth)×\(tileHeight)，重叠 \(overlap)px）")
        if max(outputWidth, outputHeight) >= 7680 {
            items.append("8K 输出：超分与编码都会很慢，请留意预计耗时")
        }
        return items
    }

    // MARK: 模型资源与 IO

    private static func modelURL(named resourceName: String) -> URL? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc") { return url }
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc", subdirectory: "Models") { return url }
        // 无 bundle 可执行（harness）：模型直接放在可执行文件旁边
        if let directory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidate = directory.appendingPathComponent("\(resourceName).mlmodelc", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 模型 IO 约定（§7.6）：输入 `frame` / 输出 `out`，BGRA，输出为输入的整数倍。
    private static func readModelIO(_ model: MLModel) throws -> (width: Int, height: Int, scale: Int) {
        guard let input = model.modelDescription.inputDescriptionsByName["frame"]?.imageConstraint else {
            throw TranscodeEngineError.enhancementUnavailable("模型缺少名为 frame 的图像输入")
        }
        guard let output = model.modelDescription.outputDescriptionsByName["out"]?.imageConstraint else {
            throw TranscodeEngineError.enhancementUnavailable("模型缺少名为 out 的图像输出")
        }
        guard input.pixelFormatType == kCVPixelFormatType_32BGRA,
              output.pixelFormatType == kCVPixelFormatType_32BGRA else {
            throw TranscodeEngineError.enhancementUnavailable("模型像素格式不是 BGRA")
        }
        guard let scale = Self.integerScale(outputWidth: output.pixelsWide, outputHeight: output.pixelsHigh, inputWidth: input.pixelsWide, inputHeight: input.pixelsHigh) else {
            throw TranscodeEngineError.enhancementUnavailable("模型输出尺寸不是输入的整数倍")
        }
        return (input.pixelsWide, input.pixelsHigh, scale)
    }

    private static func integerScale(outputWidth: Int, outputHeight: Int, inputWidth: Int, inputHeight: Int) -> Int? {
        guard inputWidth > 0, inputHeight > 0,
              outputWidth % inputWidth == 0, outputHeight % inputHeight == 0 else { return nil }
        let horizontal = outputWidth / inputWidth
        let vertical = outputHeight / inputHeight
        guard horizontal == vertical, horizontal >= 1 else { return nil }
        return horizontal
    }

    /// 主执行设备：取估算工作量最大算子的首选设备（ANE / GPU / CPU）。
    private static func dominantDevice(
        url: URL,
        configuration: MLModelConfiguration
    ) async throws -> String {
        let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
        guard case let .program(program) = plan.modelStructure else { return "ML" }
        var costs: [String: Double] = [:]
        func walk(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                if let usage = plan.deviceUsage(for: operation),
                   let cost = plan.estimatedCost(of: operation)?.weight {
                    costs[Self.deviceName(usage.preferred), default: 0] += cost
                }
                for nested in operation.blocks {
                    walk(nested)
                }
            }
        }
        for function in program.functions.values {
            walk(function.block)
        }
        return costs.max(by: { $0.value < $1.value })?.key ?? "ML"
    }

    private static func deviceName(_ device: MLComputeDevice) -> String {
        switch device {
        case .neuralEngine: "ANE"
        case .gpu: "GPU"
        case .cpu: "CPU"
        @unknown default: "ML"
        }
    }

    // MARK: tile 网格

    private func rebuildOrigins() {
        xOrigins = Self.axisOrigins(length: workWidth, tile: tileWidth, overlap: overlap)
        yOrigins = Self.axisOrigins(length: workHeight, tile: tileHeight, overlap: overlap)
    }

    /// tile 起点序列（P7.1 spike 算法）：步进 tile-overlap，末尾贴边；源小于 tile 时单 origin（走 pad 路径）。
    private static func axisOrigins(length: Int, tile: Int, overlap: Int) -> [(offset: Int, overlapWithPrevious: Int)] {
        guard length > tile else { return [(0, 0)] }
        let step = tile - overlap
        var result: [(offset: Int, overlapWithPrevious: Int)] = []
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

    // MARK: 逐帧增强

    func enhance(_ input: CVPixelBuffer) throws -> CVReadOnlyPixelBuffer {
        // 输入必须是源显示尺寸（×2 = 输出尺寸）
        let inputWidth = CVPixelBufferGetWidth(input)
        let inputHeight = CVPixelBufferGetHeight(input)
        guard inputWidth * 2 == outputWidth, inputHeight * 2 == outputHeight else {
            throw TranscodeEngineError.enhancementUnavailable(
                "帧尺寸 \(inputWidth)×\(inputHeight) 与预期源尺寸不符"
            )
        }
        // 工作帧：快速档先把源降到 0.5x（再交给 4x 模型）
        let debugTiming = ProcessInfo.processInfo.environment["ENH_TIMING"] == "1"
        var mark = EnhancementSupport.now()
        let work = try prepareWorkBuffer(from: input)
        let tile = try acquireTileBuffer()
        if debugTiming { print(String(format: "    [timing] prepare %.0f ms", (EnhancementSupport.now() - mark) * 1000)) }
        mark = EnhancementSupport.now()

        // 逐 tile 推理，输出在 Core Image（GPU）里羽化合成——
        // 不对 ANE 输出/4K 画布做任何 CPU 锁（P7.4 实测：CPU 锁 IOSurface 会触发隐式同步风暴，
        // 每 tile 额外 200–700ms；GPU 合成后 tiles 阶段 ≈ 纯推理耗时）
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        var composed: CIImage?
        for (row, y) in yOrigins.enumerated() {
            for (column, x) in xOrigins.enumerated() {
                try copyTile(from: work, x: x.offset, y: y.offset, into: tile)
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "frame": MLFeatureValue(pixelBuffer: tile),
                ])
                let result = try model.prediction(from: provider)
                guard let tileOutput = result.featureValue(for: "out")?.imageBufferValue else {
                    throw TranscodeEngineError.enhancementUnavailable("模型输出缺少 out 图像")
                }
                let visibleWidth = min(tileWidth * scale, outputWidth - x.offset * scale)
                let visibleHeight = min(tileHeight * scale, outputHeight - y.offset * scale)
                let tileImage = CIImage(cvPixelBuffer: tileOutput)
                    .cropped(to: CGRect(x: 0, y: 0, width: visibleWidth, height: visibleHeight))
                    .transformed(by: CGAffineTransform(
                        translationX: CGFloat(x.offset * scale), y: CGFloat(y.offset * scale)
                    ))
                let overlapXpx = column > 0 ? x.overlapWithPrevious * scale : 0
                let overlapYpx = row > 0 ? y.overlapWithPrevious * scale : 0
                guard let previous = composed else {
                    composed = tileImage
                    continue
                }
                if overlapXpx <= 0, overlapYpx <= 0 {
                    composed = tileImage.composited(over: previous)
                    continue
                }
                // 羽化 mask：左/上重叠区线性渐变（min 组合 X 与 Y 两个方向）
                var mask = CIImage(color: CIColor.white).cropped(to: outputRect)
                if overlapXpx > 0 {
                    let gradient = CIFilter.linearGradient()
                    gradient.point0 = CGPoint(x: CGFloat(x.offset * scale), y: 0)
                    gradient.point1 = CGPoint(x: CGFloat(x.offset * scale + overlapXpx), y: 0)
                    gradient.color0 = CIColor.black
                    gradient.color1 = CIColor.white
                    if let ramp = gradient.outputImage {
                        mask = ramp.cropped(to: outputRect).applyingFilter("CIMinimumCompositing", parameters: [
                            kCIInputBackgroundImageKey: mask,
                            kCIInputImageKey: ramp,
                        ])
                    }
                }
                if overlapYpx > 0 {
                    let gradient = CIFilter.linearGradient()
                    gradient.point0 = CGPoint(x: 0, y: CGFloat(y.offset * scale))
                    gradient.point1 = CGPoint(x: 0, y: CGFloat(y.offset * scale + overlapYpx))
                    gradient.color0 = CIColor.black
                    gradient.color1 = CIColor.white
                    if let ramp = gradient.outputImage {
                        mask = ramp.cropped(to: outputRect).applyingFilter("CIMinimumCompositing", parameters: [
                            kCIInputBackgroundImageKey: mask,
                            kCIInputImageKey: ramp,
                        ])
                    }
                }
                composed = tileImage.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: previous,
                    "inputMaskImage": mask,
                ])
            }
        }
        guard let modelImage = composed else {
            throw TranscodeEngineError.enhancementUnavailable("没有任何 tile 输出")
        }
        if debugTiming {
            print(String(format: "    [timing] tiles×%d %.0f ms", xOrigins.count * yOrigins.count, (EnhancementSupport.now() - mark) * 1000))
            mark = EnhancementSupport.now()
        }

        // 输出帧（每帧独立，写入端持有）：模型输出 + 强度后处理。
        // 参考图（light 档）在此构造成 CIImage，切断与借用输入 buffer 的 region 关联。
        let output = try EnhancementSupport.makeBuffer(width: outputWidth, height: outputHeight)
        let reference: CIImage?
        if strength == .light {
            reference = CIImage(cvPixelBuffer: input)
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: 2.0,
                    kCIInputAspectRatioKey: 1.0,
                ])
                .cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        } else {
            reference = nil
        }
        try renderOutput(modelImage: modelImage, reference: reference, into: output)
        if debugTiming { print(String(format: "    [timing] post %.0f ms", (EnhancementSupport.now() - mark) * 1000)) }
        return CVReadOnlyPixelBuffer(unsafeBuffer: output)
    }

    private func acquireTileBuffer() throws -> CVPixelBuffer {
        if let tileBuffer { return tileBuffer }
        let buffer = try EnhancementSupport.makeBuffer(width: tileWidth, height: tileHeight)
        tileBuffer = buffer
        return buffer
    }

    /// 快速档：Lanczos 0.5x 预降采样到工作帧；精细档：源帧即工作帧。
    private func prepareWorkBuffer(from input: CVPixelBuffer) throws -> CVPixelBuffer {
        guard preDownscale else { return input }
        if let workBuffer,
           CVPixelBufferGetWidth(workBuffer) == workWidth,
           CVPixelBufferGetHeight(workBuffer) == workHeight {
            let image = CIImage(cvPixelBuffer: input)
            let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: Float(workWidth) / Float(CVPixelBufferGetWidth(input)),
                kCIInputAspectRatioKey: 1.0,
            ])
            context.render(
                scaled.cropped(to: CGRect(x: 0, y: 0, width: workWidth, height: workHeight)),
                to: workBuffer,
                bounds: CGRect(x: 0, y: 0, width: workWidth, height: workHeight),
                colorSpace: EnhancementSupport.sRGB
            )
            return workBuffer
        }
        let buffer = try EnhancementSupport.makeBuffer(width: workWidth, height: workHeight)
        workBuffer = buffer
        return try prepareWorkBuffer(from: input)
    }

    // MARK: 后处理（强度三档，§7.6）

    /// 模型输出 → 输出帧：
    /// 轻度 = 与 Lanczos 2x 参考图 alpha 0.4 混合；均衡 = 快速档轻度 USM / 精细档直通；强力 = 更强 USM。
    /// 参考图由调用方预先构造成 CIImage（切断与借用输入缓冲的 region 关联）。
    private func renderOutput(modelImage: CIImage, reference: CIImage?, into output: CVPixelBuffer) throws {
        var result: CIImage
        switch (neuralModel, strength) {
        case (_, .light):
            // 与 Lanczos 2x 参考图混合，补回部分原始细节（模型输出预乘 alpha 0.4 后 source-over）
            guard let reference else {
                throw TranscodeEngineError.enhancementUnavailable("轻度模式缺少参考图")
            }
            let translucent = modelImage.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.4, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.4, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.4, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.4),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            result = translucent.composited(over: reference)
        case (.fine, .balanced):
            result = modelImage
        case (.fast, .balanced):
            result = unsharp(modelImage, intensity: 0.4)
        case (_, .strong):
            result = unsharp(modelImage, intensity: neuralModel == .fine ? 0.5 : 0.8)
        }
        result = result.cropped(to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.render(result, to: output, bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight), colorSpace: EnhancementSupport.sRGB)
    }

    private func unsharp(_ image: CIImage, intensity: Float) -> CIImage {
        image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.0,
            kCIInputIntensityKey: intensity,
        ])
    }

    // MARK: tile 拷贝与羽化合成（P7.1 spike 移植；支持源小于 tile 的边缘复制 pad）

    /// 从工作帧拷贝 tile；行内优先整段 memcpy，源越界区域才逐像素复制边缘（pad）。
    private func copyTile(from source: CVPixelBuffer, x: Int, y: Int, into destination: CVPixelBuffer) throws {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            throw TranscodeEngineError.enhancementUnavailable("像素缓冲区没有基地址")
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let tileWidth = CVPixelBufferGetWidth(destination)

        for row in 0..<CVPixelBufferGetHeight(destination) {
            let sourceY = min(max(y + row, 0), sourceHeight - 1)
            let sourceRow = sourceBase + sourceY * sourceStride
            let destinationRow = destinationBase + row * destinationStride

            // 行内源内区间：整段拷贝；左右越界（pad）才逐像素复制源边缘列
            let left = max(x, 0)
            let right = min(x + tileWidth, sourceWidth)
            if left < right {
                memcpy(
                    destinationRow + (left - x) * 4,
                    sourceRow + left * 4,
                    (right - left) * 4
                )
            }
            if x < 0 {
                // 左侧 pad：复制源第一列（clamp 后最近的有效列）
                for column in 0..<(-x) {
                    memcpy(destinationRow + column * 4, sourceRow, 4)
                }
            }
            if x + tileWidth > sourceWidth {
                let edge = sourceRow + (sourceWidth - 1) * 4
                for column in (sourceWidth - x)..<tileWidth {
                    memcpy(destinationRow + column * 4, edge, 4)
                }
            }
        }
    }

}
