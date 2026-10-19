import Foundation

// MARK: - 极简测试框架（中文输出；顺序执行）

/// 单条用例的失败描述（带文件与行号）。
struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: UInt

    var description: String { "\(message)（\(URL(fileURLWithPath: file).lastPathComponent):\(line)）" }
}

/// 无硬件编码器等环境不满足时抛出（计入跳过，不算失败；对齐 §11「XCTSkip 或期望错误」）。
struct SkipReason: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// 运行计数与输出（用例顺序执行，无需加锁）。
@MainActor
final class Harness {
    static let shared = Harness()

    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private var failureMessages: [String] = []

    /// 手工记分（基准用：整段通过/失败各记 1）。
    func record(pass: Bool) {
        if pass { passed += 1 } else { failed += 1 }
    }

    /// 当前用例是否在 `--list` 模式下（只打印目录不执行）。
    var listOnly = false

    var exitCode: Int32 { failed > 0 ? 1 : 0 }

    func summary(label: String) {
        print("")
        print("—— \(label)：\(passed) 过 / \(failed) 败 / \(skipped) 跳 ——")
        for message in failureMessages {
            print("  ✗ \(message)")
        }
    }

    func reset() {
        passed = 0
        failed = 0
        skipped = 0
        failureMessages = []
    }

    /// 整段环境性跳过（如无硬件编码器）。
    func markSkipped(_ note: String) {
        skipped += 1
        print("⊘ \(note)")
    }

    // MARK: 套件与用例

    func suite(_ name: String, _ body: () async throws -> Void) async {
        if listOnly { return }
        print("")
        print("◆ \(name)")
        try? await body()
    }

    nonisolated static func expect(
        _ condition: Bool,
        _ message: String,
        file: String = #filePath,
        line: UInt = #line
    ) throws {
        guard condition else { throw TestFailure(message: message, file: file, line: line) }
    }

    nonisolated static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String,
        file: String = #filePath,
        line: UInt = #line
    ) throws {
        guard actual == expected else {
            throw TestFailure(message: "\(message)：期望 \(expected)，实际 \(actual)", file: file, line: line)
        }
    }

    @MainActor
    static func expectError<E: Error & Equatable>(
        _ expected: E,
        _ body: () async throws -> Void,
        file: String = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await body()
        } catch let error as E {
            guard error == expected else {
                throw TestFailure(message: "错误类型匹配但值不同：\(error)", file: file, line: line)
            }
            return
        } catch {
            throw TestFailure(message: "期望错误 \(expected)，实际 \(error)", file: file, line: line)
        }
        throw TestFailure(message: "期望抛出 \(expected)，但未抛出", file: file, line: line)
    }

    // MARK: 执行包装（由套件体内调用）

    func run(_ name: String, _ body: () throws -> Void) {
        if listOnly { return }
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch let reason as SkipReason {
            skipped += 1
            print("  ⊘ \(name)（跳过：\(reason)）")
        } catch {
            failed += 1
            failureMessages.append("\(name)：\(error)")
            print("  ✗ \(name) —— \(error)")
        }
    }

    func runAsync(_ name: String, _ body: () async throws -> Void) async {
        if listOnly { return }
        do {
            try await body()
            passed += 1
            print("  ✓ \(name)")
        } catch let reason as SkipReason {
            skipped += 1
            print("  ⊘ \(name)（跳过：\(reason)）")
        } catch {
            failed += 1
            failureMessages.append("\(name)：\(error)")
            print("  ✗ \(name) —— \(error)")
        }
    }
}

/// 用例内便捷断言。
func expect(_ condition: Bool, _ message: String, file: String = #filePath, line: UInt = #line) throws {
    try Harness.expect(condition, message, file: file, line: line)
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String,
    file: String = #filePath,
    line: UInt = #line
) throws {
    try Harness.expectEqual(actual, expected, message, file: file, line: line)
}

// MARK: - 时间与目录

/// 单调时钟（秒）。
enum Stopwatch {
    static var now: Double {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
}

/// harness 产物目录：`Validation/Harness/artifacts/`（git 忽略）。
enum Artifacts {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Sources/check
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // Validation/Harness
        .appendingPathComponent("artifacts", isDirectory: true)

    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 子目录（单元/集成/基准各自独立），自动清理旧内容。
    static func subdirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// 简易 JSON 落盘。
enum JSONWriter {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
