import Foundation

/// What a phone notification for an alert says.
public struct AlertNotificationContent: Sendable, Equatable {
    /// Reusing an identifier replaces the earlier notification, so a
    /// doorbell ringing twice is one banner, not two.
    public let identifier: String
    public let title: String
    public let body: String
    /// Groups sounds and words separately in Notification Center.
    public let threadIdentifier: String
    public let isUrgent: Bool
}

/// Decides when an alert should also become a phone notification.
///
/// On screen, a doorbell or her name buzzes and shows a banner. With the
/// phone in a pocket or the screen locked, captions keep running but none
/// of that is seen. So while the app is not in front, alerts turn into
/// notifications. They stay quiet while the app is in front (the banner
/// already shows), and the same sound or word notifies at most once per
/// cooldown, because a name said five times in a minute is one thing to
/// look at.
public struct BackgroundAlertPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var cooldownSeconds: Double
    private var lastNotified: [String: TimeInterval] = [:]

    public init(isEnabled: Bool = true, cooldownSeconds: Double = 30) {
        self.isEnabled = isEnabled
        self.cooldownSeconds = cooldownSeconds
    }

    public mutating func notification(for alert: SoundAlert, appIsActive: Bool, now: TimeInterval) -> AlertNotificationContent? {
        let key = "sound-\(alert.event.identifier)"
        guard shouldNotify(key: key, appIsActive: appIsActive, now: now) else { return nil }
        let urgent = alert.event.importance == .critical
        return AlertNotificationContent(
            identifier: key,
            title: alert.event.name,
            body: urgent ? "שימו לב! נשמע עכשיו ליד הטלפון." : "נשמע עכשיו ליד הטלפון.",
            threadIdentifier: "sounds",
            isUrgent: urgent
        )
    }

    public mutating func notification(for hit: KeywordHit, lineText: String, appIsActive: Bool, now: TimeInterval) -> AlertNotificationContent? {
        let key = "keyword-\(hit.match.alertID.uuidString)"
        guard shouldNotify(key: key, appIsActive: appIsActive, now: now) else { return nil }
        return AlertNotificationContent(
            identifier: key,
            title: "נאמר: \(hit.match.phrase)",
            body: Self.excerpt(lineText),
            threadIdentifier: "keywords",
            isUrgent: false
        )
    }

    private mutating func shouldNotify(key: String, appIsActive: Bool, now: TimeInterval) -> Bool {
        guard isEnabled, !appIsActive else { return false }
        if let last = lastNotified[key], now - last < cooldownSeconds {
            return false
        }
        lastNotified[key] = now
        return true
    }

    /// What a sound alert looks like on the lock screen, for trying it out
    /// from Settings: Focus modes, notification summaries and a muted app
    /// can each keep the real ones away, and the time to find that out is
    /// not when the doorbell rings.
    public static let testNotification = AlertNotificationContent(
        identifier: "test-alert",
        title: "בדיקה: פעמון דלת",
        body: "כך תיראה התראה מאוזן כשהטלפון בכיס או נעול.",
        threadIdentifier: "sounds",
        isUrgent: false
    )

    /// Notification bodies get cut off by the system anyway; cut at a word
    /// so the reader sees whole words and an ellipsis.
    static func excerpt(_ text: String, limit: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let clipped = trimmed.prefix(limit)
        let atWord = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? clipped
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}
