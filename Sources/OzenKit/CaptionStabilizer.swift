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
    public var silenceCommitThreshold: TimeInterval

    public init(silenceCommitThreshold: TimeInterval = 1.2) {
        self.silenceCommitThreshold = silenceCommitThreshold
    }

    @discardableResult
    public mutating func ingest(_ token: TranscriptToken) -> TranscriptSegment {
        if let index = segments.firstIndex(where: { $0.id == token.utteranceID }) {
            // An engine can send an empty update (Apple's recognizer does
            // when a request ends on silence). Text the reader has already
            // seen must never vanish because of it.
            if !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments[index].text = token.text
            }
            segments[index].lastUpdateTimestamp = token.timestamp
            if let clusterID = token.speakerClusterID {
                segments[index].speakerClusterID = clusterID
            }
            if token.isFinal {
                segments[index].isCommitted = true
            }
            return segments[index]
        }

        let segment = TranscriptSegment(
            id: token.utteranceID,
            text: token.text,
            isCommitted: token.isFinal,
            speakerClusterID: token.speakerClusterID,
            startTimestamp: token.timestamp,
            lastUpdateTimestamp: token.timestamp
        )
        segments.append(segment)
        return segment
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
                justCommitted.append(segments[index])
            }
        }
        return justCommitted
    }
}
