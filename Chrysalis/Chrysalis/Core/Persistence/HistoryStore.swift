import Foundation
import Observation
import os

/// 历史记录仓库（设计文档 §9）：`Application Support/Chrysalis/history.json`，
/// 最多 500 条，超出时淘汰最旧记录；电影记录保留元数据快照。
@MainActor
@Observable
final class HistoryStore {
    static let capacity = 500

    private(set) var entries: [HistoryEntry] = []

    private struct Archive: Codable {
        static let currentVersion = 1
        var version: Int
        var entries: [HistoryEntry]
    }

    init() {
        load()
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 任务到达终态时记录一条（设计文档 §8.6）。
    func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// 清空全部历史（设置页「清除历史」也走这里）。
    func clearAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    /// 编辑元数据（人工勘误，source 记为 manual；设计文档 §7.5）。
    func updateMovieMetadata(id: UUID, metadata: MovieMetadata) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].movieMetadata = metadata
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.historyFileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(Archive.self, from: data)
            entries = archive.entries
        } catch {
            Log.app.error("读取历史记录失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let archive = Archive(version: Archive.currentVersion, entries: entries)
        do {
            let data = try encoder.encode(archive)
            try data.write(to: AppPaths.historyFileURL, options: .atomic)
        } catch {
            Log.app.error("保存历史记录失败：\(String(describing: error), privacy: .public)")
        }
    }
}

/// 历史页编辑元数据的 Sheet 上下文。
struct HistoryMetadataContext: Identifiable, Equatable {
    let id: UUID
}
