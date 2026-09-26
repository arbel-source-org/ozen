import Foundation
import Testing
@testable import OzenKit

@Suite("LiveAgreement")
struct LiveAgreementTests {
    @Test("a line that only grows is shown exactly as the engine wrote it")
    func growing() {
        var agreement = LiveAgreement()
        #expect(agreement.settle("good morning") == "good morning")
        #expect(agreement.settle("good morning  how did") == "good morning  how did")
        #expect(agreement.settle("good morning how did you sleep") == "good morning how did you sleep")
    }

    @Test("a word two passes agreed on doesn't flip under the reader's eyes, while the end of the line keeps moving")
    func heldWordStays() {
        var agreement = LiveAgreement()
        _ = agreement.settle("I have an appointment at the")
        _ = agreement.settle("I have an appointment at the doctor")
        let shown = agreement.settle("I have an ointment at the doctor at ten")
        #expect(shown == "I have an appointment at the doctor at ten")
    }

    @Test("a word read the new way twice in a row is a correction: two pills that became three shows three")
    func confirmedCorrection() {
        var agreement = LiveAgreement()
        _ = agreement.settle("take two pills after the meal")
        _ = agreement.settle("take two pills after the meal today")
        #expect(agreement.settle("take three pills after the meal today") == "take two pills after the meal today")
        #expect(agreement.settle("take three pills after the meal today please") == "take three pills after the meal today please")
        #expect(agreement.settle("take two pills after the meal today please now") == "take three pills after the meal today please now")
    }

    @Test("a word seen only once was never agreed on, so the newer reading is shown")
    func notYetAgreed() {
        var agreement = LiveAgreement()
        _ = agreement.settle("I have an ointment")
        #expect(agreement.settle("I have an appointment at") == "I have an appointment at")
    }

    @Test("a pass that rewrites much of the line is a real change of mind and is shown")
    func rewrite() {
        var agreement = LiveAgreement()
        _ = agreement.settle("the cat sat on the mat")
        _ = agreement.settle("the cat sat on the mat today")
        #expect(agreement.settle("a bat spat at a hat today and") == "a bat spat at a hat today and")
        #expect(agreement.settle("a bat spat at a hat today and then") == "a bat spat at a hat today and then")
    }

    @Test("a pass that drops words is shown, and what it dropped is no longer held")
    func shrinks() {
        var agreement = LiveAgreement()
        _ = agreement.settle("thank you thank you very much")
        _ = agreement.settle("thank you thank you very much indeed")
        #expect(agreement.settle("thank you very") == "thank you very")
        #expect(agreement.settle("thank you very much") == "thank you very much")
    }

    @Test("an empty pass changes nothing")
    func empty() {
        var agreement = LiveAgreement()
        _ = agreement.settle("hello there")
        #expect(agreement.settle("  ") == "  ")
        #expect(agreement.settle("hello there friend") == "hello there friend")
    }

    @Test("on the caption line itself: held while it is being written, and the final pass always wins")
    func throughTheStabilizer() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "I have an appointment at the", isFinal: false, timestamp: 1))
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "I have an appointment at the doctor", isFinal: false, timestamp: 2))
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "I have an ointment at the doctor at ten", isFinal: false, timestamp: 3))
        #expect(stabilizer.segments[0].text == "I have an appointment at the doctor at ten")

        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "I have an ointment at the doctor at ten.", isFinal: true, timestamp: 4))
        #expect(stabilizer.segments[0].text == "I have an ointment at the doctor at ten.")
    }
}
