@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 结果结构

struct MetadataProbeRow: Codable {
    var field: String
    var label: String
    var writtenIdentifier: String
    var writtenKeySpace: String
    var writtenKey: String
    var readBackPresent: Bool
    var readBackIdentifier: String?
    var readBackKeySpaceKey: String?
    var readBackValuePrefix: String?
    var note: String?
}

struct MetadataReadbackDumpRow: Codable {
    var identifier: String
    var keySpaceKey: String
    var valuePrefix: String
}

struct MetadataRoundtrip: Codable {
    var container: String
    var file: String
    var rows: [MetadataProbeRow]
    var dump: [MetadataReadbackDumpRow]
    var combo: [MetadataProbeRow]
    var comboDump: [MetadataReadbackDumpRow]
    var transcodeFailures: [String]
}

struct MetadataProbeResult: Codable {
    var mp4: MetadataRoundtrip
    var mov: MetadataRoundtrip
}

// MARK: - 探针

/// 逐个候选 identifier 做“写入 → AVURLAsset 读回”，记录哪些真正生效。
/// 每个候选单独转码一个 1 秒小片，保证归属清晰。
enum MetadataProbe {
    struct Candidate {
        var field: String
        var label: String
        var identifier: AVMetadataIdentifier?
        var keySpace: AVMetadataKeySpace? = nil
        var key: String? = nil
        var value: Any
        var dataType: String?
    }

    static func makeCandidates(posterPNG: Data) -> [Candidate] {
        let overview = "保罗·厄崔迪家族卷入了对阿拉基斯星球上最珍贵资源的争夺。"
        let comment = "Original Title: Dune | Cast: 提莫西·查拉梅, 丽贝卡·弗格森 | TMDB: 438631"
        return [
            Candidate(field: "标题", label: "common.title", identifier: .commonIdentifierTitle, value: "沙丘", dataType: nil),
            Candidate(field: "标题", label: "iTunes.©nam", identifier: .iTunesMetadataSongName, value: "沙丘", dataType: nil),
            Candidate(field: "标题", label: "quicktime.title", identifier: .quickTimeMetadataTitle, value: "沙丘", dataType: nil),

            Candidate(field: "简介", label: "common.description", identifier: .commonIdentifierDescription, value: overview, dataType: nil),
            Candidate(field: "简介", label: "iTunes.desc", identifier: .iTunesMetadataDescription, value: overview, dataType: nil),
            Candidate(field: "简介", label: "quicktime.description", identifier: .quickTimeMetadataDescription, value: overview, dataType: nil),

            Candidate(field: "上映日期", label: "iTunes.©day", identifier: .iTunesMetadataReleaseDate, value: "2021-10-22", dataType: nil),
            Candidate(field: "上映日期", label: "quicktime.creationdate", identifier: .quickTimeMetadataCreationDate, value: "2021-10-22T00:00:00Z", dataType: nil),
            Candidate(field: "创建日期", label: "common.creationdate", identifier: .commonIdentifierCreationDate, value: "2021-10-22T00:00:00Z", dataType: nil),

            Candidate(field: "类型", label: "iTunes.©gen", identifier: .iTunesMetadataUserGenre, value: "科幻", dataType: nil),
            Candidate(field: "类型", label: "quicktime.genre", identifier: .quickTimeMetadataGenre, value: "科幻", dataType: nil),

            Candidate(field: "导演", label: "iTunes.©dir", identifier: .iTunesMetadataDirector, value: "丹尼斯·维伦纽瓦", dataType: nil),
            Candidate(field: "导演", label: "quicktime.director", identifier: .quickTimeMetadataDirector, value: "丹尼斯·维伦纽瓦", dataType: nil),

            Candidate(field: "导演（备选）", label: "iTunes.©ART", identifier: .iTunesMetadataArtist, value: "丹尼斯·维伦纽瓦", dataType: nil),
            Candidate(field: "导演（备选）", label: "quicktime.artist", identifier: .quickTimeMetadataArtist, value: "丹尼斯·维伦纽瓦", dataType: nil),

            Candidate(field: "原名/演员/TMDB", label: "iTunes.©cmt", identifier: .iTunesMetadataUserComment, value: comment, dataType: nil),
            Candidate(field: "原名/演员/TMDB", label: "quicktime.comment", identifier: .quickTimeMetadataComment, value: comment, dataType: nil),

            Candidate(field: "海报", label: "common.artwork", identifier: .commonIdentifierArtwork, value: posterPNG, dataType: kCMMetadataBaseDataType_PNG as String),
            Candidate(field: "海报", label: "quicktime.artwork", identifier: .quickTimeMetadataArtwork, value: posterPNG, dataType: kCMMetadataBaseDataType_PNG as String),
            Candidate(
                field: "海报",
                label: "iTunes.covr",
                identifier: nil,
                keySpace: .iTunes,
                key: AVMetadataKey.iTunesMetadataKeyCoverArt.rawValue,
                value: posterPNG,
                dataType: kCMMetadataBaseDataType_PNG as String
            ),
        ]
    }

