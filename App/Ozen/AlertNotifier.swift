import Foundation
import UserNotifications
import OzenKit

/// Posts `BackgroundAlertPolicy`'s notifications through the system.
///
/// Isn't tied to the main actor: the notification center is fetched at
/// each use, so nothing main-actor-owned is handed to the framework's own
/// threads. The only state is the last scheduling error, behind a lock.
nonisolated final class AlertNotifier: Sendable {
    static let shared = AlertNotifier()
    private let lastPostError = LockedErrorText()

    /// Why the most recent notification couldn't be scheduled, or nil when
    /// it was. Shown in diagnostics: a doorbell alert that never reached
    /// the lock screen otherwise leaves no trace.
    var lastFailure: String? { lastPostError.value }

    /// Asks once; later calls just report the answer the person gave.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Whether iOS will actually show the app's notifications: false when
    /// they were turned off for Ozen, nil when nobody has been asked yet.
    func isAllowed() async -> Bool? {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return nil
        case .denied: return false
        case .authorized, .provisional, .ephemeral: return true
        @unknown default: return true
        }
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
        UNUserNotificationCenter.current().add(request) { [lastPostError] error in
            lastPostError.set(error.map { String(describing: $0) })
        }
    }
}

nonisolated private final class LockedErrorText: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ text: String?) {
        lock.lock()
        stored = text
        lock.unlock()
    }
}
