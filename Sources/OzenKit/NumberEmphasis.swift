import Foundation

/// Where the numbers are in a caption line: the time of the appointment,
/// how many pills, a phone number, a price.
///
/// Missing a word of small talk costs little; missing the "3" in "three
/// times a day" is what she would have to ask about again, and what she
/// most needs to have right afterwards. So numbers stand out on screen:
/// written with digits ("10:30", "050-1234567", "20%") or in words, with
/// Hebrew's attached prefixes ("u-veshesh" — "and at six", "lishlosha" —
/// "to three").
public enum NumberEmphasis {
    /// The stretches of `text` that are numbers, in order. Each covers a
    /// whole word (with its prefix), or for digits, from the first digit
    /// to the last, with a percent sign right after; and the unit that
    /// follows, when one does ("3 kadurim" — "3 pills", "chatzi kadur" —
    /// "half a pill", "500 mg"), since the amount alone doesn't say what of.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        let words = self.words(in: text)
        var result: [Range<String.Index>] = []
        var skipUnitAt: Int?
        for (position, word) in words.enumerated() {
            guard position != skipUnitAt else { continue }
            guard let found = numberRange(of: word, at: position, in: words) else { continue }
            // "3 kadurim" ("3 pills"): the unit joins the number, unless
            // punctuation ends the number's word first ("be-sha'a 10:30,
            // kadurim" — "at 10:30, pills").
            if found.upperBound == word.text.endIndex, position + 1 < words.count,
               let unit = words[position + 1].coreRange, let unitWord = words[position + 1].core,
               units.contains(unitWord) {
                result.append(found.lowerBound..<unit.upperBound)
                skipUnitAt = position + 1
            } else {
                result.append(found)
            }
        }
        return result
    }

    private static func numberRange(of word: Word, at position: Int, in words: [Word]) -> Range<String.Index>? {
        if let firstDigit = word.text.firstIndex(where: \.isNumber), let lastDigit = word.text.lastIndex(where: \.isNumber) {
            var end = word.text.index(after: lastDigit)
            if end < word.text.endIndex, word.text[end] == "%" {
                end = word.text.index(after: end)
            }
            return firstDigit..<end
        }
        guard let coreRange = word.coreRange, let core = word.core, let reading = numberReading(of: core) else { return nil }
        let previous = position > 0 ? words[position - 1].core : nil
        let following = words[(position + 1)...].prefix(3).compactMap(\.core)
        if onesWords.contains(reading.number) {
            // "af echad" ("nobody") and "kol echad" ("everybody"), and "echad
            // et ha-sheni" ("each other", lit. "one to the other"): none of
            // them a count of one.
            if let previous, notACountBefore.contains(previous) { return nil }
            if following.contains(where: otherOneWords.contains) { return nil }
        }
        if twoWords.contains(reading.number) {
            // "ha-sheni" ("the other one" / "the second") is never a count of
            // two.
            if reading.prefixes.contains("ה") { return nil }
            // "lishnei" after "echad" is "to each other"; alone it's "to two"
            // or "on Monday".
            let earlier = words[max(0, position - 3)..<position].compactMap(\.core)
            if otherOneWords.contains(core), earlier.contains(where: onesWords.contains) { return nil }
        }
        return coreRange
    }

    /// Whether a line is worth listing under "numbers said" in a saved
    /// conversation: it has digits, or a counting word beyond one and two.
    /// Those two are mostly idioms ("pa'am achat" — "once", "be-yom sheni" —
    /// "on Monday"); a list of every line with them in it would be most of
    /// the conversation.
    public static func hasListableNumber(_ text: String) -> Bool {
        ranges(in: text).contains { range in
            let found = text[range]
            if found.contains(where: \.isNumber) { return true }
            // The number is the first word; a unit may follow it.
            guard let reading = numberReading(of: String(found.prefix(while: { !$0.isWhitespace }))) else { return false }
            return !onesWords.contains(reading.number) && !twoWords.contains(reading.number)
        }
    }

    private struct Word {
        let text: Substring
        /// The letters, without punctuation, quotes or direction marks.
        let coreRange: Range<String.Index>?
        let core: String?
    }

    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while true {
            let atEnd = index == text.endIndex
            if atEnd || separates(at: index, in: text) {
                if let wordStart = start {
                    let slice = text[wordStart..<index]
                    let first = slice.firstIndex(where: \.isLetter)
                    let last = slice.lastIndex(where: \.isLetter)
                    let core = first.flatMap { first in last.map { first..<slice.index(after: $0) } }
                    words.append(Word(text: slice, coreRange: core, core: core.map { String(slice[$0]) }))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            guard !atEnd else { break }
            index = text.index(after: index)
        }
        return words
    }

    /// Whitespace always ends a word. A hyphen, maqaf, dash or slash does
    /// too ("shlosha-asar" — "thirteen", "be-3" — "in 3"), except between two
    /// digits, where it is
    /// part of the number ("050-1234567", "3/4", "10:30-11:00").
    private static func separates(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if character.isWhitespace { return true }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              HebrewText.wordJoiners.contains(scalar)
        else { return false }
        guard index > text.startIndex else { return true }
        let after = text.index(after: index)
        guard after < text.endIndex else { return true }
        return !(text[text.index(before: index)].isNumber && text[after].isNumber)
    }

    /// The number word inside `word` and the prefixes attached in front
    /// of it (at most two: vav + bet + "shesh" — "and" + "at" + "six"), or nil
    /// when it isn't one.
    private static func numberReading(of word: String) -> (number: String, prefixes: String)? {
        if numberWords.contains(word) { return (word, "") }
        var rest = Substring(word)
        for _ in 0..<2 {
            guard let first = rest.first, prefixes.contains(first), rest.count > 2 else { return nil }
            rest = rest.dropFirst()
            if numberWords.contains(String(rest)) {
                return (String(rest), String(word.dropLast(rest.count)))
            }
        }
        return nil
    }

    static let prefixes: Set<Character> = ["ו", "ב", "ל", "מ", "ה", "ש", "כ"]

    /// What an amount is usually of, said right after it.
    static let units: Set<String> = [
        "כדור", "כדורים", "טיפה", "טיפות", "כפית", "כפיות", "זריקה", "זריקות",
        "כף", "כפות", "כוס", "כוסות", "יחידה", "יחידות",
        "מ״ג", "מ\"ג", "מג", "מיליגרם", "מ״ל", "מ\"ל", "מל", "מיליליטר", "ליטר", "סמ״ק", "סמ\"ק",
        "גרם", "קילו", "ק״ג", "מטר", "קילומטר",
        "שקל", "שקלים", "אחוז", "אחוזים",
        "שניות", "דקה", "דקות", "שעה", "שעות", "יום", "ימים", "שבוע", "שבועות", "חודש", "חודשים", "שנה", "שנים",
        "פעם", "פעמים",
    ]

    static let onesWords: Set<String> = ["אחד", "אחת"]
    static let twoWords: Set<String> = ["שני", "שתי"]
    static let notACountBefore: Set<String> = ["אף", "ואף", "באף", "לאף", "כל", "וכל", "לכל", "בכל", "מכל", "בבת"]
    /// The second half of "each other": "echad le-sheni", "achat me-hashniya".
    static let otherOneWords: Set<String> = [
        "השני", "לשני", "מהשני", "בשני", "והשני",
        "השנייה", "לשנייה", "מהשנייה", "בשנייה",
        "השניה", "לשניה", "מהשניה", "בשניה",
    ]

    /// Counting words only. "shanim" (years), "shavua" (a week) and ordinals
    /// stay out, and so does anything that is mostly used as another word.
    static let numberWords: Set<String> = [
        "אפס",
        "אחד", "אחת",
        "שניים", "שתיים", "שתים", "שני", "שתי",
        "שלוש", "שלושה", "שלושת",
        "ארבע", "ארבעה", "ארבעת",
        "חמש", "חמישה", "חמשת",
        "שש", "שישה", "ששה", "ששת",
        "שבע", "שבעה", "שבעת",
        "שמונה", "שמונת",
        "תשע", "תשעה", "תשעת",
        "עשר", "עשרה", "עשרת",
        "עשרים", "שלושים", "ארבעים", "חמישים", "שישים", "שבעים", "שמונים", "תשעים",
        "מאה", "מאתיים", "מאות",
        "אלף", "אלפיים", "אלפים",
        "מיליון",
        "חצי", "רבע", "רבעי", "שליש", "שלישים",
        // Two by themselves, and never anything else: "twice", "two days",
        // "two weeks". The times a pill is taken and the wait for the next
        // appointment are said this way.
        "פעמיים", "שעתיים", "יומיים", "שבועיים", "חודשיים", "שנתיים",
    ]
}
