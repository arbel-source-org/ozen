import Foundation
import Testing
@testable import OzenKit

@Suite("SpeechGain")
struct SpeechGainTests {
    private func tone(peak: Float, count: Int = 16_000) -> [Float] {
        (0..<count).map { peak * sin(Float($0) * 0.05) }
    }

    @Test("speech from across the room is brought up to a level a 16-bit file keeps")
    func quietIsRaised() {
        let raised = SpeechGain.normalized(tone(peak: 0.01))
        let peak = raised.map(abs).max() ?? 0
        #expect(peak > 0.45 && peak <= 0.55)
    }

    @Test("speech that is already loud is left as it is")
    func loudIsUntouched() {
        let loud = tone(peak: 0.8)
        #expect(SpeechGain.normalized(loud) == loud)
    }

    @Test("one click doesn't decide the level, and doesn't leave the range once raised")
    func clickIsIgnored() {
        var samples = tone(peak: 0.01)
        samples[8_000] = 0.9
        let raised = SpeechGain.normalized(samples)
        #expect(raised[8_000] == 1)
        #expect(abs(raised[8_001]) < 0.6)
        #expect((raised.map(abs).sorted()[raised.count / 2]) > 0.2)
    }

    @Test("near silence isn't blown up into a roar")
    func gainIsCapped() {
        #expect(SpeechGain.gain(for: tone(peak: 0.00001)) == SpeechGain.maximumGain)
        #expect(SpeechGain.gain(for: [Float](repeating: 0, count: 100)) == 1)
        #expect(SpeechGain.gain(for: []) == 1)
        #expect(SpeechGain.gain(for: [.nan, .infinity]) == 1)
    }
}
