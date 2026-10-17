import Foundation

struct PassCriterion: Codable {
    var name: String
    var requirement: String
    var actual: String
    var passed: Bool
}

struct P0Report: Codable {
    var generatedAt: String
    var machine: MachineInfo
    var capabilities: CapabilitiesReport
    var bench: BenchReport
    var cancelProbe: CancelProbeResult
    var metadataProbe: MetadataProbeResult
    var passCriteria: [PassCriterion]
}

enum ReportRunner {
    static func runAll(artifacts: Artifacts, forceGenerate: Bool) async throws -> P0Report {
        Console.section("本机环境")
        let machine = MachineInfo.capture()
        machine.printSummary()

        let capabilities = CapabilitiesProbe.probe()
        CapabilitiesProbe.printReport(capabilities)

        try artifacts.ensureDirectories()
        try artifacts.cleanOutputs()

        Console.section("生成测试片")
        let sources = try await Bench.ensureSources(artifacts: artifacts, force: forceGenerate)

        let bench = await Bench.runAll(artifacts: artifacts, capabilities: capabilities, sources: sources)
        Bench.printTable(bench)

        let cancel = await CancelProbe.run(artifacts: artifacts, capabilities: capabilities)

        Console.section("元数据写入/读回探针")
        let metadata = try await MetadataProbe.run(artifacts: artifacts, capabilities: capabilities)
        printMetadataSummary(metadata)

        let criteria = evaluate(bench: bench, cancel: cancel)

        let report = P0Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            machine: machine,
            capabilities: capabilities,
            bench: bench,
            cancelProbe: cancel,
            metadataProbe: metadata,
            passCriteria: criteria
        )

        let jsonURL = artifacts.root.appendingPathComponent("p0-report.json")
        try JSONWriter.write(report, to: jsonURL)
        Console.section("P0 通过标准")
        for criterion in criteria {
            let mark = criterion.passed ? "✅" : "❌"
            print("  \(mark) \(criterion.name)（要求 \(criterion.requirement)，实测 \(criterion.actual)）")
        }
        Console.kv("原始数据", jsonURL.path)

        let allPassed = criteria.allSatisfy(\.passed)
        if allPassed {
            Console.ok("P0 全部通过标准达成")
        } else {
            Console.warn("存在未达成的通过标准，见上表")
        }
        return report
    }

    static func evaluate(bench: BenchReport, cancel: CancelProbeResult) -> [PassCriterion] {
        func find(_ keyword: String) -> BenchCase? {
            bench.cases.first { $0.name.contains(keyword) }
        }

        var criteria: [PassCriterion] = []

        let h264Case = find("1080p H.264 → H.264")
        let h264Speed = h264Case?.speed
        criteria.append(PassCriterion(
            name: "1080p H.264 → H.264 ≥ 4x 实时",
            requirement: "≥ 4x",
            actual: h264Speed.map { Fmt.x($0) } ?? (h264Case?.error ?? "未运行"),
            passed: (h264Speed ?? 0) >= 4.0
        ))

        let uhdCase = find("4K HEVC → 1080p H.264")
        let uhdSpeed = uhdCase?.speed
        criteria.append(PassCriterion(
            name: "4K HEVC → 1080p H.264 ≥ 1x 实时",
            requirement: "≥ 1x",
            actual: uhdSpeed.map { Fmt.x($0) } ?? (uhdCase?.error ?? "未运行"),
            passed: (uhdSpeed ?? 0) >= 1.0
        ))

        criteria.append(PassCriterion(
            name: "取消无残留（无输出、无临时文件）",
            requirement: "无残留",
            actual: cancel.ok ? "无残留" : "有残留（见取消探针）",
            passed: cancel.ok
        ))

        let verifyIssues = bench.cases.compactMap { $0.verifyIssues }.flatMap { $0 }
        criteria.append(PassCriterion(
            name: "全部输出通过读回自检（时长/分辨率/编码）",
            requirement: "0 问题",
            actual: verifyIssues.isEmpty ? "0 问题" : "\(verifyIssues.count) 个问题",
            passed: verifyIssues.isEmpty && bench.cases.allSatisfy { $0.status == "ok" }
        ))

        return criteria
    }

    static func printMetadataSummary(_ result: MetadataProbeResult) {
        for roundtrip in [result.mp4, result.mov] {
            Console.section("\(roundtrip.container) 元数据读回结果")
            let rows = roundtrip.rows.map { row -> [String] in
                [
                    row.field,
                    row.label,
                    row.readBackPresent ? "✅" : "❌",
                    row.readBackIdentifier ?? "-",
                    row.note ?? "",
                ]
            }
            print(Fmt.table(rows, headers: ["字段", "写入 identifier", "读回", "读回 identifier", "备注"]))
            if !roundtrip.transcodeFailures.isEmpty {
                Console.warn("转码失败 \(roundtrip.transcodeFailures.count) 项：")
                for failure in roundtrip.transcodeFailures {
                    Console.item(failure)
                }
            }
        }
    }
}
