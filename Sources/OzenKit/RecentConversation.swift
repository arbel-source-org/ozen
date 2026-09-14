import Foundation

/// The conversation that was going on moments ago.
///
/// iOS ends apps in the background to free memory, and a speech model is
/// one of the biggest things in memory. When that happens mid-conversation
/// she comes back to an empty screen and the last few sentences are gone
/// from view, although they were saved. If the newest saved conversation
/// was still going within the same window that keeps two stretches of
/// talk one conversation (`ConversationBreak`), the empty screen offers it.
public enum RecentConversation {
    /// Clocks move a little (a time zone, a network time fix); a
    /// conversation up to this far "in the future" still counts.
    static let clockSkewSeconds: TimeInterval = 5 * 60

    public static func resumable(
        in summaries: [TranscriptSessionSummary],
        now: TimeInterval,
        excluding current: UUID? = nil,
        within window: TimeInterval = ConversationBreak.quietSeconds
    ) -> TranscriptSessionSummary? {
        summaries
            .filter { summary in
                summary.id != current
                    && summary.segmentCount > 0
                    && summary.lastActiveAt <= now + clockSkewSeconds
                    && now - summary.lastActiveAt < window
            }
            .max { $0.lastActiveAt < $1.lastActiveAt }
    }

    /// Only a conversation saved this recently can qualify, so only those
    /// files need opening (see `TranscriptHistoryStore.summaries(modifiedSince:)`).
    public static func oldestQualifyingSave(now: TimeInterval, within window: TimeInterval = ConversationBreak.quietSeconds) -> TimeInterval {
        now - window - clockSkewSeconds
    }

    /// Whole minutes since the conversation was last going, at least 1.
    public static func minutesAgo(_ summary: TranscriptSessionSummary, now: TimeInterval) -> Int {
        max(1, Int((now - summary.lastActiveAt) / 60))
    }
}
