import AppKit
import Foundation

// MARK: - 字幕质检引擎与修复器（设计文档 §7.7：五类规则 + 人工确认后修复）

/// 问题分级（报告展示）。
enum SubtitleSeverity: String, Sendable, CaseIterable {
    case error
    case warning
    case hint

    var displayName: String {
        switch self {
        case .error: "错误"
        case .warning: "警告"
        case .hint: "提示"
        }
    }
}

/// 质检规则（修复器按 rule 分发）。
enum SubtitleRule: String, Sendable, CaseIterable {
    // 时间轴
    case timelineOverlap
    case timelineReversed
    case timelineZeroDuration
    case cpsExceeded
    // 双语
    case bilingualMismatch
    // 样式
    case styleMissing
    case fontMissing
    case lineTooLong
    // 定位
    case positionOverlap
    case positionOutOfBounds
    // 语法
    case braceUnclosed
    case cueEmpty

    var displayName: String {
        switch self {
        case .timelineOverlap: "时间轴重叠"
        case .timelineReversed: "时间倒挂"
        case .timelineZeroDuration: "零时长"
        case .cpsExceeded: "阅读速度超标"
        case .bilingualMismatch: "双语不对齐"
        case .styleMissing: "样式缺失"
        case .fontMissing: "字体缺失"
        case .lineTooLong: "行宽过长"
        case .positionOverlap: "定位遮挡"
        case .positionOutOfBounds: "定位出界"
        case .braceUnclosed: "标签未闭合"
        case .cueEmpty: "空字幕"
        }
    }
}

/// 一条质检问题。
struct SubtitleIssue: Sendable, Equatable, Identifiable {
    var id: String { "\(rule.rawValue)-\(cueIndices)-\(message)" }
    var severity: SubtitleSeverity
    var rule: SubtitleRule
    /// 涉及的 cue 索引（可多个，如双语对）。
    var cueIndices: [Int]
    var message: String
    /// 是否可自动修复（true → 修复器可处理；false → 仅告警 + 建议）。
    var autoFixable: Bool
}

/// 质检报告。
struct SubtitleReport: Sendable, Equatable {
    var issues: [SubtitleIssue]
    var cueCount: Int

    func issues(byRule rule: SubtitleRule) -> [SubtitleIssue] {
        issues.filter { $0.rule == rule }
    }
    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var hintCount: Int { issues.filter { $0.severity == .hint }.count }
}

// MARK: - 质检引擎

enum SubtitleQualityEngine {
    // MARK: 可调阈值（设置页写入；MainActor 单写多读，标注 nonisolated(unsafe)）

    /// CPS 阈值（设计文档 §7.7：默认 20）。
    nonisolated(unsafe) static var cpsThreshold: Double = 20
    /// 双语对时间偏移阈值（秒）。
    nonisolated(unsafe) static var bilingualDrift: Double = 0.3
    /// 同时间轴多行重叠的容许条数。
    nonisolated(unsafe) static var maxSimultaneousCues = 2

