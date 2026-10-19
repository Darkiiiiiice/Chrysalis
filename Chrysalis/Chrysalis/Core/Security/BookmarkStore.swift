import Foundation

/// 安全书签（设计文档 §9）：输入文件与输出目录的持久化访问授权。
/// 需要 `com.apple.security.files.bookmarks.app-scope` 权限（见 Chrysalis.entitlements）。
enum BookmarkStore {
    /// 生成安全作用域书签；非用户授权来源的 URL 可能失败，返回 nil。
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    struct Resolved {
        var url: URL
        var isStale: Bool
    }

    /// 解析安全作用域书签；失败（文件移动/授权失效）返回 nil。
    static func resolve(_ data: Data) -> Resolved? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        return Resolved(url: url, isStale: stale)
    }
}
