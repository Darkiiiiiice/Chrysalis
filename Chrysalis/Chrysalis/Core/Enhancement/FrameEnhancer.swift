import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

// MARK: - 逐帧画质增强协议（设计文档 §7.6）

/// 画质修复执行器：输入源帧（BGRA，源显示尺寸），输出 2x 帧（BGRA，偶数对齐）。
///
/// 由引擎帧泵**串行**调用（同一时刻最多一帧在增强）；实现可以自由复用内部缓冲。
/// 返回 `CVReadOnlyPixelBuffer`（Sendable）：包装由实现内部完成，跨借用边界安全。
protocol FrameEnhancer: Sendable {
    /// 接入时的提示（管线描述 / 加速器 / tile 网格），写入任务 notes。
    var notes: [String] { get }
    /// 输出帧宽（源显示宽 ×2）。
    var outputWidth: Int { get }
    /// 输出帧高（源显示高 ×2）。
    var outputHeight: Int { get }

    func enhance(_ input: CVPixelBuffer) throws -> CVReadOnlyPixelBuffer
}

/// 增强器工厂：按设置构建；神经模式模型缺失/损坏时抛 `enhancementUnavailable`（不静默回退）。
enum FrameEnhancerFactory {
    static func make(setting: EnhancementSetting, sourceWidth: Int, sourceHeight: Int) async throws -> FrameEnhancer {
        switch setting.mode {
        case .filter:
            return FilterUpscaler(strength: setting.strength, width: sourceWidth * 2, height: sourceHeight * 2)
        case .neural:
            return try await NeuralUpscaler.load(
                model: setting.neuralModel,
                strength: setting.strength,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            )
        }
    }
}

// MARK: - 轻量修复（Core Image 滤镜链）

/// Lanczos 2x + USM 锐化（设计文档 §7.6 兜底路线）；GPU 渲染，速度快。
final class FilterUpscaler: FrameEnhancer, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let strength: EnhancementStrength
    let outputWidth: Int
    let outputHeight: Int

    init(strength: EnhancementStrength, width: Int, height: Int) {
        self.strength = strength
        self.outputWidth = width
        self.outputHeight = height
    }

    var notes: [String] {
        ["轻量修复：Lanczos 2x + USM（\(strength.displayName)）"]
    }

    /// 三档对应的 USM 强度（P7.4 可调参）。
    private var usmIntensity: Float {
        switch strength {
        case .light: 0.3
        case .balanced: 0.5
        case .strong: 0.8
        }
    }

    func enhance(_ input: CVPixelBuffer) throws -> CVReadOnlyPixelBuffer {
        let image = CIImage(cvPixelBuffer: input)
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 2.0,
            kCIInputAspectRatioKey: 1.0,
        ])
        let sharpened = scaled.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.0,
            kCIInputIntensityKey: usmIntensity,
        ])
        let output = try EnhancementSupport.makeBuffer(width: outputWidth, height: outputHeight)
        let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        context.render(sharpened.cropped(to: bounds), to: output, bounds: bounds, colorSpace: EnhancementSupport.sRGB)
        return CVReadOnlyPixelBuffer(unsafeBuffer: output)
    }
}

// MARK: - 共享工具

enum EnhancementSupport {
    /// 单调时钟（秒）——诊断计时用（ENH_TIMING=1 时输出分段耗时）。
    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 新建 BGRA 输出帧缓冲（IOSurface + Metal 兼容；写入端直接可编码）。
    static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw TranscodeEngineError.enhancementUnavailable("创建输出帧缓冲失败：\(status)")
        }
        return buffer
    }
}
