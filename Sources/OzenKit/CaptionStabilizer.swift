import Foundation

/// One utterance's worth of caption text, as displayed. `isCommitted`
/// distinguishes text that's locked in from text that may still change:
/// this is the whole answer to "won't words get cut off?" — a pending
/// segment is shown (nothing is hidden or truncated), it's just visually
/// marked as still-settling until it commits, at which point it stops
/// changing for good.
public struct TranscriptSegment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var isCommitted: Bool
    public var speakerClusterID: Int?
    public var startTimestamp: TimeInterval
    public var lastUpdateTimestamp: TimeInterval
    /// The engine's latest confidence in this line, 0...1, when it gave one.
    public var confidence: Float? = nil
    /// Committed only as a guess that the engine went quiet for good (see
    /// `commitStale`), not because the engine itself said this line was
    /// done: it can still reopen and change. A listener that only rechecks
    /// the newest few lines (`CaptionAnnouncer`) needs this to know a line
    /// can't yet be treated as permanently settled, however far back it's
    /// scrolled.
    public var isProvisionalCommit: Bool = false
    /// The words in `text` the engine was least sure of (see
    /// `UncertainWords`): at the doctor's it matters whether the doubt is
    /// about "10:30" or about "thank you".
    public var uncertainWords: [String] = []
}

/// When a caption line should say "this may not be what was said".
///
/// Someone who can't hear the room can't tell a misheard sentence from a
/// strange one. A small mark on the lines the engine itself was unsure
/// about tells her when it's worth asking again.
public enum CaptionConfidence {
    /// Whisper's confidence is the exponent of its average log-probability,
    /// so 0.4 is an average log-probability of about -0.9: the range where
    /// its output is often wrong. Apple's recognizer reports on the same
    /// 0...1 scale.
    public static let uncertainBelow: Float = 0.4

    public static func isUncertain(_ segment: TranscriptSegment) -> Bool {
        isUncertain(confidence: segment.confidence, isCommitted: segment.isCommitted)
    }

    /// Only finished lines: a line still being written changes its mind.
    /// Exactly 0 means "no score" (Apple reports that on partial results).
    public static func isUncertain(confidence: Float?, isCommitted: Bool) -> Bool {
        guard isCommitted, let confidence, confidence > 0 else { return false }
        return confidence < uncertainBelow
    }
}

/// Turns a raw stream of `TranscriptToken` updates into a stable timeline of
/// `TranscriptSegment`s. Pure logic, no audio or UI — this is deliberately
/// the most heavily unit-tested piece of Ozen, since it's the direct answer
/// to the concrete worry that live captions might visibly mangle words.
public struct CaptionStabilizer: Sendable {
    public private(set) var segments: [TranscriptSegment] = []

    /// If a segment hasn't been updated in this long without the engine
    /// ever marking it final, commit it anyway. Without this, a dropped or
    /// missing "final" marker would leave a segment pending forever,
    /// frozen in the "still settling" style even though nothing further
    /// will ever arrive for it.
    ///
    /// This is a safety net, not the normal path: both engines send a
    /// final for every utterance. It must therefore be longer than an
    /// engine can legitimately go quiet on a line that is still open.
    /// Whisper finalizes after a 1 s pause *plus* a careful decode, and a
    /// hot phone spaces live updates up to 4 s apart (`InferenceCadence`).
    /// The old 1.2 s value raced the final pass on every sentence: the
    /// line turned solid and was then rewritten, exactly the visible
    /// mangling this type exists to prevent.
    public var silenceCommitThreshold: TimeInterval

    public static let defaultSilenceCommitThreshold: TimeInterval = 6

    /// Lines committed by the safety net rather than by the engine. That
    /// commit is a guess that nothing more is coming; if the engine turns
    /// out to be merely slow, its next update proves the guess wrong.
    private var provisionalCommits: Set<UUID> = []
    /// For each line still being written, which of its words to hold
    /// steady between passes; see `LiveAgreement`.
    private var liveAgreements: [UUID: LiveAgreement] = [:]

    public init(silenceCommitThreshold: TimeInterval = CaptionStabilizer.defaultSilenceCommitThreshold) {
        self.silenceCommitThreshold = silenceCommitThreshold
    }

