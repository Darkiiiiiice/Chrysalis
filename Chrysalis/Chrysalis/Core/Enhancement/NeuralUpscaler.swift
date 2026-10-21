import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation

// MARK: - 神经超分执行器（Real-ESRGAN · Core ML，设计文档 §7.6）

/// Core ML 神经超分：模型懒加载（ANE 优先）+ tile 切分羽化合成 + 强度后处理。
///
/// 串行约定：由引擎帧泵单任务调用，内部缓冲（work / tile / scratch）按此复用。
final class NeuralUpscaler: FrameEnhancer, @unchecked Sendable {
    let outputWidth: Int
    let outputHeight: Int

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
    private var scratchBuffer: CVPixelBuffer?
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
        Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc", subdirectory: "Models")
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
        let work = try prepareWorkBuffer(from: input)
        let scratch = try acquireScratchBuffer()
        let tile = try acquireTileBuffer()
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
                try composite(
                    tile: tileOutput,
                    into: scratch,
                    x: x.offset * scale,
                    y: y.offset * scale,
                    overlapX: column > 0 ? x.overlapWithPrevious : 0,
                    overlapY: row > 0 ? y.overlapWithPrevious : 0
                )
            }
        }

        // 输出帧（每帧独立，写入端持有）：模型输出 + 强度后处理。
        // 参考图（light 档）在此构造成 CIImage，切断与借用输入 buffer 的 region 关联。
        let output = try EnhancementSupport.makeBuffer(width: outputWidth, height: outputHeight)
        let modelImage = CIImage(cvPixelBuffer: scratch).cropped(
            to: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        )
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

    /// 工作帧坐标系的 scratch（tile 合成目标），跨帧复用；输出帧另行新建。
    private func acquireScratchBuffer() throws -> CVPixelBuffer {
        if let scratchBuffer { return scratchBuffer }
        let buffer = try EnhancementSupport.makeBuffer(width: outputWidth, height: outputHeight)
        scratchBuffer = buffer
        return buffer
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

    /// 从工作帧拷贝 tile；源越界区域复制边缘像素（pad）。
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

        for row in 0..<tileHeight {
            let sourceY = min(max(y + row, 0), sourceHeight - 1)
            let sourceRow = sourceBase + sourceY * sourceStride
            let destinationRow = destinationBase + row * destinationStride
            for column in 0..<tileWidth {
                let sourceX = min(max(x + column, 0), sourceWidth - 1)
                memcpy(
                    destinationRow + column * 4,
                    sourceRow + sourceX * 4,
                    4
                )
            }
        }
    }

    /// tile 输出按羽化 alpha 叠加进输出帧（左/上重叠区渐变，其余覆盖；目标越界裁剪）。
    private func composite(
        tile: CVPixelBuffer,
        into output: CVPixelBuffer,
        x: Int,
        y: Int,
        overlapX: Int,
        overlapY: Int
    ) throws {
        let tileWidth = CVPixelBufferGetWidth(tile)
        let tileHeight = CVPixelBufferGetHeight(tile)
        let outputWidth = CVPixelBufferGetWidth(output)
        let outputHeight = CVPixelBufferGetHeight(output)
        let visibleWidth = min(tileWidth, outputWidth - x)
        let visibleHeight = min(tileHeight, outputHeight - y)
        guard visibleWidth > 0, visibleHeight > 0 else { return }

        let rampX = min(overlapX * scale, tileWidth)
        var alphaX = [UInt16](repeating: 255, count: visibleWidth)
        for index in 0..<min(rampX, visibleWidth) {
            alphaX[index] = UInt16((Double(index) + 0.5) / Double(rampX) * 255.0)
        }
        let rampY = min(overlapY * scale, tileHeight)
        var alphaY = [UInt16](repeating: 255, count: visibleHeight)
        for index in 0..<min(rampY, visibleHeight) {
            alphaY[index] = UInt16((Double(index) + 0.5) / Double(rampY) * 255.0)
        }

        CVPixelBufferLockBaseAddress(tile, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(tile, .readOnly)
        }
        guard let tileBase = CVPixelBufferGetBaseAddress(tile),
              let outputBase = CVPixelBufferGetBaseAddress(output) else {
            throw TranscodeEngineError.enhancementUnavailable("像素缓冲区没有基地址")
        }
        let tileStride = CVPixelBufferGetBytesPerRow(tile)
        let outputStride = CVPixelBufferGetBytesPerRow(output)

        alphaX.withUnsafeBufferPointer { alphaXBuffer in
            alphaY.withUnsafeBufferPointer { alphaYBuffer in
                for row in 0..<visibleHeight {
                    let sourceRow = tileBase + row * tileStride
                    let destinationRow = outputBase + (y + row) * outputStride + x * 4
                    let alphaYValue = Int(alphaYBuffer[row])
                    if alphaYValue == 255 && rampX == 0 {
                        memcpy(destinationRow, sourceRow, visibleWidth * 4)
                        continue
                    }
                    let source = sourceRow.assumingMemoryBound(to: UInt8.self)
                    let destination = destinationRow.assumingMemoryBound(to: UInt8.self)
                    for column in 0..<visibleWidth {
                        let alpha = Int(alphaXBuffer[column]) * alphaYValue / 255
                        if alpha >= 255 {
                            for channel in 0..<3 {
                                destination[column * 4 + channel] = source[column * 4 + channel]
                            }
                        } else if alpha > 0 {
                            let inverse = 255 - alpha
                            for channel in 0..<3 {
                                destination[column * 4 + channel] = UInt8((
                                    Int(source[column * 4 + channel]) * alpha
                                        + Int(destination[column * 4 + channel]) * inverse + 127
                                ) / 255)
                            }
                        }
                    }
                }
            }
        }
    }
}
