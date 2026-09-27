import Testing
import AVFoundation
@testable import OzenPlatform
import OzenKit

@Suite("AudioFileSamples")
struct AudioFileSamplesTests {
    private func fixtureURL() throws -> URL {
        let fixture = try SpeakerFixtureLoading.load()
        let clip = try #require(fixture.clips["speakerA_clip1"])
        return try SpeakerFixtureLoading.url(named: clip.wavFile)
    }

    @Test("a 16 kHz recording comes back sample for sample")
    func sameRate() throws {
        let original = try SpeakerFixtureLoading.readSamples(named: "speakerA_clip1.wav")
        let loaded = try #require(AudioFileSamples.load(try fixtureURL()))
        #expect(abs(loaded.count - original.count) < 50)
        let overlap = min(loaded.count, original.count)
        let largest = zip(loaded.prefix(overlap), original.prefix(overlap)).map { abs($0 - $1) }.max() ?? 1
        #expect(largest < 0.001)
    }

    @Test("a 48 kHz stereo recording is turned into the same voice at 16 kHz")
    func phoneRateStereo() throws {
        let original = try SpeakerFixtureLoading.readSamples(named: "speakerA_clip1.wav")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(original.count * 3)))
        buffer.frameLength = AVAudioFrameCount(original.count * 3)
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<original.count * 3 {
            let low = original[index / 3]
            let high = original[min(index / 3 + 1, original.count - 1)]
            let value = low + (high - low) * Float(index % 3) / 3
            channels[0][index] = value
            channels[1][index] = value
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let loaded = try #require(AudioFileSamples.load(url))
        #expect(abs(loaded.count - original.count) < 200)

        let embedder = try #require(CAMPlusPlusSpeakerEmbedder())
        let before = try #require(embedder.embed(samples: original, sampleRate: 16_000))
        let after = try #require(embedder.embed(samples: loaded, sampleRate: 16_000))
        #expect(cosineSimilarity(before, after) > 0.95)
    }

    @Test("a file that isn't audio gives nothing instead of crashing")
    func notAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a recording".utf8).write(to: url)
        #expect(AudioFileSamples.load(url) == nil)
    }
}
