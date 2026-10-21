import Foundation

/// 画质修复模式（设计文档 §7.6）。
enum EnhancementMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// Core ML 神经超分（Real-ESRGAN）。
    case neural
    /// Core Image 轻量修复（Lanczos + USM），不加载模型。
    case filter

    var displayName: String {
        switch self {
        case .neural: "神经超分"
        case .filter: "轻量修复"
        }
    }

    var summary: String {
        switch self {
        case .neural: "Real-ESRGAN 模型，画质优先但较慢"
        case .filter: "系统滤镜放大 + 锐化，速度快"
        }
    }
}

/// 神经超分模型档位（设计文档 §7.6：双模式）。
enum NeuralUpscalerModel: String, Sendable, Codable, CaseIterable, Hashable {
    /// `realesr-general-x4v3`：半分辨率 4x，通用实拍。
    case fast
    /// `RealESRGANv2-animevideo-xsx2`：原生 2x，动画调优。
    case fine

    var displayName: String {
        switch self {
        case .fast: "快速（通用）"
        case .fine: "精细（动画）"
        }
    }

    /// 检查器/队列徽章使用的短名。
    var shortName: String {
        switch self {
        case .fast: "快速"
        case .fine: "精细"
        }
    }

    /// 模型资源名（`.mlmodelc` 去掉扩展名）。
    var resourceName: String {
        switch self {
        case .fast: "GeneralX4v3-t352x288"
        case .fine: "AnimeVideoXS2-t384"
        }
    }

    var modelDisplayName: String {
        switch self {
        case .fast: "realesr-general-x4v3"
        case .fine: "RealESRGANv2-animevideo-xsx2"
        }
    }

    var speedHint: String {
        switch self {
        case .fast: "约 0.14x 实时（1 分钟片约 7 分钟）"
        case .fine: "较慢，约 0.06–0.07x 实时（1 分钟片约 15–17 分钟）"
        }
    }

    var tileDescription: String {
        switch self {
        case .fast: "352×288 tile · 0.5x 预降采样 + 4x"
        case .fine: "384×384 tile · 原生 2x"
        }
    }
}

/// 修复强度（设计文档 §7.6：三档共用一次推理）。
enum EnhancementStrength: String, Sendable, Codable, CaseIterable, Hashable {
    case light
    case balanced
    case strong

    var displayName: String {
        switch self {
        case .light: "轻度"
        case .balanced: "均衡"
        case .strong: "强力"
        }
    }

    var summary: String {
        switch self {
        case .light: "保留更多原始细节，效果更自然"
        case .balanced: "默认档，细节与自然度折中"
        case .strong: "锐化更明显，适合动画/低清素材"
        }
    }
}

/// 任务级画质修复设置（设计文档 §7.6）。
///
/// `nil` 表示关闭；与转码预设正交。开启后输出固定为源显示尺寸 ×2，
/// 分辨率档位由队列/引擎锁定为「保持源」。
struct EnhancementSetting: Sendable, Codable, Hashable {
    var mode: EnhancementMode
    var neuralModel: NeuralUpscalerModel
    var strength: EnhancementStrength

    init(
        mode: EnhancementMode = .neural,
        neuralModel: NeuralUpscalerModel = .fast,
        strength: EnhancementStrength = .balanced
    ) {
        self.mode = mode
        self.neuralModel = neuralModel
        self.strength = strength
    }

    static let defaultNeural = EnhancementSetting()
    static let defaultFilter = EnhancementSetting(mode: .filter)

    var isNeural: Bool { mode == .neural }

    /// 输出倍率（v1 固定 2x）。
    var outputScale: Int { 2 }

    /// 队列行/历史徽章文案。
    var badgeText: String {
        switch mode {
        case .neural: "修复·\(neuralModel.shortName)"
        case .filter: "修复·滤镜"
        }
    }

    /// 检查器摘要。
    var summary: String {
        switch mode {
        case .neural:
            "\(neuralModel.displayName) · \(strength.displayName)"
        case .filter:
            "\(EnhancementMode.filter.displayName) · \(strength.displayName)"
        }
    }

    /// 速度预估（UI 如实展示，不承诺精细档 0.1x）。
    var speedHint: String {
        switch mode {
        case .neural: neuralModel.speedHint
        case .filter: "通常 ≥1x 实时（取决于输出分辨率与 GPU）"
        }
    }

    /// 模型资源名；滤镜模式为 nil。
    var modelResourceName: String? {
        isNeural ? neuralModel.resourceName : nil
    }

    /// 模型/管线描述，用于检查器和输出 notes。
    var pipelineDescription: String {
        switch mode {
        case .neural:
            "\(neuralModel.modelDisplayName) · \(neuralModel.tileDescription)"
        case .filter:
            "Core Image Lanczos 2x + USM"
        }
    }
}
