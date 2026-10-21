import Foundation

// MARK: - P8 字幕工具测试（解析器 / 质检逐规则 / 修复器；设计文档 §7.7 / §11）

@MainActor
func runSubtitleTests() async {
    let h = Harness.shared

    let assSample = """
    [Script Info]
    Title: 测试
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, Alignment, MarginL, MarginR, MarginV
    Style: Default, 思源黑体, 60, &H00FFFFFF, 2, 80, 80, 60
    Style: Top, 缺失字体, 48, &H00FFFFFF, 8, 80, 80, 40

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:04.00,Default,小明,0,0,0,,你好，世界！\\NHello world
    Dialogue: 0,0:00:01.10,0:00:03.50,Default,,0,0,0,,{\\pos(960,200)}第二行（双语对，行数一致）
    Dialogue: 0,0:00:04.50,0:00:04.00,Default,,0,0,0,,这一条时间倒挂
    Dialogue: 0,0:00:05.00,0:00:05.00,Default,,0,0,0,,零时长
    Dialogue: 0,0:00:06.00,0:00:06.20,Default,,0,0,0,,这一行文本非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长
    Dialogue: 0,0:00:07.00,0:00:07.50,Missing,,0,0,0,,引用缺失样式
    Dialogue: 0,0:00:08.00,0:00:08.10,Top,,0,0,0,,{\\pos(3000,100)}定位出界 {未闭合
    Dialogue: 0,0:00:08.00,0:00:09.00,Top,,0,0,0,,短句
    Dialogue: 0,0:00:10.00,0:00:12.00,Default,,0,0,0,,行数一致主行
    Dialogue: 0,0:00:10.05,0:00:12.60,Default,,0,0,0,,行数一致译行
    """

    let srtSample = """
    1
    00:00:01,000 --> 00:00:04,000
    <i>你好</i>，SRT 世界。

    2
    00:00:01,200 --> 00:00:03,800
    第二条 SRT（双语对）。

    3
    00:00:05,000 --> 00:00:05,100
    空隙短句
    """

    await h.suite("字幕：解析器（ASS/SRT/VTT + 编码）") {
        h.run("ASS：样式 / 双语 / 定位 / 剥标签") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            try expectEqual(document.format, SubtitleFormat.ass, "格式识别")
            try expectEqual(document.cues.count, 10, "cue 数量")
            try expectEqual(document.styles.count, 2, "样式数量")
            try expectEqual(document.playResX, 1920.0, "PlayResX")
            let first = document.cues[0]
            try expectEqual(first.start, 1.0, "起始时间")
            try expectEqual(first.lines, ["你好，世界！", "Hello world"], "双语两行（\\N 拆分）")
            let second = document.cues[1]
            try expect(second.position?.x == 960 && second.position?.y == 200, "\\pos 解析：\(String(describing: second.position))")
            try expect(second.lines == ["第二行（双语对，行数一致）"], "override 已剥离")
            try expectEqual(document.cues[2].end < document.cues[2].start, true, "倒挂样本成立")
        }
        h.run("SRT：HTML 标签剥离 + 索引行") {
            let document = try SubtitleParser.parse(text: srtSample, format: .srt)
            try expectEqual(document.cues.count, 3, "cue 数量")
            try expectEqual(document.cues[0].lines, ["你好，SRT 世界。"], "标签剥离")
            try expectEqual(document.cues[0].start, 1.0, "起始")
            try expect(abs((document.cues[2].end - document.cues[2].start) - 0.1) < 0.001, "短时长 0.1s")
        }
        h.run("VTT：头识别与小数毫秒") {
            let vtt = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            VTT 第一条。

            00:00:05.500 --> 00:00:07.000
            VTT 第二条。
            """
            let document = try SubtitleParser.parse(text: vtt, format: .vtt)
            try expectEqual(document.cues.count, 2, "cue 数量")
            try expectEqual(document.cues[1].start, 5.5, "小数毫秒")
        }
        h.run("时间戳：ASS / SRT 往返") {
            try expectEqual(SubtitleParser.parseTimestamp("0:01:02.50"), 62.5, "ASS 厘秒")
            try expectEqual(SubtitleParser.parseTimestamp("00:01:02,500"), 62.5, "SRT 逗号")
            try expectEqual(SubtitleFixer.assTimestamp(62.5), "0:01:02.50", "ASS 格式化")
            try expectEqual(SubtitleFixer.srtTimestamp(62.5), "00:01:02,500", "SRT 格式化")
        }
        h.run("编码探测：GBK 回退") {
            // 「你好」的 GBK 编码：C4 E3 BA C3（换行符 \n = 0x0A，GBK 兼容 ASCII）
            let gbkData = Data([0xC4, 0xE3, 0xBA, 0xC3, 0x0A])
            let (text, encoding) = try SubtitleEncoding.detectAndDecode(gbkData)
            try expect(text.hasPrefix("你好"), "GBK 解码：\(text)")
            try expectEqual(encoding, "GBK", "编码名")
        }
    }

    await h.suite("字幕：质检逐规则（§7.7 五类）") {
        let document = try! SubtitleParser.parse(text: assSample, format: .ass)
        let report = SubtitleQualityEngine.analyze(document)
        func has(_ rule: SubtitleRule) -> Bool { !report.issues(byRule: rule).isEmpty }

        h.run("时间倒挂被检出") { try expect(has(.timelineReversed), "倒挂") }
        h.run("零时长被检出") { try expect(has(.timelineZeroDuration), "零时长") }
        h.run("同时间轴重叠被检出") { try expect(has(.timelineOverlap), "重叠") }
        h.run("双语行数不一致被检出") {
            try expect(report.issues(byRule: .bilingualMismatch).contains {
                $0.message.contains("行数不一致")
            }, "行数不一致 warning")
        }
        h.run("双语结束时间偏移被检出") {
            try expect(report.issues(byRule: .bilingualMismatch).contains {
                $0.message.contains("结束时间偏移")
            }, "偏移 hint（行数一致对）")
        }
        h.run("样式缺失被检出") { try expect(has(.styleMissing), "样式缺失") }
        h.run("字体缺失被检出（缺失字体 样式）") { try expect(has(.fontMissing), "字体缺失") }
        h.run("行宽过长被检出") { try expect(has(.lineTooLong), "行宽") }
        h.run("定位出界被检出（\\pos(3000,100)）") { try expect(has(.positionOutOfBounds), "出界") }
        h.run("大括号不配对被检出") { try expect(has(.braceUnclosed), "大括号") }
        h.run("报告分级统计一致") {
            try expectEqual(
                report.errorCount + report.warningCount + report.hintCount,
                report.issues.count,
                "分级合计"
            )
        }
    }

    await h.suite("字幕：修复器（人工确认后的自动修复）") {
        h.run("时间倒挂修复后重新质检归零") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let report = SubtitleQualityEngine.analyze(document)
            let outcome = SubtitleFixer.apply(
                document: document, report: report, selectedRules: [.timelineReversed]
            )
            try expect(outcome.appliedRules.contains(.timelineReversed), "应用了倒挂规则")
            try expect(outcome.fixedCueCount >= 1, "修复了至少一条")
            let fixedText = outcome.newLines.joined(separator: "\n")
            let fixedDocument = try SubtitleParser.parse(text: fixedText, format: .ass)
            let fixedReport = SubtitleQualityEngine.analyze(fixedDocument)
            try expectEqual(fixedReport.issues(byRule: .timelineReversed).count, 0, "倒挂归零")
            // 修复后的行时间轴正确
            let repaired = fixedDocument.cues.first { $0.start == 4.0 && $0.end == 4.5 }
            try expect(repaired != nil, "倒挂条时间已交换（4.0→4.5）")
        }
        h.run("双语结束时间对齐（行数一致对）") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let report = SubtitleQualityEngine.analyze(document)
            let outcome = SubtitleFixer.apply(
                document: document, report: report, selectedRules: [.bilingualMismatch]
            )
            let fixedText = outcome.newLines.joined(separator: "\n")
            let fixedDocument = try SubtitleParser.parse(text: fixedText, format: .ass)
            let pair = fixedDocument.cues.filter { abs($0.start - 10.0) < 0.1 || abs($0.start - 10.05) < 0.1 }
            try expectEqual(pair.count, 2, "对齐对仍为两条")
            try expectEqual(pair[0].end, pair[1].end, "结束时间已对齐")
        }
        h.run("SRT 行拆分（标点处均衡拆分）") {
            let document = try SubtitleParser.parse(text: srtSample, format: .srt)
            try expectEqual(document.cues.count, 3, "前置：SRT 三条")
            let split = SubtitleFixer.splitLine("第一半。第二半。")
            try expect(split != nil && split!.count == 2, "标点拆分：\(String(describing: split))")
        }
        h.run("原始行不被修改（修复输出是新数组）") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let report = SubtitleQualityEngine.analyze(document)
            let outcome = SubtitleFixer.apply(
                document: document, report: report, selectedRules: [.timelineReversed, .bilingualMismatch]
            )
            try expectEqual(outcome.newLines.count, document.rawLines.count, "行数不变（行替换）")
            try expect(outcome.newLines != document.rawLines, "内容已更新")
        }
    }

    await h.suite("字幕：内容理解纯函数（P8.4）") {
        h.run("金句原文校验：命中的保留、未命中丢弃") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let quotes = [
                SubtitleQuote(text: "你好，世界！", startSeconds: 1, endSeconds: 2, kind: "台词"),
                SubtitleQuote(text: "这句台词根本不存在于字幕里", startSeconds: 3, endSeconds: 4, kind: "独白"),
            ]
            let validated = SubtitleInsightsEngine.validatedQuotes(quotes, document: document)
            try expectEqual(validated.count, 1, "只有原文命中的金句保留")
            try expectEqual(validated[0].text, "你好，世界！", "保留的是命中句")
        }
        h.run("分块：按 5 分钟窗口切片") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let chunks = SubtitleInsightsEngine.chunkSummaries(document, chunkSeconds: 5)
            try expectEqual(chunks.count, 3, "0–5s / 5–10s / 10–15s 三个窗口（10s 双语对在第三窗）")
        }
        h.run("对白统计：ASS Name 字段计数") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let stats = SubtitleInsightsEngine.speakerStats(from: document)
            try expectEqual(stats["小明"], 1, "小明一条")
        }
        h.run("Markdown 导出包含三段") {
            let document = try SubtitleParser.parse(text: assSample, format: .ass)
            let insights = SubtitleInsights(
                summary: "测试摘要。",
                quotes: [SubtitleQuote(text: "你好，世界！", startSeconds: 1, endSeconds: 2, kind: "台词")],
                speakerStats: ["小明": 1]
            )
            let markdown = insights.markdown(fileName: "测试.ass")
            try expect(markdown.contains("## 摘要") && markdown.contains("测试摘要。"), "摘要段")
            try expect(markdown.contains("00:01 – 00:02"), "金句时间戳")
            try expect(markdown.contains("小明：1 条"), "对白统计")
        }
        h.run("JSON 金句解析（宽容代码块包裹）") {
            let json = """
            ```json
            [{"text":"你好，世界！","startSeconds":1,"endSeconds":2,"kind":"台词"}]
            ```
            """
            let quotes = SubtitleInsightsSession.parseQuotes(from: json)
            try expectEqual(quotes.count, 1, "解析一条")
            try expectEqual(quotes[0].text, "你好，世界！", "内容")
        }
    }
}
