import Foundation

/// One caption line as the lock screen shows it.
public struct LockScreenCaptionLine: Sendable, Equatable, Hashable, Codable {
    /// Set on the first line of a run by one named speaker.
    public var speaker: String?
    public var text: String
    public var isFinal: Bool

    public init(speaker: String?, text: String, isFinal: Bool) {
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
    }
}

/// The newest caption lines, cut down to what fits on the lock screen.
///
/// The phone spends most of a conversation on the table or in a hand with
/// the screen locked, and unlocking it to read the last sentence is one
/// step too many while someone is talking. A Live Activity puts the newest
/// lines on the lock screen; this decides which lines and how much of each.
public enum LockScreenCaptions {
    /// Lines shown at once: the lock screen gives a Live Activity room for
    /// about three lines of large text.
    public static let lineCount = 2
    /// Characters kept from the end of a long line.
    public static let maximumCharacters = 140

    /// The newest `lineCount` lines with text. `name` gives the label for a
    /// line's speaker, or nil to show none; a name is kept only where it
    /// changes from the line before.
    public static func lines(
        from segments: [TranscriptSegment],
        name: (TranscriptSegment) -> String?
    ) -> [LockScreenCaptionLine] {
        var picked: [TranscriptSegment] = []
        var index = segments.endIndex
        // One line before the shown ones, to know whether the first shown
        // line starts a new speaker.
        var before: TranscriptSegment?
        while index > segments.startIndex {
            index -= 1
            let segment = segments[index]
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if picked.count == lineCount {
                before = segment
                break
            }
            picked.insert(segment, at: 0)
        }
        var previousName = before.flatMap(name)
        return picked.map { segment in
            let speaker = name(segment)
            defer { previousName = speaker }
            return LockScreenCaptionLine(
                speaker: speaker != previousName ? speaker : nil,
                text: tail(of: segment.text, maximumCharacters: maximumCharacters),
                isFinal: segment.isCommitted
            )
        }
    }

    /// The end of `text`, at most `maximumCharacters` long, starting at a
    /// word and marked with an ellipsis when something was cut: the newest
    /// words are the ones she needs.
    public static func tail(of text: String, maximumCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters, maximumCharacters > 1 else { return trimmed }
        var kept = String(trimmed.suffix(maximumCharacters - 1))
        if let space = kept.firstIndex(where: \.isWhitespace), kept.distance(from: kept.startIndex, to: space) < maximumCharacters / 3 {
            kept = String(kept[kept.index(after: space)...])
        }
        return "…" + kept
    }
}

/// Everything the lock screen shows: the newest lines, and a word on why
/// they stopped coming when they have.
public struct LockScreenCaptionContent: Sendable, Equatable {
    public var lines: [LockScreenCaptionLine]
    /// Set while captions aren't running but will again by themselves or
    /// with a tap ("paused because of a call", "stopped").
    public var status: String?

    public init(lines: [LockScreenCaptionLine], status: String? = nil) {
        self.lines = lines
        self.status = status
    }
}

extension LockScreenCaptions {
    /// What a phase means for the lock screen: whether the Live Activity
    /// stays, and the status it shows. Stopped, or paused on purpose, takes
    /// it away (she did that, looking at the app); a failure, a call, or
    /// captions still starting keep it, saying so, since those can come
    /// back with the phone still in her pocket and iOS won't let the app
    /// start a new one from there.
    public static func presence(
        phase: PipelinePhase,
        interruptedByCall: Bool,
        pausedForSpeech: Bool
    ) -> (keep: Bool, status: String?) {
        if interruptedByCall {
            return (true, "הכתוביות מושהות בגלל שיחה")
        }
        switch phase {
        case .listening:
            return (true, nil)
        case .requestingMicrophonePermission, .preparingEngine, .startingAudio:
            return (true, "הכתוביות מתחילות…")
        case .failed:
            return (true, "הכתוביות נעצרו. פתחו את אוזן.")
        case .paused:
            return pausedForSpeech ? (true, "הטלפון מדבר") : (false, nil)
        case .idle:
            return (false, nil)
        }
    }
}

/// How often the lock screen's lines are sent to the system.
///
/// Captions change several times a second while someone talks, and iOS
/// throttles a Live Activity that updates that often. Changes are sent at
/// most once per `minimumInterval`; one arriving sooner is sent when the
/// interval is up, so the last words of a sentence never stay unsent.
public struct LockScreenUpdateThrottle: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case send
        /// Try again after this many seconds.
        case wait(TimeInterval)
        case nothingNew
    }

    public var minimumInterval: TimeInterval
    private var lastSentAt: TimeInterval?
    private var lastSent: LockScreenCaptionContent?

    public init(minimumInterval: TimeInterval = 1) {
        self.minimumInterval = minimumInterval
    }

    public func decide(_ content: LockScreenCaptionContent, now: TimeInterval) -> Decision {
        guard content != lastSent else { return .nothingNew }
        guard let lastSentAt, now >= lastSentAt else { return .send }
        let elapsed = now - lastSentAt
        return elapsed >= minimumInterval ? .send : .wait(minimumInterval - elapsed)
    }

    public mutating func sent(_ content: LockScreenCaptionContent, at time: TimeInterval) {
        lastSent = content
        lastSentAt = time
    }

    /// The activity ended: whatever comes next is sent straight away.
    public mutating func reset() {
        lastSent = nil
        lastSentAt = nil
    }
}
