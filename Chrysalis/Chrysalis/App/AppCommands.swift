import SwiftUI

/// 菜单与快捷键（设计文档 §8.6）：`Cmd+O` 添加、`Cmd+Return` 开始、`Cmd+.` 取消、`Cmd+I` 检查器。
struct AppCommands: Commands {
    let store: QueueStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加文件…") {
                store.isAddFilesPresented = true
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("选择输出文件夹…") {
                store.isChooseOutputPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("在 Finder 中打开输出文件夹") {
                store.openOutputFolderInFinder()
            }
            .disabled(store.outputDirectory == nil)
        }

        CommandMenu("队列") {
            Button("开始全部") {
                store.startAll()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canStart)

            Button("取消全部") {
                store.cancelAll()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!store.isRunningBatch)

            Button("清理已完成") {
                store.clearCompleted()
            }
            .disabled(store.completedCount == 0)

            Divider()

            Button(store.isInspectorPresented ? "隐藏检查器" : "显示检查器") {
                store.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: .command)
        }
    }
}
