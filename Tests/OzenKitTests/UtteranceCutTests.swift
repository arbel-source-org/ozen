import Testing
@testable import OzenKit

@Suite("Where a line that ran too long is cut")
struct UtteranceCutTests {
    /// Loud alternating samples, with silence over `gap`.
    private func speech(count: Int, gap: Range<Int>? = nil) -> [Float] {
        (0..<count).map { index in
            if let gap, gap.contains(index) { return 0 }
            return index % 2 == 0 ? 0.5 : -0.5
        }
    }

    @Test("the cut goes into the quiet between words, not wherever the counter stopped")
    func findsTheGap() {
        let samples = speech(count: 16_000, gap: 12_000..<12_800)
        let cut = UtteranceCut.quietestPoint(in: samples, before: 16_000, lookBack: 8_000, frame: 400)
        #expect((12_000...12_800).contains(cut))
    }

    @Test("a gap older than the look-back is not reached for")
    func staysInTheLookBack() {
        let samples = speech(count: 16_000, gap: 1_000..<1_800)
        let cut = UtteranceCut.quietestPoint(in: samples, before: 16_000, lookBack: 4_000, frame: 400)
        #expect(cut >= 12_000)
    }

    @Test("with nothing quieter anywhere, the latest point wins so little carries over")
    func evenSpeech() {
        let samples = speech(count: 16_000)
        let cut = UtteranceCut.quietestPoint(in: samples, before: 16_000, lookBack: 4_000, frame: 400)
        #expect(cut >= 15_000)
        #expect(cut <= 16_000)
    }

    @Test("too little audio, or nonsense arguments, leave the cut where it was asked for")
    func edges() {
        #expect(UtteranceCut.quietestPoint(in: speech(count: 100), before: 100, lookBack: 4_000, frame: 400) == 100)
        #expect(UtteranceCut.quietestPoint(in: [], before: 50, lookBack: 10, frame: 4) == 0)
        #expect(UtteranceCut.quietestPoint(in: speech(count: 1_000), before: 5_000, lookBack: 1_000, frame: 0) == 1_000)
        #expect(UtteranceCut.quietestPoint(in: speech(count: 1_000), before: -3, lookBack: 1_000, frame: 100) == 0)
    }
}
