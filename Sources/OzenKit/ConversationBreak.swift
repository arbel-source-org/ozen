import Foundation

/// When a long quiet stretch means the next words start a new conversation.
///
/// Left running all day, the app would otherwise save breakfast, a phone
/// call with the doctor and dinner as one enormous "conversation", which
/// makes history useless for finding anything. After twenty minutes with
/// no new captions, whatever is said next is saved as a new conversation.
/// The screen is not cleared; only the saved record is split.
public enum ConversationBreak {
    public static let quietSeconds: TimeInterval = 20 * 60

    /// `lastCaptionAt` is when the newest line in the current saved
    /// conversation last changed, or nil when it has no lines yet.
    public static func shouldStartNew(lastCaptionAt: TimeInterval?, now: TimeInterval, quietSeconds: TimeInterval = ConversationBreak.quietSeconds) -> Bool {
        guard let lastCaptionAt else { return false }
        return now - lastCaptionAt >= quietSeconds
    }
}
