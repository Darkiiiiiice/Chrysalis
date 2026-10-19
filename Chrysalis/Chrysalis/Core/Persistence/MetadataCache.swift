import CryptoKit
import Foundation

/// TMDB 响应缓存（设计文档 §7.5）：搜索/详情缓存 7 天；海报数据同目录。
/// 文件级 JSON 封装（savedAt + payload），key 用 SHA-256 落成文件名。
struct MetadataCache: Sendable {
    var directory: URL
    var maxAge: TimeInterval

    init(directory: URL = AppPaths.metadataCacheDirectory, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory
        self.maxAge = maxAge
    }

    private struct Envelope<T: Codable>: Codable {
        var savedAt: Date
        var payload: T
    }

    func read<T: Codable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              Date.now.timeIntervalSince(envelope.savedAt) < maxAge else {
            return nil
        }
        return envelope.payload
    }

    func write<T: Codable>(_ value: T, key: String) {
        let envelope = Envelope(savedAt: .now, payload: value)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    // MARK: - 海报

    func posterData(forPath path: String) -> Data? {
        try? Data(contentsOf: posterFileURL(for: path))
    }

    func storePoster(data: Data, path: String) {
        let url = posterFileURL(for: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 路径

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.hash(key) + ".json")
    }

    private func posterFileURL(for path: String) -> URL {
        directory
            .appendingPathComponent("posters", isDirectory: true)
            .appendingPathComponent(Self.hash(path) + ".img")
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
