import Foundation

/// 输出路径规划（App 侧 Utilities 的原型）。
/// 规则来自设计文档第 6.4 / 9 节：
/// - 输出重名默认加 `-1`、`-2`，不覆盖；
/// - 写入同目录临时文件 `.chrysalis-*.tmp`，失败/取消删除，启动时清理残留。
enum OutputPlanner {
    static let tempPrefix = ".chrysalis-"
    static let tempSuffix = ".tmp"

    /// 在指定目录中为 baseName 找到不冲突的 `name.ext`、`name-1.ext`、`name-2.ext` …
    static func uniqueOutputURL(directory: URL, baseName: String, fileExtension: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var index = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).\(fileExtension)")
            index += 1
        }
        return candidate
    }

    /// 同目录临时文件：写入时用，成功后原子移动到最终路径。
    static func makeTempURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString)\(tempSuffix)")
    }

    /// 目录中是否还有 `.chrysalis-*.tmp` 残留。
    static func hasOrphanTemps(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.contains { $0.hasPrefix(tempPrefix) && $0.hasSuffix(tempSuffix) }
    }

    /// 清理目录中的残留临时文件（App 启动时调用；P0 验证此函数行为）。
    @discardableResult
    static func cleanupOrphanTemps(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }

        var removed: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(tempPrefix) && name.hasSuffix(tempSuffix) {
                try? fm.removeItem(at: entry)
                if !fm.fileExists(atPath: entry.path) {
                    removed.append(entry)
                }
            }
        }
        return removed
    }
}
