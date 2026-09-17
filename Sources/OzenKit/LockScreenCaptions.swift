import Foundation

/// One caption line as the lock screen shows it.
public struct LockScreenCaptionLine: Sendable, Equatable, Hashable, Codable {
    /// Set on the first line of a run by one named speaker.
    public var speaker: String?
    public var text: String
    public var isFinal: Bool
    /// When the line last changed.
    public var lastUpdate: TimeInterval

    public init(speaker: String?, text: String, isFinal: Bool, lastUpdate: TimeInterval = 0) {
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.lastUpdate = lastUpdate
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
        textSize: LockScreenTextSize = .regular,
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
            let budget = offset == picked.count - 1 ? textSize.newestLineMaximumCharacters : textSize.earlierLineMaximumCharacters
            // The name shares the line's room ("Speaker 2: ").
            let room = max(minimumCharacters, budget - (speaker.map { $0.count + 2 } ?? 0))
            return LockScreenCaptionLine(
                speaker: speaker,
                text: tail(of: segment.text, maximumCharacters: room),
                isFinal: segment.isCommitted,
                lastUpdate: segment.lastUpdateTimestamp
            )
        }
    }

    /// The end of `text`, at most `maximumCharacters` long, starting at a
    /// word and marked with an ellipsis when something was cut: the newest
    /// words are the ones she needs.
    public static func tail(of text: String, maximumCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters, maximumCharacters > 1 else { return trimmed }
        let cutPoint = trimmed.index(trimmed.endIndex, offsetBy: -(maximumCharacters - 1))
        var kept = String(trimmed[cutPoint...])
        // Whether the cut actually landed inside a word is the one thing
        // that matters, not how long the leading fragment looks: a cut
        // right after a space already starts at a real word, however
        // short, and must not throw it away; a cut mid-word must skip to
        // the next real word however long that takes, or the fragment
        // stays visibly broken.
        let cutMidWord = cutPoint > trimmed.startIndex && !trimmed[trimmed.index(before: cutPoint)].isWhitespace
        if cutMidWord, let space = kept.firstIndex(where: \.isWhitespace) {
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
    /// How long ago the newest line was said, once that is a while
    /// (`LockScreenCaptions.quiet`).
    public var ageNote: String?
    public var textSize: LockScreenTextSize

    public init(lines: [LockScreenCaptionLine], status: String? = nil, ageNote: String? = nil, textSize: LockScreenTextSize = .regular) {
        self.lines = lines
        self.status = status
        self.ageNote = ageNote
        self.textSize = textSize
    }
}

extension LockScreenCaptions {
    /// How the lock screen treats lines when nobody has spoken for a while.
    public enum Quiet: Sendable, Equatable {
        /// Said just now: shown as they are.
        case recent
        /// Said this many minutes ago: the newest line only, saying so.
        case minutesAgo(Int)
        /// Long enough ago that it isn't the conversation any more: no lines.
        case over
    }

    /// From this long after the newest line, it says how long ago it was.
    /// Kept on the lock screen as if just said, a sentence from twenty
    /// minutes ago reads as the latest thing someone said to her.
    public static let ageNoteAfterSeconds: TimeInterval = 60
    /// From this long after the newest line, no lines are shown.
    public static let clearAfterSeconds: TimeInterval = 15 * 60

    public static func quiet(newestLineAt: TimeInterval?, now: TimeInterval) -> Quiet {
        guard let newestLineAt else { return .recent }
        let age = now - newestLineAt
        if age >= clearAfterSeconds { return .over }
        if age >= ageNoteAfterSeconds { return .minutesAgo(Int(age / 60)) }
        return .recent
    }

    /// "said 3 minutes ago", for the lock screen.
    public static func ageNote(minutes: Int) -> String {
        tr("נאמר \(HebrewTime.minutesAgo(minutes))", "said \(HebrewTime.minutesAgo(minutes))")
    }
}

/// Times said the way Hebrew says them.
public enum HebrewTime {
    /// "a minute ago", "two minutes ago" (Hebrew's own dual form), "7 minutes ago".
    public static func minutesAgo(_ minutes: Int) -> String {
        if Localization.language == .english { return englishMinutesAgo(minutes) }
        switch minutes {
        case ...1: return "לפני דקה"
        case 2: return "לפני שתי דקות"
        default: return "לפני \(minutes) דקות"
        }
    }

    private static func englishMinutesAgo(_ minutes: Int) -> String {
        switch minutes {
        case ...1: return "a minute ago"
        default: return "\(minutes) minutes ago"
        }
    }
}

/// How big the lock screen's lines are, and so how much of each fits.
///
/// A Live Activity gets 160 points of height on the lock screen, however
/// large she has the captions in the app. Someone who reads them large
/// gets larger lines there too, and fewer words of the line before.
public enum LockScreenTextSize: String, Sendable, Equatable, Codable {
    /// 21-point lines: about 30 characters a line, three for the newest
    /// line and two for the one before.
    case regular
    /// 27-point lines: about 23 characters a line, three for the newest
    /// line and one for the one before.
    case large

    /// Captions this size or larger in the app make the lock screen large.
    public static let largeFromCaptionSize: Double = 34

    public init(captionSize: Double) {
        self = captionSize >= Self.largeFromCaptionSize ? .large : .regular
    }

    /// Characters kept from the end of the newest line. A line longer than
    /// its lines would lose its end, the newest words, so it is cut from
    /// the front instead.
    public var newestLineMaximumCharacters: Int {
        switch self {
        case .regular: return 80
        case .large: return 60
        }
    }

    /// Characters kept from the end of each earlier line.
    public var earlierLineMaximumCharacters: Int {
        switch self {
        case .regular: return 45
        case .large: return 22
        }
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
            return (true, tr("הכתוביות מושהות בגלל שיחה", "Captions paused for a call"))
        }
        switch phase {
        case .listening:
            return (true, nil)
        case .requestingMicrophonePermission, .preparingEngine, .startingAudio:
            return (true, tr("הכתוביות מתחילות…", "Captions starting…"))
        case .failed:
            return (true, tr("הכתוביות נעצרו. פתחו את אוזן.", "Captions stopped. Open Ozen."))
        case .paused:
            return pausedForSpeech ? (true, tr("הטלפון מדבר", "The phone is talking")) : (false, nil)
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
