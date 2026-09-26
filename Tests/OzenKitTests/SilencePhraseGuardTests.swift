import Foundation
import Testing
@testable import OzenKit

@Suite("Thanks said to an empty room")
struct SilencePhraseGuardTests {
    private func line(_ text: String, id: UUID = UUID(), final: Bool = true, at time: TimeInterval) -> (TranscriptToken, TimeInterval) {
        (TranscriptToken(utteranceID: id, text: text, isFinal: final, timestamp: time), time)
    }

    private func admitted(_ lines: [(TranscriptToken, TimeInterval)]) -> [Bool] {
        var guardian = SilencePhraseGuard()
        return lines.map { guardian.admits($0.0, at: $0.1) }
    }

    @Test("thanks repeated within one line is never shown")
    func repeatedWithinLine() {
        #expect(admitted([
            line("תודה. תודה. תודה.", at: 10),
            line("תודה רבה, תודה רבה", at: 200),
            line("Thank you. Thank you.", at: 400),
        ]) == [false, false, false])
    }

    @Test("a lone thanks shows once; the same again within seconds with nothing said between does not, and a run of them stays hidden")
    func loneThanksComesBack() {
        let first = UUID()
        #expect(admitted([
            line("תודה.", id: first, final: false, at: 0),
            line("תודה.", id: first, at: 1),
            line(" ... ", at: 5),
            line("תודה.", at: 12),
            line("תודה רבה", at: 24),
            line("תודה.", at: 36),
            line("תודה.", at: 60),
        ]) == [true, true, true, false, false, false, true])
    }

    @Test("two real thank-yous half a minute apart both show")
    func twoRealThanks() {
        #expect(admitted([
            line("תודה", at: 0),
            line("תודה רבה", at: 30),
        ]) == [true, true])
    }

    @Test("real words in between, or grown into a sentence, show as usual")
    func realSpeech() {
        let growing = UUID()
        #expect(admitted([
            line("תודה", at: 0),
            line("בבקשה, אין על מה", at: 5),
            line("תודה", at: 8),
            line("תודה", id: growing, final: false, at: 9),
            line("תודה רבה על הארוחה", id: growing, at: 10),
            line("תודה תודה לסבתא", at: 11),
        ]) == [true, true, true, false, true, true])
    }
}
