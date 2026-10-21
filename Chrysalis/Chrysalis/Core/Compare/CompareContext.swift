import Foundation

/// A/B 质量对比上下文（设计文档 §7.9）：`openWindow(item:)` 携带的值类型。
///
/// 只存路径与输入书签；访问权在对比窗口打开时经 `BookmarkStore` 恢复。
struct CompareContext: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourcePath: String
    var outputPath: String
    /// 源文件的输入书签快照（历史 / 队列任务带入）。
    var sourceBookmark: Data?
    /// 窗口标题（源文件名）。
    var title: String

    init(id: UUID = UUID(), sourceURL: URL, outputURL: URL, sourceBookmark: Data? = nil) {
        self.id = id
        self.sourcePath = sourceURL.path(percentEncoded: false)
        self.outputPath = outputURL.path(percentEncoded: false)
        self.sourceBookmark = sourceBookmark
        self.title = sourceURL.lastPathComponent
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var outputURL: URL { URL(fileURLWithPath: outputPath) }
}

/// A/B 双侧规格行（设计文档 §7.9）：读回媒体信息后的展示纯函数。
enum CompareSpecs {
    /// 单侧规格行：`1920×1080 · HEVC · 4.2 Mbps · 128 MB`。
    static func summaryLine(_ info: MediaInfo) -> String {
        var parts: [String] = []
        parts.append(info.dimensionsLabel)
        if let codec = info.video?.codecName {
            parts.append(codec.uppercased())
        }
        if let bitrate = info.video?.bitrate, bitrate > 0 {
            parts.append(Fmt.mbps(bitrate))
        }
        parts.append(Fmt.bytes(info.fileSizeBytes))
        return parts.joined(separator: " · ")
    }
}
