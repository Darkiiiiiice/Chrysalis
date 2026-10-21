import Foundation

// MARK: - 蝉蜕（Chrysalis）P6 验证 harness 入口
// 用法：swift run check [all|unit|integration|bench|list]

setvbuf(stdout, nil, _IOLBF, 0)

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

@MainActor
func printUsage() {
    print("""
    蝉蜕（Chrysalis）P6 验证 harness
    用法：swift run check [all|unit|integration|bench|list]

      all          单元测试 + 集成测试（默认）
      unit         仅单元测试（纯函数，无硬件要求）
      integration  仅集成测试（真实编码，需要硬件编码器）
      bench        性能/内存基准（生成 10s 测试源，需要硬件编码器）
      list         打印覆盖范围说明

    产物目录：Validation/Harness/artifacts/（git 忽略）
    """)
}

@MainActor
func run() async throws {
    let harness = Harness.shared

    switch command {
    case "all":
        try Artifacts.prepare()
        await runUnitTests()
        let unitSummary = (harness.passed, harness.failed, harness.skipped)
        harness.reset()
        await runIntegrationTests()
        let integrationSummary = (harness.passed, harness.failed, harness.skipped)
        harness.reset()
        await runSubtitleTests()
        harness.summary(label: "字幕（P8 解析 / 质检 / 修复）")
        print("")
        print("—— 集成测试：\(integrationSummary.0) 过 / \(integrationSummary.1) 败 / \(integrationSummary.2) 跳 ——")
        print("—— 单元测试：\(unitSummary.0) 过 / \(unitSummary.1) 败 / \(unitSummary.2) 跳 ——")
        if unitSummary.1 > 0 || integrationSummary.1 > 0 || harness.failed > 0 { exit(1) }

    case "unit":
        try Artifacts.prepare()
        await runUnitTests()
        let unitSummary = (harness.passed, harness.failed, harness.skipped)
        harness.reset()
        await runSubtitleTests()
        harness.summary(label: "字幕（P8 解析 / 质检 / 修复）")
        print("")
        print("—— 单元测试：\(unitSummary.0) 过 / \(unitSummary.1) 败 / \(unitSummary.2) 跳 ——")
        if unitSummary.1 > 0 || harness.failed > 0 { exit(1) }

    case "integration":
        try Artifacts.prepare()
        await runIntegrationTests()
        harness.summary(label: "集成测试")
        if harness.exitCode != 0 { exit(1) }

    case "bench":
        try Artifacts.prepare()
        await runBench()
        if harness.exitCode != 0 { exit(1) }

    case "list":
        harness.listOnly = true
        printUsage()
        print("""
        覆盖范围（设计文档 §11）：
          单元测试：码率计算 / 输出路径 / 预设解析与兼容 / 任务状态机与持久化 / 文件名解析 / \
        匹配评分 / 元数据校验与前置拦截 / TMDB 解码与错误 / 代理设置 / 格式化 / 硬件能力
          集成测试：H.264·HEVC·ProRes 真实编码 / 竖屏旋转 / 质量单调 / 目标大小与夹取 / 磁盘预检 / \
        无音轨 / 取消清理 / 重名保护 / 电影元数据写回 / 源元数据保留 / 预检拒绝
          基准：§11 性能表 4 场景 + 4K 内存峰值
        """)

    default:
        print("未知命令：\(command)")
        printUsage()
        exit(2)
    }
}

do {
    try await run()
} catch {
    print("✗ harness 执行失败：\(error)")
    exit(1)
}
