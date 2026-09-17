import Testing
import Foundation
@testable import OzenKit

@Suite("Alert sounds heard too faintly to alert")
struct SoundNearMissesTests {
    private func heard(_ identifier: String, _ confidence: Double, at time: TimeInterval) -> SoundObservation {
        SoundObservation(identifier: identifier, confidence: confidence, timestamp: time)
    }

    @Test("keeps the best confidence and the latest time for each sound below the alert level")
    func recordsBelowAlertLevel() {
        var misses = SoundNearMisses()
        misses.record(heard("door_bell", 0.41, at: 100), alertConfidence: 0.6)
        misses.record(heard("door_bell", 0.52, at: 50), alertConfidence: 0.6)
        misses.record(heard("door_bell", 0.35, at: 200), alertConfidence: 0.6)
        misses.record(heard("door_bell", 0.9, at: 300), alertConfidence: 0.6)
        misses.record(heard("speech", 0.5, at: 310), alertConfidence: 0.6)
        misses.record(heard("knock", 0.33, at: 150), alertConfidence: 0.6)
        #expect(misses.recentFirst.map(\.identifier) == ["door_bell", "knock"])
        #expect(misses.recentFirst.first?.bestConfidence == 0.52)
        #expect(misses.recentFirst.first?.lastHeardAt == 200)
        #expect(misses.reportLine(utcOffsetSeconds: 0) == "door_bell 52% 00:03:20, knock 33% 00:02:30")
    }

    @Test("two identifiers the catalog shows as the same sound are merged into one near-miss")
    func synonymIdentifiersAreMerged() {
        var misses = SoundNearMisses()
        misses.record(heard("telephone_bell_ringing", 0.45, at: 100), alertConfidence: 0.6)
        misses.record(heard("ringtone", 0.50, at: 101), alertConfidence: 0.6)
        #expect(misses.entries.count == 1)
        #expect(misses.entries.first?.bestConfidence == 0.50)
        #expect(misses.entries.first?.lastHeardAt == 101)
    }

    @Test("remembers a limited number of sounds, forgetting the one heard longest ago")
    func limited() {
        var misses = SoundNearMisses()
        let identifiers = SoundEventCatalog.events.map(\.identifier).prefix(SoundNearMisses.limit + 1)
        for (offset, identifier) in identifiers.enumerated() {
            misses.record(heard(identifier, 0.4, at: Double(offset)), alertConfidence: 0.6)
        }
        #expect(misses.entries.count == SoundNearMisses.limit)
        #expect(!misses.entries.contains { $0.identifier == identifiers.first })
        #expect(SoundNearMisses().reportLine(utcOffsetSeconds: 0) == nil)
    }
}

@Suite("Pipeline keeps sounds heard too faintly to alert")
@MainActor
struct PipelineSoundNearMissTests {
    @Test("a faint doorbell is noted without an alert; a clear one alerts and isn't a near miss")
    func faintAndClear() async {
        let detector = FakeSoundDetector()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in FakeEngine() },
            embedder: FakeEmbedder(),
            soundDetector: detector
        )
        await pipeline.start(settings: AppSettings.default)
        detector.push(SoundObservation(identifier: "door_bell", confidence: 0.45, timestamp: 1_000))
        #expect(await eventually { pipeline.soundNearMisses.entries.count == 1 })
        #expect(pipeline.soundAlerts.isEmpty)

        detector.push(SoundObservation(identifier: "smoke_detector", confidence: 0.95, timestamp: 1_001))
        #expect(await eventually { pipeline.soundAlerts.count == 1 })
        #expect(pipeline.soundNearMisses.entries.map { $0.identifier } == ["door_bell"])
    }
}
