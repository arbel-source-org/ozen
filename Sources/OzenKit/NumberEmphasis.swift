import Foundation

/// Where the numbers are in a caption line: the time of the appointment,
/// how many pills, a phone number, a price.
///
/// Missing a word of small talk costs little; missing the "3" in "three
/// times a day" is what she would have to ask about again, and what she
/// most needs to have right afterwards. So numbers stand out on screen:
/// written with digits ("10:30", "050-1234567", "20%") or in words, with
/// Hebrew's attached prefixes ("ובשש", "לשלושה").
public enum NumberEmphasis {
    /// The stretches of `text` that are numbers, in order. Each covers a
    /// whole word (with its prefix), or for digits, from the first digit
    /// to the last, with a percent sign right after.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var previousWord = ""
        var start: String.Index?
        var index = text.startIndex
        while index <= text.endIndex {
            let isBoundary = index == text.endIndex || separates(at: index, in: text)
            if isBoundary {
                if let wordStart = start {
                    let word = text[wordStart..<index]
                    if let range = numberRange(in: word, after: previousWord) {
                        result.append(range)
                    }
                    previousWord = String(letters(of: word).map { text[$0] } ?? "")
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return result
    }

    /// Whitespace always ends a word. A hyphen, maqaf, dash or slash does
    /// too ("שלושה-עשר", "ב-3"), except between two digits, where it is
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

    private static func numberRange(in word: Substring, after previousWord: String) -> Range<String.Index>? {
        if let firstDigit = word.firstIndex(where: \.isNumber), let lastDigit = word.lastIndex(where: \.isNumber) {
            var end = word.index(after: lastDigit)
            if end < word.endIndex, word[end] == "%" {
                end = word.index(after: end)
            }
            return firstDigit..<end
        }
        guard let core = letters(of: word) else { return nil }
        let spelled = String(word[core])
        guard isNumberWord(spelled) else { return nil }
        // "אף אחד" is nobody and "כל אחד" everybody, not a count of one.
        if onesWords.contains(spelled), notACountBefore.contains(previousWord) {
            return nil
        }
        return core
    }

    /// The word without the punctuation, quotes or direction marks around it.
    private static func letters(of word: Substring) -> Range<String.Index>? {
        guard let first = word.firstIndex(where: \.isLetter), let last = word.lastIndex(where: \.isLetter) else { return nil }
        return first..<word.index(after: last)
    }

    private static func isNumberWord(_ word: String) -> Bool {
        if numberWords.contains(word) { return true }
        // Up to two attached prefixes: "ב" + "שש", "ו" + "ב" + "שש".
        var rest = Substring(word)
        for _ in 0..<2 {
            guard let first = rest.first, prefixes.contains(first), rest.count > 2 else { return false }
            rest = rest.dropFirst()
            if numberWords.contains(String(rest)) { return true }
        }
        return false
    }

    static let prefixes: Set<Character> = ["ו", "ב", "ל", "מ", "ה", "ש", "כ"]

    static let onesWords: Set<String> = ["אחד", "אחת"]
    static let notACountBefore: Set<String> = ["אף", "ואף", "באף", "לאף", "כל", "וכל", "לכל", "בכל", "מכל", "בבת"]

    /// Counting words only. "שנים" (years), "שבוע" (a week) and ordinals
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
        "חצי", "רבע", "שליש",
    ]
}
