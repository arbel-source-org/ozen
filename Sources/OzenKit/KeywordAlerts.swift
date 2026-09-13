import Foundation

/// One word or phrase the reader has asked to be alerted about — her own
/// name, a grandchild's name, "אמבולנס", "תרופה", "אוכל". Kept as plain
/// data (no matching logic here) so it can be stored in `AppSettings`-style
/// JSON and edited from a simple list screen.
public struct KeywordAlert: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var phrase: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), phrase: String, isEnabled: Bool = true) {
        self.id = id
        self.phrase = phrase
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, phrase, isEnabled
    }

    /// Tolerant like `AppSettings`: an alert saved before the enable/
    /// disable toggle existed has no `isEnabled` key at all, and that must
    /// not be treated as "off" — it should behave exactly like a freshly
    /// created alert, which defaults to on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        phrase = try container.decode(String.self, forKey: .phrase)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// One place a keyword was found in a caption: which alert fired, the
/// alert's own phrase (for display, e.g. "your alert for 'סבתא'"), the
/// text as it actually appeared in the caption (which may carry an
/// attached prefix, e.g. "לסבתא"), and the index of its first word within
/// the caption's word list, used by `KeywordAlertDeduplicator` to tell a
/// repeated partial update from a genuinely new occurrence.
public struct KeywordMatch: Sendable, Equatable {
    public var alertID: UUID
    public var phrase: String
    public var matchedText: String
    public var wordIndex: Int

    public init(alertID: UUID, phrase: String, matchedText: String, wordIndex: Int) {
        self.alertID = alertID
        self.phrase = phrase
        self.matchedText = matchedText
        self.wordIndex = wordIndex
    }
}

/// Hebrew-aware text normalization shared by the keyword matcher. Kept as
/// a namespace (no stored state) since every function here is a pure
/// transformation of a `String`.
public enum HebrewText {
    /// Hebrew niqqud (vowel points) and cantillation marks occupy this
    /// Unicode block (U+0591...U+05C7). Whisper and Apple's on-device
    /// recognizer never emit them, but a keyword phrase typed or pasted by
    /// the user might carry them, so both sides of a comparison are
    /// stripped down to consonants before anything else happens.
    public static func stripNiqqud(_ text: String) -> String {
        let withoutNiqqud = text.unicodeScalars.filter { scalar in
            !(0x0591...0x05C7).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(withoutNiqqud))
    }

    /// The canonical form every keyword comparison is done in: niqqud
    /// gone, punctuation and symbols gone, case folded, whitespace
    /// collapsed to single spaces. Mirrors `WhisperResultFilter.normalize`
    /// with the added niqqud pass Hebrew needs.
    public static func normalize(_ text: String) -> String {
        let withoutNiqqud = stripNiqqud(text)
        let stripped = withoutNiqqud.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// `normalize`, split into individual words. Used for a phrase, where
    /// only the resulting word list matters — not each word's position in
    /// the original phrase text.
    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Hebrew attaches single-letter prepositions and conjunctions
    /// directly to the following word with no space — ו ("and"), ה
    /// ("the"), ב ("in/with"), ל ("to"), מ ("from"), ש ("that"), כ ("as")
    /// — and these stack, e.g. "וכש" ("and when"). This list is a
    /// heuristic tuned for the prefixes that show up before names and
    /// everyday nouns in speech, not a morphological analyzer: it will
    /// miss rarer stackings and, in principle, could strip a letter that
    /// happens to start the word itself, but that trade-off is the right
    /// one for an alert that must not stay silent just because a caption
    /// said "לסבתא" instead of "סבתא".
    public static let attachedPrefixes: Set<String> = [
        "ו", "ה", "ב", "ל", "מ", "ש", "כ",
        "וה", "וב", "ול", "ומ", "וש", "וכ",
        "שה", "שב", "של", "שמ",
        "כש", "בה", "לה", "מה",
        "וכש", "ולכ", "ושה",
    ]

    /// True if `word` is `stem` on its own, or `stem` with one of the
    /// attached prefixes glued to the front. Deliberately does not touch
    /// the end of the word, so a *suffix* change ("סבתאות") is correctly
    /// left unmatched.
    public static func stripAttachedPrefix(from word: String, leaving stem: String) -> Bool {
        if word == stem { return true }
        for prefix in attachedPrefixes where word == prefix + stem {
            return true
        }
        return false
    }
}

/// Finds every place a caption mentions a keyword the reader cares about.
/// Multi-word phrases must match consecutively, whole caption words only
/// (so "דן" never matches "דנה"), and the attached-prefix rule applies
/// only to a phrase's first word — a caption is far more likely to attach
/// a prefix to the word right after a preposition than in the middle of a
/// fixed phrase.
public struct KeywordAlertMatcher: Sendable, Equatable {
    public var alerts: [KeywordAlert]

    public init(alerts: [KeywordAlert]) {
        self.alerts = alerts
    }

