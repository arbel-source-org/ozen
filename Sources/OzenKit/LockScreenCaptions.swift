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
    /// Lines shown at once.
    public static let lineCount = 2
    /// Characters kept from the end of the newest line. The lock screen
    /// gives a Live Activity 160 points of height, about five lines of the
    /// 21-point text at some 30 characters each: three for the newest line
    /// and two for the one before. A line longer than its lines would lose
    /// its end, the newest words, so it is cut from the front here instead.
    public static let newestLineMaximumCharacters = 80
    /// Characters kept from the end of each earlier line.
    public static let earlierLineMaximumCharacters = 45
    /// Never cut a line shorter than this for a long speaker name.
    static let minimumCharacters = 20

    /// The newest `count` lines with text. `name` gives the label for a
    /// line's speaker, or nil to show none. The first line shown always
    /// carries its name, since on the lock screen there is nothing above
    /// it to say who is talking; after that a name is kept only where the
    /// speaker changes.
    public static func lines(
        from segments: [TranscriptSegment],
        count: Int = lineCount,
        name: (TranscriptSegment) -> String?
    ) -> [LockScreenCaptionLine] {
        var picked: [TranscriptSegment] = []
        var index = segments.endIndex
        while index > segments.startIndex, picked.count < count {
            index -= 1
            let segment = segments[index]
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            picked.insert(segment, at: 0)
        }
        var previousName: String?
        return picked.enumerated().map { offset, segment in
            let name = name(segment)
            defer { previousName = name }
            let speaker = offset == 0 || name != previousName ? name : nil
            let budget = offset == picked.count - 1 ? newestLineMaximumCharacters : earlierLineMaximumCharacters
            // The name shares the line's room ("Speaker 2: ").
            let room = max(minimumCharacters, budget - (speaker.map { $0.count + 2 } ?? 0))
            return LockScreenCaptionLine(
                speaker: speaker,
                text: tail(of: segment.text, maximumCharacters: room),
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
/// interval is up, so the last words of a sentence never stay unsent. A
/// changed status ("paused because of a call") goes at once.
public struct LockScreenUpdateThrottle: Sendable, Equatable {
    /// With the app out of sight: the lock screen may be what she reads.
    public static let backgroundInterval: TimeInterval = 1
    /// With the app in front, where the lock screen can't be seen. Every
    /// update has the widget extension draw the lines again, so hours of
    /// captions on screen shouldn't redraw an invisible copy each second;
    /// leaving the app sends the newest lines straight away.
    public static let foregroundInterval: TimeInterval = 15

    public enum Decision: Sendable, Equatable {
        case send
        /// Try again after this many seconds.
        case wait(TimeInterval)
        case nothingNew
    }

    public var minimumInterval: TimeInterval
    private var lastSentAt: TimeInterval?
    private var lastSent: LockScreenCaptionContent?

    public init(minimumInterval: TimeInterval = LockScreenUpdateThrottle.backgroundInterval) {
        self.minimumInterval = minimumInterval
    }

    public func decide(_ content: LockScreenCaptionContent, now: TimeInterval) -> Decision {
        guard content != lastSent else { return .nothingNew }
        guard let lastSentAt, now >= lastSentAt, content.status == lastSent?.status else { return .send }
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
