import AppKit
import SwiftUI

/// 蝉蜕（Chrysalis）：macOS 本地视频转码工具。
@main
struct ChrysalisApp: App {
    @State private var store = QueueStore()

    /// 仅截图辅助用：强制浅色外观（`--capture-light`）。
    private static var forceLightAppearance: Bool {
        ProcessInfo.processInfo.arguments.contains("--capture-light")
    }

    var body: some Scene {
        WindowGroup {
            QueueScreen()
                .environment(store)
                .frame(minWidth: 960, minHeight: 620)
                .tint(Theme.accent)
                .preferredColorScheme(Self.forceLightAppearance ? .light : nil)
                .task {
                    await store.bootstrap()
                    await captureScreenshotsIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.prepareForTermination()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            AppCommands(store: store)
        }

        Window("关于蝉蜕", id: "about") {
            AboutScreen()
                .tint(Theme.accent)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - README 截图辅助（仅 `--capture <目录>` 启动参数时生效；应用截自己的窗口无需屏幕录制权限）

extension ChrysalisApp {
    /// 逐页切换侧边栏并快照主窗口内容区。
    /// `--capture <目录>`：写盘模式（沙盒内路径）；`--capture-one <页名>`：PNG base64 → 剪贴板。
    private func captureScreenshotsIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        let pages: [(SidebarItem, String)] = [
            (.queue, "queue"),
            (.presets, "presets"),
            (.history, "history"),
            (.settings, "settings"),
        ]

        // 单页模式：快照 → base64 → 剪贴板（沙盒下绕过文件系统限制）
        if let pageName = value(after: "--capture-one"),
           let page = pages.first(where: { $0.1 == pageName }) {
            try? await Task.sleep(for: .seconds(3))
            store.sidebarSelection = page.0
            try? await Task.sleep(for: .seconds(1))
            guard let data = Self.renderMainWindowPNG() else {
                print("CAPTURE \(pageName) failed")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }
            let base64 = data.base64EncodedString()
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(base64, forType: .string)
            }
            print("CAPTURED \(pageName) bytes=\(data.count)")
            try? await Task.sleep(for: .seconds(0.3))
            await MainActor.run { NSApp.terminate(nil) }
            return
        }

        // 写盘模式
        guard arguments.contains("--capture") else { return }
        let requested = value(after: "--capture").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory: URL
        if let requested,
           (try? FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)) != nil,
           FileManager.default.isWritableFile(atPath: requested.path) {
            directory = requested
        } else {
            directory = AppPaths.supportDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        print("CAPTURE → \(directory.path)")

        // 等 bootstrap（硬件探测、队列恢复）与首帧布局完成
        try? await Task.sleep(for: .seconds(3))
        for (item, name) in pages {
            store.sidebarSelection = item
            try? await Task.sleep(for: .seconds(1))
            let ok = Self.writeMainWindowPNG(to: directory.appending(path: "\(name).png"))
            print("CAPTURE \(name) ok=\(ok)")
        }
        print("CAPTURE DONE")
        try? await Task.sleep(for: .seconds(0.5))
        await MainActor.run { NSApp.terminate(nil) }
    }

    /// 主窗口内容区渲染为 PNG 数据（自身视图缓存渲染，不经过系统截屏服务）。
    private static func renderMainWindowPNG() -> Data? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
              let contentView = window.contentView else { return nil }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        contentView.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// 渲染并写盘；仅在沙盒允许的路径成功。
    private static func writeMainWindowPNG(to url: URL) -> Bool {
        guard let data = renderMainWindowPNG() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("CAPTURE write failed: \(error)")
            return false
        }
    }
}
