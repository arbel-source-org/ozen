import Foundation
import Testing
@testable import OzenKit

@Suite("DownloadEstimator")
struct DownloadEstimatorTests {
    @Test("a steady download is estimated from its pace")
    func steady() throws {
        var estimator = DownloadEstimator()
        // 1% a second.
        for second in 0...10 {
            estimator.record(fraction: Double(second) / 100, at: 1_000 + Double(second))
        }
        let left = try #require(estimator.secondsRemaining())
        #expect(abs(left - 90) < 0.5)
    }

    @Test("no estimate in the first seconds, or while nothing moves")
    func notYet() {
        var estimator = DownloadEstimator()
        #expect(estimator.secondsRemaining() == nil)
        estimator.record(fraction: 0.1, at: 0)
        estimator.record(fraction: 0.12, at: 3)
        #expect(estimator.secondsRemaining() == nil)

        var stalled = DownloadEstimator()
        stalled.record(fraction: 0.4, at: 0)
        stalled.record(fraction: 0.4, at: 20)
        #expect(stalled.secondsRemaining() == nil)
    }

    @Test("the estimate follows the recent pace, not the average since the start")
    func recentPace() throws {
        var estimator = DownloadEstimator()
        // Two minutes at 0.1% a second on a poor connection...
        for second in stride(from: 0, through: 120, by: 5) {
            estimator.record(fraction: Double(second) / 1_000, at: Double(second))
        }
        // ...then half a minute at 1% a second on better Wi-Fi.
        for second in stride(from: 125, through: 160, by: 5) {
            estimator.record(fraction: 0.12 + Double(second - 120) / 100, at: Double(second))
        }
        let left = try #require(estimator.secondsRemaining())
        // 48% left at 1%/s is 48 s; the whole-download average would say several minutes.
        #expect(left < 60)
        #expect(left > 40)
    }

    @Test("a stall longer than the window doesn't leave the estimate anchored to pre-stall progress")
    func recoversFromAStall() throws {
        var estimator = DownloadEstimator()
        estimator.record(fraction: 0.1, at: 0)
        // A ten-minute stall -- no progress reported at all.
        estimator.record(fraction: 0.11, at: 600)
        estimator.record(fraction: 0.5, at: 605)
        let left = try #require(estimator.secondsRemaining())
        // True recent pace is (0.5-0.11)/5 ≈ 7.8%/s, about 6.4s left.
        // Anchored to the stale sample from before the stall instead, the
        // span balloons to 605s and the estimate to well over ten minutes.
        #expect(left < 15)
    }

    @Test("a download that starts over starts the estimate over")
    func restart() {
        var estimator = DownloadEstimator()
        estimator.record(fraction: 0.5, at: 0)
        estimator.record(fraction: 0.6, at: 10)
        estimator.record(fraction: 0.0, at: 11)
        estimator.record(fraction: 0.01, at: 13)
        #expect(estimator.secondsRemaining() == nil)
    }
}

@Suite("CaptionPipeline download time left")
@MainActor
struct CaptionPipelineDownloadEstimateTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 1_000
        func tick() -> TimeInterval {
            lock.withLock {
                time += 3
                return time
            }
        }
    }

    private final class Engines: @unchecked Sendable {
        var current: FakeEngine
        init(_ engine: FakeEngine) { current = engine }
    }

    @Test("a model download reports how long it has left, and a new start times it afresh")
    func estimatesDownload() async {
        let downloading = FakeEngine(progressUpdates: [0.1, 0.2, 0.3, 0.4].map {
            EnginePreparationProgress(stage: .downloadingModel, fraction: $0)
        })
        let engines = Engines(downloading)
        let clock = Clock()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engines.current },
            embedder: FakeEmbedder(),
            recovery: .disabled,
            audioWatchdog: .disabled,
            now: { clock.tick() }
        )
        var left: Double?
        downloading.duringPrepare = { left = pipeline.downloadSecondsRemaining }
        await pipeline.start(settings: .default)
        #expect((left ?? 0) > 0)

        // Another model, already on the phone: nothing left over from before.
        pipeline.stop()
        let ready = FakeEngine(kind: .appleSpeech)
        engines.current = ready
        left = -1
        ready.duringPrepare = { left = pipeline.downloadSecondsRemaining }
        var settings = AppSettings.default
        settings.engine = .appleSpeech
        await pipeline.start(settings: settings)
        #expect(left == nil)
    }
}

