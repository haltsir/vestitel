import Foundation
import AppKit
import UserNotifications

/// Local notifications. Two cases: a site started bot-challenging the
/// app's feed fetches (open it in a browser), and the app relaunched after
/// a self-update.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    nonisolated private static let openSiteActionID = "OPEN_SITE"
    nonisolated private static let feedBlockedCategoryID = "FEED_BLOCKED"

    /// Register categories and become delegate. Call once at app start —
    /// the delegate must be in place before any notification is acted on.
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(
            identifier: Self.openSiteActionID,
            title: "Open Website",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.feedBlockedCategoryID,
                actions: [open],
                intentIdentifiers: []
            )
        ])
    }

    /// A feed started returning a bot challenge. Authorization is requested
    /// lazily here: the first blocked feed triggers the system permission
    /// prompt, and the pending notification delivers once the user allows.
    func notifyFeedBlocked(feedTitle: String, host: String, siteURL: URL) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(feedTitle) can't be fetched"
            content.body = "\(host) is asking for a browser check before serving its feed. You can open the site and complete it — Vestitel keeps retrying on every refresh."
            content.categoryIdentifier = Self.feedBlockedCategoryID
            content.userInfo = ["url": siteURL.absoluteString]
            // one visible notification per host: repeats replace, not stack
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "feed-blocked-\(host)",
                content: content,
                trigger: nil
            ))
        }
    }

    /// The launch after an update swapped the bundle: one quiet note. No
    /// category, so tapping it does nothing beyond dismissing.
    func notifyUpdated(version: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Vestitel updated"
            content.body = "Version \(version) is now installed."
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "updated",
                content: content,
                trigger: nil
            ))
        }
    }

    // Menu bar apps count as "active", which normally suppresses banners —
    // show them anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard action == Self.openSiteActionID
                || action == UNNotificationDefaultActionIdentifier else { return }
        guard let raw = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: raw) else { return }
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}
