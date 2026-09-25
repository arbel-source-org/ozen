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

    @Test("a typed word already on the list is found, ignoring case, niqqud and spaces")
    func listedEntry() {
        let terms = ["Ruti", "אבי"]
        #expect(VocabularyHints.listedEntry(matching: "  ruti ", in: terms) == "Ruti")
        #expect(VocabularyHints.listedEntry(matching: "אָבִי", in: terms) == "אבי")
        #expect(VocabularyHints.listedEntry(matching: "Rotem", in: terms) == nil)
        #expect(VocabularyHints.listedEntry(matching: "   ", in: terms) == nil)
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

@Suite("PromptEchoDetector")
struct PromptEchoDetectorTests {
    private let detector = PromptEchoDetector(terms: ["אבי", "רותי", "דני", "ד״ר כהן", "אקמול"])

    @Test("the prompt read back, whole or as a run of three or more entries, is an echo")
    func echoes() {
        #expect(detector.isEcho("אבי, רותי, דני, ד״ר כהן, אקמול."))
        #expect(detector.isEcho("רותי, דני, ד\"ר כהן"))
        #expect(detector.isEcho("דני ד״ר כהן אקמול"))
    }

    @Test("a single name, or two, is real speech and passes")
    func shortRunsPass() {
        #expect(detector.isEcho("אבי") == false)
        #expect(detector.isEcho("אבי!") == false)
        #expect(detector.isEcho("אבי, רותי") == false)
    }

    @Test("names out of list order, or mixed with other words, are real speech")
    func realSpeech() {
        #expect(detector.isEcho("דני, אבי, רותי") == false)
        #expect(detector.isEcho("אבי רותי ודני באים") == false)
        #expect(detector.isEcho("צריך לקנות אקמול") == false)
    }

    @Test("with a two-name list the whole list counts, but either name alone does not")
    func twoNameList() {
        let small = PromptEchoDetector(terms: ["אבי", "רותי"])
        #expect(small.isEcho("אבי, רותי."))
        #expect(small.isEcho("רותי") == false)
    }

    @Test("a one-name list never flags anything")
    func oneNameList() {
        let single = PromptEchoDetector(terms: ["סבתא"])
        #expect(single.isEcho("סבתא") == false)
        #expect(single.isEcho("סבתא.") == false)
    }

    @Test("naming two people who share a word (a name and a titled form of it) is real speech, not an echo")
    func overlappingEntriesAreNotAnEcho() {
        let small = PromptEchoDetector(terms: ["רותי", "ד״ר רותי"])
        #expect(small.isEcho("רותי, ד״ר רותי") == false)

        let larger = PromptEchoDetector(terms: ["אבי", "רותי", "ד״ר רותי"])
        #expect(larger.isEcho("אבי, רותי, ד״ר רותי") == false)
    }

    @Test("the filter drops an echo segment and keeps the real one next to it")
    func filterIntegration() {
        let filter = WhisperResultFilter()
        let segments = [
            WhisperSegmentSummary(text: " אבי, רותי, דני.", noSpeechProb: 0.2, avgLogprob: -0.3, compressionRatio: 1.2),
            WhisperSegmentSummary(text: " דני, בוא לאכול", noSpeechProb: 0.1, avgLogprob: -0.2, compressionRatio: 1.1),
        ]
        #expect(filter.acceptedText(from: segments, echo: detector) == "דני, בוא לאכול")
        #expect(filter.acceptedText(from: segments) == "אבי, רותי, דני. דני, בוא לאכול")
    }
}
