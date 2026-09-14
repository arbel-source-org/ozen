import Foundation
import UserNotifications
import OzenKit

/// Posts `BackgroundAlertPolicy`'s notifications through the system.
///
/// Holds no state and isn't tied to the main actor: the notification
/// center is fetched at each use, so nothing main-actor-owned is handed to
/// the framework's own threads.
nonisolated final class AlertNotifier: Sendable {
    static let shared = AlertNotifier()

    /// Asks once; later calls just report the answer the person gave.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(_ content: AlertNotificationContent) {
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.threadIdentifier = content.threadIdentifier
        body.sound = .default
        // Time-sensitive delivery needs an entitlement a free signing
        // account doesn't get; urgent alerts use the loudest level that
        // works without it.
        body.interruptionLevel = .active
        body.relevanceScore = content.isUrgent ? 1 : 0.5
        let request = UNNotificationRequest(identifier: content.identifier, content: body, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
