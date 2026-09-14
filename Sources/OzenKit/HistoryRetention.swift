import Foundation

/// How long saved conversations are kept before they delete themselves.
///
/// Off ("forever") by default: nothing she said is ever thrown away unless
/// someone chose that. Conversations she marked (a starred line) or gave a
/// name are kept whatever this says; those are the ones she meant to keep.
public enum HistoryRetention: String, Sendable, Codable, CaseIterable, Equatable {
    case forever
    case year
    case threeMonths
    case month
    case week

    public var days: Int? {
        switch self {
        case .forever: return nil
        case .year: return 365
        case .threeMonths: return 90
        case .month: return 30
        case .week: return 7
        }
    }

    /// Conversations last active before this moment have expired; nil when
    /// nothing ever does.
    public func cutoff(now: TimeInterval) -> TimeInterval? {
        days.map { now - TimeInterval($0) * 86_400 }
    }

    /// A settings file from a newer build may name a choice this one
    /// doesn't know; keeping everything is the safe reading of that.
    public init(from decoder: any Decoder) throws {
        let raw = try String(from: decoder)
        self = HistoryRetention(rawValue: raw) ?? .forever
    }
}

extension TranscriptSessionSummary {
    /// When the conversation was last going: when it ended, or, for one
    /// the app never got to close (a crash, iOS ending it in the
    /// background), when its newest line began.
    public var lastActiveAt: TimeInterval { endedAt ?? lastLineAt ?? startedAt }

    /// Starred lines or a name mean she wanted this one kept.
    public var isKeptByChoice: Bool { starredCount > 0 || title != nil }
}

extension TranscriptHistoryStore {
    /// Deletes conversations last active before `cutoff`, except ones kept
    /// by choice (see `isKeptByChoice`) and the ones in `protected` (the
    /// conversation still on screen). Returns how many were deleted.
    @discardableResult
    public func deleteConversations(inactiveBefore cutoff: TimeInterval, protecting protected: Set<UUID> = []) -> Int {
        var deleted = 0
        for summary in listSummaries()
        where summary.lastActiveAt < cutoff && !summary.isKeptByChoice && !protected.contains(summary.id) {
            if (try? delete(id: summary.id)) != nil {
                deleted += 1
            }
        }
        return deleted
    }
}
