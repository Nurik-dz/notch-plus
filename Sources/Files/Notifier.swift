import Foundation
import UserNotifications

/// A normal macOS notification, for work that took a while and finished while you were elsewhere.
enum Notifier {
    static func post(title: String, body: String) {
        // only a real app bundle may use the notification centre (not the test program)
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
