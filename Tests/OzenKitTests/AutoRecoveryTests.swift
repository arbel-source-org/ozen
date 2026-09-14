import Foundation
import Testing
@testable import OzenKit

@Suite("AutoRecoveryPolicy")
struct AutoRecoveryPolicyTests {
    private func failure(_ kind: PipelineFailure.Kind, engine: EngineUnavailability.Kind? = nil) -> PipelineFailure {
        PipelineFailure(kind: kind, detail: "", engineUnavailability: engine.map { EngineUnavailability(kind: $0, detail: "") })
    }

    @Test("only failures that can clear up on their own are retried")
    func classification() {
        #expect(AutoRecoveryPolicy.schedule(for: failure(.microphonePermissionDenied)) == .never)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .permissionDenied)) == .never)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .languageNotSupportedOnDevice)) == .never)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.transcriptionStopped)) == .glitch)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.audioSessionFailed)) == .glitch)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.noAudioInputs)) == .glitch)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .temporarilyUnavailable)) == .glitch)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .modelDownloadFailed)) == .download)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .modelLoadFailed)) == .loadFailure)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .cloudKeyNeeded)) == .never)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .cloudOutOfCredit)) == .never)
        #expect(AutoRecoveryPolicy.schedule(for: failure(.engineUnavailable, engine: .noInternet)) == .glitch)
    }

    @Test("glitches back off through their delays and then stop")
    func glitchBackoff() {
        var policy = AutoRecoveryPolicy(glitchDelays: [1, 3, 8], downloadDelays: [60])
        let stopped = failure(.transcriptionStopped)
        let delays = (0..<4).map { _ in policy.nextDelay(for: stopped) }
        #expect(delays == [1, 3, 8, nil])
        #expect(policy.attempts == 3)
    }

    @Test("a download waits longer between tries than a glitch")
    func downloadBackoff() {
        var policy = AutoRecoveryPolicy()
        let first = policy.nextDelay(for: failure(.engineUnavailable, engine: .modelDownloadFailed))
        #expect((first ?? 0) >= 15)
    }

    @Test("a model that won't load gets two tries, not the full glitch schedule")
    func loadFailureCap() {
        var policy = AutoRecoveryPolicy(glitchDelays: [1, 3, 8, 20], downloadDelays: [])
        let broken = failure(.engineUnavailable, engine: .modelLoadFailed)
        let delays = (0..<3).map { _ in policy.nextDelay(for: broken) }
        #expect(delays == [1, 3, nil])
    }

    @Test("reset starts the count over, and the disabled policy never retries")
    func resetAndDisabled() {
        var policy = AutoRecoveryPolicy(glitchDelays: [1], downloadDelays: [])
        let stopped = failure(.transcriptionStopped)
        _ = policy.nextDelay(for: stopped)
        #expect(policy.nextDelay(for: stopped) == nil)
        policy.reset()
        #expect(policy.nextDelay(for: stopped) == 1)

        var disabled = AutoRecoveryPolicy.disabled
        #expect(disabled.nextDelay(for: stopped) == nil)
    }
}

/// A clock the test moves by hand, for the "healthy for a minute" rule.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

@Suite("CaptionPipeline automatic recovery")
@MainActor
struct CaptionPipelineRecoveryTests {
    private let fast = AutoRecoveryPolicy(glitchDelays: [0.01, 0.01], downloadDelays: [0.01])

    private func makeRecoveringPipeline(
        audio: FakeAudioCapturer = FakeAudioCapturer(),
        engine: FakeEngine = FakeEngine(),
        policy: AutoRecoveryPolicy,
        clock: TestClock = TestClock()
    ) -> CaptionPipeline {
        CaptionPipeline(
            audio: audio,
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: policy,
            now: { clock.now }
        )
    }

    @Test("the recognizer dropping out mid-conversation recovers by itself")
    func recoversFromEngineDropout() async {
        let engine = FakeEngine()
        let pipeline = makeRecoveringPipeline(engine: engine, policy: fast)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.isListening)