    public func matches(in text: String) -> [KeywordMatch] {
        let rawWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rawWords.isEmpty else { return [] }
        // Normalizing word-by-word (rather than normalizing the whole
        // string and re-splitting) keeps this array the same length as
        // `rawWords`, so a word's index always means the same thing on
        // both sides even when a word is pure punctuation and normalizes
        // to the empty string.
        let normalizedWords = rawWords.map(HebrewText.normalize)
        let trimmedWords = rawWords.map(Self.trimmingEdgePunctuation)

        var unordered: [(match: KeywordMatch, sequence: Int)] = []
        var sequence = 0
        for alert in alerts where alert.isEnabled {
            let phraseWords = HebrewText.words(alert.phrase)
            guard !phraseWords.isEmpty, phraseWords.count <= normalizedWords.count else { continue }

            let lastPossibleStart = normalizedWords.count - phraseWords.count
            for start in 0...lastPossibleStart {
                guard HebrewText.stripAttachedPrefix(from: normalizedWords[start], leaving: phraseWords[0]) else {
                    continue
                }
                var isFullMatch = true
                for offset in 1..<phraseWords.count where normalizedWords[start + offset] != phraseWords[offset] {
                    isFullMatch = false
                    break
                }
                guard isFullMatch else { continue }

                let matchedText = trimmedWords[start...(start + phraseWords.count - 1)].joined(separator: " ")
                let match = KeywordMatch(alertID: alert.id, phrase: alert.phrase, matchedText: matchedText, wordIndex: start)
                unordered.append((match, sequence))
                sequence += 1
            }
        }

        // Matches are found alert-by-alert above, but callers want them in
        // caption order regardless of which alert fired; `sequence` breaks
        // ties deterministically for two alerts that match at the same
        // word (rather than relying on `sorted` being a stable sort).
        return unordered
            .sorted { $0.match.wordIndex != $1.match.wordIndex ? $0.match.wordIndex < $1.match.wordIndex : $0.sequence < $1.sequence }
            .map(\.match)
    }

    /// Strips only leading and trailing punctuation/symbol characters,
    /// leaving case and niqqud untouched, so `matchedText` reads as the
    /// word actually looked in the caption ("סבתא" out of "\"סבתא\"" or
    /// "סבתא,") rather than the fully normalized comparison form.
    private static func trimmingEdgePunctuation(_ word: String) -> String {
        var scalars = Array(word.unicodeScalars)
        func isEdgeCharacter(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
        }
        while let first = scalars.first, isEdgeCharacter(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, isEdgeCharacter(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Suppresses repeat alerts on the same match as a caption's partial
/// updates keep arriving for one utterance ("היום" → "היום סבתא" → "היום
/// סבתא אכלה"): without this, buzzing/highlighting would fire again on
/// every single token the engine emits for the same utterance instead of
/// once when the keyword first appears.
public struct KeywordAlertDeduplicator: Sendable {
    private struct MatchKey: Hashable, Sendable {
        let alertID: UUID
        let wordIndex: Int
    }

    /// How many utterances' worth of "already reported" state to keep.
    /// A live-captioning session can run for hours, and nothing ever tells
    /// this type an utterance is done with for good (an engine's "final"
    /// marker can be missed, see `CaptionStabilizer`) — without a cap this
    /// dictionary would grow for the whole conversation. Bounding it to
    /// recent utterances only re-fires an alert for one that scrolled far
    /// out of view, which is a cosmetic edge case, not a correctness one.
    public static let maxTrackedUtterances = 64

    private var reportedByUtterance: [UUID: Set<MatchKey>] = [:]
    /// Oldest-first order of tracked utterance ids, used only to know
    /// which one to evict once the cap is hit.
    private var trackingOrder: [UUID] = []

    public init() {}

    @discardableResult
    public mutating func newMatches(utteranceID: UUID, matches: [KeywordMatch]) -> [KeywordMatch] {
        var alreadyReported = reportedByUtterance[utteranceID] ?? []
        let isNewUtterance = reportedByUtterance[utteranceID] == nil

        var fresh: [KeywordMatch] = []
        for match in matches {
            let key = MatchKey(alertID: match.alertID, wordIndex: match.wordIndex)
            if !alreadyReported.contains(key) {
                alreadyReported.insert(key)
                fresh.append(match)
            }
        }
        reportedByUtterance[utteranceID] = alreadyReported

        if isNewUtterance {
            trackingOrder.append(utteranceID)
            if trackingOrder.count > Self.maxTrackedUtterances {
                let oldest = trackingOrder.removeFirst()
                reportedByUtterance.removeValue(forKey: oldest)
            }
        }
        return fresh
    }

    public mutating func forget(utteranceID: UUID) {
        reportedByUtterance.removeValue(forKey: utteranceID)
        trackingOrder.removeAll { $0 == utteranceID }
    }

    public mutating func forgetAll() {
        reportedByUtterance.removeAll()
        trackingOrder.removeAll()
    }
}
