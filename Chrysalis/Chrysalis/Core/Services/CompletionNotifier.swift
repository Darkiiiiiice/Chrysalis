import Foundation
import UserNotifications

/// 转码完成/失败的系统通知（设计文档 §8.6 设置页「通知」分组；P5）。
/// 仅在用户开启开关时调用；授权首次请求发生在开关打开或首次通知时。
@MainActor
enum CompletionNotifier {
    /// 应用在前台时也以横幅呈现（默认前台不显示系统通知）。
    final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }

    private static let presenter = Presenter()
    private static var isDelegateInstalled = false

    /// 当前是否已获得通知授权。
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// 需要时请求授权；返回是否可用。
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        installDelegateIfNeeded(center)
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// 发送一条完成/失败通知（开关关闭或未授权时静默跳过）。
    static func notify(fileName: String, kind: HistoryEntry.Kind, message: String?) async {
        guard AppSettings.notifyOnCompletion else { return }
        switch kind {
        case .completed, .failed:
            break
        case .cancelled, .interrupted:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "蝉蜕"
        switch kind {
        case .completed:
            content.body = "「\(fileName)」转码完成。"
            content.sound = .default
        case .failed:
            content.body = "「\(fileName)」转码失败：\(message ?? "未知错误")"
        default:
            return
        }

        guard await requestAuthorizationIfNeeded() else { return }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func installDelegateIfNeeded(_ center: UNUserNotificationCenter) {
        guard !isDelegateInstalled else { return }
        isDelegateInstalled = true
        center.delegate = presenter
    }
}
