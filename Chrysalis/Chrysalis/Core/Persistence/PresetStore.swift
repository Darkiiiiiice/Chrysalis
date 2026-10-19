import Foundation
import Observation
import os

/// 预设编辑器提交的参数（设计文档 P3.5 / P4）。
struct PresetDraft: Sendable, Equatable {
    var name: String
    var videoCodec: VideoCodec
    var container: MediaContainer
    var resolution: ResolutionSetting
    var frameRate: FrameRateSetting
    var bitrate1080p: Int
    var bitrateMode: BitrateMode
    var quality: Double
    var targetSizeMB: Int
    var keyframeInterval: KeyframeIntervalSetting
    var profile: VideoProfileSetting
    var audioBitrate: Int
    var audioSampleRate: Double?
    var audioChannels: Int
    var audioPCMSampleBitDepth: Int?
}

/// 预设仓库（设计文档 §9）：内置预设写在代码里；自定义预设存
/// `Application Support/Chrysalis/presets.json`；新任务默认预设记在 UserDefaults。
@MainActor
@Observable
final class PresetStore {
    private(set) var customPresets: [TranscodePreset] = []
    /// 新任务默认使用的预设 ID。
    private(set) var selectedPresetID: String

    private static let selectedIDKey = "preset.selectedID"
    private let defaults: UserDefaults
    private let fileURL: URL

    init(defaults: UserDefaults = .standard, fileURL: URL = AppPaths.presetsFileURL) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.selectedPresetID = defaults.string(forKey: Self.selectedIDKey) ?? TranscodePreset.defaultPreset.id
        self.customPresets = Self.loadCustomPresets(from: fileURL)
        // 预设被删除/文件损坏时回退到默认
        if preset(id: selectedPresetID) == nil {
            selectedPresetID = TranscodePreset.defaultPreset.id
        }
    }

    // MARK: - 查询

    var allPresets: [TranscodePreset] { TranscodePreset.builtIns + customPresets }

    func preset(id: String?) -> TranscodePreset? {
        guard let id else { return nil }
        return allPresets.first { $0.id == id }
    }

    var selectedPreset: TranscodePreset {
        preset(id: selectedPresetID) ?? .defaultPreset
    }

    /// 复制为自定义时的默认名称（“X 副本”“X 副本 2”…）。
    func uniqueName(basedOn base: String) -> String {
        var candidate = "\(base) 副本"
        var index = 2
        while allPresets.contains(where: { $0.name == candidate }) {
            candidate = "\(base) 副本 \(index)"
            index += 1
        }
        return candidate
    }

    // MARK: - 修改

    func select(id: String) {
        guard preset(id: id) != nil else { return }
        selectedPresetID = id
        defaults.set(id, forKey: Self.selectedIDKey)
    }

    /// 校验自定义预设表单（合法返回 nil，否则返回错误文案）。
    func validationMessage(_ draft: PresetDraft, excludingID: String?) -> String? {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "名称不能为空。"
        }
        if allPresets.contains(where: { $0.name == trimmed && $0.id != excludingID }) {
            return "已有同名预设，请换一个名称。"
        }
        if draft.videoCodec.isProRes {
            // 容器由 `apply` 归一为 MOV（设计文档 §3：ProRes 仅 MOV），此处只校验 PCM 位深。
            if let depth = draft.audioPCMSampleBitDepth, !AudioPolicy.pcmBitDepthChoices.contains(depth) {
                return "PCM 位深仅支持 16-bit / 24-bit。"
            }
            return nil
        }
        switch draft.bitrateMode {
        case .targetBitrate:
            if !(1_000_000...40_000_000).contains(draft.bitrate1080p) {
                return "基准码率需在 1–40 Mbps 之间。"
            }
        case .quality:
            if !(0.05...1.0).contains(draft.quality) {
                return "质量值需在 0.05–1.0 之间。"
            }
        case .targetSize:
            if !(1...100_000).contains(draft.targetSizeMB) {
                return "目标大小需在 1–100000 MB 之间。"
            }
        }
        return nil
    }

    /// 新建自定义预设（由来源预设复制，表单覆盖视频/容器/分辨率/帧率/音频/码率控制）。
    @discardableResult
    func create(copyOf base: TranscodePreset, draft: PresetDraft) -> TranscodePreset? {
        guard validationMessage(draft, excludingID: nil) == nil else {
            return nil
        }
        var preset = TranscodePreset.copy(
            of: base,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if base.bitrate1080p > 0, draft.bitrateMode == .targetBitrate, !draft.videoCodec.isProRes {
            preset.bitrateRange = Self.scaled(
                base.bitrateRange,
                by: Double(draft.bitrate1080p) / Double(base.bitrate1080p)
            )
        }
        Self.apply(draft, to: &preset)
        customPresets.append(preset)
        saveCustomPresets()
        return preset
    }

    /// 编辑自定义预设；夹取范围随基准码率等比缩放（保持预设意图）。
    @discardableResult
    func update(id: String, draft: PresetDraft) -> TranscodePreset? {
        guard validationMessage(draft, excludingID: id) == nil,
              let index = customPresets.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var updated = customPresets[index]
        if updated.bitrate1080p > 0, draft.bitrateMode == .targetBitrate, !draft.videoCodec.isProRes {
            updated.bitrateRange = Self.scaled(
                updated.bitrateRange,
                by: Double(draft.bitrate1080p) / Double(updated.bitrate1080p)
            )
        }
        updated.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.apply(draft, to: &updated)
        customPresets[index] = updated
        saveCustomPresets()
        return updated
    }

    private static func apply(_ draft: PresetDraft, to preset: inout TranscodePreset) {
        preset.videoCodec = draft.videoCodec
        // ProRes 仅能装 MOV；音频固定 PCM（默认 16-bit）。
        preset.container = draft.videoCodec.isProRes ? .mov : draft.container
        preset.resolution = draft.resolution
        preset.frameRate = draft.frameRate
        preset.bitrate1080p = draft.bitrate1080p
        preset.bitrateMode = draft.videoCodec.isProRes ? .targetBitrate : draft.bitrateMode
        preset.quality = min(max(draft.quality, 0.05), 1.0)
        preset.targetSizeMB = max(draft.targetSizeMB, 1)
        preset.keyframeInterval = draft.keyframeInterval
        preset.profile = draft.videoCodec == .h264 ? draft.profile : .auto
        preset.audio = AudioPolicy(
            bitrate: draft.audioBitrate,
            sampleRateOverride: draft.audioSampleRate,
            maxChannels: draft.audioChannels,
            pcmBitDepth: draft.videoCodec.isProRes ? (draft.audioPCMSampleBitDepth ?? 16) : nil
        )
    }

    func delete(id: String) {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        customPresets.remove(at: index)
        if selectedPresetID == id {
            select(id: TranscodePreset.defaultPreset.id)
        }
        saveCustomPresets()
    }

    nonisolated static func scaled(_ range: ClosedRange<Int>, by ratio: Double) -> ClosedRange<Int> {
        guard ratio > 0, ratio != 1 else { return range }
        let lower = Int((Double(range.lowerBound) * ratio).rounded())
        let upper = Int((Double(range.upperBound) * ratio).rounded())
        return min(lower, upper)...max(lower, upper)
    }

    // MARK: - 持久化

    private static func loadCustomPresets(from fileURL: URL) -> [TranscodePreset] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([TranscodePreset].self, from: data).filter { !$0.isBuiltIn }
        } catch {
            Log.app.error("读取自定义预设失败：\(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func saveCustomPresets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(customPresets).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("保存自定义预设失败：\(String(describing: error), privacy: .public)")
        }
    }
}