    /// The text to show for `token`: a final pass as it is, a live one with
    /// the words earlier passes agreed on held in place.
    private mutating func settled(_ token: TranscriptToken) -> String {
        guard !token.isFinal else {
            liveAgreements[token.utteranceID] = nil
            return token.text
        }
        // Lines are written one at a time; anything else left here is a
        // line whose final never came.
        if liveAgreements.count > 4 {
            liveAgreements = liveAgreements.filter { $0.key == token.utteranceID }
        }
        return liveAgreements[token.utteranceID, default: LiveAgreement()].settle(token.text)
    }

    @discardableResult
    public mutating func ingest(_ token: TranscriptToken) -> TranscriptSegment {
        // From the end: the line being written is almost always the last
        // one, and a phone left listening for days holds thousands.
        if let index = segments.lastIndex(where: { $0.id == token.utteranceID }) {
            if segments[index].isCommitted {
                if provisionalCommits.remove(token.utteranceID) != nil {
                    // Committed only because the engine went quiet, and it
                    // wasn't done: show the line as still settling again
                    // rather than changing words that looked final.
                    // isProvisionalCommit is left as-is: if this same
                    // update also finalizes the line below, that only
                    // clears once the finality is real, not another guess.
                    segments[index].isCommitted = false
                } else {
                    // Final is final. Both engines start a new utterance
                    // after a final, so anything more for this one is a
                    // straggler, and the words she already read stay put.
                    // Who said it can still be learned afterwards.
                    if let clusterID = token.speakerClusterID {
                        segments[index].speakerClusterID = clusterID
                    }
                    return segments[index]
                }
            }
            // An engine can send an empty update (Apple's recognizer does
            // when a request ends on silence). Text the reader has already
            // seen must never vanish because of it.
            if !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments[index].text = settled(token)
            }
            segments[index].lastUpdateTimestamp = token.timestamp
            if let confidence = token.confidence {
                segments[index].confidence = confidence
            }
            // Each update describes its own text: the doubts of the pass
            // before don't carry over to words that may have changed.
            segments[index].uncertainWords = token.uncertainWords
            if let clusterID = token.speakerClusterID {
                segments[index].speakerClusterID = clusterID
            }
            if token.isFinal {
                segments[index].isCommitted = true
                segments[index].isProvisionalCommit = false
            }
            return segments[index]
        }

        let segment = TranscriptSegment(
            id: token.utteranceID,
            text: settled(token),
            isCommitted: token.isFinal,
            speakerClusterID: token.speakerClusterID,
            startTimestamp: token.timestamp,
            lastUpdateTimestamp: token.timestamp,
            confidence: token.confidence,
            uncertainWords: token.uncertainWords
        )
        segments.append(segment)
        return segment
    }

    /// Marks an already-known segment as finished without changing its
    /// text — for a final update whose words were suppressed elsewhere
    /// (see `SilencePhraseGuard`) but whose finality still needs to reach
    /// the reader, instead of leaving the line "still settling" until
    /// `commitStale`'s safety net eventually catches up. Nil (nothing to
    /// react to) if there's no such segment, or it's already committed.
    @discardableResult
    public mutating func commit(id: UUID) -> TranscriptSegment? {
        guard let index = segments.lastIndex(where: { $0.id == id }), !segments[index].isCommitted else { return nil }
        segments[index].isCommitted = true
        segments[index].isProvisionalCommit = false
        return segments[index]
    }

    /// Call periodically (e.g. once per incoming audio chunk) with the
    /// current stream time. Returns whichever segments just became
    /// committed as a result, so a caller can react (stop animating them)
    /// without re-scanning the whole transcript.
    @discardableResult
    public mutating func commitStale(now: TimeInterval) -> [TranscriptSegment] {
        var justCommitted: [TranscriptSegment] = []
        for index in segments.indices where !segments[index].isCommitted {
            if now - segments[index].lastUpdateTimestamp >= silenceCommitThreshold {
                segments[index].isCommitted = true
                segments[index].isProvisionalCommit = true
                provisionalCommits.insert(segments[index].id)
                justCommitted.append(segments[index])
            }
        }
        return justCommitted
    }

    /// Finalizes every line still being written, for when the engine that
    /// was writing them has gone (pause, stop, a failure). Nothing will
    /// ever finish them otherwise: a new engine starts new lines.
    @discardableResult
    public mutating func commitAll() -> [TranscriptSegment] {
        var justCommitted: [TranscriptSegment] = []
        for index in segments.indices where !segments[index].isCommitted {
            segments[index].isCommitted = true
            justCommitted.append(segments[index])
        }
        // The engine that could have continued them is gone.
        provisionalCommits = []
        return justCommitted
    }
}
