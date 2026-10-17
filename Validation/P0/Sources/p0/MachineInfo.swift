import Foundation

/// 本机环境快照，写入报告用。
struct MachineInfo: Codable {
    var macOSVersion: String
    var macOSBuild: String
    var modelIdentifier: String
    var chip: String
    var physicalMemoryBytes: UInt64
    var activeProcessors: Int
    var swiftVersion: String

    static func capture() -> MachineInfo {
        MachineInfo(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            macOSBuild: sysctlString("kern.osversion") ?? "unknown",
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
            swiftVersion: "Swift 6.4 (Xcode 27.1)"
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[0..<end], as: UTF8.self)
    }

    func printSummary() {
        Console.kv("系统", "macOS \(macOSVersion) (\(macOSBuild))")
        Console.kv("机型", "\(modelIdentifier) / \(chip)")
        Console.kv("内存", Fmt.bytes(Int64(physicalMemoryBytes)))
        Console.kv("CPU 核心", "\(activeProcessors)")
    }
}