        engine.endStream(throwing: TestError())
        #expect(await eventually { pipeline.phase.failure != nil })
        #expect(pipeline.scheduledRetry?.attempt == 1)
        #expect(await eventually { pipeline.phase.isListening })
        #expect(pipeline.scheduledRetry == nil)
    }

    @Test("retries stop when the schedule runs out, leaving the failure for a person")
    func givesUp() async {
        let audio = FakeAudioCapturer()
        audio.startError = TestError()
        let pipeline = makeRecoveringPipeline(audio: audio, policy: fast)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure?.kind == .audioSessionFailed)

        // Initial attempt plus the two scheduled retries.
        #expect(await eventually { audio.calls.filter { $0 == "startCapture" }.count == 3 && pipeline.scheduledRetry == nil })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(audio.calls.filter { $0 == "startCapture" }.count == 3)
        #expect(pipeline.phase.failure?.kind == .audioSessionFailed)
    }

    @Test("a denied microphone is never retried")
    func permissionNotRetried() async {
        let audio = FakeAudioCapturer()
        audio.permissionAnswer = .denied
        let pipeline = makeRecoveringPipeline(audio: audio, policy: fast)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure?.kind == .microphonePermissionDenied)
        #expect(pipeline.scheduledRetry == nil)
    }

    @Test("stopping by hand cancels a retry that was waiting")
    func stopCancels() async {
        let engine = FakeEngine()
        let pipeline = makeRecoveringPipeline(engine: engine, policy: AutoRecoveryPolicy(glitchDelays: [0.15], downloadDelays: []))
        await pipeline.start(settings: .default)
        engine.endStream(throwing: TestError())
        #expect(await eventually { pipeline.scheduledRetry != nil })
        pipeline.stop()
        #expect(pipeline.scheduledRetry == nil)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(pipeline.phase == .idle)
    }

    @Test("during a phone call nothing is retried; when the call ends, recovery starts fresh")
    func waitsOutInterruption() async {
        let audio = FakeAudioCapturer()
        audio.startError = TestError()
        let pipeline = makeRecoveringPipeline(audio: audio, policy: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: []))
        pipeline.systemInterruptionChanged(active: true)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure != nil)
        #expect(pipeline.scheduledRetry == nil)

        audio.startError = nil
        pipeline.systemInterruptionChanged(active: false)
        #expect(pipeline.scheduledRetry != nil)
        #expect(await eventually { pipeline.phase.isListening })
    }

    @Test("a minute of healthy listening earns a fresh set of attempts")
    func healthyListeningResets() async {
        let engine = FakeEngine()
        let clock = TestClock()
        let pipeline = makeRecoveringPipeline(engine: engine, policy: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: [], healthyListeningSeconds: 60), clock: clock)
        await pipeline.start(settings: .default)

        engine.endStream(throwing: TestError())
        #expect(await eventually { pipeline.phase.failure != nil })
        #expect(await eventually { pipeline.phase.isListening && pipeline.scheduledRetry == nil })

        clock.advance(61)
        engine.endStream(throwing: TestError())
        #expect(await eventually { pipeline.phase.failure != nil })
        #expect(pipeline.scheduledRetry != nil)
        #expect(await eventually { pipeline.phase.isListening })
    }

    @Test("failing again right after a recovery does not get a fresh set of attempts")
    func quickRefailExhausts() async {
        let engine = FakeEngine()
        let pipeline = makeRecoveringPipeline(engine: engine, policy: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: []))
        await pipeline.start(settings: .default)

        engine.endStream(throwing: TestError())
        #expect(await eventually { pipeline.phase.failure != nil })
        #expect(await eventually { pipeline.phase.isListening && pipeline.scheduledRetry == nil })

        engine.endStream(throwing: TestError())
        #expect(await eventually { pipeline.phase.failure != nil })
        #expect(pipeline.scheduledRetry == nil)
    }
}
