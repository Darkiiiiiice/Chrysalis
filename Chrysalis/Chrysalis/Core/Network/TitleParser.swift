import Foundation

/// 文件名解析结果（设计文档 §7.5）。
struct ParsedTitle: Sendable, Equatable {
    /// 主标题（搜索用）。
    var primaryTitle: String
    /// 括号内备选标题（主标题无结果时使用）。
    var alternativeTitle: String?
    var year: Int?
}

/// 电影文件名 → 标题/年份（纯函数，设计文档 §7.5）：
/// 去扩展名 → `.`/`_` 归一 → 提取年份 → 括号备选 → 剥离发布标记。
enum TitleParser {
    /// 发布标记：整个 token 命中即认为标题到此为止（小写比较）。
    private static let releaseTokens: Set<String> = [
        // 分辨率
        "480p", "576p", "720p", "1080p", "1080i", "2160p", "4320p", "4k", "8k", "uhd", "fhd", "hd", "sd",
        // 片源
        "bluray", "blu-ray", "bdrip", "brrip", "webrip", "web-dl", "webdl", "web", "hdtv", "dvdrip", "dvd",
        "remux", "hdrip", "cam", "ts", "tc", "r5",
        // 编码 / 色彩
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "vp9", "10bit", "8bit", "hdr", "hdr10",
        "hdr10+", "dovi", "dv", "sdr",
        // 音频
        "aac", "ac3", "eac3", "ddp", "dd", "dts", "dts-hd", "truehd", "atmos", "flac", "mp3", "opus",
        "5.1", "7.1", "2.0", "1.0",
        // 其他
        "proper", "repack", "extended", "remastered", "imax", "multi", "internal", "complete",
    ]

    /// 括号内的纯杂项（不进备选标题）。
    private static let alternativeJunk: Set<String> = [
        "中字", "中英", "中英双字", "中英字幕", "简中", "简繁", "简繁英", "双语", "双语字幕", "国粤双语",
        "国英双语", "特效字幕", "蓝光", "原盘", "高清", "超清", "bd", "web", "mkv", "mp4",
    ]

    static func parse(filename: String) -> ParsedTitle {
        let base = (filename as NSString).lastPathComponent
        let noExtension = (base as NSString).deletingPathExtension
        let text = noExtension
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        // 1) 年份：合法范围过滤（「2049」这类数字留给标题）；取最后一个合法匹配；
        //    若其前面没有内容（形如「2012.mkv」），则视为标题而不是年份。
        let yearHits = yearMatches(in: text)
        var year: Int?
        var cutIndex: String.Index?
        if let last = yearHits.last {
            let before = text[text.startIndex..<last.range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if !before.isEmpty {
                year = last.value
                cutIndex = last.range.lowerBound
            }
        }

        // 2) 括号备选标题（用原文提取；年份、发布标记、杂项括号都会被过滤）。
        var alternativeTitle: String?
        for (range, inner) in bracketMatches(in: text) {
            let candidate = inner.trimmingCharacters(in: .whitespaces)
            // 开头的方括号通常是发布组名，不是备选标题
            guard range.lowerBound != text.startIndex else { continue }
            guard !candidate.isEmpty, !isPureYear(candidate),
                  !alternativeJunk.contains(candidate.lowercased()),
                  !isReleaseOnly(candidate) else { continue }
            alternativeTitle = candidate
            break
        }

        // 3) 主标题 = 年份之前（或全文）→ 去括号 → 在首个发布标记处截断。
        let region = cutIndex.map { String(text[text.startIndex..<$0]) } ?? text
        var title = cleanTitle(region)

        // 4) 兜底：括号内容本身就是标题（如「[REC]」）→ 保留括号内文字；
        //    仍为空则用整体净化后的文件名。
        if title.isEmpty {
            let inner = bracketMatches(in: region).map(\.inner).joined(separator: " ")
            title = cleanTitle(inner)
        }
        if title.isEmpty {
            title = cleanTitle(text)
        }
        if title.isEmpty {
            title = noExtension
        }
        if alternativeTitle == title { alternativeTitle = nil }

        return ParsedTitle(primaryTitle: title, alternativeTitle: alternativeTitle, year: year)
    }

    // MARK: - 私有工具

    /// 净化标题：去括号 → 首个发布标记处截断 → 收敛空白与边缘符号。
    private static func cleanTitle(_ raw: String) -> String {
        let text = stripBrackets(raw[...])
        var kept: [Substring] = []
        for token in text.split(separator: " ") {
            if isReleaseToken(String(token)) { break }
            kept.append(token)
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—·()[]【】"))
    }

    private static func yearMatches(in text: String) -> [(range: Range<String.Index>, value: Int)] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])[0-9]{4}(?![0-9])") else { return [] }
        let upperBound = Calendar.current.component(.year, from: .now) + 2
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text), let value = Int(text[range]),
                  (1888...upperBound).contains(value) else { return nil }
            return (range, value)
        }
    }

    private static func bracketMatches(in text: String) -> [(range: Range<String.Index>, inner: String)] {
        let pairs: [(open: Character, close: Character)] = [("[", "]"), ("(", ")"), ("【", "】")]
        var results: [(range: Range<String.Index>, inner: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            if let pair = pairs.first(where: { $0.open == text[index] }),
               let closeIndex = text[text.index(after: index)...].firstIndex(of: pair.close) {
                let inner = String(text[text.index(after: index)..<closeIndex])
                if inner.count <= 60 {
                    results.append((index..<text.index(after: closeIndex), inner))
                    index = text.index(after: closeIndex)
                    continue
                }
            }
            index = text.index(after: index)
        }
        return results
    }

    /// 去掉配对括号及其内容；截断产生的孤儿括号也丢弃。
    private static func stripBrackets(_ text: Substring) -> String {
        let pairs: [Character: Character] = ["[": "]", "(": ")", "【": "】"]
        var result = ""
        var skipUntil: Character?
        for character in text {
            if let until = skipUntil {
                if character == until { skipUntil = nil }
                continue
            }
            if let close = pairs[character] {
                skipUntil = close
                continue
            }
            if character == "]" || character == ")" || character == "】" { continue }
            result.append(character)
        }
        return result
    }

    private static func isPureYear(_ text: String) -> Bool {
        text.count == 4 && text.allSatisfy(\.isNumber)
    }

    /// 整个括号都是发布标记（如「1080p」「BluRay」）→ 不是备选标题。
    private static func isReleaseOnly(_ text: String) -> Bool {
        let tokens = text.split(separator: " ")
        return !tokens.isEmpty && tokens.allSatisfy { isReleaseToken(String($0)) }
    }

    private static func isReleaseToken(_ token: String) -> Bool {
        let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[](){}（）"))
        guard !lower.isEmpty else { return false }
        if releaseTokens.contains(lower) { return true }
        if let first = lower.split(separator: "-").first, releaseTokens.contains(String(first)) {
            return true
        }
        if lower.hasSuffix("p") || lower.hasSuffix("i") {
            let digits = lower.dropLast()
            if digits.count == 3 || digits.count == 4, digits.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }
}
