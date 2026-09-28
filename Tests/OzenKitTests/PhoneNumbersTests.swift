import Foundation
import Testing
@testable import OzenKit

struct PhoneNumbersTests {
    private func dialed(_ text: String) -> [String] {
        PhoneNumbers.matches(in: text).map(\.dialable)
    }

    @Test("Israeli mobile and landline numbers, however they are spaced, dial as digits")
    func finds() {
        #expect(dialed("תתקשרי לרופא 050-1234567 מחר") == ["0501234567"])
        #expect(dialed("call 03 123 4567 please") == ["031234567"])
        #expect(dialed("0521234567") == ["0521234567"])
        #expect(dialed("+972 50 123 4567") == ["+972501234567"])
        #expect(dialed("+972-3-1234567") == ["+97231234567"])
        #expect(dialed("050-1234567 או 04-8123456") == ["0501234567", "048123456"])
    }

    @Test("1-700 and 1-800 numbers dial; star numbers stay text, since iOS refuses to dial a link with a star")
    func serviceNumbers() {
        #expect(dialed("המוקד 1-700-50-50-50 פתוח") == ["1700505050"])
        #expect(dialed("1800123456") == ["1800123456"])
        #expect(dialed("1-599-123-456 או 050-1234567") == ["1599123456", "0501234567"])
        for text in ["תתקשרי לקופה *2700", "1700", "בשנת 1800", "1-900-123-456", "*1-700-50-50-50"] {
            #expect(dialed(text).isEmpty, "\(text)")
        }
    }

    @Test("the span covers exactly the number, so only it becomes tappable")
    func range() throws {
        let text = "הטלפון 050-1234567."
        let match = try #require(PhoneNumbers.matches(in: text).first)
        #expect(text[match.range] == "050-1234567")
        #expect(match.url == URL(string: "tel:0501234567"))
    }

    @Test("times, doses, prices, dates, years and long numbers are not phone numbers")
    func ignores() {
        for text in [
            "בשעה 10:30", "3 כדורים פעמיים ביום", "500 מ״ג", "20%", "₪1500",
            "01/02/2026", "2026", "12345678", "1234567890", "05012345678901",
            "0012345678", "050--1234567", "5501234567",
        ] {
            #expect(dialed(text).isEmpty, "\(text)")
        }
    }

    @Test("the number is still found in the line as the caption screen draws it, with its direction marks")
    func displayedLine() {
        let shown = CaptionLayout.displayText("תתקשרי ל-050-1234567.")
        #expect(PhoneNumbers.matches(in: shown).map(\.dialable) == ["0501234567"])
    }
}
