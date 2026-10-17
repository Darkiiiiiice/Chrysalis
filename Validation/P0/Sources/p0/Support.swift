import Foundation

// MARK: - 路径推导

/// P0 工具用到的固定路径。
/// 通过 #filePath 反推仓库根目录：<repo>/Validation/P0/Sources/p0/Support.swift
enum P0Paths {
    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // Support.swift
        url.deleteLastPathComponent() // p0
        url.deleteLastPathComponent() // Sources
        url.deleteLastPathComponent() // P0
        url.deleteLastPathComponent() // Validation
        return url
    }

    static var validationDir: URL { repoRoot.appendingPathComponent("Validation/P0") }
    static var defaultArtifactsDir: URL { validationDir.appendingPathComponent("artifacts") }
}

/// 运行期产物目录（测试片、转码输出、报告）。
/// 全部为临时数据，已在 .gitignore 中排除。
struct Artifacts {
    let root: URL

    var sourcesDir: URL { root.appendingPathComponent("sources") }
    var outputsDir: URL { root.appendingPathComponent("outputs") }

    init(root: URL = P0Paths.defaultArtifactsDir) {
        self.root = root
    }

    func ensureDirectories() throws {
        for dir in [root, sourcesDir, outputsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 清空 outputs 目录（保留 sources，避免重复生成测试片）。
    func cleanOutputs() throws {
        if FileManager.default.fileExists(atPath: outputsDir.path) {
            try FileManager.default.removeItem(at: outputsDir)
        }
        try FileManager.default.createDirectory(at: outputsDir, withIntermediateDirectories: true)
    }
}

// MARK: - 格式化

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        let mb = Double(value) / 1_000_000.0
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1000.0) }
        return String(format: "%.1f MB", mb)
    }

    static func seconds(_ value: Double) -> String {
        if value < 60 { return String(format: "%.2fs", value) }
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, seconds)
    }

    /// 媒体时长 → 00:12.3
    static func clock(_ value: Double) -> String {
        let total = Int(value.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func x(_ value: Double) -> String { String(format: "%.2fx", value) }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    static func table(_ rows: [[String]], headers: [String]) -> String {
        var widths = headers.map { $0.count }
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], visibleWidth(cell))
            }
        }
        func pad(_ text: String, _ width: Int) -> String {
            let diff = width - visibleWidth(text)
            return diff > 0 ? text + String(repeating: " ", count: diff) : text
        }
        var lines: [String] = []
        lines.append(zip(headers, widths).map { pad($0.0, $0.1) }.joined(separator: "  "))
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for row in rows {
            lines.append(zip(row, widths).map { pad($0.0, $0.1) }.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    /// 粗略可见宽度：CJK 与全角字符按 2 列计。
    private static func visibleWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            width += scalar.value > 0x2E80 ? 2 : 1
        }
        return width
    }
}

// MARK: - 控制台与错误

enum Console {
    static func section(_ title: String) {
        print("\n▍\(title)")
    }

    static func kv(_ key: String, _ value: String) {
        print("  \(key): \(value)")
    }

    static func item(_ text: String) {
        print("  · \(text)")
    }

    static func warn(_ text: String) {
        print("  ⚠️ \(text)")
    }

    static func ok(_ text: String) {
        print("  ✅ \(text)")
    }

    static func fail(_ text: String) {
        print("  ❌ \(text)")
    }
}

enum P0Error: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - JSON 输出

enum JSONWriter {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }
}

// MARK: - 单调时钟

enum MonotonicClock {
    static var now: Double { ProcessInfo.processInfo.systemUptime }
}
