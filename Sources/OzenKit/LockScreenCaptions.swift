import Foundation

/// One caption line as the lock screen shows it.
public struct LockScreenCaptionLine: Sendable, Equatable, Hashable, Codable {
    /// Set on the first line of a run by one named speaker.
    public var speaker: String?
    public var text: String
    public var isFinal: Bool
    /// When the line last changed.
    public var lastUpdate: TimeInterval
    /// A line without a name that continues its speaker's run, as opposed
    /// to one nobody was recognised on: a line drawn alone takes the name
    /// above it only then.
    public var sameSpeakerAsAbove: Bool

    public init(speaker: String?, text: String, isFinal: Bool, lastUpdate: TimeInterval = 0, sameSpeakerAsAbove: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.lastUpdate = lastUpdate
        self.sameSpeakerAsAbove = sameSpeakerAsAbove
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

    /// The newest `count` lines with text, none from before a quiet
    /// stretch (`CaptionLayout.quietGapSeconds`). `name` gives the label for a
    /// line's speaker, or nil to show none. The first line shown always
    /// carries its name, since on the lock screen there is nothing above
    /// it to say who is talking; after that a name is kept only where the
    /// speaker changes. An earlier line short enough to leave its own
    /// budget unused hands the rest to the newest line, which grows past
    /// `textSize`'s usual maximum.
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
            // The caption screen puts a clock time between lines a quiet
            // stretch apart; with no room for one here, the older line
            // would read as the one just before the words just said.
            if let later = picked.first, CaptionLayout.startsAfterQuiet(later, previous: segment) { break }
            picked.insert(segment, at: 0)
        }
        let names = picked.map(name)
        let sameSpeakerAsAbove = names.indices.map { $0 > 0 && names[$0] != nil && names[$0] == names[$0 - 1] }
        let speakers: [String?] = names.indices.map { sameSpeakerAsAbove[$0] ? nil : names[$0] }
        // An earlier line that fits comfortably under its own budget leaves
        // room nobody reads; the newest line, where the words she needs are,
        // gets it added to its own instead of leaving blank space above a
        // short one.
        var bonus = 0
        for offset in picked.indices where offset != picked.count - 1 {
            let room = lineRoom(budget: textSize.earlierLineMaximumCharacters, speaker: speakers[offset])
            let used = picked[offset].text.trimmingCharacters(in: .whitespacesAndNewlines).count
            bonus += max(0, room - used)
        }
        return picked.enumerated().map { offset, segment in
            let speaker = speakers[offset]
            let isNewest = offset == picked.count - 1
            let budget = (isNewest ? textSize.newestLineMaximumCharacters + bonus : textSize.earlierLineMaximumCharacters)
            var room = lineRoom(budget: budget, speaker: speaker)
            if isNewest {
                // The name counts even when hidden under the same speaker's
                // line: the widget puts it back when it shows this line alone.
                room = min(room, lineRoom(budget: textSize.newestLineCapacity, speaker: names[offset]))
            }
            return LockScreenCaptionLine(
                speaker: speaker,
                // The widget draws this on its own line, the same as any
                // other caption text (`CaptionLayout.directed`): without
                // the mark, a line ending in a Latin brand or medication
                // name reorders under the system's bidi algorithm instead
                // of reading right to left.
                text: CaptionLayout.directed(tail(of: segment.text, maximumCharacters: room)),
                isFinal: segment.isCommitted,
                lastUpdate: segment.lastUpdateTimestamp,
                sameSpeakerAsAbove: sameSpeakerAsAbove[offset]
            )
        }
    }

    /// A line's character budget once its speaker's name ("Speaker 2: ")
    /// has taken its share of the room.
    private static func lineRoom(budget: Int, speaker: String?) -> Int {
        max(minimumCharacters, budget - (speaker.map { $0.count + 2 } ?? 0))
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
    /// The app's language when this was made: the lock screen's own words
    /// ("Listening…") follow it, so a switch counts as something new to send.
    public var language: UILanguage

    public init(lines: [LockScreenCaptionLine], status: String? = nil, ageNote: String? = nil, textSize: LockScreenTextSize = .regular, language: UILanguage = Localization.language) {
        self.lines = lines
        self.status = status
        self.ageNote = ageNote
        self.textSize = textSize
        self.language = language
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
        tr("נאמר %1", "said %1", args: ["\(HebrewTime.minutesAgo(minutes))"])
    }
}

/// Times said the way Hebrew says them.
extension LockScreenCaptions {
    /// Sent when iOS took the captions off the lock screen while the app
    /// was away; opening the app puts them back.
    public static var endedNotice: AlertNotificationContent {
        AlertNotificationContent(
            identifier: "ozen.lockscreen.ended",
            title: tr("הכתוביות ירדו ממסך הנעילה", "Captions left the lock screen"),
            body: tr("הכתוביות ממשיכות באפליקציה. פתחו את אוזן כדי להחזיר אותן למסך הנעילה.", "Captions carry on in the app. Open Ozen to bring them back to the lock screen."),
            threadIdentifier: "status",
            isUrgent: false
        )
    }
}

