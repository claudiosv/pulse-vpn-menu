import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for the connection-state
/// notifications gated by `AppSettings.notifyOnUnexpectedDisconnect` /
/// `notifyOnTransientDrops`. Every entry point is a no-op when running
/// outside an app bundle (a bare `swift run`), where
/// `UNUserNotificationCenter.current()` traps.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// One fixed request identifier per kind, so a repeat replaces the
    /// previous banner in Notification Center instead of stacking.
    enum Kind: String {
        case lost = "vpn.lost"
        case dropped = "vpn.dropped"
        case restored = "vpn.restored"
    }

    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func install() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ kind: Kind, title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Show the banner even while the main window is frontmost — by
    /// default macOS suppresses notifications from the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
