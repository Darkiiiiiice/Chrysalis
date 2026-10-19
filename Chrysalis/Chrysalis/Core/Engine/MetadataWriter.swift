import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 电影元数据 → 容器 metadata（设计文档 §7.5 + P0 实测报告第 6 节）。
/// MP4 用 iTunes 写法（itsk）；MOV 用 QuickTime mdta 主字段 + itsk 标题兜底。
enum MetadataWriter {
    /// 生成 `AVAssetWriter.metadata`（需在 start 之前设置）。
    static func items(container: MediaContainer, metadata: MovieMetadata, posterData: Data?) -> [AVMetadataItem] {
        switch container {
        case .mp4:
            mp4Items(metadata: metadata, posterData: posterData)
        case .mov:
            movItems(metadata: metadata, posterData: posterData)
        }
    }

    // MARK: - MP4（iTunes）

    private static func mp4Items(metadata: MovieMetadata, posterData: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(stringItem(.iTunesMetadataSongName, metadata.title))
        if let overview = nonEmpty(metadata.overview) {
            items.append(stringItem(.iTunesMetadataDescription, overview))
        }
        if let releaseDate = nonEmpty(metadata.releaseDate) {
            items.append(stringItem(.iTunesMetadataReleaseDate, releaseDate))
        }
        if !metadata.genres.isEmpty {
            items.append(stringItem(.iTunesMetadataUserGenre, metadata.genres.joined(separator: " / ")))
        }
        if let director = nonEmpty(metadata.director) {
            items.append(stringItem(.iTunesMetadataDirector, director))
            items.append(stringItem(.iTunesMetadataArtist, director))
        }
        if let comment = commentText(metadata) {
            items.append(stringItem(.iTunesMetadataUserComment, comment))
        }
        if let posterData, let artwork = artworkItem(
            keySpace: .iTunes, key: "covr", identifier: nil, data: posterData
        ) {
            items.append(artwork)
        }
        return items
    }

    // MARK: - MOV（QuickTime mdta + itsk 标题）

    private static func movItems(metadata: MovieMetadata, posterData: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(stringItem(.quickTimeMetadataTitle, metadata.title))
        items.append(stringItem(.iTunesMetadataSongName, metadata.title))
        if let overview = nonEmpty(metadata.overview) {
            items.append(stringItem(.quickTimeMetadataDescription, overview))
        }
        if let releaseDate = nonEmpty(metadata.releaseDate) {
            items.append(stringItem(.quickTimeMetadataCreationDate, releaseDate))
        }
        if !metadata.genres.isEmpty {
            items.append(stringItem(.quickTimeMetadataGenre, metadata.genres.joined(separator: " / ")))
        }
        if let director = nonEmpty(metadata.director) {
            items.append(stringItem(.quickTimeMetadataDirector, director))
        }
        if let comment = commentText(metadata) {
            items.append(stringItem(.quickTimeMetadataComment, comment))
        }
        if let posterData, let artwork = artworkItem(
            keySpace: nil, key: nil, identifier: .quickTimeMetadataArtwork, data: posterData
        ) {
            items.append(artwork)
        }
        return items
    }

    // MARK: - 写入后自检（设计文档 §7.5：读回关键字段，缺失给警告但保留输出）

    static func verificationIssues(
        url: URL,
        container: MediaContainer,
        metadata: MovieMetadata,
        expectsArtwork: Bool
    ) async -> [String] {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else {
            return ["元数据读回失败"]
        }
        var issues: [String] = []

        switch container {
        case .mp4:
            if await stringValue(of: .iTunesMetadataSongName, in: items) != metadata.title {
                issues.append("元数据写入不完整：缺少标题")
            }
            if nonEmpty(metadata.overview) != nil,
               await stringValue(of: .iTunesMetadataDescription, in: items) == nil {
                issues.append("元数据写入不完整：缺少简介")
            }
            if expectsArtwork, !hasMP4Artwork(in: items) {
                issues.append("元数据写入不完整：缺少海报")
            }
        case .mov:
            if await stringValue(of: .quickTimeMetadataTitle, in: items) != metadata.title {
                issues.append("元数据写入不完整：缺少标题")
            }
            if nonEmpty(metadata.overview) != nil,
               await stringValue(of: .quickTimeMetadataDescription, in: items) == nil {
                issues.append("元数据写入不完整：缺少简介")
            }
            if expectsArtwork, await !hasDataValue(of: .quickTimeMetadataArtwork, in: items) {
                issues.append("元数据写入不完整：缺少海报")
            }
        }
        return issues
    }

    // MARK: - 工具

    private static func stringItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        return item
    }

    /// 海报条目：MP4 用 keySpace + key（`.commonIdentifierArtwork` 无效，见 P0 报告）。
    private static func artworkItem(
        keySpace: AVMetadataKeySpace?,
        key: String?,
        identifier: AVMetadataIdentifier?,
        data: Data
    ) -> AVMetadataItem? {
        let item = AVMutableMetadataItem()
        if let identifier {
            item.identifier = identifier
        } else if let keySpace, let key {
            item.keySpace = keySpace
            item.key = key as NSString
        } else {
            return nil
        }
        item.value = data as NSData
        item.dataType = imageDataType(of: data)?.identifier
        return item
    }

    private static func imageDataType(of data: Data) -> UTType? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if data.starts(with: [0xFF, 0xD8]) { return .jpeg }
        return nil
    }

    /// 原名/演员/TMDB ID 汇总进 comment（设计文档 §7.5 字段映射）。
    private static func commentText(_ metadata: MovieMetadata) -> String? {
        var parts: [String] = []
        if let originalTitle = nonEmpty(metadata.originalTitle) {
            parts.append("Original Title: \(originalTitle)")
        }
        if !metadata.cast.isEmpty {
            parts.append("Cast: \(metadata.cast.prefix(5).joined(separator: ", "))")
        }
        if let tmdbID = metadata.tmdbID {
            parts.append("TMDB: \(tmdbID)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    /// MP4 海报读回判定：写入用 keySpace+key，读回时 key 为空、identifier 呈现为 `itsk/covr`。
    private static func hasMP4Artwork(in items: [AVMetadataItem]) -> Bool {
        items.contains { item in
            if item.identifier?.rawValue == "itsk/covr" { return true }
            return item.keySpace == .iTunes && (item.key as? String) == "covr"
        }
    }

    private static func stringValue(
        of identifier: AVMetadataIdentifier,
        in items: [AVMetadataItem]
    ) async -> String? {
        guard let item = items.first(where: { $0.identifier == identifier }) else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func hasDataValue(
        of identifier: AVMetadataIdentifier,
        in items: [AVMetadataItem]
    ) async -> Bool {
        guard let item = items.first(where: { $0.identifier == identifier }) else { return false }
        let data = try? await item.load(.dataValue)
        return data?.isEmpty == false
    }
}
