import Foundation

/// The lines said while the caption screen wasn't in front of her.
///
/// Captions keep coming with the phone locked or another app open, so
/// picking the phone back up puts her at the newest line with no way to
/// tell where she stopped reading. The screen marks where the lines she
/// missed begin, and offers to jump there.
///
/// Only an absence of `minimumAwaySeconds` or more counts: a glance at a
/// message shouldn't move the mark from a longer absence before it. And a
/// mark needs `minimumLines` lines after it to be worth drawing.
public struct AwayCatchUp: Sendable, Equatable {
    public var minimumAwaySeconds: TimeInterval
    public var minimumLines: Int

    private var leftAt: TimeInterval?
    /// When she was last away long enough to count, from leaving to coming
    /// back.
    public private(set) var away: ClosedRange<TimeInterval>?
    /// She has seen the mark or used the jump, so it needn't be offered.
    public private(set) var isAcknowledged = false

    public init(minimumAwaySeconds: TimeInterval = 15, minimumLines: Int = 2) {
        self.minimumAwaySeconds = minimumAwaySeconds
        self.minimumLines = minimumLines
    }

    /// The screen went away (locked, or another app came to the front).
    public mutating func screenLeft(at time: TimeInterval) {
        if leftAt == nil { leftAt = time }
    }

    /// The screen is in front of her again.
    public mutating func screenReturned(at time: TimeInterval) {
        guard let left = leftAt else { return }
        leftAt = nil
        guard time - left >= minimumAwaySeconds else { return }
        away = left...time
        isAcknowledged = false
    }

    public mutating func acknowledge() {
        isAcknowledged = true
    }

    public mutating func clear() {
        leftAt = nil
        away = nil
        isAcknowledged = false
    }

    /// How many lines began while she was away.
    public func missedLineCount(in segments: [TranscriptSegment]) -> Int {
        guard let away else { return 0 }
        return segments.reduce(0) { $0 + (away.contains($1.startTimestamp) ? 1 : 0) }
    }

    /// Where the mark goes: the first line that began while she was away,
    /// when enough did.
    public func firstMissedIndex(in segments: [TranscriptSegment]) -> Int? {
        guard let away, missedLineCount(in: segments) >= max(minimumLines, 1) else { return nil }
        return segments.firstIndex { away.contains($0.startTimestamp) }
    }

    /// Where the mark is drawn when only the lines from `firstDrawnIndex`
    /// on are on screen (see `CaptionLayout.onScreenLineLimit`): at the
    /// first missed line among them. Nil when every missed line is above
    /// them, since a mark on a later line would say that line was missed.
    public func drawnMarkIndex(in segments: [TranscriptSegment], firstDrawnIndex: Int) -> Int? {
        guard let away, let first = firstMissedIndex(in: segments) else { return nil }
        let index = max(first, firstDrawnIndex)
        guard segments.indices.contains(index), away.contains(segments[index].startTimestamp) else { return nil }
        return index
    }

    /// Whether to offer jumping back to the mark.
    public func offersJump(in segments: [TranscriptSegment]) -> Bool {
        !isAcknowledged && firstMissedIndex(in: segments) != nil
    }
}
