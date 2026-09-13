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

    @Test("silence still produces a valid embedding rather than nil")
    func silenceProducesAnEmbedding() {
        let silence = [Float](repeating: 0, count: Int(sampleRate))
        let embedding = embedder.embed(samples: silence, sampleRate: sampleRate)
        #expect(embedding != nil)
        #expect(embedding?.count == 13)
    }
}
