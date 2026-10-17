import SwiftUI

/// 蝉蜕（Chrysalis）：macOS 本地视频转码工具。
@main
struct ChrysalisApp: App {
    @State private var store = QueueStore()

    var body: some Scene {
        WindowGroup {
            QueueScreen()
                .environment(store)
                .frame(minWidth: 960, minHeight: 620)
                .tint(Theme.accent)
                .task { await store.bootstrap() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            AppCommands(store: store)
        }
    }
}
