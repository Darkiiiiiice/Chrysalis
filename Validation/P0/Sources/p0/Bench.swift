@preconcurrency import AVFoundation
import Foundation

// MARK: - 结果结构

struct BenchSource: Codable {
    var name: String
    var path: String
    var width: Int
    var height: Int
    var codec: String
    var durationSeconds: Double
    var sizeBytes: Int64
}

struct BenchCase: Codable {
    var name: String
    var status: String // ok / failed
    var error: String?
    var inputName: String
    var outputCodec: String
    var resolution: String
    var durationSeconds: Double?
    var wallSeconds: Double?
    var speed: Double?
    var avgCPUPercent: Double?
    var peakFootprintMB: Double?
    var outputMB: Double?
    var outputBitrateMbps: Double?
    var verifyIssues: [String]?
    var tempFileLeft: Bool?
}

struct BenchReport: Codable {
    var sources: [BenchSource]
    var cases: [BenchCase]
}

// MARK: - 用例定义

struct BenchCaseSpec {
    var name: String
    var sourceName: String
    var codec: AVVideoCodecType
    var fileType: AVFileType
    var outputSize: CGSize?
    var bitrate: Int?
}

enum Bench {
    static let sourceSpecs: [(name: String, width: Int, height: Int, codec: AVVideoCodecType, bitrate: Int)] = [
        ("1080p-h264", 1920, 1080, .h264, 8_000_000),
        ("1080p-hevc", 1920, 1080, .hevc, 6_000_000),
        ("4k-hevc", 3840, 2160, .hevc, 40_000_000),
    ]

    static let caseSpecs: [BenchCaseSpec] = [
        BenchCaseSpec(
            name: "1080p H.264 → H.264（快路径）",
            sourceName: "1080p-h264", codec: .h264, fileType: .mp4,
            outputSize: nil, bitrate: 8_000_000
        ),
        BenchCaseSpec(
            name: "1080p HEVC → H.264（快路径）",
            sourceName: "1080p-hevc", codec: .h264, fileType: .mp4,
            outputSize: nil, bitrate: 8_000_000
        ),
        BenchCaseSpec(
            name: "1080p H.264 → HEVC（快路径）",
            sourceName: "1080p-h264", codec: .hevc, fileType: .mp4,
            outputSize: nil, bitrate: 6_000_000
        ),
        BenchCaseSpec(
            name: "1080p H.264 → ProRes 422（MOV）",
            sourceName: "1080p-h264", codec: .proRes422, fileType: .mov,
            outputSize: nil, bitrate: nil
        ),
        BenchCaseSpec(
            name: "4K HEVC → 1080p H.264（慢路径）",
            sourceName: "4k-hevc", codec: .h264, fileType: .mp4,
            outputSize: CGSize(width: 1920, height: 1080), bitrate: 8_000_000
        ),
    ]

    static func sourceURL(_ name: String, artifacts: Artifacts) -> URL {
        artifacts.sourcesDir.appendingPathComponent("\(name).mp4")
    }

