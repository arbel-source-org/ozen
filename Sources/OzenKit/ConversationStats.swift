import Foundation

/// One person's part in a saved conversation.
public struct SpeakerShare: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// The cluster the name was first seen with, for the speaker's colour.
    public let clusterID: Int?
    public let words: Int
    /// Stretches of consecutive lines by this speaker.
    public let turns: Int
}

/// The longest uninterrupted stretch by one speaker.
public struct LongestTurn: Sendable, Equatable {
    public let speakerName: String
    public let words: Int
}

/// A short, exact summary of a saved conversation: how long, how many
/// words, who said how much. Saved lines carry only their start time, so
/// nothing here pretends to know how long anyone actually spoke; every
/// number is a count or a span between real timestamps.
public struct ConversationStats: Sendable, Equatable {
    public static var unknownSpeakerName: String { tr("דובר לא ידוע", "Unknown speaker") }

    public let totalWords: Int
    public let totalTurns: Int
    public let durationSeconds: Double
    /// Sorted by words, most first; ties by name.
    public let speakers: [SpeakerShare]
    public let longestTurn: LongestTurn?

    public var wordsPerMinute: Double {
        durationSeconds >= 1 ? Double(totalWords) / (durationSeconds / 60) : 0
    }

    public func wordFraction(of speaker: SpeakerShare) -> Double {
        totalWords > 0 ? Double(speaker.words) / Double(totalWords) : 0
    }

    public static func compute(from record: TranscriptSessionRecord) -> ConversationStats {
        compute(segments: record.segments, startedAt: record.startedAt, endedAt: record.endedAt)
    }

    /// Duration is the recorded session span when the session ended
    /// cleanly, otherwise first line to last line.
    public static func compute(
        segments: [SavedSegment],
        startedAt: TimeInterval? = nil,
        endedAt: TimeInterval? = nil
    ) -> ConversationStats {
        var wordsBySpeaker: [String: Int] = [:]
        var turnsBySpeaker: [String: Int] = [:]
        var clusterBySpeaker: [String: Int] = [:]
        var order: [String] = []
        var totalWords = 0
        var totalTurns = 0
        var longest: LongestTurn?

        var currentSpeaker: String?
        var currentTurnWords = 0

        func closeTurn() {
            guard let speaker = currentSpeaker else { return }
            if currentTurnWords > (longest?.words ?? 0) {
                longest = LongestTurn(speakerName: speaker, words: currentTurnWords)
            }
        }

        for segment in segments {
            let name = speakerName(of: segment)
            let words = HebrewText.words(segment.text).count
            if wordsBySpeaker[name] == nil {
                order.append(name)
                wordsBySpeaker[name] = 0
                turnsBySpeaker[name] = 0
            }
            if clusterBySpeaker[name] == nil, let cluster = segment.speakerClusterID {
                clusterBySpeaker[name] = cluster
            }
            wordsBySpeaker[name, default: 0] += words
            totalWords += words

            if name != currentSpeaker {
                closeTurn()
                currentSpeaker = name
                currentTurnWords = 0
                turnsBySpeaker[name, default: 0] += 1
                totalTurns += 1
            }
            currentTurnWords += words
        }
        closeTurn()

        let speakers = order
            .map { name in
                SpeakerShare(
                    name: name,
                    clusterID: clusterBySpeaker[name],
                    words: wordsBySpeaker[name] ?? 0,
                    turns: turnsBySpeaker[name] ?? 0
                )
            }
            .sorted { lhs, rhs in
                lhs.words != rhs.words ? lhs.words > rhs.words : lhs.name < rhs.name
            }

        let duration: Double
        if let startedAt, let endedAt, endedAt > startedAt {
            duration = endedAt - startedAt
        } else if let first = segments.first, let last = segments.last {
            duration = max(0, last.startTimestamp - first.startTimestamp)
        } else {
            duration = 0
        }

        return ConversationStats(
            totalWords: totalWords,
            totalTurns: totalTurns,
            durationSeconds: duration,
            speakers: speakers,
            longestTurn: longest
        )
    }

