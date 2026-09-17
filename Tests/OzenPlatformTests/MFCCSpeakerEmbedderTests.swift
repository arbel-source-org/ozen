import Testing
@testable import OzenPlatform
import OzenKit
import Foundation

// These only run where OzenPlatform builds at all — a macOS/iOS CI runner,
// since Accelerate isn't available on Linux. This is the least-verified
// file in the repo until CI actually runs it for the first time: it's
// hand-written DSP that couldn't be compiled or exercised on the dev
// machine, so these are sanity checks on real, measurable properties
// (determinism, and that clearly different tones don't collapse to the
// same embedding) rather than a claim that the MFCC math is textbook-exact.
@Suite("MFCCSpeakerEmbedder")
struct MFCCSpeakerEmbedderTests {
    let embedder = MFCCSpeakerEmbedder()
    let sampleRate: Double = 16_000

    func sineWave(frequency: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { i in
            Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    @Test("audio shorter than one frame returns nil instead of crashing")
    func tooShortReturnsNil() {
        let embedding = embedder.embed(samples: [0.1, 0.2, 0.3], sampleRate: sampleRate)
        #expect(embedding == nil)
    }

    @Test("embedding the same audio twice gives the same result")
    func deterministic() {
        let audio = sineWave(frequency: 220, seconds: 1.0)
        let first = embedder.embed(samples: audio, sampleRate: sampleRate)
        let second = embedder.embed(samples: audio, sampleRate: sampleRate)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("a low tone and a high tone produce more different embeddings than two close tones")
    func differentPitchesProduceDifferentEmbeddings() throws {
        let low = try #require(embedder.embed(samples: sineWave(frequency: 120, seconds: 1.0), sampleRate: sampleRate))
        let closeToLow = try #require(embedder.embed(samples: sineWave(frequency: 140, seconds: 1.0), sampleRate: sampleRate))
        let high = try #require(embedder.embed(samples: sineWave(frequency: 3_000, seconds: 1.0), sampleRate: sampleRate))

        let closeSimilarity = cosineSimilarity(low, closeToLow)
        let farSimilarity = cosineSimilarity(low, high)
        #expect(closeSimilarity > farSimilarity)
    }

    @Test("MFCC's own scale needs a much higher similarity threshold than the app default, tuned for CAM++")
    func recommendsItsOwnThreshold() {
        #expect(embedder.recommendedSimilarityThreshold == 0.75)
        #expect(embedder.recommendedSimilarityThreshold != AppSettings.default.speakerSimilarityThreshold)
    }

    @Test("silence still produces a valid embedding rather than nil")
    func silenceProducesAnEmbedding() {
        let silence = [Float](repeating: 0, count: Int(sampleRate))
        let embedding = embedder.embed(samples: silence, sampleRate: sampleRate)
        #expect(embedding != nil)
        #expect(embedding?.count == SpeakerProfile.voicePrintLength)
    }

    /// Harmonics of `pitch` over a little deterministic noise, so every
    /// band has energy well above the log floor at both loudnesses.
    func voice(pitch: Double, harmonics: Int, gain: Float) -> [Float] {
        var state: UInt32 = 1
        return (0..<Int(sampleRate)).map { i in
            var value = 0.0
            for h in 1...harmonics {
                value += 0.6 / Double(h) * sin(2 * Double.pi * pitch * Double(h) * Double(i) / sampleRate)
            }
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Double(state) / Double(UInt32.max) * 2 - 1
            return Float(value + 0.02 * noise) * gain
        }
    }

    @Test("the same voice further from the phone gives the same print")
    func loudnessDoesNotChangeThePrint() throws {
        let near = try #require(embedder.embed(samples: voice(pitch: 150, harmonics: 19, gain: 1), sampleRate: sampleRate))
        let far = try #require(embedder.embed(samples: voice(pitch: 150, harmonics: 19, gain: 0.1), sampleRate: sampleRate))
        let other = try #require(embedder.embed(samples: voice(pitch: 260, harmonics: 11, gain: 1), sampleRate: sampleRate))
        // With the loudness coefficient in the print these came out 0.06
        // and 0.93: the same voice quieter looked like a stranger, and a
        // different voice at the same loudness looked like the same one.
        #expect(cosineSimilarity(near, far) > 0.999)
        #expect(cosineSimilarity(near, other) < 0.9)
    }
}