    /// 组合测试：按容器一次性写入的“推荐字段集”，验证多字段共存。
    static let comboLabels: [String: [String]] = [
        "MP4": ["iTunes.©nam", "iTunes.desc", "iTunes.©day", "iTunes.©gen", "iTunes.©dir", "iTunes.©ART", "iTunes.©cmt", "iTunes.covr"],
        "MOV": ["quicktime.title", "quicktime.description", "quicktime.creationdate", "quicktime.genre", "quicktime.director", "quicktime.comment", "quicktime.artwork"],
    ]

    static func makeItem(_ candidate: Candidate) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        if let identifier = candidate.identifier {
            item.identifier = identifier
        } else if let keySpace = candidate.keySpace, let key = candidate.key {
            item.keySpace = keySpace
            item.key = key as NSString
        }
        if let string = candidate.value as? String {
            item.value = string as NSString
            if let dataType = candidate.dataType { item.dataType = dataType }
        } else if let data = candidate.value as? Data {
            item.value = data as NSData
            if let dataType = candidate.dataType { item.dataType = dataType }
        }
        item.extendedLanguageTag = "und"
        return item
    }

    static func run(artifacts: Artifacts, capabilities: CapabilitiesReport) async throws -> MetadataProbeResult {
        let fm = FileManager.default
        let sourceURL = artifacts.sourcesDir.appendingPathComponent("meta-src.mp4")
        if !fm.fileExists(atPath: sourceURL.path) {
            Console.item("生成元数据探针用 1 秒小片（640x360，无音频）…")
            _ = try await ClipGenerator.generate(ClipGenerator.Spec(
                url: sourceURL,
                size: CGSize(width: 640, height: 360),
                codec: .h264,
                bitrate: 1_500_000,
                duration: 1,
                withAudio: false
            ))
        }

        let poster = makePosterPNG() ?? Data()
        let candidates = makeCandidates(posterPNG: poster)
        let encoderID = capabilities.hardwareEncoder(forCodecFourCC: "avc1")?.encoderID

        let mp4 = await roundtrip(
            container: "MP4",
            fileType: .mp4,
            ext: "mp4",
            candidates: candidates,
            sourceURL: sourceURL,
            artifacts: artifacts,
            encoderID: encoderID
        )
        let mov = await roundtrip(
            container: "MOV",
            fileType: .mov,
            ext: "mov",
            candidates: candidates,
            sourceURL: sourceURL,
            artifacts: artifacts,
            encoderID: encoderID
        )
        return MetadataProbeResult(mp4: mp4, mov: mov)
    }

    private static func roundtrip(
        container: String,
        fileType: AVFileType,
        ext: String,
        candidates: [Candidate],
        sourceURL: URL,
        artifacts: Artifacts,
        encoderID: String?
    ) async -> MetadataRoundtrip {
        Console.section("元数据写入/读回：\(container)")
        let fm = FileManager.default
        var rows: [MetadataProbeRow] = []
        var failures: [String] = []

        for (index, candidate) in candidates.enumerated() {
            let outputURL = artifacts.outputsDir
                .appendingPathComponent("meta-\(container.lowercased())-\(index).\(ext)")
            try? fm.removeItem(at: outputURL)

            let item = makeItem(candidate)

            let settings = TranscodeSettings(
                codec: .h264,
                fileType: fileType,
                outputSize: CGSize(width: 640, height: 360),
                bitrate: 1_500_000,
                frameDuration: nil,
                requireHardware: true,
                encoderID: encoderID,
                metadata: [item]
            )

            var failure: String?
            do {
                _ = try await Transcoder.run(
                    input: sourceURL,
                    settings: settings,
                    outputURL: outputURL,
                    cancelFlag: nil,
                    progress: nil
                )
            } catch {
                failure = "\(error)"
                failures.append("\(candidate.label): \(error)")
            }

            let readItems = ((failure == nil) ? (try? await AVURLAsset(url: outputURL).load(.metadata)) : nil) ?? []
            var row = await probeRow(candidate: candidate, readItems: readItems)
            row.note = failure
            rows.append(row)
            print(String(format: "  %@ %-22@ → %@", row.readBackPresent ? "✅" : "❌", candidate.label as NSString, failure ?? (row.readBackPresent ? "读回可见" : "读回不可见")))
        }

        // 完整 dump：最后写入的一项的容器里实际存在哪些 metadata
        var dump: [MetadataReadbackDumpRow] = []
        let lastURL = artifacts.outputsDir.appendingPathComponent("meta-\(container.lowercased())-\(candidates.count - 1).\(ext)")
        if let items = try? await AVURLAsset(url: lastURL).load(.metadata) {
            for item in items {
                dump.append(MetadataReadbackDumpRow(
                    identifier: item.identifier?.rawValue ?? "(nil)",
                    keySpaceKey: describe(item),
                    valuePrefix: valuePrefix((try? await item.load(.value)) ?? nil)
                ))
            }
        }

        // 组合测试：推荐字段集一次性写入 + 读回
        var comboRows: [MetadataProbeRow] = []
        var comboDump: [MetadataReadbackDumpRow] = []
        let comboURL = artifacts.outputsDir.appendingPathComponent("meta-\(container.lowercased())-combo.\(ext)")
        try? fm.removeItem(at: comboURL)
        if let labels = comboLabels[container] {
            let combo = candidates.filter { labels.contains($0.label) }
            let comboItems = combo.map { makeItem($0) }
            let settings = TranscodeSettings(
                codec: .h264,
                fileType: fileType,
                outputSize: CGSize(width: 640, height: 360),
                bitrate: 1_500_000,
                frameDuration: nil,
                requireHardware: true,
                encoderID: encoderID,
                metadata: comboItems
            )
            do {
                _ = try await Transcoder.run(
                    input: sourceURL,
                    settings: settings,
                    outputURL: comboURL,
                    cancelFlag: nil,
                    progress: nil
                )
                let readItems = (try? await AVURLAsset(url: comboURL).load(.metadata)) ?? []
                for readItem in readItems {
                    comboDump.append(MetadataReadbackDumpRow(
                        identifier: readItem.identifier?.rawValue ?? "(nil)",
                        keySpaceKey: describe(readItem),
                        valuePrefix: valuePrefix((try? await readItem.load(.value)) ?? nil)
                    ))
                }
                for candidate in combo {
                    comboRows.append(await probeRow(candidate: candidate, readItems: readItems))
                }
                let present = comboRows.filter(\.readBackPresent).count
                print(String(format: "  组合写入：%d 项中读回 %d 项", comboRows.count, present))
                for row in comboRows where !row.readBackPresent {
                    print(String(format: "    ❌ %@", row.label as NSString))
                }
            } catch {
                failures.append("组合写入失败: \(error)")
            }
        }

        return MetadataRoundtrip(
            container: container,
            file: lastURL.path,
            rows: rows,
            dump: dump,
            combo: comboRows,
            comboDump: comboDump,
            transcodeFailures: failures
        )
    }

    private static func probeRow(candidate: Candidate, readItems: [AVMetadataItem]) async -> MetadataProbeRow {
        let item = makeItem(candidate)
        var present = false
        var readIdentifier: String?
        var readKeySpaceKey: String?
        var readValue: String?
        for readItem in readItems where matches(readItem: readItem, candidate: item) {
            present = true
            readIdentifier = readItem.identifier?.rawValue
            readKeySpaceKey = describe(readItem)
            readValue = valuePrefix((try? await readItem.load(.value)) ?? nil)
            break
        }
        return MetadataProbeRow(
            field: candidate.field,
            label: candidate.label,
            writtenIdentifier: item.identifier?.rawValue ?? "\(item.keySpace?.rawValue ?? "?")/\(keyString(item))",
            writtenKeySpace: item.keySpace?.rawValue ?? "(nil)",
            writtenKey: keyString(item),
            readBackPresent: present,
            readBackIdentifier: readIdentifier,
            readBackKeySpaceKey: readKeySpaceKey,
            readBackValuePrefix: readValue,
            note: nil
        )
    }

    private static func matches(readItem: AVMetadataItem, candidate: AVMetadataItem) -> Bool {
        if let a = readItem.identifier, let b = candidate.identifier, a == b { return true }
        if let aSpace = readItem.keySpace, let bSpace = candidate.keySpace, aSpace == bSpace {
            let aKey = readItem.key as? String
            let bKey = candidate.key as? String
            if let aKey, let bKey, aKey == bKey { return true }
        }
        // 写入 common title 可能被规范化为 iTunes ©nam 等；用共同 key 兜底
        if let aCommon = readItem.commonKey, let bCommon = candidate.commonKey, aCommon == bCommon { return true }
        return false
    }

    private static func describe(_ item: AVMetadataItem) -> String {
        let keySpace = item.keySpace?.rawValue ?? "(nil)"
        return "\(keySpace)/\(keyString(item))"
    }

    private static func keyString(_ item: AVMetadataItem) -> String {
        if let key = item.key as? NSString { return key as String }
        if let key = item.key { return String(describing: key) }
        return "(nil)"
    }

    private static func valuePrefix(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string.count > 80 ? String(string.prefix(80)) + "…" : string
        case let data as Data:
            return "Data(\(data.count) bytes)"
        case let number as NSNumber:
            return number.stringValue
        case .none:
            return "(nil)"
        case .some(let other):
            return String(describing: type(of: other))
        }
    }

    /// 生成一张 342x513 的占位海报 PNG（仅测试用）。
    static func makePosterPNG() -> Data? {
        let width = 342
        let height = 513
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.36, green: 0.88, blue: 1.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))
        context.setFillColor(CGColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1))
        context.fill(CGRect(x: 24, y: height - 120, width: width - 48, height: 56))
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85))
        context.fill(CGRect(x: 24, y: height - 180, width: (width - 48) / 2, height: 36))

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
