import AVFoundation
import Foundation
import Observation
import os

/// A/B 对比播放状态与同步编排（设计文档 §7.9；MainActor）。
///
/// 同步模型：主时钟跟随原片（A），输出（B）用 periodicTimeObserver 校偏 ±1 帧；
/// 音轨互斥只播一侧。所有 AVPlayer 访问都在主线程。
@MainActor
@Observable
final class CompareStore {
    /// 展示模式（设计文档 §7.9：双模式标签页切换）。
    enum Mode: String, CaseIterable, Identifiable {
        case wipe
        case sideBySide

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .wipe: "滑动分割"
            case .sideBySide: "左右并排"
            }
        }
    }

    /// 音源（互斥，防回声）。
    enum AudioSource: String, CaseIterable, Identifiable {
        case source
        case output

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .source: "原片"
            case .output: "输出"
            }
        }
    }

    let context: CompareContext

    private(set) var sourcePlayer: AVPlayer?
    private(set) var outputPlayer: AVPlayer?
    /// 双侧可用性（false 时窗口降级单画面 + 提示，设计文档 §7.9）。
    private(set) var sourceAvailable = true
    private(set) var outputAvailable = true
    private(set) var sourceInfo: MediaInfo?
    private(set) var outputInfo: MediaInfo?

    private(set) var mode: Mode = .wipe
    private(set) var audioSource: AudioSource = .source
    private(set) var isPlaying = false
    private(set) var currentSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// wipe 分割位置（0–1，顶部工具条/把手拖动更新）。
    var splitPosition: Double = 0.5

    /// 源文件安全作用域持有（窗口关闭时释放）。
    private var heldSourceScopeURL: URL?
    private var timeObserver: Any?
    /// seek 进行中标志（校偏器跳过，避免 seek 竞争）。
    private var isSeeking = false

    init(context: CompareContext) {
        self.context = context
    }

    /// 窗口打开时执行：恢复访问权 → 读规格 → 建双播放器 → 挂校偏观察器。
    func setup() async {
        let source = context.sourceURL
        let output = context.outputURL

        // 源访问权：优先书签解析（沙盒），失败时直接路径探测（非沙盒来源）
        if let bookmark = context.sourceBookmark, let resolved = BookmarkStore.resolve(bookmark) {
            if resolved.url.startAccessingSecurityScopedResource() {
                heldSourceScopeURL = resolved.url
            }
            sourceAvailable = FileManager.default.fileExists(atPath: resolved.url.path)
        } else {
            sourceAvailable = FileManager.default.fileExists(atPath: source.path)
        }
        outputAvailable = FileManager.default.fileExists(atPath: output.path)

        // 规格读回（只读；失败仅影响规格条展示）
        sourceInfo = sourceAvailable ? try? await MediaInspector.inspect(url: source) : nil
        outputInfo = outputAvailable ? try? await MediaInspector.inspect(url: output) : nil

        guard sourceAvailable || outputAvailable else { return }

        if sourceAvailable {
            sourcePlayer = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: source)))
        }
        if outputAvailable {
            outputPlayer = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: output)))
        }
        applyAudioSource(audioSource)

        let clock = sourcePlayer ?? outputPlayer
        durationSeconds = await loadDuration(of: clock)

        // 校偏观察器：主时钟侧更新 UI 与对齐另一侧（±1 帧容忍，§7.9）
        let reference = sourcePlayer ?? outputPlayer
        guard let reference else { return }
        let observer = reference.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTick(mainTime: time.seconds)
            }
        }
        timeObserver = observer
    }

    /// 窗口关闭：停播 + 移除观察器 + 释放访问权。
    func teardown() {
        sourcePlayer?.pause()
        outputPlayer?.pause()
        if let timeObserver {
            sourcePlayer?.removeTimeObserver(timeObserver)
            outputPlayer?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let heldSourceScopeURL {
            heldSourceScopeURL.stopAccessingSecurityScopedResource()
            self.heldSourceScopeURL = nil
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        // 主时钟在末尾时先回到起点
        if let reference = sourcePlayer ?? outputPlayer,
           durationSeconds > 0, reference.currentTime().seconds >= durationSeconds - 0.05 {
            seek(toFraction: 0)
        }
        sourcePlayer?.play()
        outputPlayer?.play()
        isPlaying = true
    }

    func pause() {
        sourcePlayer?.pause()
        outputPlayer?.pause()
        isPlaying = false
    }

    /// 双端 seek（进度条 / 回到起点）。
    func seek(toFraction fraction: Double) {
        let clamped = max(0, min(fraction, 1))
        let target = clamped * durationSeconds
        isSeeking = true
        let tolerance = CMTime(seconds: 1.0 / 120, preferredTimescale: 600)
        let group = DispatchGroup()
        for player in [sourcePlayer, outputPlayer].compactMap({ $0 }) {
            group.enter()
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance,
                completionHandler: { _ in group.leave() }
            )
        }
        currentSeconds = target
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.isSeeking = false
                self?.handleTick(mainTime: target)
            }
        }
    }

    /// 模式切换（wipe / 并排）；切换不清播放状态。
    func setMode(_ newMode: Mode) {
        mode = newMode
    }

    /// 音源切换（互斥）。
    func setAudioSource(_ newSource: AudioSource) {
        audioSource = newSource
        applyAudioSource(newSource)
    }

    // MARK: - 私有

    private func applyAudioSource(_ source: AudioSource) {
        sourcePlayer?.isMuted = source != .source
        outputPlayer?.isMuted = source != .output
    }

    private func loadDuration(of player: AVPlayer?) async -> Double {
        guard let item = player?.currentItem else { return 0 }
        let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    /// 主时钟节拍：更新进度；输出侧偏离超过 1 帧时对齐（§7.9）。
    private func handleTick(mainTime: Double) {
        currentSeconds = max(0, min(mainTime, durationSeconds))
        guard !isSeeking, isPlaying else { return }

        if let source = sourcePlayer, let output = outputPlayer {
            let main = source.currentTime().seconds
            let other = output.currentTime().seconds
            if abs(other - main) > 1.0 / 60 {
                output.seek(
                    to: CMTime(seconds: min(max(main, 0), durationSeconds), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        }
    }
}
