import Foundation
import Testing
import OzenKit
@testable import OzenPlatform

@Suite("SileroVoiceScorer")
struct SileroVoiceScorerTests {
    func voicedChunks(_ samples: [Float]) throws -> (voiced: Int, total: Int) {
        let scorer = try #require(SileroVoiceScorer())
        var scores: [Float] = []
        var evidence = VoiceEvidence { input in
            let score = scorer.score(input)
            if let score { scores.append(score) }
            return score
        }
        evidence.append(samples)
        let chunks = samples.count / VoiceEvidence.chunkSamples
        #expect(scores.count == chunks)
        return (scores.filter { $0 >= VoiceEvidence.voiceThreshold }.count, chunks)
    }

    @Test("the bundled model loads")
    func loads() {
        #expect(SileroVoiceScorer() != nil)
    }

    @Test("hears a voice in each recorded speaker", arguments: ["speakerA_clip1.wav", "speakerA_clip2.wav", "speakerB_clip1.wav"])
    func speech(file: String) throws {
        let result = try voicedChunks(SpeakerFixtureLoading.readSamples(named: file))
        #expect(result.total == 7)
        #expect(result.voiced >= 4)
    }

    @Test("hears none in hiss, hum or silence")
    func noise() throws {
        var state: UInt64 = 3
        let hiss = (0..<64_000).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.0195
        }
        let hum = (0..<64_000).map { Float(0.03 * sin(2 * Double.pi * 100 * Double($0) / 16_000)) }
        let silence = [Float](repeating: 0, count: 16_384)
        #expect(try voicedChunks(hiss).voiced == 0)
        #expect(try voicedChunks(hum).voiced == 0)
        #expect(try voicedChunks(silence).voiced == 0)
    }
}
