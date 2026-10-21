import AVFoundation
import SwiftUI

// MARK: - 双路播放画布（设计文档 §7.9）

/// 双 `AVPlayerLayer` 画布：原片在底层、输出在顶层；
/// wipe 模式顶层沿分割位置裁剪（CAShapeLayer mask），并排模式左右各半。
struct ComparePlayerView: NSViewRepresentable {
    let store: CompareStore

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.sourceLayer.videoGravity = .resizeAspect
        view.outputLayer.videoGravity = .resizeAspect
        if let sourcePlayer = store.sourcePlayer {
            view.sourceLayer.player = sourcePlayer
        }
        if let outputPlayer = store.outputPlayer {
            view.outputLayer.player = outputPlayer
        }
        // 顶层输出（wipe 时被 mask 裁剪；并排时占右半）
        view.layer?.addSublayer(view.sourceLayer)
        view.layer?.addSublayer(view.outputLayer)
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        if let sourcePlayer = store.sourcePlayer, nsView.sourceLayer.player !== sourcePlayer {
            nsView.sourceLayer.player = sourcePlayer
        }
        if let outputPlayer = store.outputPlayer, nsView.outputLayer.player !== outputPlayer {
            nsView.outputLayer.player = outputPlayer
        }
        nsView.mode = store.mode
        nsView.splitPosition = store.splitPosition
        nsView.needsLayout = true
    }

    /// 容器视图：layout 时按模式摆放两个 layer 并更新 mask。
    final class ContainerView: NSView {
        let sourceLayer = AVPlayerLayer()
        let outputLayer = AVPlayerLayer()
        private let maskLayer = CAShapeLayer()
        var mode: CompareStore.Mode = .wipe
        var splitPosition: Double = 0.5

        override func layout() {
            super.layout()
            guard let bounds = layer?.bounds, bounds.width > 0, bounds.height > 0 else { return }
            sourceLayer.frame = bounds
            outputLayer.frame = bounds

            switch mode {
            case .wipe:
                sourceLayer.isHidden = false
                outputLayer.isHidden = false
                // 顶层输出只显示分割线右侧；左侧露出底层原片
                maskLayer.frame = bounds
                let x = bounds.width * splitPosition
                maskLayer.path = CGPath(
                    rect: CGRect(x: x, y: 0, width: bounds.width - x, height: bounds.height),
                    transform: nil
                )
                outputLayer.mask = maskLayer
            case .sideBySide:
                outputLayer.mask = nil
                let half = bounds.width / 2
                sourceLayer.frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
                outputLayer.frame = CGRect(x: half, y: 0, width: half, height: bounds.height)
            }
        }
    }
}
