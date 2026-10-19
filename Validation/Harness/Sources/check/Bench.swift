import Foundation

// MARK: - 内存资源采样器（phys_footprint；模式沿用 Validation/P0）

/// 转码过程中的内存采样器（独立队列定时采样，finishWriting 收尾峰值也能采到）。
final class MemorySampler: @unchecked Sendable {
    struct Metrics: Codable {
        var wallSeconds: Double
        var peakFootprintBytes: Int64
        var sampleCount: Int
    }

    private struct Sample {
        var wall: Double
        var footprint: Int64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var timer: DispatchSourceTimer?
    private var startedWall: Double = 0

    /// 物理内存占用（phys_footprint），与 Xcode 内存报告口径一致。
    private static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    func start(interval: TimeInterval = 0.05) {
        let wall = Stopwatch.now
        lock.lock()
        startedWall = wall
        samples = [Sample(wall: wall, footprint: Self.footprintBytes())]
        lock.unlock()

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "harness.sampler", qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let sample = Sample(wall: Stopwatch.now, footprint: Self.footprintBytes())
            self.lock.lock()
            self.samples.append(sample)
            self.lock.unlock()
        }
        timer = source
        source.resume()
    }

    func stop() -> Metrics {
        let endWall = Stopwatch.now
        let endFootprint = Self.footprintBytes()

        timer?.cancel()
        timer = nil

        lock.lock()
        let captured = samples
        let startWall = startedWall
        samples = []
        lock.unlock()

        var peak: Int64 = 0
        for sample in captured { peak = max(peak, sample.footprint) }
        peak = max(peak, endFootprint)

        return Metrics(
            wallSeconds: max(endWall - startWall, 0.0001),
            peakFootprintBytes: peak,
            sampleCount: captured.count + 1
        )
    }
}

// MARK: - 性能/内存基准（设计文档 §11 性能基准表）

