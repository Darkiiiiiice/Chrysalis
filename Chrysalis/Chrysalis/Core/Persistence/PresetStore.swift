import Foundation
import Observation
import os

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedPresetID = defaults.string(forKey: Self.selectedIDKey) ?? TranscodePreset.defaultPreset.id
        self.customPresets = Self.loadCustomPresets()
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
    func validationMessage(name: String, bitrate1080p: Int, excludingID: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "名称不能为空。"
        }
        if allPresets.contains(where: { $0.name == trimmed && $0.id != excludingID }) {
            return "已有同名预设，请换一个名称。"
        }
        if !(1_000_000...40_000_000).contains(bitrate1080p) {
            return "基准码率需在 1–40 Mbps 之间。"
        }
        return nil
    }

    /// 新建自定义预设（由来源预设复制，表单覆盖名称/编码/音频/基准码率）。
    @discardableResult
    func create(
        copyOf base: TranscodePreset,
        name: String,
        videoCodec: VideoCodec,
        audioBitrate: Int,
        bitrate1080p: Int
    ) -> TranscodePreset? {
        guard validationMessage(name: name, bitrate1080p: bitrate1080p, excludingID: nil) == nil else {
            return nil
        }
        var preset = TranscodePreset.copy(
            of: base,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        preset.bitrateRange = Self.scaled(base.bitrateRange, by: Double(bitrate1080p) / Double(base.bitrate1080p))
        preset.videoCodec = videoCodec
        preset.audio = .stereoAAC(bitrate: audioBitrate)
        preset.bitrate1080p = bitrate1080p
        customPresets.append(preset)
        saveCustomPresets()
        return preset
    }

    /// 编辑自定义预设；夹取范围随基准码率等比缩放（保持预设意图）。
    @discardableResult
    func update(
        id: String,
        name: String,
        videoCodec: VideoCodec,
        audioBitrate: Int,
        bitrate1080p: Int
    ) -> TranscodePreset? {
        guard validationMessage(name: name, bitrate1080p: bitrate1080p, excludingID: id) == nil,
              let index = customPresets.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var updated = customPresets[index]
        updated.bitrateRange = Self.scaled(updated.bitrateRange, by: Double(bitrate1080p) / Double(updated.bitrate1080p))
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.videoCodec = videoCodec
        updated.audio = .stereoAAC(bitrate: audioBitrate)
        updated.bitrate1080p = bitrate1080p
        customPresets[index] = updated
        saveCustomPresets()
        return updated
    }

    func delete(id: String) {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        customPresets.remove(at: index)
        if selectedPresetID == id {
            select(id: TranscodePreset.defaultPreset.id)
        }
        saveCustomPresets()
    }

    private static func scaled(_ range: ClosedRange<Int>, by ratio: Double) -> ClosedRange<Int> {
        guard ratio > 0, ratio != 1 else { return range }
        let lower = Int((Double(range.lowerBound) * ratio).rounded())
        let upper = Int((Double(range.upperBound) * ratio).rounded())
        return min(lower, upper)...max(lower, upper)
    }

    // MARK: - 持久化

    private static func loadCustomPresets() -> [TranscodePreset] {
        guard let data = try? Data(contentsOf: AppPaths.presetsFileURL) else { return [] }
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
            try encoder.encode(customPresets).write(to: AppPaths.presetsFileURL, options: .atomic)
        } catch {
            Log.app.error("保存自定义预设失败：\(String(describing: error), privacy: .public)")
        }
    }
}
