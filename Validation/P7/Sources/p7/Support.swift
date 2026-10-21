import CoreML
import Foundation

// 蝉蜕（Chrysalis）P7.1 探针的通用小工具。

enum P7Error: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

struct Options {
    var command = "all"
    var modelPath = "../Models/build/AnimeVideoXS2.mlmodelc"
    var referenceDir: String?
    var saveFrame: String?
    var width = 1920
    var height = 1080
    var tile = 512
    var tileHeight: Int?
    var overlap = 32
    var frames = 3
    var warmup = 1
    var computeUnits = "all"
    var fastPrediction = false
    var batch = false

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next(_ name: String) throws -> String {
                index += 1
                guard index < arguments.count else {
                    throw P7Error.message("参数 \(name) 缺少取值")
                }
                return arguments[index]
            }
            switch argument {
            case "--model":
                options.modelPath = try next(argument)
            case "--reference":
                options.referenceDir = try next(argument)
            case "--save-frame":
                options.saveFrame = try next(argument)
            case "--width":
                options.width = Int(try next(argument)) ?? options.width
            case "--height":
                options.height = Int(try next(argument)) ?? options.height
            case "--tile":
                options.tile = Int(try next(argument)) ?? options.tile
            case "--tile-height":
                options.tileHeight = Int(try next(argument)) ?? options.tileHeight
            case "--overlap":
                options.overlap = Int(try next(argument)) ?? options.overlap
            case "--frames":
                options.frames = Int(try next(argument)) ?? options.frames
            case "--warmup":
                options.warmup = Int(try next(argument)) ?? options.warmup
            case "--compute-units":
                options.computeUnits = try next(argument)
            case "--fast-prediction":
                options.fastPrediction = true
            case "--batch":
                options.batch = true
            default:
                if argument.hasPrefix("--") {
                    throw P7Error.message("未知参数：\(argument)")
                }
                options.command = argument
            }
            index += 1
        }
        return options
    }

    func mlComputeUnits() throws -> MLComputeUnits {
        switch computeUnits {
        case "all": return .all
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuOnly": return .cpuOnly
        case "cpuAndNeuralEngine", "ane": return .cpuAndNeuralEngine
        default: throw P7Error.message("未知 compute-units：\(computeUnits)")
        }
    }
}

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return String(format: "%.1f %@", size, units[unit])
    }

    static func ms(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000.0)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }
}

enum Memory {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func peak() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(usage.ru_maxrss)
    }
}

func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func seconds(since start: UInt64) -> Double {
    Double(now() - start) / 1_000_000_000.0
}
