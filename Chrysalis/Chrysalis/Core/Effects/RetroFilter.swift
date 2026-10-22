import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreText
import CoreVideo

// MARK: - 复古输出滤镜（设计文档 §7.15）
// VHS 磁带感 / 老 DV 数码感；CoreImage 系统滤镜链（0 第三方依赖），全程 GPU。
// 管线位置：占据画质修复的帧处理插槽（互斥），在帧混合器之后、写入端之前。
// 泵内串行使用（@unchecked Sendable 与 FrameBlender 同模式）。

final class RetroFilter: @unchecked Sendable {
    private let style: RetroEffectStyle
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let colorSpace: CGColorSpace
    private let frameExtent: CGRect
    /// 老 DV 时间戳基准（源创建时间；nil = 不叠加 OSD）。
    private let osdBaseDate: Date?
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// OSD 文本渲染缓存（时间分钟粒度递增，每分钟重渲染一次）。
    private var osdCacheKey: Int = -1
    private var osdImage: CIImage?

    init(
        style: RetroEffectStyle,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        osdBaseDate: Date?
    ) {
        self.style = style
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.osdBaseDate = osdBaseDate
        frameExtent = CGRect(x: 0, y: 0, width: width, height: height)
        if pixelFormat == kCVPixelFormatType_32BGRA {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    // MARK: - 纯函数（harness 可测）

    /// DV 取景器 OSD 文案：上行「OCT.22 2026」、下行「PM 8:15」（英文缩写、12 小时制）。
    static func osdLines(for date: Date, calendar: Calendar = .current) -> (top: String, bottom: String) {
        let months = ["JAN.", "FEB.", "MAR.", "APR.", "MAY", "JUN.", "JUL.", "AUG.", "SEP.", "OCT.", "NOV.", "DEC."]
        let components = calendar.dateComponents([.month, .day, .year, .hour, .minute], from: date)
        let month = months[max((components.month ?? 1) - 1, 0)]
        let top = "\(month)\(components.day ?? 1) \(components.year ?? 2000)"
        let hour24 = max(components.hour ?? 0, 0)
        let suffix = hour24 < 12 ? "AM" : "PM"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        let minute = String(format: "%02d", max(components.minute ?? 0, 0))
        return (top: top, bottom: "\(suffix) \(hour12):\(minute)")
    }

    /// OSD 显示时间 = 基准时间 + 播放进度（随播放递增，模拟摄像机时钟）。
    static func osdDate(base: Date, pts: Double) -> Date {
        base.addingTimeInterval(max(pts, 0))
    }

    /// 噪点相位（确定性纯函数）：同 PTS 同相位，不同 PTS 相位漂移——噪点每帧变化且可复现。
    static func noisePhase(pts: Double) -> CGPoint {
        let t = max(pts, 0).truncatingRemainder(dividingBy: 4096) * 12.9898
        func hash(_ v: Double) -> Double {
            let s = sin(v) * 43758.5453
            return s - s.rounded(.down)
        }
        return CGPoint(x: hash(t) * 512, y: hash(t * 1.618) * 512)
    }

    // MARK: - 泵接口

    /// 逐帧处理：帧 → 风格化帧（同格式同尺寸）；PTS 用于噪点相位与 DV 时钟。
    func process(pixelBuffer: CVPixelBuffer, pts: Double) throws -> CVPixelBuffer {
        let input = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: frameExtent)
        var image: CIImage
        switch style {
        case .vhs:
            image = Self.vhsChain(input, extent: frameExtent, noise: Self.noisePhase(pts: pts))
        case .dv:
            image = Self.dvChain(input, extent: frameExtent, noise: Self.noisePhase(pts: pts))
            if let osd = osdOverlay(pts: pts) {
                image = osd.composited(over: image)
            }
        }
        let output = try makeBuffer()
        context.render(image, to: output, bounds: frameExtent, colorSpace: colorSpace)
        return output
    }

    // MARK: - 滤镜链

    /// VHS 磁带感：垂直软感 → 色彩渗色 → 饱和/对比 → 暗角 → 扫描线 → 噪点。
    private static func vhsChain(_ input: CIImage, extent: CGRect, noise: CGPoint) -> CIImage {
        var image = input
        // 1) 垂直分辨率衰减：Lanczos 下采样 ~0.35x 再回原尺寸（磁带垂直软感）
        let factor: CGFloat = 0.35
        let softened = image
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": factor, "inputAspectRatio": 1.0])
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 1 / factor, "inputAspectRatio": 1.0])
            .cropped(to: extent)
        // 2) 色彩渗色：水平拖影 + 亮度混合模式——亮度取原帧（保持清晰）、色度取拖影（渗色）
        //    （通道拆分重组在 CI 预乘合成下亮度失真，已验证弃用）
        let smear = softened.applyingFilter("CIMotionBlur", parameters: ["inputAngle": 0.0, "inputRadius": 3.0])
        image = smear.applyingFilter("CILuminosityBlendMode", parameters: ["inputBackgroundImage": softened])
        // 3) 饱和轻降 + 对比轻提（磁带褪色感）
        image = image.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": 0.85, "inputContrast": 1.06, "inputBrightness": 0.01,
        ])
        // 4) 暗角
        image = image.applyingFilter("CIVignette", parameters: ["inputIntensity": 0.6, "inputRadius": 2.0])
        // 5) 扫描线（水平条纹 multiply，周期 2 输出行：条纹宽 1 + 隙 1）
        if let scanline = scanlinePattern(extent: extent) {
            image = image.applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": scanline])
        }
        // 6) 噪点（磁带雪花）
        if let grain = noiseLayer(extent: extent, phase: noise, strength: 0.12) {
            image = image.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": grain])
        }
        return image.cropped(to: extent)
    }

    /// 老 DV 数码感：色度偏淡 → 水平轻拖影（4:1:1 近似）→ 轻噪点；OSD 由调用方叠加。
    private static func dvChain(_ input: CIImage, extent: CGRect, noise: CGPoint) -> CIImage {
        var image = input
        image = image.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": 0.86, "inputContrast": 1.03, "inputBrightness": 0.0,
        ])
        image = image.applyingFilter("CIMotionBlur", parameters: ["inputAngle": 0.0, "inputRadius": 3.0])
        if let grain = noiseLayer(extent: extent, phase: noise, strength: 0.05) {
            image = image.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": grain])
        }
        return image.cropped(to: extent)
    }

    /// 扫描线图案：竖条纹生成器旋转 90° → 水平条纹，周期 2px（条纹 1px + 隙 1px）、暗行 0.82。
    private static func scanlinePattern(extent: CGRect) -> CIImage? {
        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1)
        stripes.color1 = CIColor(red: 0.82, green: 0.82, blue: 0.82)
        // width 是条纹宽度而非周期：1 → 周期 2，逐行明暗交替
        stripes.width = 1.0
        stripes.sharpness = 1.0
        guard let pattern = stripes.outputImage else { return nil }
        return pattern
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            .cropped(to: extent)
    }

    /// 噪点层：随机生成图按帧相位平移（每帧噪声不同且确定性），缩放至 ±strength/2 加性噪声。
    private static func noiseLayer(extent: CGRect, phase: CGPoint, strength: Double) -> CIImage? {
        let random = CIFilter.randomGenerator()
        guard let raw = random.outputImage else { return nil }
        let s = CGFloat(strength)
        return raw
            .transformed(by: CGAffineTransform(translationX: phase.x, y: phase.y))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -s / 2, y: -s / 2, z: -s / 2, w: 0),
            ])
            .cropped(to: extent)
    }

    // MARK: - DV OSD（日期时间戳）

    /// 右上角 OSD 叠加图；基准时间缺失时返回 nil。
    private func osdOverlay(pts: Double) -> CIImage? {
        guard let base = osdBaseDate else { return nil }
        let date = Self.osdDate(base: base, pts: pts)
        // 分钟粒度缓存：时间文案每分钟才变一次
        let cacheKey = Int(floor(date.timeIntervalSince1970 / 60))
        if cacheKey != osdCacheKey || osdImage == nil {
            let lines = Self.osdLines(for: date)
            let fontSize = max(CGFloat(height) * 0.024, 14)
            osdImage = Self.renderOSDImage(top: lines.top, bottom: lines.bottom, fontSize: fontSize)
            osdCacheKey = cacheKey
        }
        guard let osd = osdImage else { return nil }
        let margin = CGFloat(width) * 0.04
        let size = osd.extent.size
        let position = CGPoint(
            x: CGFloat(width) - size.width - margin,
            y: CGFloat(height) - size.height - margin
        )
        return osd.transformed(by: CGAffineTransform(translationX: position.x, y: position.y))
    }

    /// CoreText 渲染双行 OSD（等宽字体白字 + 轻阴影，透明底）。
    static func renderOSDImage(top: String, bottom: String, fontSize: CGFloat) -> CIImage? {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
        ]
        guard let topLine = makeLine(top, attributes: attributes),
              let bottomLine = makeLine(bottom, attributes: attributes)
        else { return nil }
        let widthTop = CGFloat(CTLineGetTypographicBounds(topLine, nil, nil, nil))
        let widthBottom = CGFloat(CTLineGetTypographicBounds(bottomLine, nil, nil, nil))
        let lineHeight = fontSize * 1.4
        let canvasWidth = Int(ceil(max(widthTop, widthBottom) + fontSize * 0.6))
        let canvasHeight = Int(ceil(lineHeight * 2 + fontSize * 0.5))
        guard canvasWidth > 0, canvasHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: canvasWidth,
                  height: canvasHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: canvasWidth * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setShadow(
            offset: CGSize(width: 1, height: -1),
            blur: 1.5,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
        )
        // CGContext 位图 y 向下、CoreText y 向上：翻转后 y 为「距顶部距离」
        context.translateBy(x: fontSize * 0.3, y: CGFloat(canvasHeight))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: fontSize * 0.25)
        CTLineDraw(topLine, context)
        context.textPosition = CGPoint(x: 0, y: fontSize * 0.25 + lineHeight)
        CTLineDraw(bottomLine, context)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static func makeLine(_ text: String, attributes: [CFString: Any]) -> CTLine? {
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return nil
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    // MARK: - 缓冲

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw TranscodeEngineError.readWriteFailed("复古滤镜缓冲创建失败：\(status)")
        }
        return buffer
    }
}