@MainActor
func runBench() async {
    let h = Harness.shared

    guard VideoToolboxCapabilities.probe().isReady else {
        h.markSkipped("性能基准（本机没有 H.264 硬件编码器，基准无意义）")
        return
    }

    let directory = try! Artifacts.subdirectory("bench")
    let outputs = directory.appendingPathComponent("outputs", isDirectory: true)
    try! FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
    print("◆ 性能/内存基准（源为 10 秒合成片；机器：\(MachineInfo.line)）")

    do {
        // 生成 10 秒源片（编码负载与 P0 相同的合成画面）
        print("  生成 10s 测试源…")
        try await ClipFactory.generate(ClipFactory.Spec(
            url: directory.appendingPathComponent("源-1080p-h264.mp4"),
            size: CGSize(width: 1920, height: 1080), codec: .h264, bitrate: 8_000_000, duration: 10
        ))
        try await ClipFactory.generate(ClipFactory.Spec(
            url: directory.appendingPathComponent("源-1080p-hevc.mp4"),
            size: CGSize(width: 1920, height: 1080), codec: .hevc, bitrate: 6_000_000, duration: 10
        ))
        try await ClipFactory.generate(ClipFactory.Spec(
            url: directory.appendingPathComponent("源-4k-hevc.mp4"),
            size: CGSize(width: 3840, height: 2160), codec: .hevc, bitrate: 20_000_000, duration: 10
        ))

        struct Row: Codable {
            var scene: String
            var target: String
            var sourceDuration: Double
            var wallSeconds: Double
            var speedMultiple: Double
            var peakFootprintBytes: Int64
            var passed: Bool
        }

        var rows: [Row] = []
        let outputs = directory.appendingPathComponent("outputs", isDirectory: true)

        func scene(_ name: String, input: URL, target: String, minimumSpeed: Double?, memoryLimitBytes: Int64?, build: (inout TranscodeRequest) -> Void) async {
            var request = TranscodeRequest(
                inputURL: input,
                outputURL: outputs.appendingPathComponent("\(name).mp4"),
                videoCodec: .h264,
                container: .mp4,
                resolution: .source,
                frameRate: .source,
                averageBitrate: 8_000_000,
                audioBitrate: 192_000,
                audioMaxChannels: 2,
                audioSampleRate: nil,
                audioPCMSampleBitDepth: nil,
                requireHardware: true,
                encoderID: nil,
                metadata: nil,
                posterData: nil
            )
            request.bitrateRange = 2_500_000...12_000_000
            // 引擎要求显式编码器 ID（requireHardware = true 时）
            request.encoderID = VideoToolboxCapabilities.probe().hardwareEncoder(for: request.videoCodec)?.encoderID
            build(&request)

            let sourceInfo = try? await MediaInspector.inspect(url: input)
            let sourceDuration = sourceInfo?.durationSeconds ?? 10

            let engine = TranscodeEngine()
            let sampler = MemorySampler()
            sampler.start()
            let started = Stopwatch.now
            do {
                _ = try await engine.run(request) { _ in }
                let metrics = sampler.stop()
                let wall = max(Stopwatch.now - started, 0.0001)
                let speed = sourceDuration / wall
                var passed = true
                if let minimumSpeed {
                    passed = passed && speed >= minimumSpeed
                }
                if let memoryLimitBytes {
                    passed = passed && metrics.peakFootprintBytes < memoryLimitBytes
                }
                rows.append(Row(
                    scene: name,
                    target: target,
                    sourceDuration: sourceDuration,
                    wallSeconds: wall,
                    speedMultiple: speed,
                    peakFootprintBytes: metrics.peakFootprintBytes,
                    passed: passed
                ))
                let mark = passed ? "✓" : "✗"
                print("  \(mark) \(name)：\(String(format: "%.1fx", speed)) 实时，内存峰值 \(Fmt.bytes(metrics.peakFootprintBytes))（目标：\(target)）")
            } catch {
                _ = sampler.stop()
                rows.append(Row(
                    scene: name, target: target, sourceDuration: sourceDuration,
                    wallSeconds: Stopwatch.now - started, speedMultiple: 0, peakFootprintBytes: 0, passed: false
                ))
                print("  ✗ \(name)：失败 —— \(error)")
            }
        }

        let source1080H264 = directory.appendingPathComponent("源-1080p-h264.mp4")
        let source1080HEVC = directory.appendingPathComponent("源-1080p-hevc.mp4")
        let source4KHEVC = directory.appendingPathComponent("源-4k-hevc.mp4")

        await scene(
            "1080p H.264 → 1080p H.264",
            input: source1080H264,
            target: "≥4x 实时",
            minimumSpeed: 4,
            memoryLimitBytes: nil
        ) { _ in }

        await scene(
            "1080p HEVC → 1080p H.264",
            input: source1080HEVC,
            target: "≥3x 实时",
            minimumSpeed: 3,
            memoryLimitBytes: nil
        ) { _ in }

        await scene(
            "4K HEVC → 1080p H.264",
            input: source4KHEVC,
            target: "≥1x 实时 且 内存 <800MB",
            minimumSpeed: 1,
            memoryLimitBytes: 800_000_000
        ) { request in
            request.resolution = .r1080
        }

        // ProRes 场景：MOV 容器 + PCM
        await scene(
            "1080p H.264 → ProRes 422 MOV",
            input: source1080H264,
            target: "≥2x 实时",
            minimumSpeed: 2,
            memoryLimitBytes: nil
        ) { request in
            request.outputURL = outputs.appendingPathComponent("1080p-h264-prores.mov")
            request.videoCodec = .proRes422
            request.container = .mov
            request.averageBitrate = nil
            request.audioPCMSampleBitDepth = 16
            request.bitrateRange = 40_000_000...400_000_000
            request.encoderID = VideoToolboxCapabilities.probe().hardwareEncoder(for: .proRes422)?.encoderID
        }

        // 汇总
        let allPassed = rows.allSatisfy(\.passed)
        h.record(pass: allPassed)
        if !allPassed {
            print("  ✗ 存在未达标场景")
        }
        print("")
        print("—— 基准汇总：\(allPassed ? "全部达标" : "存在未达标场景") ——")

        struct BenchReport: Codable {
            var machine: String
            var rows: [Row]
        }
        try JSONWriter.write(
            BenchReport(machine: MachineInfo.line, rows: rows),
            to: Artifacts.root.appendingPathComponent("bench-report.json")
        )
        print("  报告：\(Artifacts.root.appendingPathComponent("bench-report.json").path)")
    } catch {
        h.record(pass: false)
        print("  ✗ 基准执行失败 —— \(error)")
    }
}

/// 机器信息（报告头）。
enum MachineInfo {
    static let line: String = {
        let processInfo = ProcessInfo.processInfo
        var size: UInt64 = 0
        var length: size_t = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        var nameBuffer: [CChar] = Array(repeating: 0, count: 256)
        // hw.model 需要特权，改用 CPU 品牌串（Apple Silicon 返回芯片名）
        sysctlbyname("machdep.cpu.brand_string", &nameBuffer, nil, nil, 0)
        let chip = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
        let chipPart = chip.isEmpty ? "" : "\(chip) · "
        return "\(chipPart)\(processInfo.processorCount) 核 · \(size / 1_073_741_824) GB · macOS \(processInfo.operatingSystemVersionString)"
    }()
}
