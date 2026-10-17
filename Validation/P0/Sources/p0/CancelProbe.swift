import Foundation

struct CancelProbeResult: Codable {
    var cancelAtFraction: Double
    var reachedFraction: Double
    var transcodeWasCancelled: Bool
    var outputExistsAfterCancel: Bool
    var tempExistsAfterCancel: Bool
    var orphanCreated: Bool
    var orphanRemoved: Int
    var cleanupOk: Bool

    var ok: Bool {
        transcodeWasCancelled && !outputExistsAfterCancel && !tempExistsAfterCancel && cleanupOk
    }
}

/// 取消 → 无残留；启动清理 → 删除孤儿临时文件。
enum CancelProbe {
    static func run(
        artifacts: Artifacts,
        capabilities: CapabilitiesReport,
        cancelAt: Double = 0.5
    ) async -> CancelProbeResult {
        let fm = FileManager.default
        let input = Bench.sourceURL("4k-hevc", artifacts: artifacts)
        let output = artifacts.outputsDir.appendingPathComponent("cancel-test.mp4")
        try? fm.removeItem(at: output)

        let flag = CancelFlag()
        var reached = 0.0
        var wasCancelled = false
        let encoderID = capabilities.hardwareEncoder(forCodecFourCC: "avc1")?.encoderID
        let settings = TranscodeSettings(
            codec: .h264,
            fileType: .mp4,
            outputSize: CGSize(width: 1920, height: 1080),
            bitrate: 8_000_000,
            frameDuration: nil,
            requireHardware: true,
            encoderID: encoderID
        )

        do {
            _ = try await Transcoder.run(
                input: input,
                settings: settings,
                outputURL: output,
                cancelFlag: flag,
                progress: { progress in
                    reached = max(reached, progress.fraction)
                    if progress.fraction >= cancelAt {
                        flag.cancel()
                    }
                }
            )
            // 没有抛 cancelled：说明跑完了没来得及取消
        } catch TranscodeError.cancelled {
            wasCancelled = true
        } catch {
            Console.warn("取消探针出现意外错误：\(error)")
        }

        let outputExists = fm.fileExists(atPath: output.path)
        let tempExists = OutputPlanner.hasOrphanTemps(in: artifacts.outputsDir)

        // 孤儿临时文件清理探针
        let orphan = artifacts.outputsDir.appendingPathComponent("\(OutputPlanner.tempPrefix)orphan-probe\(OutputPlanner.tempSuffix)")
        let orphanCreated = (try? Data([0x00]).write(to: orphan)) != nil
        let removed = OutputPlanner.cleanupOrphanTemps(in: artifacts.outputsDir)
        let orphanStillExists = fm.fileExists(atPath: orphan.path)

        Console.section("取消与临时文件")
        Console.kv("取消进度", Fmt.percent(reached * 100))
        Console.kv("捕获取消", wasCancelled ? "是" : "否（未及时取消）")
        Console.kv("取消后输出文件", outputExists ? "存在（❌ 不应存在）" : "不存在")
        Console.kv("取消后临时文件", tempExists ? "存在（❌ 不应存在）" : "不存在")
        Console.kv("孤儿临时文件清理", "删除 \(removed.count) 个；孤儿仍存在：\(orphanStillExists ? "是（❌）" : "否")")

        return CancelProbeResult(
            cancelAtFraction: cancelAt,
            reachedFraction: reached,
            transcodeWasCancelled: wasCancelled,
            outputExistsAfterCancel: outputExists,
            tempExistsAfterCancel: tempExists,
            orphanCreated: orphanCreated,
            orphanRemoved: removed.count,
            cleanupOk: orphanCreated && !orphanStillExists
        )
    }
}
