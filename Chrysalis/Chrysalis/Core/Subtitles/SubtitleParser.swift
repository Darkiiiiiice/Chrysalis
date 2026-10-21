import CoreFoundation
import Foundation

// MARK: - 字幕解析器（设计文档 §7.7：纯 Swift 自研，零依赖）

/// 编码探测链：BOM → UTF-8 严格校验 → GBK 回退，失败明确报错。
enum SubtitleEncoding {
    static func detectAndDecode(_ data: Data) throws -> (text: String, encoding: String) {
        // 1) BOM
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) {
                return (text, "UTF-8 (BOM)")
            }
        }
        if data.starts(with: [0xFF, 0xFE]), data.count >= 2 {
            if let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return (text, "UTF-16LE")
            }
        }
        if data.starts(with: [0xFE, 0xFF]), data.count >= 2 {
            if let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return (text, "UTF-16BE")
            }
        }
        // 2) UTF-8 严格校验（含 NUL 垃圾检测）
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            return (text, "UTF-8")
        }
        // 3) GBK 回退（GB18030 超集）
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbk)), !text.contains("\0") {
            return (text, "GBK")
        }
        throw SubtitleError.unreadableEncoding()
    }
}

/// 字幕解析：ASS/SSA/SRT/VTT → `SubtitleDocument`。
enum SubtitleParser {
    static func parse(url: URL) throws -> SubtitleDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let (text, encoding) = try SubtitleEncoding.detectAndDecode(data)
        let format = SubtitleFormat.detect(fileExtension: url.pathExtension, content: text)
        var document = try parse(text: text, format: format)
        document.encoding = encoding
        return document
    }

    static func parse(text: String, format: SubtitleFormat) throws -> SubtitleDocument {
        let rawLines = text.components(separatedBy: .newlines)
        let document: SubtitleDocument
        switch format {
        case .ass: document = parseASS(rawLines)
        case .srt: document = parseSRT(rawLines)
        case .vtt: document = parseVTT(rawLines)
        }
        guard !document.cues.isEmpty else {
            throw SubtitleError.noCues(format: format)
        }
        return document
    }

    // MARK: 时间轴

    /// `H:MM:SS.cc`（ASS 厘秒）/ `HH:MM:SS,mmm`（SRT）/ `HH:MM:SS.mmm`（VTT）→ 秒。
    static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return nil }
        let secondsParts = parts[2].split(whereSeparator: { $0 == "." || $0 == "," })
        guard secondsParts.count <= 2, let seconds = Double(secondsParts[0]) else { return nil }
        var value = hours * 3600 + minutes * 60 + seconds
        if secondsParts.count == 2 {
            let fraction = secondsParts[1]
            guard fraction.allSatisfy(\.isNumber) else { return nil }
            let divisor = pow(10.0, Double(fraction.count))
            if let fractionValue = Double(fraction) {
                value += fractionValue / divisor
            }
        }
        return value.isFinite ? value : nil
    }

    /// 第 ordinal 个逗号的位置（ordinal=9 → 第 9 个逗号，即 10 列中前 9 个字段之后的分界）；不足返回 nil。
    private static func commaIndex(_ line: String, ordinal: Int) -> String.Index? {
        var count = 0
        for (index, character) in line.enumerated() where character == "," {
            count += 1
            if count == ordinal { return line.index(line.startIndex, offsetBy: index) }
        }
        return nil
    }

    // MARK: ASS / SSA

    private static func parseASS(_ lines: [String]) -> SubtitleDocument {
        var document = SubtitleDocument(format: .ass, rawLines: lines)
        var eventColumns: [String] = []
        var styleColumns: [String] = []
        var currentSection = ""

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = line.uppercased()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyword = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])

            switch currentSection {
            case "[SCRIPT INFO]":
                let key = keyword.lowercased()
                if key == "playresx" { document.playResX = Double(value.trimmingCharacters(in: .whitespaces)) }
                if key == "playresy" { document.playResY = Double(value.trimmingCharacters(in: .whitespaces)) }

            case "[V4+ STYLES]", "[V4 STYLES]", "[V4 STYLES+]":
                if keyword == "Format" {
                    styleColumns = value.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).lowercased()
                    }
                } else if keyword == "Style", !styleColumns.isEmpty {
                    let fields = value.split(separator: ",", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    var style = SubtitleStyle(name: "", fontName: "", fontSize: 0, alignment: 2, marginL: 0, marginR: 0, marginV: 0)
                    for (position, column) in styleColumns.enumerated() where position < fields.count {
                        let field = fields[position]
                        switch column {
                        case "name": style.name = field
                        case "fontname": style.fontName = field
                        case "fontsize": style.fontSize = Double(field) ?? 0
                        case "alignment": style.alignment = Int(field) ?? 2
                        case "marginl": style.marginL = Int(field) ?? 0
                        case "marginr": style.marginR = Int(field) ?? 0
                        case "marginv": style.marginV = Int(field) ?? 0
                        default: break
                        }
                    }
                    if !style.name.isEmpty {
                        document.styles.append(style)
                    }
                }

            case "[EVENTS]":
                if keyword == "Format" {
                    eventColumns = value.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).lowercased()
                    }
                } else if keyword == "Dialogue", !eventColumns.isEmpty {
                    // text 是最后一个字段，内容可能含逗号（如 \pos(960,200)）：
                    // 取第 (列数-1) 个逗号之后的全部内容作为 text，其余按逗号切分
                    guard eventColumns.last == "text",
                          let lastComma = Self.commaIndex(value, ordinal: eventColumns.count - 1) else { continue }
                    let prefix = String(value[value.startIndex..<lastComma])
                    let rawText = String(value[value.index(after: lastComma)...])
                    let fields = prefix.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
                    func field(_ name: String) -> String? {
                        guard let position = eventColumns.firstIndex(of: name), position < fields.count else { return nil }
                        return fields[position]
                    }
                    guard let startText = field("start"), let start = parseTimestamp(startText),
                          let endText = field("end"), let end = parseTimestamp(endText) else { continue }
                    let position = parseOverrideTags(rawText)
                    var margins: [Int?] = []
                    for name in ["marginl", "marginr", "marginv"] {
                        margins.append(field(name).flatMap { Int($0) == 0 ? nil : Int($0) })
                    }
                    document.cues.append(SubtitleCue(
                        lineIndex: index,
                        start: start,
                        end: end,
                        lines: plainLines(fromASS: rawText),
                        style: field("style")?.trimmingCharacters(in: .whitespaces),
                        speaker: field("name")?.trimmingCharacters(in: .whitespaces),
                        position: SubtitlePosition(
                            x: position.x, y: position.y,
                            moveFrom: position.moveFrom, moveTo: position.moveTo,
                            alignment: position.alignment,
                            marginL: margins[0], marginR: margins[1], marginV: margins[2]
                        ),
                        rawText: rawText
                    ))
                }

            default:
                break
            }
        }
        return document
    }

    /// ASS override tags：提取定位（\pos/\move/\an），文本剥标签并按 \N 拆行。
    static func parseOverrideTags(_ rawText: String) -> (x: Double?, y: Double?, moveFrom: SubtitlePosition.CGPointValue?, moveTo: SubtitlePosition.CGPointValue?, alignment: Int?) {
        var x: Double?
        var y: Double?
        var moveFrom: SubtitlePosition.CGPointValue?
        var moveTo: SubtitlePosition.CGPointValue?
        var alignment: Int?

        for brace in rawText.split(separator: "{", omittingEmptySubsequences: true) {
            guard let tag = brace.split(separator: "}").first else { continue }
            for tagPart in tag.split(separator: "\\") {
                let part = String(tagPart)
                if part.hasPrefix("pos("), part.hasSuffix(")") {
                    let numbers = part.dropFirst(4).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if numbers.count >= 2 {
                        x = numbers[0]
                        y = numbers[1]
                    }
                } else if part.hasPrefix("move("), part.hasSuffix(")") {
                    let numbers = part.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if numbers.count >= 4 {
                        moveFrom = .init(x: numbers[0], y: numbers[1])
                        moveTo = .init(x: numbers[2], y: numbers[3])
                    }
                } else if part.hasPrefix("an") {
                    alignment = Int(part.dropFirst(2).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return (x, y, moveFrom, moveTo, alignment)
    }

    /// ASS 文本 → 纯文本行：剥 `{...}` override，`\N`/`\n` 拆行，`\h` → 空格，剥 SRT 式 HTML 标签。
    static func plainLines(fromASS rawText: String) -> [String] {
        let withoutOverrides = rawText.replacingOccurrences(
            of: "\\{[^}]*\\}", with: "", options: .regularExpression
        )
        let withoutHTML = withoutOverrides.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        // \N / \n 换行 → 统一分隔符拆行；\h → 空格（正则需转义字面反斜杠：模式 \\\\N = 字面 \N）
        let normalized = withoutHTML
            .replacingOccurrences(of: "\\\\N", with: "\u{2029}", options: .regularExpression)
            .replacingOccurrences(of: "\\\\n", with: "\u{2029}", options: .regularExpression)
            .replacingOccurrences(of: "\\\\h", with: " ", options: .regularExpression)
        return normalized
            .components(separatedBy: "\u{2029}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: SRT

    private static func parseSRT(_ lines: [String]) -> SubtitleDocument {
        parseTimelineFormat(lines, format: .srt, requireIndex: true)
    }

    private static func parseVTT(_ lines: [String]) -> SubtitleDocument {
        var document = parseTimelineFormat(lines, format: .vtt, requireIndex: false)
        // VTT 的 STYLE/REGION 块简单忽略；标题行 WEBVTT 不产生 cue
        document.rawLines = lines
        return document
    }

    /// SRT / VTT 共用的时间轴解析：`时间行` + 文本行（可多行）+ 空行分隔。
    private static func parseTimelineFormat(
        _ lines: [String], format: SubtitleFormat, requireIndex: Bool
    ) -> SubtitleDocument {
        var document = SubtitleDocument(format: format, rawLines: lines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                index += 1
                continue
            }
            var timeLine = line
            if requireIndex, !line.contains("-->") {
                // SRT 序号行：下一行才是时间轴
                index += 1
                guard index < lines.count else { break }
                timeLine = lines[index].trimmingCharacters(in: .whitespaces)
            }
            guard timeLine.contains("-->"),
                  let range = parseTimeRange(timeLine) else {
                index += 1
                continue
            }
            let cueIndex = index
            index += 1
            var textLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index])
                index += 1
            }
            let cleaned = textLines
                .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else { continue }
            document.cues.append(SubtitleCue(
                lineIndex: cueIndex,
                start: range.start,
                end: range.end,
                lines: cleaned,
                style: nil,
                speaker: nil,
                position: nil,
                rawText: textLines.joined(separator: "\\N")
            ))
        }
        return document
    }

    /// `00:00:01,000 --> 00:00:04,000`（可带位置后缀，忽略）。
    static func parseTimeRange(_ line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startText = String(line[line.startIndex..<arrow.lowerBound])
        let rest = String(line[arrow.upperBound...])
        let endText = rest.split(separator: " ").first.map(String.init) ?? rest
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }
        return (start, end)
    }
}