    static func analyze(_ document: SubtitleDocument) -> SubtitleReport {
        var issues: [SubtitleIssue] = []
        let cues = document.cues
        let styles = document.styleByName
        let canvas = CGSize(
            width: document.playResX ?? 384,
            height: document.playResY ?? 288
        )

        // MARK: 时间轴 + CPS（逐 cue）

        for (index, cue) in cues.enumerated() {
            if cue.end < cue.start {
                issues.append(.init(
                    severity: .error, rule: .timelineReversed, cueIndices: [index],
                    message: String(format: "第 %d 条时间倒挂（%.2fs → %.2fs）", index + 1, cue.start, cue.end),
                    autoFixable: true
                ))
            }
            if cue.duration <= 0.01 {
                issues.append(.init(
                    severity: .error, rule: .timelineZeroDuration, cueIndices: [index],
                    message: String(format: "第 %d 条时长为零或过短", index + 1),
                    autoFixable: false
                ))
            }
            if cue.duration > 0.2 {
                let cps = Double(cue.characterCount) / cue.duration
                if cps > cpsThreshold {
                    let suggestedEnd = cue.start + Double(cue.characterCount) / cpsThreshold
                    issues.append(.init(
                        severity: .warning, rule: .cpsExceeded, cueIndices: [index],
                        message: String(
                            format: "第 %d 条阅读速度 %.0f 字符/秒（阈值 %.0f）；建议延长到 %.2f 秒",
                            index + 1, cps, cpsThreshold, suggestedEnd
                        ),
                        autoFixable: false
                    ))
                }
            }
            // 语法：ASS 大括号配对 + 空字幕
            if document.format == .ass, let raw = cue.rawText {
                let open = raw.filter { $0 == "{" }.count
                let close = raw.filter { $0 == "}" }.count
                if open != close {
                    issues.append(.init(
                        severity: .error, rule: .braceUnclosed, cueIndices: [index],
                        message: "第 \(index + 1) 条 override 标签大括号不配对（{ ×\(open) / } ×\(close)）",
                        autoFixable: false
                    ))
                }
            }
            if cue.lines.isEmpty {
                issues.append(.init(
                    severity: .warning, rule: .cueEmpty, cueIndices: [index],
                    message: "第 \(index + 1) 条没有文本内容",
                    autoFixable: false
                ))
            }
        }

        // MARK: 同时间轴重叠（相邻 cue 对，排序后扫描）

        let sorted = cues.enumerated().sorted { $0.element.start < $1.element.start }
        for position in 1..<max(sorted.count, 1) {
            let (previousIndex, previous) = sorted[position - 1]
            let (currentIndex, current) = sorted[position]
            guard current.start < previous.end else { continue }
            // 倒挂单独报（上面已覆盖）；这里报同时间轴挤压
            let simultaneous = cues.filter { $0.start <= previous.end && $0.end >= previous.start }.count
            if simultaneous > maxSimultaneousCues {
                issues.append(.init(
                    severity: .warning, rule: .timelineOverlap, cueIndices: [previousIndex, currentIndex],
                    message: String(
                        format: "第 %d–%d 条同屏字幕达 %d 条（超过 %d）：建议合并或错开",
                        previousIndex + 1, currentIndex + 1, simultaneous, maxSimultaneousCues
                    ),
                    autoFixable: true
                ))
            } else if current.start < previous.end, current.end <= previous.end, current.start >= previous.start {
                // 完全包含：疑似重复
                issues.append(.init(
                    severity: .warning, rule: .timelineOverlap, cueIndices: [previousIndex, currentIndex],
                    message: String(
                        format: "第 %d 条被第 %d 条完全覆盖（疑似重复）",
                        currentIndex + 1, previousIndex + 1
                    ),
                    autoFixable: true
                ))
            }
        }

        // MARK: 双语对（start 差 < 0.3s 的相邻 cue）

        for position in 1..<max(sorted.count, 1) {
            let (previousIndex, previous) = sorted[position - 1]
            let (currentIndex, current) = sorted[position]
            guard abs(current.start - previous.start) < bilingualDrift else { continue }
            let previousLines = previous.lines.count
            let currentLines = current.lines.count
            if previousLines != currentLines {
                issues.append(.init(
                    severity: .warning, rule: .bilingualMismatch, cueIndices: [previousIndex, currentIndex],
                    message: "第 \(previousIndex + 1) / \(currentIndex + 1) 条双语行数不一致（\(previousLines) 行 vs \(currentLines) 行）",
                    autoFixable: true
                ))
            } else if abs(current.end - previous.end) > bilingualDrift {
                issues.append(.init(
                    severity: .hint, rule: .bilingualMismatch, cueIndices: [previousIndex, currentIndex],
                    message: String(
                        format: "第 %d / %d 条双语结束时间偏移 %.2fs",
                        previousIndex + 1, currentIndex + 1, abs(current.end - previous.end)
                    ),
                    autoFixable: true
                ))
            }
        }

        // MARK: 样式与字体

        for (index, cue) in cues.enumerated() where document.format == .ass {
            if let styleName = cue.style, !styleName.isEmpty, styles[styleName] == nil {
                issues.append(.init(
                    severity: .error, rule: .styleMissing, cueIndices: [index],
                    message: "第 \(index + 1) 条引用了不存在的样式「\(styleName)」",
                    autoFixable: false
                ))
            }
        }
        var missingFonts = Set<String>()
        for style in document.styles {
            if !style.fontName.isEmpty, !isFontAvailable(style.fontName), !missingFonts.contains(style.fontName) {
                missingFonts.insert(style.fontName)
            }
        }
        if !missingFonts.isEmpty {
            let suggestion = missingFonts.map { "「\($0)」" }.joined(separator: "、")
            issues.append(.init(
                severity: .warning, rule: .fontMissing, cueIndices: [],
                message: "样式使用了本机未安装的字体：\(suggestion)——播放器将回退到默认字体；可在样式表中改为可用字体（需确认后替换）",
                autoFixable: false
            ))
        }

        // MARK: 行宽过长（字号 × 字符数估算）

        for (index, cue) in cues.enumerated() {
            let style = cue.style.flatMap { styles[$0] } ?? SubtitleStyle(
                name: "", fontName: "", fontSize: 18, alignment: 2, marginL: 10, marginR: 10, marginV: 10
            )
            for line in cue.lines {
                let estimatedWidth = estimateTextWidth(line, fontSize: style.fontSize)
                let available = canvas.width - Double(max(style.marginL, cue.position?.marginL ?? 0) + max(style.marginR, cue.position?.marginR ?? 0))
                if available > 0, estimatedWidth > available * 1.05 {
                    issues.append(.init(
                        severity: .hint, rule: .lineTooLong, cueIndices: [index],
                        message: String(format: "第 %d 条行宽可能超出画面（估算 %.0f / 可用 %.0f）：建议拆分", index + 1, estimatedWidth, available),
                        autoFixable: true
                    ))
                }
            }
        }

        // MARK: 定位遮挡与出界（静态几何近似，ASS 专属）

        for (index, cue) in cues.enumerated() {
            guard let rect = cueRect(cue, styles: styles, canvas: canvas, isASS: document.format == .ass) else { continue }
            if rect.minX < -1 || rect.minY < -1 || rect.maxX > canvas.width + 1 || rect.maxY > canvas.height + 1 {
                issues.append(.init(
                    severity: .warning, rule: .positionOutOfBounds, cueIndices: [index],
                    message: String(
                        format: "第 %d 条定位超出画布（%.0f,%.0f–%.0f,%.0f，画布 %.0f×%.0f）",
                        index + 1, rect.minX, rect.minY, rect.maxX, rect.maxY, canvas.width, canvas.height
                    ),
                    autoFixable: false
                ))
            }
        }
        for position in 1..<max(sorted.count, 1) {
            let (previousIndex, previous) = sorted[position - 1]
            let (currentIndex, current) = sorted[position]
            guard current.start < previous.end,
                  let previousRect = cueRect(previous, styles: styles, canvas: canvas, isASS: document.format == .ass),
                  let currentRect = cueRect(current, styles: styles, canvas: canvas, isASS: document.format == .ass) else { continue }
            let intersection = previousRect.intersection(currentRect)
            guard !intersection.isEmpty, intersection.width > 8, intersection.height > 8 else { continue }
            let hasExplicitPosition = previous.position?.x != nil || current.position?.x != nil
                || previous.position?.moveFrom != nil || current.position?.moveFrom != nil
            if hasExplicitPosition {
                issues.append(.init(
                    severity: .warning, rule: .positionOverlap, cueIndices: [previousIndex, currentIndex],
                    message: String(
                        format: "第 %d / %d 条同屏且定位区域重叠（%.0f×%.0f）：可能互相遮挡",
                        previousIndex + 1, currentIndex + 1, intersection.width, intersection.height
                    ),
                    autoFixable: false
                ))
            }
        }

        return SubtitleReport(issues: issues, cueCount: cues.count)
    }

