import Foundation
import Testing
@testable import OzenKit

@Suite("UncertainWords")
struct UncertainWordsTests {
    private let sure: Float = -0.05
    private let unsure: Float = -2.5

    @Test("the word the model guessed at is picked, the ones it knew are not")
    func picks() {
        let picked = UncertainWords.pick(
            words: [" The", " appointment", " is", " at", " 10:30."],
            logprobs: [[sure], [sure, sure], [sure], [sure], [unsure, unsure, sure]]
        )
        #expect(picked == ["1030"])
    }

    @Test("a word whose first piece alone was a toss-up isn't marked")
    func oneWeakPiece() {
        let picked = UncertainWords.pick(words: [" tomorrow", " morning"], logprobs: [[-1.6, sure, sure], [sure]])
        #expect(picked.isEmpty)
    }

    @Test("when most of the line is doubtful the line's own mark says it, not every word")
    func mostlyDoubtful() {
        let picked = UncertainWords.pick(words: [" a", " b", " c"], logprobs: [[unsure], [unsure], [sure]])
        #expect(picked.isEmpty)
    }

    @Test("punctuation on its own, missing scores and numbers that aren't numbers are passed over")
    func oddInput() {
        #expect(UncertainWords.pick(words: [" -", " word", " other", " third"], logprobs: [[unsure], [], [.nan], [sure]]).isEmpty)
        #expect(UncertainWords.pick(words: [], logprobs: []).isEmpty)
        #expect(UncertainWords.pick(words: [" more", " words"], logprobs: [[sure]]).isEmpty)
    }

    @Test("the marked word is found in the line as shown, punctuation and all, and only as a whole word")
    func ranges() {
        let text = "The appointment is at 10:30, not at 10."
        let ranges = UncertainWords.ranges(in: text, words: ["1030", "appoint"])
        #expect(ranges.map { String(text[$0]) } == ["10:30,"])
        #expect(UncertainWords.ranges(in: text, words: []).isEmpty)
    }

    @Test("a line that reached the screen carries its doubtful words, and a later pass replaces them")
    func throughTheStabilizer() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "at ten", isFinal: false, timestamp: 1, uncertainWords: ["ten"]))
        #expect(stabilizer.segments[0].uncertainWords == ["ten"])
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "at 10:30", isFinal: true, timestamp: 2))
        #expect(stabilizer.segments[0].uncertainWords.isEmpty)
    }
}