public enum HebrewTime {
    /// "a minute ago", "two minutes ago" (Hebrew's own dual form), "7 minutes ago";
    /// from an hour on, whole hours ("two hours ago", not "130 minutes ago").
    public static func minutesAgo(_ minutes: Int) -> String {
        switch Localization.language {
        case .english: return englishMinutesAgo(minutes)
        case .hebrew: break
        default: return genericMinutesAgo(minutes, in: Localization.language)
        }
        switch minutes {
        case ...1: return "לפני דקה"
        case 2: return "לפני שתי דקות"
        case 3..<60: return "לפני \(minutes) דקות"
        case 60..<120: return "לפני שעה"
        case 120..<180: return "לפני שעתיים"
        default: return "לפני \(minutes / 60) שעות"
        }
    }

    private static func englishMinutesAgo(_ minutes: Int) -> String {
        switch minutes {
        case ...1: return "a minute ago"
        case 2..<60: return "\(minutes) minutes ago"
        case 60..<120: return "an hour ago"
        default: return "\(minutes / 60) hours ago"
        }
    }

    private enum TimeUnit { case minute, hour }

    private static func genericMinutesAgo(_ minutes: Int, in language: UILanguage) -> String {
        switch minutes {
        case ...1: return agoPhrase(1, unit: .minute, in: language)
        case 2..<60: return agoPhrase(minutes, unit: .minute, in: language)
        case 60..<120: return agoPhrase(1, unit: .hour, in: language)
        case 120..<180: return agoPhrase(2, unit: .hour, in: language)
        default: return agoPhrase(minutes / 60, unit: .hour, in: language)
        }
    }

    /// Arabic's dual takes a different ending after "قبل" ("ago") than it
    /// does standing alone, and so do the Russian and Ukrainian feminine
    /// singulars after "назад"/"тому" ("1 минуту назад", "1 годину тому"),
    /// so those are looked up separately here instead of through
    /// `TimeUnitWord`.
    private static func agoPhrase(_ count: Int, unit: TimeUnit, in language: UILanguage) -> String {
        let category = pluralCategory(for: count, in: language)
        let word: String
        if language == .arabic, category == .two {
            word = unit == .minute ? "دقيقتين" : "ساعتين"
        } else if language == .russian, category == .one, unit == .minute {
            word = "минуту"
        } else if language == .ukrainian, category == .one {
            word = unit == .minute ? "хвилину" : "годину"
        } else {
            word = unit == .minute ? TimeUnitWord.minute(category, in: language) : TimeUnitWord.hour(category, in: language)
        }
        let counted = countedPhrase(count, word: word, omitNumeral: omitsNumeral(category, in: language))
        switch language {
        case .russian: return "\(counted) назад"
        case .ukrainian: return "\(counted) тому"
        case .arabic: return "قبل \(counted)"
        case .french: return "il y a \(counted)"
        case .spanish: return "hace \(counted)"
        case .german: return "vor \(counted)"
        case .portuguese: return "há \(counted)"
        case .chineseSimplified: return "\(counted)前"
        case .hindi: return "\(counted) पहले"
        case .amharic: return "ከ\(count) \(word) በፊት"
        case .hebrew, .english: return counted
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

    /// What the widget's newest line holds at full size: three rows of
    /// about 30 (or 23) characters. The room a short line above leaves can
    /// not become a fourth row, so the newest line is kept to this: longer,
    /// the widget cut it, and the name at its head went first (the words
    /// read as the line above's) or, cut on its last row, words from the
    /// middle vanished.
    public var newestLineCapacity: Int {
        switch self {
        case .regular: return 90
        case .large: return 69
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
    /// start a new one from there. A failure the app is already bringing
    /// back (a retry lined up, the phone's model taking over) says they are
    /// starting: "open Ozen" would send her to the app for nothing.
    public static func presence(
        phase: PipelinePhase,
        interruptedByCall: Bool,
        pausedForSpeech: Bool,
        recoveringByItself: Bool = false
    ) -> (keep: Bool, status: String?) {
        // Captions she paused or stopped herself are not the call's doing.
        if interruptedByCall, phase != .idle, phase != .paused || pausedForSpeech {
            return (true, tr("הכתוביות מושהות בגלל שיחה", "Captions paused for a call"))
        }
        switch phase {
        case .listening:
            return (true, nil)
        case .requestingMicrophonePermission, .preparingEngine, .startingAudio:
            return (true, tr("הכתוביות מתחילות…", "Captions starting…"))
        case .failed where recoveringByItself:
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
        guard let lastSentAt, now >= lastSentAt, content.status == lastSent?.status, content.language == lastSent?.language else { return .send }
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
