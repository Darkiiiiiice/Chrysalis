import SwiftUI
import UniformTypeIdentifiers

/// 主界面：两栏 NavigationSplitView + 可隐藏检查器（设计文档 §8.3）。
struct QueueScreen: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
        } detail: {
            detailContent
        }
        .inspector(isPresented: $store.isInspectorPresented) {
            InspectorView()
                .inspectorColumnWidth(
                    min: Theme.Size.inspectorWidth,
                    ideal: Theme.Size.inspectorWidth,
                    max: Theme.Size.inspectorWidth
                )
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $store.isAddFilesPresented,
            allowedContentTypes: Self.acceptedVideoTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                store.prepareAdd(urls)
            case .failure(let error):
                store.showBanner(kind: .error, message: "选择文件失败：\(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $store.isChooseOutputPresented,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                store.setOutputDirectory(url)
            case .failure(let error):
                store.showBanner(kind: .error, message: "选择输出文件夹失败：\(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $store.isAddSheetPresented) {
            AddFilesSheet()
        }
        .sheet(item: $store.confirmMovieContext) { context in
            ConfirmMovieSheet(jobID: context.id)
        }
        .navigationTitle("Chrysalis")
        .background(Theme.bg)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.sidebarSelection {
        case .queue:
            QueueContentView()
        case .presets:
            PresetsScreen()
        case .history:
            HistoryScreen()
        case .settings:
            SettingsScreen()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            IconButton(systemImage: "plus", help: "添加文件（⌘O）") {
                store.isAddFilesPresented = true
            }

            PrimaryButton(title: "开始", systemImage: "play.fill", isEnabled: store.canStart) {
                store.startAll()
            }

            if store.isRunningBatch {
                IconButton(systemImage: "stop.fill", help: "取消全部（⌘.）") {
                    store.cancelAll()
                }
            }

            IconButton(systemImage: "folder", help: "选择输出文件夹（⇧⌘O）") {
                store.isChooseOutputPresented = true
            }

            IconButton(systemImage: "sidebar.right", help: "显示 / 隐藏检查器（⌘I）") {
                store.toggleInspector()
            }
        }
    }

    /// v1 只接受 MP4 / MOV / M4V；其他类型在入队时会被过滤并提示。
    private static var acceptedVideoTypes: [UTType] {
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType(filenameExtension: "m4v") {
            types.append(m4v)
        }
        return types
    }
}