    private static func speakerName(of segment: SavedSegment) -> String {
        // A line saved while the app was in another language keeps that
        // language's "Unknown speaker", which is still nobody in particular.
        guard let name = segment.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !TranscriptSessionSummary.isUnknownSpeakerLabel(name)
        else {
            return unknownSpeakerName
        }
        return name
    }

    // MARK: - Wording

    /// "12 dakot · 3 dovrim · 840 milim" ("12 minutes · 3 speakers ·
    /// 840 words"), with Hebrew's special forms for one and two.
    public var hebrewSummary: String {
        var parts = [Self.minutesText(durationSeconds)]
        if !speakers.isEmpty {
            parts.append(Self.speakersText(speakers.count))
        }
        parts.append(Self.wordsText(totalWords))
        return parts.joined(separator: " · ")
    }

    /// How long, in words: "12 dakot", and from an hour on the way people
    /// say it, "sha'a va-reva" ("an hour and a quarter"), "sha'atayim
    /// va-chetzi" ("two and a half hours"). Every other language keeps a
    /// plain "1 hour 15 minutes" style instead of Hebrew's quarter/half
    /// phrasing.
    public static func minutesText(_ seconds: Double) -> String {
        switch Localization.language {
        case .english: return englishMinutesText(seconds)
        case .hebrew: break
        default: return genericMinutesText(seconds, in: Localization.language)
        }
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case ..<1: return "פחות מדקה"
        case 1: return "דקה אחת"
        case 2: return "שתי דקות"
        case ..<60: return "\(minutes) דקות"
        default: break
        }
        let hours = minutes / 60
        let hoursText: String
        switch hours {
        case 1: hoursText = "שעה"
        case 2: hoursText = "שעתיים"
        default: hoursText = "\(hours) שעות"
        }
        switch minutes % 60 {
        case 0: return hoursText
        case 1: return "\(hoursText) ודקה"
        case 2: return "\(hoursText) ושתי דקות"
        case 15: return "\(hoursText) ורבע"
        case 30: return "\(hoursText) וחצי"
        case 45: return "\(hoursText) ושלושה רבעים"
        case let rest: return "\(hoursText) ו-\(rest) דקות"
        }
    }

    private static func englishMinutesText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let rest = minutes % 60
        let hoursText = "\(hours) hour\(hours == 1 ? "" : "s")"
        return rest == 0 ? hoursText : "\(hoursText) \(rest) minute\(rest == 1 ? "" : "s")"
    }

    public static func speakersText(_ count: Int) -> String {
        switch Localization.language {
        case .english: return englishSpeakersText(count)
        case .hebrew: break
        default: return genericSpeakersText(count, in: Localization.language)
        }
        switch count {
        case 1: return "דובר אחד"
        case 2: return "שני דוברים"
        default: return "\(count) דוברים"
        }
    }

    private static func englishSpeakersText(_ count: Int) -> String {
        count == 1 ? "1 speaker" : "\(count) speakers"
    }

    /// "one line", "two lines" and "7 lines", with `adjective` after the
    /// noun as Hebrew puts it ("starred"), in its singular and plural.
    /// `englishAdjective`, when given, sits before the noun instead
    /// ("3 starred lines"), as English puts it. Every other language
    /// carries its own agreement for "starred" and "new"; an adjective
    /// this file doesn't know falls back to the English wording rather
    /// than guessing at it.
    public static func linesText(
        _ count: Int,
        adjective: (singular: String, plural: String)? = nil,
        englishAdjective: String? = nil
    ) -> String {
        switch Localization.language {
        case .english: return englishLinesText(count, adjective: englishAdjective)
        case .hebrew: break
        default: return genericLinesText(count, englishAdjective: englishAdjective, in: Localization.language)
        }
        let singular = adjective.map { " " + $0.singular } ?? ""
        let plural = adjective.map { " " + $0.plural } ?? ""
        switch count {
        case 1: return "שורה\(singular) אחת"
        case 2: return "שתי שורות\(plural)"
        default: return "\(count) שורות\(plural)"
        }
    }

    private static func englishLinesText(_ count: Int, adjective: String?) -> String {
        let prefix = adjective.map { $0 + " " } ?? ""
        return count == 1 ? "1 \(prefix)line" : "\(count) \(prefix)lines"
    }

    public static func wordsText(_ count: Int) -> String {
        switch Localization.language {
        case .english: return englishWordsText(count)
        case .hebrew: break
        default: return genericWordsText(count, in: Localization.language)
        }
        switch count {
        case 0: return "אין מילים"
        case 1: return "מילה אחת"
        case 2: return "שתי מילים"
        default: return "\(count) מילים"
        }
    }

    /// "About 21 minutes left" for a download (3 to 59 minutes). Russian
    /// "около" and Ukrainian "близько" take the genitive, singular after
    /// 21, 31, 41, 51; Arabic counts 3 to 10 in the plural. The table has
    /// one wording per language, so only the noun is changed here.
    public static func aboutMinutesLeftText(_ minutes: Int) -> String {
        let text = tr("עוד כ-%1 דקות", "About %1 minutes left", args: ["\(minutes)"])
        let endsInOne = minutes % 10 == 1 && minutes % 100 != 11
        switch Localization.language {
        case .russian where endsInOne: return text.replacingOccurrences(of: " минут", with: " минуты")
        case .ukrainian where endsInOne: return text.replacingOccurrences(of: " хвилин", with: " хвилини")
        case .arabic where (3...10).contains(minutes): return text.replacingOccurrences(of: "دقيقة", with: "دقائق")
        default: return text
        }
    }

    /// "12 old conversations will be deleted now" (3 or more). The table
    /// has one wording per language, the form for 5 and up in Russian and
    /// Ukrainian and for 3 to 10 in Arabic; the phrase is changed here for
    /// the numbers that take another (the same forms as the table's own
    /// "1" and "2" lines).
    public static func oldConversationsDeletedText(_ count: Int) -> String {
        let text = tr("%1 שיחות ישנות יימחקו עכשיו", "%1 old conversations will be deleted now", args: ["\(count)"])
        let language = Localization.language
        switch (language, pluralCategory(for: count, in: language)) {
        case (.russian, .one): return text.replacingOccurrences(of: "старых разговоров будут удалены", with: "старый разговор будет удалён")
        case (.russian, .few): return text.replacingOccurrences(of: "старых разговоров", with: "старых разговора")
        case (.ukrainian, .one): return text.replacingOccurrences(of: "старих розмов", with: "стару розмову")
        case (.ukrainian, .few): return text.replacingOccurrences(of: "старих розмов", with: "старі розмови")
        case (.arabic, .many), (.arabic, .other): return text.replacingOccurrences(of: "محادثات قديمة", with: "محادثة قديمة")
        default: return text
        }
    }

    /// "one second", "two seconds", "7 seconds", as VoiceOver reads a
    /// voice sample's recording progress.
    public static func secondsText(_ count: Int) -> String {
        switch Localization.language {
        case .english: return count == 1 ? "1 second" : "\(count) seconds"
        case .hebrew: break
        default:
            let language = Localization.language
            let category = pluralCategory(for: count, in: language)
            return countedPhrase(count, word: TimeUnitWord.second(category, in: language), omitNumeral: omitsNumeral(category, in: language))
        }
        switch count {
        case 1: return "שנייה אחת"
        case 2: return "שתי שניות"
        default: return "\(count) שניות"
        }
    }

    public static func paceText(_ wordsPerMinute: Double) -> String {
        tr("%1 לדקה", "%1 per minute", args: ["\(wordsText(Int(wordsPerMinute.rounded())))"])
    }

    private static func englishWordsText(_ count: Int) -> String {
        switch count {
        case 0: return "no words"
        case 1: return "1 word"
        default: return "\(count) words"
        }
    }

    // MARK: - The other ten languages

    private enum TimeUnit { case minute, hour }

    private static func genericMinutesText(_ seconds: Double, in language: UILanguage) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return TimeUnitWord.lessThanAMinute(in: language) }
        if minutes < 60 { return countedTime(minutes, unit: .minute, in: language) }
        let hours = minutes / 60
        let rest = minutes % 60
        let hoursPhrase = countedTime(hours, unit: .hour, in: language)
        return rest == 0 ? hoursPhrase : "\(hoursPhrase) \(countedTime(rest, unit: .minute, in: language))"
    }

    private static func countedTime(_ n: Int, unit: TimeUnit, in language: UILanguage) -> String {
        let category = pluralCategory(for: n, in: language)
        let word = unit == .minute ? TimeUnitWord.minute(category, in: language) : TimeUnitWord.hour(category, in: language)
        return countedPhrase(n, word: word, omitNumeral: omitsNumeral(category, in: language))
    }

    private static func genericSpeakersText(_ count: Int, in language: UILanguage) -> String {
        let category = pluralCategory(for: count, in: language)
        return countedPhrase(count, word: speakerWord(category, in: language), omitNumeral: omitsNumeral(category, in: language))
    }

    private static func speakerWord(_ category: PluralCategory, in language: UILanguage) -> String {
        switch language {
        case .russian:
            switch category {
            case .one: return "собеседник"
            case .few: return "собеседника"
            default: return "собеседников"
            }
        case .ukrainian:
            switch category {
            case .one: return "співрозмовник"
            case .few: return "співрозмовники"
            default: return "співрозмовників"
            }
        case .arabic:
            switch category {
            case .one: return "متحدث"
            case .two: return "متحدثان"
            case .few: return "متحدثين"
            default: return "متحدث"
            }
        case .french: return category == .one ? "intervenant" : "intervenants"
        case .spanish: return category == .one ? "interlocutor" : "interlocutores"
        case .german: return "Sprecher"
        case .portuguese: return category == .one ? "interlocutor" : "interlocutores"
        case .hindi: return "वक्ता"
        case .amharic: return category == .one ? "ተናጋሪ" : "ተናጋሪዎች"
        case .chineseSimplified: return "位发言人"
        case .hebrew, .english: return category == .one ? "speaker" : "speakers"
        }
    }

    private static func genericWordsText(_ count: Int, in language: UILanguage) -> String {
        if count == 0 { return noWordsPhrase(in: language) }
        let category = pluralCategory(for: count, in: language)
        return countedPhrase(count, word: wordWord(category, in: language), omitNumeral: omitsNumeral(category, in: language))
    }

    private static func noWordsPhrase(in language: UILanguage) -> String {
        switch language {
        case .russian: return "нет слов"
        case .ukrainian: return "немає слів"
        case .arabic: return "لا كلمات"
        case .french: return "aucun mot"
        case .spanish: return "sin palabras"
        case .german: return "keine Wörter"
        case .portuguese: return "sem palavras"
        case .hindi: return "कोई शब्द नहीं"
        case .amharic: return "ምንም ቃላት የሉም"
        case .chineseSimplified: return "没有字"
        case .hebrew, .english: return "no words"
        }
    }

    private static func wordWord(_ category: PluralCategory, in language: UILanguage) -> String {
        switch language {
        case .russian:
            switch category {
            case .one: return "слово"
            case .few: return "слова"
            default: return "слов"
            }
        case .ukrainian:
            switch category {
            case .one: return "слово"
            case .few: return "слова"
            default: return "слів"
            }
        case .arabic:
            switch category {
            case .one: return "كلمة"
            case .two: return "كلمتان"
            case .few: return "كلمات"
            default: return "كلمة"
            }
        case .french: return category == .one ? "mot" : "mots"
        case .spanish: return category == .one ? "palabra" : "palabras"
        case .german: return category == .one ? "Wort" : "Wörter"
        case .portuguese: return category == .one ? "palavra" : "palavras"
        case .hindi: return "शब्द"
        case .amharic: return category == .one ? "ቃል" : "ቃላት"
        case .chineseSimplified: return "字"
        case .hebrew, .english: return category == .one ? "word" : "words"
        }
    }

    private static func genericLinesText(_ count: Int, englishAdjective: String?, in language: UILanguage) -> String {
        let category = pluralCategory(for: count, in: language)
        guard let englishAdjective else {
            return countedPhrase(count, word: lineWord(category, in: language), omitNumeral: omitsNumeral(category, in: language))
        }
        guard let phrase = adjectiveLinePhrase(count, category: category, adjective: englishAdjective, in: language) else {
            return englishLinesText(count, adjective: englishAdjective)
        }
        return phrase
    }

    private static func lineWord(_ category: PluralCategory, in language: UILanguage) -> String {
        switch language {
        case .russian:
            switch category {
            case .one: return "строка"
            case .few: return "строки"
            default: return "строк"
            }
        case .ukrainian:
            switch category {
            case .one: return "рядок"
            case .few: return "рядки"
            default: return "рядків"
            }
        case .arabic:
            switch category {
            case .one: return "سطر"
            case .two: return "سطران"
            case .few: return "أسطر"
            default: return "سطر"
            }
        case .french: return category == .one ? "ligne" : "lignes"
        case .spanish: return category == .one ? "línea" : "líneas"
        case .german: return category == .one ? "Zeile" : "Zeilen"
        case .portuguese: return category == .one ? "linha" : "linhas"
        case .hindi: return category == .one ? "पंक्ति" : "पंक्तियाँ"
        case .amharic: return category == .one ? "መስመር" : "መስመሮች"
        case .chineseSimplified: return "行"
        case .hebrew, .english: return category == .one ? "line" : "lines"
        }
    }

    /// `nil` when `adjective` isn't one this file has agreement forms
    /// for, so the caller can fall back to English rather than Hebrew.
    private static func adjectiveLinePhrase(
        _ count: Int,
        category: PluralCategory,
        adjective: String,
        in language: UILanguage
    ) -> String? {
        let noun = lineWord(category, in: language)
        let omit = omitsNumeral(category, in: language)
        switch (language, adjective) {
        case (.russian, "new"):
            let form = category == .one ? "новая" : category == .few ? "новые" : "новых"
            return countedPhrase(count, word: "\(form) \(noun)", omitNumeral: omit)
        case (.russian, "starred"):
            let form = category == .one ? "избранная" : category == .few ? "избранные" : "избранных"
            return countedPhrase(count, word: "\(form) \(noun)", omitNumeral: omit)
        case (.ukrainian, "new"):
            let form = category == .one ? "новий" : category == .few ? "нові" : "нових"
            return countedPhrase(count, word: "\(form) \(noun)", omitNumeral: omit)
        case (.ukrainian, "starred"):
            let form = category == .one ? "позначений" : category == .few ? "позначені" : "позначених"
            return countedPhrase(count, word: "\(form) \(noun)", omitNumeral: omit)
        case (.arabic, "new"):
            let form = category == .one ? "جديد" : category == .two ? "جديدان" : category == .few ? "جديدة" : "جديد"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.arabic, "starred"):
            let form = category == .one ? "مفضل" : category == .two ? "مفضلان" : category == .few ? "مفضلة" : "مفضل"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.french, "new"):
            let form = category == .one ? "nouvelle" : "nouvelles"
            return countedPhrase(count, word: "\(form) \(noun)", omitNumeral: omit)
        case (.french, "starred"):
            let form = category == .one ? "favorite" : "favorites"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.spanish, "new"):
            let form = category == .one ? "nueva" : "nuevas"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.spanish, "starred"):
            let form = category == .one ? "destacada" : "destacadas"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.german, "new"):
            return countedPhrase(count, word: "neue \(noun)", omitNumeral: omit)
        case (.german, "starred"):
            return countedPhrase(count, word: "markierte \(noun)", omitNumeral: omit)
        case (.portuguese, "new"):
            let form = category == .one ? "nova" : "novas"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.portuguese, "starred"):
            let form = category == .one ? "marcada" : "marcadas"
            return countedPhrase(count, word: "\(noun) \(form)", omitNumeral: omit)
        case (.hindi, "new"):
            return countedPhrase(count, word: "नई \(noun)", omitNumeral: omit)
        case (.hindi, "starred"):
            return countedPhrase(count, word: "चिह्नित \(noun)", omitNumeral: omit)
        case (.amharic, "new"):
            return countedPhrase(count, word: "አዲስ \(noun)", omitNumeral: omit)
        case (.amharic, "starred"):
            return countedPhrase(count, word: "ኮከብ የተሰጠው \(noun)", omitNumeral: omit)
        case (.chineseSimplified, "new"):
            return countedPhrase(count, word: "新\(noun)", omitNumeral: omit)
        case (.chineseSimplified, "starred"):
            return countedPhrase(count, word: "星标\(noun)", omitNumeral: omit)
        default:
            return nil
        }
    }
}
