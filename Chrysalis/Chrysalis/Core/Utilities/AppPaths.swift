import Foundation

/// 应用数据位置（设计文档 §9）：`Application Support/Chrysalis/`。
enum AppPaths {
    /// 沙盒容器内的 Application Support/Chrysalis（不存在则创建）。
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Chrysalis", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var presetsFileURL: URL { supportDirectory.appendingPathComponent("presets.json") }
    static var queueFileURL: URL { supportDirectory.appendingPathComponent("queue.json") }

    /// TMDB 元数据缓存目录（搜索/详情/海报，7 天；设计文档 §7.5）。
    static var metadataCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? supportDirectory
        let dir = base.appendingPathComponent("Chrysalis/Metadata", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