    /// 确保三个测试片存在（不存在则生成）。
    static func ensureSources(artifacts: Artifacts, force: Bool) async throws -> [BenchSource] {
        var sources: [BenchSource] = []
        for spec in sourceSpecs {
            let url = sourceURL(spec.name, artifacts: artifacts)
            let existingSize = (((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]) as? Int64) ?? 0
            let needsGenerate = force || existingSize == 0
            if needsGenerate {
                Console.item("生成测试片 \(spec.name)（\(spec.width)x\(spec.height)，\(spec.bitrate / 1_000_000) Mbps · 10s）…")
                let stats = try await ClipGenerator.generate(ClipGenerator.Spec(
                    url: url,
                    size: CGSize(width: spec.width, height: spec.height),
                    codec: spec.codec,
                    bitrate: spec.bitrate,
                    duration: 10
                ))
                Console.item("  完成：\(Fmt.bytes(stats.bytes))，用时 \(Fmt.seconds(stats.wallSeconds))")
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            sources.append(BenchSource(
                name: spec.name,
                path: url.path,
                width: spec.width,
                height: spec.height,
                codec: spec.codec.rawValue,
                durationSeconds: 10,
                sizeBytes: size
            ))
        }
        return sources
    }

    /// 跑整个矩阵；返回结构化结果。
    static func runAll(
        artifacts: Artifacts,
        capabilities: CapabilitiesReport,
        sources: [BenchSource]
    ) async -> BenchReport {
        var cases: [BenchCase] = []
        for (index, spec) in caseSpecs.enumerated() {
            Console.section("用例 \(index + 1)/\(caseSpecs.count)：\(spec.name)")
            let inputURL = sourceURL(spec.sourceName, artifacts: artifacts)
            let source = sourceSpecs.first { $0.name == spec.sourceName }!
            let outputSize = spec.outputSize ?? CGSize(width: source.width, height: source.height)
            let ext = spec.fileType == .mp4 ? "mp4" : "mov"
            let outputURL = artifacts.outputsDir
                .appendingPathComponent("bench-\(index + 1)-\(spec.sourceName)-to-\(spec.codec.rawValue).\(ext)")
            try? FileManager.default.removeItem(at: outputURL)

            let encoderID = capabilities.hardwareEncoder(forCodecFourCC: Transcoder.codecFourCCFor(spec.codec))?.encoderID
            if encoderID == nil {
                Console.warn("能力矩阵中没有 \(spec.codec.rawValue) 的硬件编码器，将带 Require 标志直接尝试")
            } else {
                Console.item("硬件编码器：\(encoderID!)")
            }

            let settings = TranscodeSettings(
                codec: spec.codec,
                fileType: spec.fileType,
                outputSize: outputSize,
                bitrate: spec.bitrate,
                frameDuration: nil,
                requireHardware: true,
                encoderID: encoderID
            )

            var lastPrint = MonotonicClock.now
            do {
                let report = try await Transcoder.run(
                    input: inputURL,
                    settings: settings,
                    outputURL: outputURL,
                    cancelFlag: nil,
                    progress: { progress in
                        let now = MonotonicClock.now
                        if now - lastPrint >= 1.0 {
                            lastPrint = now
                            let eta = progress.etaSeconds.map { Fmt.clock($0) } ?? "--"
                            print(String(
                                format: "    %5.1f%% · %@ · ETA %@",
                                progress.fraction * 100, Fmt.x(progress.speed), eta
                            ))
                        }
                    }
                )
                let tempLeft = OutputPlanner.hasOrphanTemps(in: artifacts.outputsDir)
                let bitrateMbps = report.durationSeconds > 0
                    ? Double(report.outputBytes) * 8 / report.durationSeconds / 1_000_000
                    : 0
                let item = BenchCase(
                    name: spec.name,
                    status: "ok",
                    error: nil,
                    inputName: spec.sourceName,
                    outputCodec: report.verify.videoCodecFourCC,
                    resolution: "\(report.verify.width)x\(report.verify.height)",
                    durationSeconds: report.durationSeconds,
                    wallSeconds: report.wallSeconds,
                    speed: report.speed,
                    avgCPUPercent: report.avgCPUPercent,
                    peakFootprintMB: Double(report.peakFootprintBytes) / 1_000_000,
                    outputMB: Double(report.outputBytes) / 1_000_000,
                    outputBitrateMbps: bitrateMbps,
                    verifyIssues: report.verify.issues,
                    tempFileLeft: tempLeft
                )
                cases.append(item)
                printResultLine(item)
            } catch {
                let item = BenchCase(
                    name: spec.name, status: "failed",
                    error: "\(error)", inputName: spec.sourceName,
                    outputCodec: spec.codec.rawValue, resolution: "\(Int(outputSize.width))x\(Int(outputSize.height))",
                    durationSeconds: nil, wallSeconds: nil, speed: nil, avgCPUPercent: nil,
                    peakFootprintMB: nil, outputMB: nil, outputBitrateMbps: nil,
                    verifyIssues: nil, tempFileLeft: nil
                )
                cases.append(item)
                Console.fail("失败：\(error)")
            }
        }
        return BenchReport(sources: sources, cases: cases)
    }

    static func printResultLine(_ item: BenchCase) {
        if let speed = item.speed, let wall = item.wallSeconds,
           let cpu = item.avgCPUPercent, let memory = item.peakFootprintMB {
            Console.ok("\(Fmt.x(speed)) 实时 · 用时 \(Fmt.seconds(wall)) · CPU \(Fmt.percent(cpu)) · 峰值内存 \(String(format: "%.0f MB", memory)) · 输出 \(String(format: "%.1f MB", item.outputMB ?? 0))")
            if let issues = item.verifyIssues, !issues.isEmpty {
                for issue in issues { Console.warn("自检：\(issue)") }
            }
        }
    }

    static func printTable(_ report: BenchReport) {
        Console.section("吞吐汇总")
        let rows = report.cases.map { item -> [String] in
            if item.status == "ok" {
                return [
                    item.name,
                    item.resolution,
                    item.outputCodec,
                    item.speed.map { Fmt.x($0) } ?? "-",
                    item.wallSeconds.map { Fmt.seconds($0) } ?? "-",
                    item.avgCPUPercent.map { Fmt.percent($0) } ?? "-",
                    item.peakFootprintMB.map { String(format: "%.0f MB", $0) } ?? "-",
                    item.outputMB.map { String(format: "%.1f MB", $0) } ?? "-",
                ]
            }
            return [item.name, item.resolution, item.outputCodec, "失败", item.error ?? "", "", "", ""]
        }
        print(Fmt.table(rows, headers: ["用例", "分辨率", "编码", "速度", "用时", "CPU", "峰值内存", "输出"]))
    }
}
