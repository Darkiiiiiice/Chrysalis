import CoreML
import Foundation

@main
struct P7Main {
    static func main() async {
        // 行缓冲，保证通过管道查看日志时实时输出。
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch {
            print("失败：\(error)")
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        let modelURL = URL(fileURLWithPath: options.modelPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw P7Error.message("模型不存在：\(modelURL.path)\n先运行 Validation/Models/convert_realesrgan.py 并用 coremlcompiler 编译")
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = try options.mlComputeUnits()
        if options.fastPrediction {
            configuration.optimizationHints.specializationStrategy = .fastPrediction
        }

        print("蝉蜕 P7.1 可行性探针")
        print("模型：\(modelURL.path)")
        print("computeUnits：\(options.computeUnits)\(options.fastPrediction ? "，fastPrediction" : "")")

        var planSummary: ComputePlanReport.Summary?
        if options.command == "all" || options.command == "plan" {
            planSummary = try await ComputePlanReport.inspect(
                modelURL: modelURL,
                configuration: configuration
            )
            if let planSummary {
                ComputePlanReport.printReport(planSummary)
            }
        }
        if options.command == "plan" { return }

        let baseline = Memory.footprint()
        let loadStart = now()
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let loadSeconds = seconds(since: loadStart)
        let afterLoad = Memory.footprint()
        Benchmark.describeModel(model)

        let shouldVerify = options.command == "verify"
            || (options.command == "all" && options.referenceDir != nil)
        if shouldVerify {
            guard let referenceDir = options.referenceDir else {
                throw P7Error.message("verify 需要 --reference <目录>")
            }
            try Benchmark.verify(
                model: model,
                modelName: modelURL.deletingPathExtension().lastPathComponent,
                referenceDirectory: URL(fileURLWithPath: referenceDir)
            )
            if options.command == "verify" { return }
        }

        let result = try Benchmark.run(
            model: model,
            modelName: modelURL.deletingPathExtension().lastPathComponent,
            options: options,
            saveFrame: options.saveFrame.map { URL(fileURLWithPath: $0) },
            baselineFootprint: baseline,
            footprintAfterLoad: afterLoad,
            modelLoadSeconds: loadSeconds
        )
        try Benchmark.writeJSON(
            result,
            plan: planSummary,
            to: URL(fileURLWithPath: "artifacts/last-bench.json")
        )
    }
}
