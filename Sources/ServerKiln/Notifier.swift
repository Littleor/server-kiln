import Foundation
import UserNotifications

enum Notifier {
    /// `UNUserNotificationCenter` crashes when not running from an app bundle
    /// (e.g. `swift run`), so notifications are disabled in that case.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: UUID) {
        guard isAvailable else {
            print("[notify] \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = id.uuidString
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A single replaceable notification, e.g. the update reminder.
    static func post(title: String, body: String, identifier: String) {
        guard isAvailable else {
            print("[notify] \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func remove(identifier: String) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// Only clicks are handled; foreground presentation stays the system default.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationClickHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == MacUpdater.reminderID {
            Task { @MainActor in MacUpdater.shared.checkForUpdates() }
        }
        completionHandler()
    }
}
