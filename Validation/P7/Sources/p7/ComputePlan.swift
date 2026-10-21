import CoreML
import Foundation

enum ComputePlanReport {
    struct Summary {
        var operationCount = 0
        var deviceCounts: [String: Int] = [:]
        var deviceCosts: [String: Double] = [:]
        var operatorCosts: [(name: String, cost: Double, devices: [String: Int])] = []
        var supportedDevices: Set<String> = []
    }

    static func deviceName(_ device: MLComputeDevice) -> String {
        switch device {
        case .neuralEngine: return "ANE"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        @unknown default: return "unknown"
        }
    }

    static func inspect(modelURL: URL, configuration: MLModelConfiguration) async throws -> Summary {
        let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: configuration)
        var summary = Summary()

        guard case let .program(program) = plan.modelStructure else {
            throw P7Error.message("模型不是 ML Program（可能是 NeuralNetwork），P7 只使用 mlprogram")
        }

        func walk(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                summary.operationCount += 1
                let usage = plan.deviceUsage(for: operation)
                let device = usage.map { deviceName($0.preferred) } ?? "unknown"
                summary.deviceCounts[device, default: 0] += 1
                let cost = plan.estimatedCost(of: operation)?.weight ?? 0
                summary.deviceCosts[device, default: 0] += cost
                if let usage {
                    for supported in usage.supported {
                        summary.supportedDevices.insert(deviceName(supported))
                    }
                }
                if let existing = summary.operatorCosts.firstIndex(where: { $0.name == operation.operatorName }) {
                    summary.operatorCosts[existing].cost += cost
                    summary.operatorCosts[existing].devices[device, default: 0] += 1
                } else {
                    summary.operatorCosts.append(
                        (operation.operatorName, cost, [device: 1])
                    )
                }
                for nested in operation.blocks {
                    walk(nested)
                }
            }
        }

        for function in program.functions.values {
            walk(function.block)
        }
        summary.operatorCosts.sort { $0.cost > $1.cost }
        return summary
    }

    static func printReport(_ summary: Summary) {
        print("")
        print("== MLComputePlan ==")
        print("算子总数：\(summary.operationCount)")
        print("支持设备：\(summary.supportedDevices.sorted().joined(separator: " / "))")
        let devices = summary.deviceCounts.keys.sorted()
        for device in devices {
            let count = summary.deviceCounts[device, default: 0]
            let share = summary.operationCount > 0
                ? Double(count) / Double(summary.operationCount) * 100
                : 0
            let cost = summary.deviceCosts[device, default: 0] * 100
            print(
                String(
                    format: "  %-7@ 算子 %4d (%5.1f%%)  估算工作量 %5.1f%%",
                    device as NSString,
                    count,
                    share,
                    cost
                )
            )
        }
        print("热点算子（按估算工作量排序，取前 12）：")
        for item in summary.operatorCosts.prefix(12) {
            let breakdown = item.devices
                .sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: " ")
            print(
                String(
                    format: "  %-18@ 工作量 %5.1f%%  %@",
                    item.name as NSString,
                    item.cost * 100,
                    breakdown as NSString
                )
            )
        }
    }
}
