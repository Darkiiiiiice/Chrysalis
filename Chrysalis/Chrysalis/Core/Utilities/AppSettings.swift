import Foundation

/// 通用设置（设计文档 §9：轻量键值存 UserDefaults；敏感信息一律不在这里）。
enum AppSettings {
    static let notifyOnCompletionKey = "notify.onCompletion"

    /// 转码完成/失败后发送系统通知（默认开）。
    static var notifyOnCompletion: Bool {
        get { UserDefaults.standard.object(forKey: notifyOnCompletionKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: notifyOnCompletionKey) }
    }
}
