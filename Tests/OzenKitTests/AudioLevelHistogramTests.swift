import Testing
import Foundation
@testable import OzenKit

@Suite("Microphone level histogram")
struct AudioLevelHistogramTests {
    private func rms(decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }

    @Test("percentiles come from the levels added, to the top of their 2 dB step")
    func percentiles() {
        var histogram = AudioLevelHistogram()
        #expect(histogram.decibels(atFraction: 0.5) == nil)
        #expect(histogram.summary == nil)
        for _ in 0..<10 { histogram.add(rms: rms(decibels: -71)) }
        for _ in 0..<80 { histogram.add(rms: rms(decibels: -57)) }
        for _ in 0..<10 { histogram.add(rms: rms(decibels: -43)) }
        #expect(histogram.total == 100)
        #expect(histogram.decibels(atFraction: 0.1) == -70)
        #expect(histogram.decibels(atFraction: 0.5) == -56)
        #expect(histogram.decibels(atFraction: 0.95) == -42)
        #expect(histogram.summary == "quiet -70 / middle -56 / loud -56 dBFS")
    }

    @Test("silence and clipping land in the end steps instead of crashing")
    func extremes() {
        var histogram = AudioLevelHistogram()
        histogram.add(rms: 0)
        histogram.add(rms: 1e-9)
        histogram.add(rms: 4)
        histogram.add(rms: .nan)
        #expect(histogram.total == 4)
        #expect(histogram.decibels(atFraction: 0) == -98)
        #expect(histogram.decibels(atFraction: 0.75) == -98)
        #expect(histogram.decibels(atFraction: 1) == 0)
    }
}

@Suite("Pipeline records how loud the microphone is")
@MainActor
struct PipelineInputLevelTests {
    @Test("every chunk is counted by level, and speech chunks separately")
    func recordsLevels() async {
        let audio = FakeAudioCapturer()
        let pipeline = CaptionPipeline(audio: audio, engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder())
        await pipeline.start(settings: .default)
        #expect(pipeline.stats.speechShare == nil)
        audio.push([Float](repeating: 0.00012, count: 800))
        audio.push([Float](repeating: 0.2, count: 800))
        audio.push([Float](repeating: 0.2, count: 800))
        audio.push([Float](repeating: 0.00012, count: 800))
        #expect(await eventually { pipeline.stats.inputLevels.total == 4 })
        #expect(pipeline.stats.speechChunks == 2)
        #expect(pipeline.stats.speechShare == 0.5)
        #expect(pipeline.stats.inputLevels.decibels(atFraction: 0.5) == -78)
        #expect(pipeline.stats.inputLevels.decibels(atFraction: 1) == -12)
    }
}