    // MARK: 几何近似（静态；不承诺像素级渲染一致）

    /// 估算一行文本宽度（全角 ×1.0、半角 ×0.55，乘字号）。
    static func estimateTextWidth(_ line: String, fontSize: Double) -> Double {
        let wide = line.filter(isCJK).count
        let narrow = line.count - wide
        return (Double(wide) + Double(narrow) * 0.55) * fontSize
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value)
    }

    /// cue 的静态区域（ASS 画布坐标）；SRT/VTT 无画布概念，返回 nil。
    static func cueRect(
        _ cue: SubtitleCue, styles: [String: SubtitleStyle], canvas: CGSize, isASS: Bool
    ) -> CGRect? {
        guard isASS else { return nil }
        let style = cue.style.flatMap { styles[$0] }
        let fontSize = style?.fontSize ?? 18
        let alignment = cue.position?.alignment ?? style?.alignment ?? 2
        let marginL = Double(max(cue.position?.marginL ?? style?.marginL ?? 10, 0))
        let marginR = Double(max(cue.position?.marginR ?? style?.marginR ?? 10, 0))
        let marginV = Double(max(cue.position?.marginV ?? style?.marginV ?? 10, 0))

        let longest = cue.lines.max(by: { $0.count < $1.count }) ?? ""
        let width = estimateTextWidth(longest, fontSize: fontSize)
        let height = Double(cue.lines.count) * fontSize * 1.2

        // 有 \pos/\move：\an / 样式对齐决定锚点（ASS numpad）
        if let x = cue.position?.x, let y = cue.position?.y {
            return rectFor(anchorX: x, anchorY: y, alignment: alignment, width: width, height: height)
        }
        if let from = cue.position?.moveFrom, let to = cue.position?.moveTo {
            let first = rectFor(anchorX: from.x, anchorY: from.y, alignment: alignment, width: width, height: height)
            let last = rectFor(anchorX: to.x, anchorY: to.y, alignment: alignment, width: width, height: height)
            return first.union(last)
        }
        // 无显式定位：按对齐 + 边距的默认布局
        let effectiveAlignment = alignment
        var originX: Double
        switch effectiveAlignment % 3 {
        case 1: originX = marginL
        case 0: originX = canvas.width - marginR - width
        default: originX = (canvas.width - width) / 2
        }
        let fromBottom = effectiveAlignment > 3
        let originY = fromBottom ? canvas.height - marginV - height : marginV
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static func rectFor(
        anchorX: Double, anchorY: Double, alignment: Int, width: Double, height: Double
    ) -> CGRect {
        let horizontal = alignment % 3
        let vertical = alignment
        let originX: Double
        switch horizontal {
        case 1: originX = anchorX
        case 0: originX = anchorX - width
        default: originX = anchorX - width / 2
        }
        let originY: Double
        switch vertical {
        case 1...3: originY = anchorY - height          // 底部对齐：锚点在下缘
        case 4...6: originY = anchorY - height / 2      // 中部
        default: originY = anchorY                       // 顶部
        }
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static func isFontAvailable(_ name: String) -> Bool {
        NSFont(name: name, size: 12) != nil
            || NSFontManager.shared.availableFonts.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - 修复器（全部经人工确认后调用；输出行替换，不改原文件）

enum SubtitleFixer {
    /// 修复结果：按 cue.lineIndex 替换原始行；ASS 需要重写 Dialogue 的 start/end/text 字段。
    struct FixOutcome {
        var newLines: [String]
        /// 应用的规则（报告展示）。
        var appliedRules: [SubtitleRule]
        var fixedCueCount: Int
    }

    /// 对选中的规则执行自动修复，返回替换后的完整行数组（原文件不动）。
    static func apply(
        document: SubtitleDocument, report: SubtitleReport, selectedRules: Set<SubtitleRule>
    ) -> FixOutcome {
        var lines = document.rawLines
        var cues = document.cues
        var applied: [SubtitleRule] = []
        var fixedCues = 0

        let rules = selectedRules.intersection(Set(report.issues.map(\.rule)))

        // 1) 时间倒挂：交换 start/end
        if rules.contains(.timelineReversed) {
            let reversed = report.issues(byRule: .timelineReversed)
            for issue in reversed {
                guard let index = issue.cueIndices.first, cues.indices.contains(index) else { continue }
                let cue = cues[index]
                guard cue.end < cue.start else { continue }
                cues[index].start = cue.end
                cues[index].end = cue.start
                rewriteTimeLine(document: document, cue: cues[index], into: &lines)
                fixedCues += 1
            }
            if !reversed.isEmpty { applied.append(.timelineReversed) }
        }

        // 2) 疑似重复（完全包含）：删除被覆盖的 cue
        if rules.contains(.timelineOverlap) {
            let duplicates = report.issues(byRule: .timelineOverlap).filter { $0.message.contains("完全覆盖") }
            var removedIndices = Set<Int>()
            for issue in duplicates {
                guard issue.cueIndices.count == 2 else { continue }
                let contained = issue.cueIndices[1]
                guard cues.indices.contains(contained) else { continue }
                removedIndices.insert(contained)
            }
            if !removedIndices.isEmpty {
                for index in removedIndices {
                    eraseCue(document: document, cue: cues[index], into: &lines)
                }
                // 不从 cues 移除：后续修复步骤继续使用原索引（被删 cue 的行已清空）
                fixedCues += removedIndices.count
            }
            if !duplicates.isEmpty { applied.append(.timelineOverlap) }
        }

        // 3) 双语行数不一致：以较少一方为准，把多出的一方截断/合并？——不改动内容语义，
        //    改为把两 cue 的时间轴对齐（start/end 取并集），行数差异仅报告
        if rules.contains(.bilingualMismatch) {
            let mismatches = report.issues(byRule: .bilingualMismatch)
            for issue in mismatches where issue.message.contains("结束时间偏移") {
                guard issue.cueIndices.count == 2,
                      cues.indices.contains(issue.cueIndices[0]),
                      cues.indices.contains(issue.cueIndices[1]) else { continue }
                let first = cues[issue.cueIndices[0]]
                let second = cues[issue.cueIndices[1]]
                let alignedEnd = max(first.end, second.end)
                cues[issue.cueIndices[0]].end = alignedEnd
                cues[issue.cueIndices[1]].end = alignedEnd
                rewriteTimeLine(document: document, cue: cues[issue.cueIndices[0]], into: &lines)
                rewriteTimeLine(document: document, cue: cues[issue.cueIndices[1]], into: &lines)
                fixedCues += 2
            }
            if !mismatches.isEmpty { applied.append(.bilingualMismatch) }
        }

        // 4) 行宽过长：在标点/空格处拆分为两行（\N 或独立行）
        if rules.contains(.lineTooLong) {
            let tooLong = report.issues(byRule: .lineTooLong)
            var touched = Set<Int>()
            for issue in tooLong {
                guard let index = issue.cueIndices.first, cues.indices.contains(index), !touched.contains(index) else { continue }
                let cue = cues[index]
                guard cue.lines.count == 1, let split = splitLine(cue.lines[0]) else { continue }
                let isASS = document.format == .ass
                if isASS, var raw = cue.rawText {
                    let joined = split.joined(separator: "\\N")
                    // rawText 的文本部分替换：Dialogue 行去掉 override 前缀再拼回
                    if let lastComma = nthCommaRange(in: raw, field: 9) {
                        raw = String(raw[raw.startIndex..<lastComma.lowerBound]) + joined
                        lines[cue.lineIndex] = rebuildDialogueLine(original: document.rawLines[cue.lineIndex], newText: raw)
                    }
                } else if !isASS {
                    // SRT/VTT：替换时间行之后的文本行
                    let textStart = cue.lineIndex + 1 + (document.format == .srt ? 1 : 0)
                    for offset in 0..<max(cue.lines.count, split.count) {
                        let target = textStart + offset
                        guard target < lines.count else { break }
                        lines[target] = offset < split.count ? split[offset] : ""
                    }
                }
                touched.insert(index)
                fixedCues += 1
            }
            if !tooLong.isEmpty { applied.append(.lineTooLong) }
        }

        return FixOutcome(newLines: lines, appliedRules: applied, fixedCueCount: fixedCues)
    }

    /// 在标点/空格处把过长单行拆成两行（均衡两侧长度）。
    static func splitLine(_ line: String) -> [String]? {
        let punctuation: Set<Character> = ["，", "。", "！", "？", "；", "、", ",", ".", "!", "?", ";", " "]
        let middle = line.count / 2
        var best = -1
        var bestScore = Int.max
        for (offset, character) in line.enumerated() where punctuation.contains(character) {
            let distance = abs(offset - middle)
            if distance < bestScore {
                bestScore = distance
                best = offset
            }
        }
        guard best >= 0, best < line.count - 1 else { return nil }
        let first = String(line.prefix(best + 1)).trimmingCharacters(in: .whitespaces)
        let second = String(line.dropFirst(best + 1)).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return [first, second]
    }

    /// ASS Dialogue 行：替换文本字段（第 10 个逗号之后）。
    private static func nthCommaRange(in line: String, field: Int) -> Range<String.Index>? {
        var commas: [String.Index] = []
        for (index, character) in line.enumerated() where character == "," {
            commas.append(line.index(line.startIndex, offsetBy: index))
            if commas.count >= field { break }
        }
        guard commas.count >= field else { return nil }
        return commas[field - 1]..<line.endIndex
    }

    /// 用新 Dialogue 文本重建原始行（保留行首字段：Layer…Effect）。
    private static func rebuildDialogueLine(original: String, newText: String) -> String {
        guard let range = nthCommaRange(in: original, field: 9) else { return original }
        return String(original[original.startIndex..<range.lowerBound]) + newText
    }

    /// 重写 ASS Dialogue 行的时间轴；SRT/VTT 重写时间行。
    static func rewriteTimeLine(document: SubtitleDocument, cue: SubtitleCue, into lines: inout [String]) {
        guard cue.lineIndex < lines.count else { return }
        switch document.format {
        case .ass:
            lines[cue.lineIndex] = rewriteASSTimestamps(lines[cue.lineIndex], start: cue.start, end: cue.end)
        case .srt:
            lines[cue.lineIndex] = rewriteSRTRow(lines[cue.lineIndex], start: cue.start, end: cue.end)
        case .vtt:
            lines[cue.lineIndex] = rewriteSRTRow(lines[cue.lineIndex], start: cue.start, end: cue.end, decimal: ".")
        }
    }

    /// 删除 cue（含文本行）。
    static func eraseCue(document: SubtitleDocument, cue: SubtitleCue, into lines: inout [String]) {
        guard cue.lineIndex < lines.count else { return }
        switch document.format {
        case .ass:
            lines[cue.lineIndex] = ""
        case .srt, .vtt:
            var index = cue.lineIndex
            if document.format == .srt { lines[index] = ""; index += 1 }
            guard index < lines.count else { return }
            lines[index] = ""
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                lines[index] = ""
                index += 1
            }
        }
    }

    static func rewriteASSTimestamps(_ line: String, start: Double, end: Double) -> String {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // ASS Dialogue: Layer,Start,End,Style,...（Start=1，End=2）
        if fields.count > 2 {
            fields[1] = " " + assTimestamp(start)
            fields[2] = " " + assTimestamp(end)
        }
        return fields.joined(separator: ",")
    }

    static func assTimestamp(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = Int(clamped) % 60
        let centis = Int((clamped - Double(Int(clamped))) * 100)
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, centis)
    }

    static func rewriteSRTRow(_ line: String, start: Double, end: Double, decimal: String = ",") -> String {
        guard let arrow = line.range(of: "-->") else { return line }
        let suffix = String(line[arrow.upperBound...])
        let suffixTail = suffix.split(separator: " ").dropFirst().joined(separator: " ")
        let newStart = srtTimestamp(start, decimal: decimal)
        let newEnd = srtTimestamp(end, decimal: decimal)
        return "\(newStart) --> \(newEnd)" + (suffixTail.isEmpty ? "" : " \(suffixTail)")
    }

    static func srtTimestamp(_ seconds: Double, decimal: String = ",") -> String {
        let clamped = max(seconds, 0)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = Int(clamped) % 60
        let millis = Int((clamped - Double(Int(clamped))) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, decimal, millis)
    }
}
