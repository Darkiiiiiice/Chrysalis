import Foundation

// 蝉蜕（Chrysalis）P0 技术验证工具入口。
// 用法：
//   swift run p0 [all|capabilities|generate|bench|cancel|metadata] [--artifacts <dir>] [--force]
// 默认 all：能力矩阵 → 生成测试片 → 吞吐矩阵 → 取消/清理 → 元数据探针 → p0-report.json

// 行缓冲，保证通过管道查看日志时实时输出。
setvbuf(stdout, nil, _IOLBF, 0)

var command = "all"
var artifactsRoot = P0Paths.defaultArtifactsDir
var forceGenerate = false

let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--artifacts":
        index += 1
        if index < arguments.count {
            artifactsRoot = URL(fileURLWithPath: arguments[index])
        }
    case "--force":
        forceGenerate = true
    default:
        if !argument.hasPrefix("--") {
            command = argument
        }
    }
    index += 1
}

@MainActor
func run() async throws {
    let artifacts = Artifacts(root: artifactsRoot)

    switch command {
    case "all":
        _ = try await ReportRunner.runAll(artifacts: artifacts, forceGenerate: forceGenerate)

    case "capabilities":
        CapabilitiesProbe.printReport(CapabilitiesProbe.probe())

    case "generate":
        try artifacts.ensureDirectories()
        let sources = try await Bench.ensureSources(artifacts: artifacts, force: forceGenerate)
        for source in sources {
            Console.item("\(source.name)：\(source.width)x\(source.height) \(source.codec) \(Fmt.bytes(source.sizeBytes)) → \(source.path)")
        }

    case "bench":
        try artifacts.ensureDirectories()
        let capabilities = CapabilitiesProbe.probe()
        let sources = try await Bench.ensureSources(artifacts: artifacts, force: forceGenerate)
        let bench = await Bench.runAll(artifacts: artifacts, capabilities: capabilities, sources: sources)
        Bench.printTable(bench)
        try JSONWriter.write(bench, to: artifacts.root.appendingPathComponent("bench-report.json"))

    case "cancel":
        try artifacts.ensureDirectories()
        let capabilities = CapabilitiesProbe.probe()
        _ = try await Bench.ensureSources(artifacts: artifacts, force: false)
        let result = await CancelProbe.run(artifacts: artifacts, capabilities: capabilities)
        Console.kv("结果", result.ok ? "取消无残留，清理正常" : "存在异常")

    case "metadata":
        try artifacts.ensureDirectories()
        let capabilities = CapabilitiesProbe.probe()
        let result = try await MetadataProbe.run(artifacts: artifacts, capabilities: capabilities)
        ReportRunner.printMetadataSummary(result)
        try JSONWriter.write(result, to: artifacts.root.appendingPathComponent("metadata-report.json"))

    default:
        print("未知命令：\(command)")
        print("用法：swift run p0 [all|capabilities|generate|bench|cancel|metadata] [--artifacts <dir>] [--force]")
        exit(2)
    }
}

do {
    try await run()
} catch {
    Console.fail("P0 工具执行失败：\(error)")
    exit(1)
}
