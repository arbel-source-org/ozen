import Testing
@testable import OzenKit

@Suite("WhisperResultFilter")
struct WhisperResultFilterTests {
    let filter = WhisperResultFilter()

    private func segment(
        _ text: String,
        noSpeech: Float = 0.1,
        logprob: Float = -0.3,
        compression: Float = 1.2
    ) -> WhisperSegmentSummary {
        WhisperSegmentSummary(text: text, noSpeechProb: noSpeech, avgLogprob: logprob, compressionRatio: compression)
    }

    @Test("a confident, ordinary Hebrew sentence passes")
    func ordinarySentencePasses() {
        #expect(filter.accepts(segment("מה שלומך היום")))
        #expect(filter.acceptedText(from: [segment("מה שלומך היום")]) == "מה שלומך היום")
    }

    @Test("known silence hallucinations are dropped regardless of punctuation or brackets")
    func knownHallucinationsDropped() {
        #expect(!filter.accepts(segment("תודה שצפיתם.")))
        #expect(!filter.accepts(segment("[תודה על הצפייה]")))
        #expect(!filter.accepts(segment("  תודה   שצפיתם!  ")))
        #expect(!filter.accepts(segment("Thank you for watching")))
        #expect(!filter.accepts(segment("Subtitles by the Amara.org community")))
        #expect(!filter.accepts(segment("[מוזיקה]")))
    }

    @Test("'תודה' inside a real sentence is not a hallucination")
    func thanksInsideSentenceKept() {
        #expect(filter.accepts(segment("תודה רבה על העזרה עם הקניות")))
    }

    @Test("high no-speech probability only rejects when the model was also unsure of its tokens")
    func noSpeechNeedsLowLogprobToo() {
        #expect(!filter.accepts(segment("משהו", noSpeech: 0.9, logprob: -1.5)))
        #expect(filter.accepts(segment("משהו", noSpeech: 0.9, logprob: -0.2)))
        #expect(filter.accepts(segment("משהו", noSpeech: 0.3, logprob: -1.5)))
    }

    @Test("a repetitive decoding loop is caught by the compression ratio")
    func compressionLoopRejected() {
        #expect(!filter.accepts(segment("תודה תודה תודה תודה תודה תודה", compression: 3.1)))
    }

    @Test("empty and whitespace-only segments never make it through")
    func emptyRejected() {
        #expect(!filter.accepts(segment("")))
        #expect(!filter.accepts(segment("   \n")))
        #expect(filter.acceptedText(from: [segment("  ")]) == "")
    }

    @Test("accepted text joins surviving segments and skips the junk between them")
    func joinsSurvivors() {
        let text = filter.acceptedText(from: [
            segment("בוקר טוב"),
            // Invented on a noisy stretch: the model barely heard it.
            segment("תודה רבה", noSpeech: 0.5, logprob: -0.4),
            segment("איך ישנת", noSpeech: 0.2),
        ])
        #expect(text == "בוקר טוב איך ישנת")
    }

    @Test("Whisper control tokens never reach the screen")
    func specialTokensStripped() {
        #expect(WhisperResultFilter.stripSpecialTokens("<|startoftranscript|><|he|><|transcribe|><|0.00|>שלום<|2.40|>") == "שלום")
        #expect(WhisperResultFilter.stripSpecialTokens("no tokens here") == "no tokens here")
        #expect(WhisperResultFilter.stripSpecialTokens("<|unterminated") == "<|unterminated")
        #expect(filter.acceptedText(from: [segment("<|0.00|> מה נשמע <|1.20|>")]) == "מה נשמע")
        // A segment that is nothing but tokens is empty, hence rejected.
        #expect(!filter.accepts(segment("<|nospeech|><|endoftext|>")))
    }

    @Test("normalization strips punctuation, symbols and case")
    func normalization() {
        #expect(WhisperResultFilter.normalize("  Thank You!!  ") == "thank you")
        #expect(WhisperResultFilter.normalize("♪ תודה ♪") == "תודה")
    }

    @Test("invented credit lines with a name attached are dropped")
    func creditLines() {
        let filter = WhisperResultFilter()
        #expect(filter.isKnownHallucination("כתוביות על ידי ישראל ישראלי"))
        #expect(filter.isKnownHallucination("כתוביות: אבי כהן"))
        #expect(filter.isKnownHallucination("תורגם על ידי: קהילת עמרה"))
        #expect(filter.isKnownHallucination("Subtitles by Jane Doe."))
        #expect(filter.isKnownHallucination("[תרגום: מיכל]"))
    }

    @Test("real speech that merely starts with a credit word passes")
    func creditWordsInRealSpeech() {
        let filter = WhisperResultFilter()
        // Longer than a credit line: somebody is talking.
        #expect(filter.isKnownHallucination("תרגום של הספר הזה לקח לה שלוש שנים שלמות בערך") == false)
        // The word is inside the sentence, not opening it.
        #expect(filter.isKnownHallucination("אני צריכה כתוביות בטלוויזיה") == false)
        // A different word that shares letters.
        #expect(filter.isKnownHallucination("תרגומים חדשים") == false)
        #expect(filter.isKnownHallucination("תרגומים: חדשים") == false)
        // Bare labels are ordinary words without a colon.
        #expect(filter.isKnownHallucination("כתוביות בבקשה") == false)
        #expect(filter.isKnownHallucination("תרגום לאנגלית בבקשה") == false)
        #expect(filter.isKnownHallucination("הפקה של הצגה בבית הספר") == false)
    }

    @Test("a clearly heard 'תודה רבה' is real conversation and is kept")
    func clearThanksKept() {
        #expect(filter.accepts(segment("תודה רבה.", noSpeech: 0.05, logprob: -0.35)))
        #expect(filter.accepts(segment("תודה!", noSpeech: 0.1, logprob: -0.5)))
    }

    @Test("'תודה רבה' that the model barely heard or guessed at is dropped as invented")
    func doubtfulThanksDropped() {
        #expect(!filter.accepts(segment("תודה רבה.", noSpeech: 0.45, logprob: -0.4)))
        #expect(!filter.accepts(segment("[תודה רבה]", noSpeech: 0.1, logprob: -1.0)))
        #expect(!filter.accepts(segment("Thank you.", noSpeech: 0.6, logprob: -0.3)))
    }
}
