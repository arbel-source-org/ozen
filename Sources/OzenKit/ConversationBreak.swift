import Foundation

public enum ConversationBreak {
    public static let quietSeconds: TimeInterval = 20 * 60

    public static func shouldStartNew(lastCaptionAt: TimeInterval?, now: TimeInterval, quietSeconds: TimeInterval = ConversationBreak.quietSeconds) -> Bool {
        guard let lastCaptionAt else { return false }
        return now - lastCaptionAt >= quietSeconds
    }

    public static func start(listeningSince: TimeInterval?, firstLineAt: TimeInterval?, quietSeconds: TimeInterval = ConversationBreak.quietSeconds) -> TimeInterval? {
        guard let listeningSince else { return firstLineAt }
        guard let firstLineAt, firstLineAt - listeningSince >= quietSeconds else { return listeningSince }
        return firstLineAt
    }
}
