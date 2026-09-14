import Testing
@testable import OzenPlatform
import Foundation

// These only run where OzenPlatform builds at all — a macOS/iOS CI runner,
// since Accelerate isn't available on Linux (see MFCCSpeakerEmbedderTests).
@Suite("KaldiFBank")
struct KaldiFBankTests {
    @Test("audio shorter than one frame returns nil instead of crashing")
    func tooShortReturnsNil() {
        let frames = KaldiFBank().frames(samples: [0.1, 0.2, 0.3], sampleRate: 16_000)
        #expect(frames == nil)
    }

    @Test("computing the same audio twice gives the same frames")
    func deterministic() {
        let audio = (0..<24_000).map { Float(sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        let first = KaldiFBank().frames(samples: audio, sampleRate: 16_000)
        let second = KaldiFBank().frames(samples: audio, sampleRate: 16_000)
        #expect(first != nil)
        #expect(first == second)
    }

    /// The primary checkpoint for this file: the Swift filterbank has to
    /// reproduce `kaldi_native_fbank`'s own output on real speech, not just
    /// look reasonable. A 1% relative tolerance (against 1 where the
    /// reference value is near zero, since these are mean-subtracted log
    /// energies centered on zero) allows for FFT/trig rounding differences
    /// between Accelerate and the reference library, not for a wrong
    /// formula.
    @Test("the first frames of a real clip match kaldi_native_fbank's own output")
    func matchesReferenceFrames() throws {
        let fixture = try SpeakerFixtureLoading.load()
        let clip = try #require(fixture.clips["speakerA_clip1"])
        let samples = try SpeakerFixtureLoading.readSamples(named: clip.wavFile)

        let frames = try #require(KaldiFBank().frames(samples: samples, sampleRate: fixture.sampleRate))
        #expect(frames.count == clip.frameCount)

        for (frameIndex, expectedFrame) in clip.firstFrames.enumerated() {
            let actualFrame = frames[frameIndex]
            #expect(actualFrame.count == expectedFrame.count)
            for bin in expectedFrame.indices {
                let expected = expectedFrame[bin]
                let actual = actualFrame[bin]
                let tolerance = max(abs(expected), 1) * 0.01
                #expect(
                    abs(actual - expected) < tolerance,
                    "frame \(frameIndex) bin \(bin): got \(actual), expected \(expected)"
                )
            }
        }
    }
}
