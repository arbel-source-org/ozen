import Testing
@testable import OzenKit

@Suite("VocabularyHints")
struct VocabularyTests {
    @Test("normalizing trims, drops blanks and duplicates, and keeps first-seen order")
    func normalize() {
        let cleaned = VocabularyHints.normalized(["  רותי ", "", "אבי", "רותי", "אָבִי", "   ", "Dani", "dani"])
        #expect(cleaned == ["רותי", "אבי", "Dani"])
    }

    @Test("an over-long entry is clipped and the list is capped")
    func caps() {
        let long = String(repeating: "א", count: 100)
        let cleaned = VocabularyHints.normalized([long])
        #expect(cleaned == [String(repeating: "א", count: VocabularyHints.maximumTermLength)])

        let many = (0..<300).map { "שם\($0)" }
        #expect(VocabularyHints.normalized(many).count == VocabularyHints.maximumTerms)
    }

    @Test("the Whisper prompt is a comma list ending in a period, or empty when there is nothing to say")
    func prompt() {
        #expect(VocabularyHints.whisperPrompt([]) == "")
        #expect(VocabularyHints.whisperPrompt(["", "  "]) == "")
        #expect(VocabularyHints.whisperPrompt(["אבי", "רותי "]) == "אבי, רותי.")
    }

    @Test("AppSettings cleans the vocabulary on construction so callers cannot store junk")
    func settingsNormalize() {
        var settings = AppSettings.default
        settings.vocabulary = ["x"]
        let built = AppSettings(engine: .whisperKit, languageCode: "he", preferredInputUID: nil, speakerProfiles: [], creditLine: "", vocabulary: [" a ", "a"])
        #expect(built.vocabulary == ["a"])
        #expect(settings.vocabulary == ["x"])
    }
}
