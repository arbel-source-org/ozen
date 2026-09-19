import Testing
@testable import OzenPlatform
import OzenKit
import Foundation

@Suite("CAMPlusPlusSpeakerEmbedder")
struct CAMPlusPlusSpeakerEmbedderTests {
    @Test("the bundled model loads")
    func loads() {
        #expect(CAMPlusPlusSpeakerEmbedder() != nil)
    }

    @Test("the model runs and gives prints of the declared length")
    func runsAtDeclaredLength() throws {
        let embedder = try #require(CAMPlusPlusSpeakerEmbedder())
        let window = (0..<24_000).map { Float(sin(Double($0) * 0.05)) * 0.1 }
        let print = try #require(embedder.embed(samples: window, sampleRate: 16_000))
        #expect(print.count == embedder.embeddingLength)
    }

    @Test("audio shorter than one frame returns nil instead of crashing")
    func tooShortReturnsNil() throws {
        let embedder = try #require(CAMPlusPlusSpeakerEmbedder())
        #expect(embedder.embed(samples: [0.1, 0.2, 0.3], sampleRate: 16_000) == nil)
    }

    @Test("two clips of the same real speaker score far more alike than a different speaker's")
    func sameSpeakerScoresHigherThanDifferentSpeaker() throws {
        let embedder = try #require(CAMPlusPlusSpeakerEmbedder())
        let fixture = try SpeakerFixtureLoading.load()

        func embed(_ key: String) throws -> [Float] {
            let clip = try #require(fixture.clips[key])
            let samples = try SpeakerFixtureLoading.readSamples(named: clip.wavFile)
            return try #require(embedder.embed(samples: samples, sampleRate: fixture.sampleRate))
        }

        let a1 = try embed("speakerA_clip1")
        let a2 = try embed("speakerA_clip2")
        let b1 = try embed("speakerB_clip1")

        let sameSpeaker = cosineSimilarity(a1, a2)
        let acrossSpeakers1 = cosineSimilarity(a1, b1)
        let acrossSpeakers2 = cosineSimilarity(a2, b1)

        #expect(sameSpeaker > 0.45)
        #expect(acrossSpeakers1 < 0.45)
        #expect(acrossSpeakers2 < 0.45)
        #expect(acrossSpeakers1 < sameSpeaker)
        #expect(acrossSpeakers2 < sameSpeaker)
    }
}
