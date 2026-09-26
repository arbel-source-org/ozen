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

    @Test("a price in shekels joins the sign, glued or spaced; a thousands-grouped number stays whole")
    func shekelsAndGrouping() {
        #expect(emphasized("150₪") == ["150₪"])
        #expect(emphasized("מחיר הבדיקה 150 ₪") == ["150 ₪"])
        #expect(emphasized("המחיר הוא 1,234 שקל") == ["1,234 שקל"])
        #expect(emphasized("יש לי 1,234,567 שקל בבנק") == ["1,234,567 שקל"])
    }

    @Test("distinct numbers joined by a bare comma stand out separately, not as one merged number")
    func commaSeparatedDistinctNumbers() {
        #expect(emphasized("קח כדורים 1,2,3 ותנוח") == ["1", "2", "3"])
        #expect(emphasized("050-1234567,03-1234567") == ["050-1234567", "03-1234567"])
    }

    @Test("numbers in words, with Hebrew's attached prefixes and around punctuation")
    func words() {
        #expect(emphasized("לקחת שלושה כדורים, ובשש בערב עוד חצי.") == ["שלושה כדורים", "ובשש", "חצי"])
        #expect(emphasized("שלושה-עשר אנשים") == ["שלושה-עשר"])
        #expect(emphasized("\u{200F}\"לשניים\"") == ["לשניים"])
    }

    @Test("compound teens, tens-and-units, hundreds and time expressions chain into one span")
    func compoundNumbers() {
        #expect(emphasized("לקחת עשרים ושלושה כדורים") == ["עשרים ושלושה כדורים"])
        #expect(emphasized("חמש עשרה דקות") == ["חמש עשרה דקות"])
        #expect(emphasized("ניפגש בעשר וחצי") == ["בעשר וחצי"])
        #expect(emphasized("מאה ועשרים שקל") == ["מאה ועשרים שקל"])
        #expect(emphasized("אלפיים וחמש מאות שקל") == ["אלפיים וחמש מאות שקל"])
        // "ביום שני בשלוש" ("on Monday at three") is two unrelated times, not
        // a compound: a prefix other than "and" never chains.
        #expect(emphasized("ביום שני בשלוש") == ["שני", "בשלוש"])
    }

    @Test("the unit right after an amount stands out with it")
    func units() {
        #expect(emphasized("לקחת 3 כדורים ביום") == ["3 כדורים"])
        #expect(emphasized("חצי כדור בערב, ו-500 מ״ג בבוקר") == ["חצי כדור", "500 מ״ג"])
        #expect(emphasized("שלוש פעמים ביום") == ["שלוש פעמים"])
        // Punctuation after the number ends it; a unit before it isn't one.
        #expect(emphasized("בשעה 10:30, דקות ספורות") == ["10:30"])
        #expect(emphasized("פעם אחת ביום") == ["אחת"])
        #expect(NumberEmphasis.hasListableNumber("חצי כדור בערב"))
        #expect(NumberEmphasis.hasListableNumber("שני ימים") == false)
    }

    @Test("twice, two days, two weeks and the other words that are two by themselves stand out and are listed")
    func dualWords() {
        #expect(emphasized("פעמיים ביום, אחרי האוכל") == ["פעמיים"])
        #expect(emphasized("נתראה בעוד שבועיים, ולפני זה יומיים בלי") == ["שבועיים", "יומיים"])
        #expect(emphasized("תוך שעתיים, לחודשיים ובשנתיים האחרונות") == ["שעתיים", "לחודשיים", "ובשנתיים"])
        #expect(NumberEmphasis.hasListableNumber("כדור פעמיים ביום"))
        #expect(NumberEmphasis.hasListableNumber("ביקורת בעוד שבועיים"))
        #expect(emphasized("בדיקה שבועית וכדור יומי, תשלום חודשי") == [])
    }

    @Test("Latin dosage units, medication terms, temperatures and prices grandma hears from a doctor or a cashier keep their unit")
    func medicalAndCurrencyUnits() {
        #expect(emphasized("לקחת 500 mg בבוקר") == ["500 mg"])
        #expect(emphasized("לקחת 500 MG בבוקר") == ["500 MG"])
        #expect(emphasized("10 ml פעמיים ביום") == ["10 ml", "פעמיים"])
        #expect(emphasized("קח שתי טבליות ושתי קפסולות") == ["שתי טבליות", "ושתי קפסולות"])
        #expect(emphasized("שתי שאיפות מהמשאף") == ["שתי שאיפות"])
        #expect(emphasized("שלוש מנות ביום") == ["שלוש מנות"])
        #expect(emphasized("חום 38 מעלות") == ["38 מעלות"])
        #expect(emphasized("עולה 150 ש״ח") == ["150 ש״ח"])
        #expect(emphasized("זה עולה 20 דולר") == ["20 דולר"])
    }

    @Test("doses and measures written out in full, and three quarters, keep their unit")
    func moreUnits() {
        #expect(emphasized("שלושים מיליגרם בבוקר ועשר יחידות אינסולין") == ["שלושים מיליגרם", "ועשר יחידות"])
        #expect(emphasized("חמישה מיליליטר, שתי כפות ושלושת רבעי כוס") == ["חמישה מיליליטר", "שתי כפות", "ושלושת רבעי כוס"])
        #expect(emphasized("לחכות שלושים שניות") == ["שלושים שניות"])
    }

    @Test("quarters count only after a number, and a unit with the article still joins its amount")
    func quartersAndTheUnit() {
        #expect(emphasized("רבעי הירח משתנים כל שבוע") == [])
        #expect(NumberEmphasis.hasListableNumber("הדוח יוצא בכל רבעי השנה") == false)
        #expect(emphasized("שתיתי כבר שלושת רבעי הכוס") == ["שלושת רבעי הכוס"])
        #expect(emphasized("חצי הכוס, ורבע השעה הראשונה") == ["חצי הכוס", "ורבע השעה"])
        #expect(emphasized("שלושת רבעי, כוס") == ["שלושת רבעי"])
        #expect(emphasized("שלושת, רבעי כוס") == ["שלושת"])
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

    @Test("lines listed under numbers said: digits and real amounts, not the idioms of one and two")
    func listable() {
        #expect(NumberEmphasis.hasListableNumber("ניפגש ב-10:30"))
        #expect(NumberEmphasis.hasListableNumber("לקחת שלושה כדורים"))
        #expect(NumberEmphasis.hasListableNumber("ובערב חצי כדור"))
        #expect(NumberEmphasis.hasListableNumber("רק פעם אחת") == false)
        #expect(NumberEmphasis.hasListableNumber("נתראה ביום שני") == false)
        #expect(NumberEmphasis.hasListableNumber("כל אחד לבד") == false)
        #expect(NumberEmphasis.hasListableNumber("") == false)
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
