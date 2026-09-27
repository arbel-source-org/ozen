import Testing
@testable import OzenKit

@Suite("Alert suggestions")
struct AlertSuggestionsTests {
    @Test("a suggested word shows its meaning in the app's language beside the Hebrew word it listens for")
    func labels() {
        #expect(AlertSuggestions.label(for: "סבתא", in: .hebrew) == "סבתא")
        #expect(AlertSuggestions.label(for: "סבתא", in: .english) == "Grandma · סבתא")
        #expect(AlertSuggestions.label(for: "אמא", in: .russian) == "Мама · אמא")
        #expect(AlertSuggestions.label(for: "רופא", in: .french) == "Médecin · רופא")
        #expect(AlertSuggestions.label(for: "Dana", in: .english) == "Dana")
        for language in UILanguage.allCases where language != .hebrew {
            for word in AlertSuggestions.words {
                let meaning = AlertSuggestions.meaning(of: word, in: language) ?? ""
                #expect(!meaning.isEmpty && !meaning.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }, "\(language): \(word)")
            }
        }
    }
}
