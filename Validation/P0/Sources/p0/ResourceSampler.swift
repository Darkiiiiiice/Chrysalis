import Foundation

/// 转码过程中的 CPU / 内存采样器。
/// 独立队列上的定时器采样，不受主循环阻塞影响（finishWriting 的收尾峰值也能采到）。
final class ResourceSampler: @unchecked Sendable {
    struct Metrics: Codable {
        var wallSeconds: Double
        var cpuTimeSeconds: Double
        var avgCPUPercent: Double
        var peakFootprintBytes: Int64
        var sampleCount: Int
    }

    private struct Sample {
        var wall: Double
        var cpuTime: Double
        var footprint: Int64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var timer: DispatchSourceTimer?
    private var startedWall: Double = 0
    private var startedCPU: Double = 0

    private static func cpuTimeSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return user + system
    }

    /// 物理内存占用（phys_footprint），与 Xcode 内存报告一致。
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
        let wall = MonotonicClock.now
        let cpu = Self.cpuTimeSeconds()
        let footprint = Self.footprintBytes()
        lock.lock()
        startedWall = wall
        startedCPU = cpu
        samples = [Sample(wall: wall, cpuTime: cpu, footprint: footprint)]
        lock.unlock()

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "p0.sampler", qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let sample = Sample(
                wall: MonotonicClock.now,
                cpuTime: Self.cpuTimeSeconds(),
                footprint: Self.footprintBytes()
            )
            self.lock.lock()
            self.samples.append(sample)
            self.lock.unlock()
        }
        timer = source
        source.resume()
    }

    func stop() -> Metrics {
        let endWall = MonotonicClock.now
        let endCPU = Self.cpuTimeSeconds()
        let endFootprint = Self.footprintBytes()

        timer?.cancel()
        timer = nil

        lock.lock()
        let captured = samples
        let startWall = startedWall
        let startCPU = startedCPU
        samples = []
        lock.unlock()

        var peak: Int64 = 0
        for sample in captured { peak = max(peak, sample.footprint) }
        peak = max(peak, endFootprint)

        let wall = max(endWall - startWall, 0.0001)
        let cpuDelta = max(endCPU - startCPU, 0)
        return Metrics(
            wallSeconds: wall,
            cpuTimeSeconds: cpuDelta,
            avgCPUPercent: cpuDelta / wall * 100.0,
            peakFootprintBytes: peak,
            sampleCount: captured.count + 2
        )
    }
}
