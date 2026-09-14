import Foundation
import Testing
@testable import OzenKit

@Suite("Numbers standing out in captions")
struct NumberEmphasisTests {
    private func emphasized(_ text: String) -> [String] {
        NumberEmphasis.ranges(in: text).map { String(text[$0]) }
    }

    @Test("times, phone numbers, fractions and percentages written in digits")
    func digits() {
        #expect(emphasized("ניפגש ב-10:30 אצל הרופא") == ["10:30"])
        #expect(emphasized("המספר הוא 050-1234567.") == ["050-1234567"])
        #expect(emphasized("הנחה של 20% על 3/4 מהמחיר") == ["20%", "3/4"])
        #expect(emphasized("בין 10:30-11:00, (בערך)") == ["10:30-11:00"])
    }

    @Test("numbers in words, with Hebrew's attached prefixes and around punctuation")
    func words() {
        #expect(emphasized("לקחת שלושה כדורים, ובשש בערב עוד חצי.") == ["שלושה", "ובשש", "חצי"])
        #expect(emphasized("שלושה-עשר יום") == ["שלושה", "עשר"])
        #expect(emphasized("\u{200F}\"לשניים\"") == ["לשניים"])
    }

    @Test("nobody, everybody and at once are not a count of one; once is")
    func notACount() {
        #expect(emphasized("אף אחד לא בא, כל אחד לבד, הכול בבת אחת") == [])
        #expect(emphasized("רק פעם אחת ביום") == ["אחת"])
    }

    @Test("each other, the other one and the second are not counts; Monday and the two of them are")
    func otherOne() {
        #expect(emphasized("הם עוזרים אחד לשני, אחת את השנייה") == [])
        #expect(emphasized("בצד השני, והשני לא בא") == [])
        #expect(emphasized("ביום שני בשלוש, השניים באו עם שני ילדים") == ["שני", "בשלוש", "השניים", "שני"])
        #expect(emphasized("נתראה בשני, זה מספיק לשני אנשים") == ["בשני", "לשני"])
    }

    @Test("words that only contain a number word, or years and weeks, stay plain")
    func lookalikes() {
        #expect(emphasized("לפני שנים, בעוד שבוע, המונה") == [])
        #expect(emphasized("") == [])
        #expect(emphasized("   ") == [])
    }

    @Test("a prefix counts only in front of a whole number word")
    func shortWords() {
        #expect(emphasized("שש משש") == ["שש", "משש"])
        #expect(emphasized("מש הש") == [])
    }

    @Test("on by default, survives older settings files, and can be turned off")
    func settingDefault() throws {
        #expect(DisplayPreferences.default.emphasizeNumbers)
        let old = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"fontSize":30}"#.utf8))
        #expect(old.emphasizeNumbers)
        var off = DisplayPreferences.default
        off.emphasizeNumbers = false
        let roundTripped = try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(off))
        #expect(roundTripped.emphasizeNumbers == false)
    }
}
