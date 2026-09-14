import Testing
@testable import OzenKit
import Foundation

// MARK: - Fakes

/// Scripted audio layer: the test decides the permission answer, the input
/// list, and pushes audio chunks by hand. Records every call so tests can
/// assert on ordering (e.g. "inputs were listed before the engine loaded").
@MainActor
final class FakeAudioCapturer: AudioCapturing {
    var availableInputs: [AudioInputDescriptor] = [
        AudioInputDescriptor(uid: "builtin", portName: "iPhone Microphone", portType: .builtInMic),
    ]
    var selectedInputUID: String?
    var inputLevel: Float = 0
    var onInputsChanged: (@MainActor () -> Void)?

    var permissionAnswer: AudioPermission = .granted
    var prepareError: Error?
    var startError: Error?
    var calls: [String] = []
    private var continuation: AsyncStream<[Float]>.Continuation?

    func requestPermission() async -> AudioPermission {
        calls.append("requestPermission")
        return permissionAnswer
    }

    func prepareSession(preferredInputUID: String?) throws {
        calls.append("prepareSession")
        if let prepareError { throw prepareError }
        selectedInputUID = AudioRoutePolicy.resolveSelection(
            available: availableInputs, preferredUID: preferredInputUID, currentUID: selectedInputUID
        )
    }

    func startCapture() throws -> AsyncStream<[Float]> {
        calls.append("startCapture")
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stopCapture() {
        calls.append("stopCapture")
        continuation?.finish()
        continuation = nil
    }

    /// Inputs the system would report if asked again right now.
    var inputsOnRefresh: [AudioInputDescriptor]?

    func refreshInputs() {
        calls.append("refreshInputs")
        if let inputsOnRefresh {
            availableInputs = inputsOnRefresh
        }
    }

    func selectInput(uid: String) throws {
        calls.append("selectInput:\(uid)")
        guard availableInputs.contains(where: { $0.uid == uid }) else {
            throw NSError(domain: "FakeAudio", code: 1)
        }
        selectedInputUID = uid
    }

    func push(_ samples: [Float]) {
        continuation?.yield(samples)
    }

    func simulateRouteChange(inputs: [AudioInputDescriptor]) {
        availableInputs = inputs
        onInputsChanged?()
    }
}

/// Scripted engine: the test hands it an availability answer, optional
/// progress updates to emit during `prepare`, and a channel to push tokens
/// through. Also records how many times it was constructed via the factory
/// so engine caching across restarts is observable.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    let kind: TranscriptionEngineKind
    let availability: EngineAvailability
    let progressUpdates: [EnginePreparationProgress]
    /// Runs on the main actor in the middle of `prepare`, so a test can
    /// inspect pipeline state at that exact moment.
    var duringPrepare: (@MainActor () -> Void)?
    /// Megabytes `prepare` would still download; nil when the model is there.
    var pendingDownload: Int?
    private(set) var prepareCount = 0
    private let lock = NSLock()
    private var tokenContinuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation?
    private(set) var chunksSeen = 0
    private var vocabularyHistory: [[String]] = []
    /// Every list handed to `setVocabulary`, in order.
    var vocabularySeen: [[String]] { lock.withLock { vocabularyHistory } }

    init(
        kind: TranscriptionEngineKind = .whisperKit,
        availability: EngineAvailability = .available,
        progressUpdates: [EnginePreparationProgress] = []
    ) {
        self.kind = kind
        self.availability = availability
        self.progressUpdates = progressUpdates
    }

    func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability {
        lock.withLock { prepareCount += 1 }
        for update in progressUpdates {
            progress(update)
            await Task.yield()
        }
        if let duringPrepare {
            await MainActor.run { duringPrepare() }
        }
        return availability
    }

    func pendingDownloadMegabytes() async -> Int? {
        lock.withLock { pendingDownload }
    }

    func stream(languageCode: String, audio: AsyncStream<[Float]>) -> AsyncThrowingStream<TranscriptToken, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { tokenContinuation = continuation }
            Task {
                for await _ in audio {
                    self.lock.withLock { self.chunksSeen += 1 }
                }
            }
        }
    }

    func setVocabulary(_ terms: [String]) async {
        lock.withLock { vocabularyHistory.append(terms) }
    }

    func emit(_ token: TranscriptToken) {
        lock.withLock { tokenContinuation }?.yield(token)
    }

    func endStream(throwing error: Error? = nil) {
        let continuation = lock.withLock { tokenContinuation }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

struct FakeEmbedder: SpeakerEmbedding {
    /// The first sample of a window decides the "voice": windows starting
    /// with the same value embed identically, so a test can put two
    /// speakers on the line deterministically.
    func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        guard let first = samples.first else { return nil }
        return first > 0 ? [1, 0, 0] : [0, 1, 0]
    }
}

struct TestError: Error {}

/// Scripted sound classifier: the test pushes observations by hand.
final class FakeSoundDetector: SoundEventDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<SoundObservation>.Continuation?
    private(set) var chunksSeen = 0

    func observations(audio: AsyncStream<[Float]>) -> AsyncStream<SoundObservation> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            Task {
                for await _ in audio {
                    self.lock.withLock { self.chunksSeen += 1 }
                }
                continuation.finish()
            }
        }
    }

    func push(_ observation: SoundObservation) {
        lock.withLock { continuation }?.yield(observation)
    }

    /// The classifier giving up on its own, mid-session.
    func finish() {
        lock.withLock { continuation }?.finish()
    }
}

// MARK: - Helpers

@MainActor
private func makePipeline(
    audio: FakeAudioCapturer = FakeAudioCapturer(),
    engines: [TranscriptionEngineKind: FakeEngine] = [.whisperKit: FakeEngine()],
    soundDetector: FakeSoundDetector? = nil,
    recovery: AutoRecoveryPolicy = .disabled,
    audioWatchdog: AudioStallWatchdog = AudioStallWatchdog(),
    now: @escaping @Sendable () -> TimeInterval = { 1_000 }
) -> (CaptionPipeline, FakeAudioCapturer, FactoryLog) {
    let log = FactoryLog()
    let pipeline = CaptionPipeline(
        audio: audio,
        engineFactory: { settings in
            log.calls += 1
            return engines[settings.engine] ?? FakeEngine(kind: settings.engine)
        },
        embedder: FakeEmbedder(),
        soundDetector: soundDetector,
        recovery: recovery,
        audioWatchdog: audioWatchdog,
        now: now
    )
    return (pipeline, audio, log)
}

@MainActor
final class FactoryLog {
    var calls = 0
}

/// Polls until `condition` holds or the deadline passes. The pipeline
/// hops through Tasks internally, so state lands a few run-loop turns
/// after the triggering call; waiting on the condition rather than a fixed
/// sleep keeps these tests both fast and non-flaky.
@MainActor
private func eventually(
    timeoutMilliseconds: Int = 2_000,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func token(_ id: UUID, _ text: String, final: Bool = false, at time: TimeInterval = 1_000) -> TranscriptToken {
    TranscriptToken(utteranceID: id, text: text, isFinal: final, timestamp: time)
}

// MARK: - Tests

@Suite("CaptionPipeline startup sequence")
@MainActor
struct CaptionPipelineStartupTests {
    @Test("happy path lands in .listening and asks for permission, session, then capture, in that order")
    func happyPath() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)

        #expect(pipeline.phase == .listening)
        #expect(pipeline.activeEngineKind == .whisperKit)
        #expect(audio.calls == ["requestPermission", "prepareSession", "startCapture"])
        #expect(pipeline.stats.sessionStartedAt == 1_000)
    }

    @Test("microphones are listed BEFORE the engine is prepared, not after")
    func inputsListedBeforeEngineLoads() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        var inputsSeenDuringPrepare: [AudioInputDescriptor] = []
        var phaseSeenDuringPrepare: PipelinePhase = .idle
        engine.duringPrepare = {
            inputsSeenDuringPrepare = pipeline.availableInputs
            phaseSeenDuringPrepare = pipeline.phase
        }

        await pipeline.start(settings: .default)

        #expect(inputsSeenDuringPrepare.map(\.uid) == ["builtin"])
        #expect(phaseSeenDuringPrepare.preparationProgress != nil)
        #expect(pipeline.selectedInputUID == "builtin")
    }

    @Test("engine progress updates are reflected in the phase while preparing")
    func progressIsSurfaced() async {
        let updates = [
            EnginePreparationProgress(stage: .downloadingModel, fraction: 0.25, detail: "small"),
            EnginePreparationProgress(stage: .loadingModel),
        ]
        let engine = FakeEngine(progressUpdates: updates)
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        var seen: [EnginePreparationProgress] = []
        engine.duringPrepare = {
            if let progress = pipeline.phase.preparationProgress { seen.append(progress) }
        }

        await pipeline.start(settings: .default)

        // The last update emitted is the one visible when prepare finishes.
        #expect(seen.last == updates.last)
        #expect(pipeline.phase == .listening)
    }

    @Test("denied microphone permission fails without ever touching the engine or session")
    func permissionDenied() async {
        let audio = FakeAudioCapturer()
        audio.permissionAnswer = .denied
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(audio: audio, engines: [.whisperKit: engine])

        await pipeline.start(settings: .default)

        #expect(pipeline.phase.failure?.kind == .microphonePermissionDenied)
        #expect(pipeline.phase.failure?.isRetryableInApp == false)
        #expect(pipeline.phase.failure?.needsSystemSettings == true)
        #expect(engine.prepareCount == 0)
        #expect(!audio.calls.contains("prepareSession"))
    }

    @Test("an engine that reports itself unavailable produces a structured failure with a suggestion")
    func engineUnavailable() async {
        let why = EngineUnavailability(kind: .languageNotSupportedOnDevice, detail: "he-IL on-device model missing")
        let engine = FakeEngine(kind: .appleSpeech, availability: .unavailable(why))
        var settings = AppSettings.default
        settings.engine = .appleSpeech
        let (pipeline, audio, _) = makePipeline(engines: [.appleSpeech: engine])

        await pipeline.start(settings: settings)

        #expect(pipeline.phase.failure?.kind == .engineUnavailable)
        #expect(pipeline.phase.failure?.engineUnavailability == why)
        #expect(pipeline.phase.failure?.suggestsOtherEngine == true)
        #expect(pipeline.phase.failure?.isRetryableInApp == true)
        #expect(!audio.calls.contains("startCapture"))
        // Inputs stay listed even though the engine failed - the mic
        // picker must keep working so the user can fix things.
        #expect(pipeline.availableInputs.count == 1)
    }

    @Test("a denied speech permission is not retryable in-app")
    func speechPermissionDeniedNotRetryable() async {
        let why = EngineUnavailability(kind: .permissionDenied, detail: "SFSpeechRecognizer denied")
        let engine = FakeEngine(kind: .appleSpeech, availability: .unavailable(why))
        var settings = AppSettings.default
        settings.engine = .appleSpeech
        let (pipeline, _, _) = makePipeline(engines: [.appleSpeech: engine])

        await pipeline.start(settings: settings)

        #expect(pipeline.phase.failure?.isRetryableInApp == false)
        #expect(pipeline.phase.failure?.suggestsOtherEngine == false)
    }

    @Test("a broken audio session fails with .audioSessionFailed")
    func audioSessionFails() async {
        let audio = FakeAudioCapturer()
        audio.prepareError = TestError()
        let (pipeline, _, _) = makePipeline(audio: audio)

        await pipeline.start(settings: .default)

        #expect(pipeline.phase.failure?.kind == .audioSessionFailed)
        #expect(pipeline.phase.failure?.isRetryableInApp == true)
    }

    @Test("no inputs at all is its own failure, not a silent empty picker")
    func noInputs() async {
        let audio = FakeAudioCapturer()
        audio.availableInputs = []
        let (pipeline, _, _) = makePipeline(audio: audio)

        await pipeline.start(settings: .default)

        #expect(pipeline.phase.failure?.kind == .noAudioInputs)
    }

    @Test("start() while already listening is a no-op")
    func startWhileListeningIsNoop() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)
        await pipeline.start(settings: .default)

        #expect(audio.calls.filter { $0 == "startCapture" }.count == 1)
    }
}

@Suite("CaptionPipeline tokens, segments and speakers")
@MainActor
struct CaptionPipelineTokenTests {
    @Test("tokens become segments; the same utterance updates in place; final commits it")
    func tokensBecomeSegments() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        let id = UUID()

        engine.emit(token(id, "שלום"))
        #expect(await eventually { pipeline.segments.count == 1 })
        engine.emit(token(id, "שלום סבתא"))
        #expect(await eventually { pipeline.segments.first?.text == "שלום סבתא" })
        #expect(pipeline.segments.first?.isCommitted == false)

        engine.emit(token(id, "שלום סבתא", final: true))
        #expect(await eventually { pipeline.segments.first?.isCommitted == true })
        #expect(pipeline.segments.count == 1)
        #expect(pipeline.stats.tokensReceived == 3)
        #expect(pipeline.stats.segmentsCommitted == 1)
    }

    @Test("a segment the engine never finalizes is committed by the stale timer")
    func staleCommit() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine], now: { 1_000 })
        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(token(id, "מילה", at: 1_000))
        #expect(await eventually { pipeline.segments.count == 1 })

        // Longer than the old 1.2 s threshold and longer than a Whisper
        // final pass takes: the line must still be open.
        pipeline.commitStaleSegments(now: 1_004.5)
        #expect(pipeline.segments.first?.isCommitted == false)

        pipeline.commitStaleSegments(now: 1_000 + CaptionStabilizer.defaultSilenceCommitThreshold + 0.5)
        #expect(pipeline.segments.first?.isCommitted == true)
        #expect(pipeline.stats.segmentsCommitted == 1)
    }

    @Test("a live update, a pause, then the engine's final: the line stays open until the final arrives")
    func finalPassIsNotRaced() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine], now: { 1_000 })
        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(token(id, "מה שלו", at: 1_000))
        #expect(await eventually { pipeline.segments.count == 1 })

        // A 1 s pause ends the utterance and the careful final pass takes
        // ~1 s more on a phone; the stale timer ticks in between.
        pipeline.commitStaleSegments(now: 1_002.2)
        #expect(pipeline.segments.first?.isCommitted == false)

        engine.emit(token(id, "מה שלומך?", final: true, at: 1_002.3))
        #expect(await eventually { pipeline.segments.first?.isCommitted == true })
        #expect(pipeline.segments.first?.text == "מה שלומך?")
        #expect(pipeline.stats.segmentsCommitted == 1)
    }

    @Test("audio windows are embedded and the pending utterance gets a speaker cluster")
    func speakerAssignment() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)

        let id = UUID()
        engine.emit(token(id, "מי מדבר"))
        #expect(await eventually { pipeline.segments.count == 1 })

        // 1.5 s at 16 kHz is the embedding window; one positive-led window
        // is "speaker A".
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })
        #expect(pipeline.speakerClusters.count == 1)
        #expect(pipeline.stats.speakerClustersOpened == 1)
        #expect(pipeline.stats.audioSecondsReceived == 1.5)

        // A different voice on the next utterance opens a second cluster.
        let id2 = UUID()
        engine.emit(token(id, "מי מדבר", final: true))
        engine.emit(token(id2, "אני"))
        #expect(await eventually { pipeline.segments.count == 2 })
        audio.push([Float](repeating: -0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.last?.speakerClusterID == 1 })
        #expect(pipeline.speakerClusters.count == 2)
        #expect(pipeline.displayName(for: pipeline.segments[0]) != pipeline.displayName(for: pipeline.segments[1]))
    }

    @Test("naming a speaker returns the centroid for persistence and renames the cluster")
    func nameSpeaker() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(token(id, "היי"))
        #expect(await eventually { pipeline.segments.count == 1 })
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })

        let centroid = pipeline.nameSpeaker(of: pipeline.segments[0], name: "סבתא")
        #expect(centroid == [1, 0, 0])
        #expect(pipeline.displayName(for: pipeline.segments[0]) == "סבתא")
    }

    @Test("an enrolled profile names the matching voice from its first window")
    func enrolledProfileNamesFirstUtterance() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        pipeline.enroll(profile: SpeakerProfile(name: "דנה", embedding: [1, 0, 0]))
        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(token(id, "היי"))
        #expect(await eventually { pipeline.segments.count == 1 })
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })

        #expect(pipeline.displayName(for: pipeline.segments[0]) == "דנה")
        #expect(pipeline.stats.speakerClustersOpened == 0)
    }

    @Test("clearTranscript empties segments but keeps listening")
    func clearTranscript() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        engine.emit(token(UUID(), "x"))
        #expect(await eventually { pipeline.segments.count == 1 })

        pipeline.clearTranscript()

        #expect(pipeline.segments.isEmpty)
        #expect(pipeline.phase == .listening)
    }
}

@Suite("CaptionPipeline lifecycle: stop, restart, retry, pause")
@MainActor
struct CaptionPipelineLifecycleTests {
    @Test("the engine stream ending on its own while listening is surfaced as a retryable failure")
    func engineStreamEndsUnexpectedly() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)

        engine.endStream(throwing: TestError())

        #expect(await eventually { pipeline.phase.failure != nil })
        #expect(pipeline.phase.failure?.kind == .transcriptionStopped)
        #expect(pipeline.phase.failure?.isRetryableInApp == true)
        #expect(audio.calls.last == "stopCapture")
    }

    @Test("stop() returns to idle and stops capture")
    func stop() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)
        pipeline.stop()

        #expect(pipeline.phase == .idle)
        #expect(audio.calls.last == "stopCapture")
    }

    @Test("switching engines restarts with the new engine and keeps the transcript")
    func restartSwitchesEngine() async {
        let whisper = FakeEngine(kind: .whisperKit)
        let apple = FakeEngine(kind: .appleSpeech)
        let (pipeline, audio, log) = makePipeline(engines: [.whisperKit: whisper, .appleSpeech: apple])
        await pipeline.start(settings: .default)
        whisper.emit(token(UUID(), "לפני"))
        #expect(await eventually { pipeline.segments.count == 1 })

        var settings = AppSettings.default
        settings.engine = .appleSpeech
        await pipeline.restart(settings: settings)

        #expect(pipeline.phase == .listening)
        #expect(pipeline.activeEngineKind == .appleSpeech)
        #expect(pipeline.segments.count == 1)
        #expect(pipeline.stats.engineRestarts == 1)
        #expect(audio.calls.filter { $0 == "stopCapture" }.count == 1)
        #expect(audio.calls.filter { $0 == "startCapture" }.count == 2)
        #expect(log.calls == 2)

        apple.emit(token(UUID(), "אחרי"))
        #expect(await eventually { pipeline.segments.count == 2 })
    }

    @Test("restarting with the same engine settings reuses the prepared engine instead of building a new one")
    func restartReusesCachedEngine() async {
        let whisper = FakeEngine(kind: .whisperKit)
        let (pipeline, _, log) = makePipeline(engines: [.whisperKit: whisper])
        await pipeline.start(settings: .default)
        await pipeline.restart(settings: .default)

        #expect(log.calls == 1)
        #expect(whisper.prepareCount == 2)
        #expect(pipeline.phase == .listening)
    }

    @Test("a different Whisper model variant is a different engine")
    func modelVariantChangesEngineKey() async {
        let (pipeline, _, log) = makePipeline()
        await pipeline.start(settings: .default)
        var settings = AppSettings.default
        settings.whisperModelVariant = "large-v3_turbo"
        await pipeline.restart(settings: settings)

        #expect(log.calls == 2)
    }

    @Test("retry after a failure starts again with the same settings")
    func retryAfterFailure() async {
        let audio = FakeAudioCapturer()
        audio.startError = TestError()
        let (pipeline, _, _) = makePipeline(audio: audio)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure?.kind == .audioSessionFailed)

        audio.startError = nil
        await pipeline.retry()

        #expect(pipeline.phase == .listening)
    }

    @Test("pause stops capture and resume starts again")
    func pauseAndResume() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)
        pipeline.pause()
        #expect(pipeline.phase == .paused)
        #expect(audio.calls.last == "stopCapture")

        await pipeline.resume()
        #expect(pipeline.phase == .listening)
    }

    @Test("progress from a superseded run cannot clobber the new run's phase")
    func staleProgressIsIgnored() async {
        let slow = FakeEngine(progressUpdates: [EnginePreparationProgress(stage: .downloadingModel, fraction: 0.1)])
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: slow])
        let first = Task { await pipeline.start(settings: .default) }
        // Let the first run get as far as requesting permission, then
        // restart underneath it.
        await Task.yield()
        pipeline.stop()
        await pipeline.start(settings: .default)
        await first.value

        #expect(pipeline.phase == .listening)
    }
}

@Suite("CaptionPipeline inputs")
@MainActor
struct CaptionPipelineInputTests {
    @Test("selecting an input updates the selection and counts the change")
    func selectInput() async {
        let audio = FakeAudioCapturer()
        audio.availableInputs.append(AudioInputDescriptor(uid: "airpods", portName: "AirPods", portType: .bluetooth))
        let (pipeline, _, _) = makePipeline(audio: audio)
        await pipeline.start(settings: .default)

        pipeline.selectInput(uid: "airpods")

        #expect(pipeline.selectedInputUID == "airpods")
        #expect(pipeline.stats.inputChanges == 1)
    }

    @Test("a failed selection keeps the previous input and doesn't fail the pipeline")
    func selectUnknownInputIsHarmless() async {
        let (pipeline, _, _) = makePipeline()
        await pipeline.start(settings: .default)

        pipeline.selectInput(uid: "ghost")

        #expect(pipeline.selectedInputUID == "builtin")
        #expect(pipeline.phase == .listening)
    }

    @Test("a system route change refreshes the list without restarting")
    func routeChangeRefreshesInputs() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)

        audio.simulateRouteChange(inputs: [
            AudioInputDescriptor(uid: "builtin", portName: "iPhone Microphone", portType: .builtInMic),
            AudioInputDescriptor(uid: "usb-lav", portName: "USB Lavalier", portType: .usb),
        ])

        #expect(pipeline.availableInputs.map(\.uid) == ["builtin", "usb-lav"])
        #expect(pipeline.stats.inputChanges == 1)
        #expect(pipeline.phase == .listening)
        #expect(audio.calls.filter { $0 == "startCapture" }.count == 1)
    }
}

@Suite("CaptionPipeline enrollment capture")
@MainActor
struct CaptionPipelineEnrollmentTests {
    @Test("enrollment records through the live capture path, pausing and resuming captions around it")
    func enrollmentPausesAndResumes() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)

        var progress: [Double] = []
        let recording = Task { @MainActor in
            await pipeline.captureEnrollmentSamples(seconds: 1) { progress.append($0) }
        }
        #expect(await eventually { audio.calls.filter { $0 == "startCapture" }.count == 2 })
        #expect(pipeline.phase == .paused)
        audio.push([Float](repeating: 0.1, count: 8_000))
        audio.push([Float](repeating: 0.1, count: 8_000))
        let samples = await recording.value

        #expect(samples.count == 16_000)
        #expect(progress.last == 1)
        #expect(pipeline.phase == .listening)
        #expect(audio.calls.filter { $0 == "startCapture" }.count == 3)
    }

    @Test("enrollment while idle leaves the pipeline idle afterwards")
    func enrollmentFromIdle() async {
        let (pipeline, audio, _) = makePipeline()
        let recording = Task { @MainActor in
            await pipeline.captureEnrollmentSamples(seconds: 0.5)
        }
        #expect(await eventually { audio.calls.contains("startCapture") })
        audio.push([Float](repeating: 0.1, count: 8_000))
        let samples = await recording.value

        #expect(samples.count == 8_000)
        #expect(pipeline.phase == .idle)
    }

    @Test("an empty token for an unknown utterance creates no row")
    func emptyNewTokenIgnored() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        engine.emit(token(UUID(), ""))
        engine.emit(token(UUID(), "ממשי"))
        #expect(await eventually { pipeline.segments.count == 1 })
        #expect(pipeline.segments.first?.text == "ממשי")
        #expect(pipeline.stats.tokensReceived == 2)
    }
}

@Suite("CaptionPipeline alerts")
@MainActor
struct CaptionPipelineAlertTests {
    @Test("a keyword in a caption fires once per utterance and marks the segment")
    func keywordFiresOncePerUtterance() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        var settings = AppSettings.default
        settings.keywordAlerts = [KeywordAlert(phrase: "סבתא")]
        await pipeline.start(settings: settings)
        let id = UUID()

        engine.emit(token(id, "היום"))
        engine.emit(token(id, "היום לסבתא"))
        engine.emit(token(id, "היום לסבתא יש"))
        engine.emit(token(id, "היום לסבתא יש אורחים", final: true))
        #expect(await eventually { pipeline.segments.first?.isCommitted == true })

        #expect(pipeline.keywordHits.count == 1)
        #expect(pipeline.keywordHits.first?.match.matchedText == "לסבתא")
        #expect(pipeline.keywordHits.first?.segmentID == id)
        #expect(pipeline.keywordHitSegmentIDs == [id])

        let id2 = UUID()
        engine.emit(token(id2, "סבתא שוב"))
        #expect(await eventually { pipeline.keywordHits.count == 2 })
    }

    @Test("changing the keyword list takes effect without a restart, and clearing the transcript clears hits")
    func keywordListChanges() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        engine.emit(token(UUID(), "דנה הגיעה"))
        #expect(await eventually { pipeline.segments.count == 1 })
        #expect(pipeline.keywordHits.isEmpty)

        pipeline.setKeywordAlerts([KeywordAlert(phrase: "דנה")])
        engine.emit(token(UUID(), "ודנה יצאה"))
        #expect(await eventually { pipeline.keywordHits.count == 1 })
        #expect(audio.calls.filter { $0 == "startCapture" }.count == 1)

        pipeline.clearTranscript()
        #expect(pipeline.keywordHits.isEmpty)
        #expect(pipeline.keywordHitSegmentIDs.isEmpty)
    }

    @Test("sound observations become alerts through the policy, and audio reaches the detector")
    func soundAlerts() async {
        let detector = FakeSoundDetector()
        let (pipeline, audio, _) = makePipeline(soundDetector: detector)
        await pipeline.start(settings: .default)

        audio.push([Float](repeating: 0.1, count: 1_024))
        #expect(await eventually { detector.chunksSeen == 1 })

        detector.push(SoundObservation(identifier: "door_bell", confidence: 0.9, timestamp: 100))
        #expect(await eventually { pipeline.soundAlerts.count == 1 })
        #expect(pipeline.soundAlerts.first?.event.name == "פעמון דלת")

        // Same sound inside the cooldown: no second banner.
        detector.push(SoundObservation(identifier: "door_bell", confidence: 0.95, timestamp: 105))
        detector.push(SoundObservation(identifier: "speech", confidence: 0.99, timestamp: 106))
        detector.push(SoundObservation(identifier: "cough", confidence: 0.2, timestamp: 107))
        detector.push(SoundObservation(identifier: "smoke_detector", confidence: 0.8, timestamp: 108))
        #expect(await eventually { pipeline.soundAlerts.count == 2 })
        #expect(pipeline.soundAlerts.last?.event.identifier == "smoke_detector")

        pipeline.dismissSoundAlert(id: pipeline.soundAlerts[0].id)
        #expect(pipeline.soundAlerts.count == 1)
        pipeline.clearSoundAlerts()
        #expect(pipeline.soundAlerts.isEmpty)
    }

    @Test("sound preferences from settings are applied at start")
    func soundPreferencesApplied() async {
        let detector = FakeSoundDetector()
        let (pipeline, _, _) = makePipeline(soundDetector: detector)
        var settings = AppSettings.default
        settings.soundAlerts = SoundAlertPreferences(isEnabled: false)
        await pipeline.start(settings: settings)

        detector.push(SoundObservation(identifier: "door_bell", confidence: 0.9, timestamp: 100))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pipeline.soundAlerts.isEmpty)

        pipeline.soundPolicy.preferences.isEnabled = true
        detector.push(SoundObservation(identifier: "door_bell", confidence: 0.9, timestamp: 101))
        #expect(await eventually { pipeline.soundAlerts.count == 1 })
    }

    @Test("without a detector the pipeline still runs with two audio consumers")
    func noDetector() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        audio.push([Float](repeating: 0.1, count: 1_024))
        #expect(await eventually { engine.chunksSeen == 1 })
        #expect(pipeline.phase == .listening)
        #expect(pipeline.soundAlerts.isEmpty)
    }
}

@Suite("CaptionPipeline vocabulary hints")
@MainActor
struct CaptionPipelineVocabularyTests {
    @Test("the engine receives the cleaned vocabulary before streaming starts")
    func vocabularyPassedOnStart() async throws {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        var settings = AppSettings.default
        settings.vocabulary = [" אבי ", "רותי", "אבי", ""]
        await pipeline.start(settings: settings)
        #expect(pipeline.phase.isListening)
        #expect(engine.vocabularySeen == [["אבי", "רותי"]])
    }

    @Test("editing the vocabulary while listening reaches the engine without a restart")
    func vocabularyUpdatedLive() async throws {
        let engine = FakeEngine()
        let (pipeline, _, log) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        let callsAfterStart = log.calls
        await pipeline.setVocabulary(["סבתא", "דני"])
        #expect(engine.vocabularySeen == [[], ["סבתא", "דני"]])
        #expect(pipeline.phase.isListening)
        #expect(log.calls == callsAfterStart)
        #expect(pipeline.activeSettings?.vocabulary == ["סבתא", "דני"])
    }

    @Test("a vocabulary edit while stopped is remembered for the next start, not sent to a dead engine")
    func vocabularyWhileStopped() async throws {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.setVocabulary(["דני"])
        #expect(engine.vocabularySeen.isEmpty)
        await pipeline.start(settings: .default)
        #expect(engine.vocabularySeen == [[]])
    }
}

@Suite("CaptionPipeline permission pre-check")
@MainActor
struct CaptionPipelinePermissionTests {
    @Test("asking for the microphone up front does not start anything")
    func permissionOnly() async {
        let audio = FakeAudioCapturer()
        audio.permissionAnswer = .denied
        let (pipeline, _, log) = makePipeline(audio: audio)
        let answer = await pipeline.requestMicrophonePermission()
        #expect(answer == .denied)
        #expect(pipeline.phase == .idle)
        #expect(log.calls == 0)
        #expect(audio.calls == ["requestPermission"])
    }
}

@Suite("CaptionPipeline speaker names")
@MainActor
struct CaptionPipelineSpeakerNameTests {
    @Test("renaming and forgetting a saved speaker updates the lines already on screen")
    func renameAndForget() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        pipeline.enroll(profile: SpeakerProfile(name: "אבי", embedding: [1, 0, 0]))
        await pipeline.start(settings: .default)

        // The line must exist before its audio window is embedded, and a
        // positive-led window is FakeEmbedder's [1, 0, 0] voice.
        let id = UUID()
        engine.emit(token(id, "שלום", at: 1_000))
        #expect(await eventually { pipeline.segments.count == 1 })
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })
        let segment = pipeline.segments[0]
        #expect(pipeline.displayName(for: segment) == "אבי")

        pipeline.renameSpeakers(named: "אבי", to: "אביגדור")
        #expect(pipeline.displayName(for: segment) == "אביגדור")

        pipeline.forgetSpeakerName("אביגדור")
        #expect(pipeline.displayName(for: segment).hasPrefix("דובר "))
    }
}

@Suite("CaptionPipeline alert hooks")
@MainActor
struct CaptionPipelineAlertHookTests {
    @Test("a keyword heard in a line calls the hook once with the line")
    func keywordHook() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        var settings = AppSettings.default
        settings.keywordAlerts = [KeywordAlert(phrase: "סבתא")]
        var calls: [(Int, String)] = []
        pipeline.onKeywordHits = { hits, segment in calls.append((hits.count, segment.text)) }
        await pipeline.start(settings: settings)

        let id = UUID()
        engine.emit(token(id, "סבתא בואי"))
        engine.emit(token(id, "סבתא בואי לאכול", final: true))
        #expect(await eventually { pipeline.segments.first?.isCommitted == true })
        #expect(calls.count == 1)
        #expect(calls.first?.0 == 1)
        #expect(calls.first?.1 == "סבתא בואי")
    }

    @Test("a sound alert calls the hook")
    func soundHook() async {
        let detector = FakeSoundDetector()
        let (pipeline, _, _) = makePipeline(soundDetector: detector)
        var raised: [String] = []
        pipeline.onSoundAlert = { raised.append($0.event.identifier) }
        await pipeline.start(settings: .default)
        detector.push(SoundObservation(identifier: "door_bell", confidence: 0.95, timestamp: 1_000))
        #expect(await eventually { raised == ["door_bell"] })
    }
}

@Suite("CaptionPipeline speaker detection ignores silence")
@MainActor
struct CaptionPipelineSilenceSpeakerTests {
    @Test("silence and faint noise never open a speaker or label a line")
    func silenceOpensNothing() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(token(id, "..."))
        #expect(await eventually { pipeline.segments.count == 1 })

        audio.push([Float](repeating: 0, count: 24_000))
        audio.push([Float](repeating: 0.001, count: 24_000))
        #expect(await eventually { pipeline.stats.audioSecondsReceived == 3 })
        #expect(pipeline.speakerClusters.isEmpty)
        #expect(pipeline.segments.first?.speakerClusterID == nil)
    }

    @Test("a short reply spoken before its line appears still gets that voice")
    func shortReplyGetsRecentSpeaker() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)

        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.speakerClusters.count == 1 })
        let voice = pipeline.speakerClusters[0].id

        let id = UUID()
        engine.emit(token(id, "כן", final: true))
        #expect(await eventually { pipeline.segments.count == 1 })
        #expect(pipeline.segments.first?.speakerClusterID == voice)
    }

    @Test("an old voice is not pinned on a line that starts much later")
    func staleVoiceNotUsed() async {
        let clock = TestClock()
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine], now: { clock.now })
        await pipeline.start(settings: .default)

        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.speakerClusters.count == 1 })
        clock.advance(10)

        engine.emit(token(UUID(), "שלום", at: clock.now))
        #expect(await eventually { pipeline.segments.count == 1 })
        #expect(pipeline.segments.first?.speakerClusterID == nil)
    }
}

@Suite("CaptionPipeline sound detection status")
@MainActor
struct CaptionPipelineSoundStatusTests {
    @Test("the stats say when sound detection is running, and when the classifier stops on its own")
    func soundStatus() async {
        let detector = FakeSoundDetector()
        let (pipeline, _, _) = makePipeline(soundDetector: detector)
        #expect(pipeline.stats.soundDetectionRunning == false)
        await pipeline.start(settings: .default)
        #expect(pipeline.stats.soundDetectionRunning)

        detector.finish()
        #expect(await eventually { pipeline.stats.soundDetectionRunning == false })
        #expect(pipeline.phase.isListening)
    }

    @Test("stopping captions marks sound detection as not running")
    func stopClears() async {
        let (pipeline, _, _) = makePipeline(soundDetector: FakeSoundDetector())
        await pipeline.start(settings: .default)
        pipeline.stop()
        #expect(pipeline.stats.soundDetectionRunning == false)
    }
}

@Suite("CaptionPipeline mic picker refresh")
@MainActor
struct CaptionPipelineRefreshTests {
    @Test("refresh asks the system again even when captions never started, without recording")
    func refreshWhileIdle() {
        let audio = FakeAudioCapturer()
        audio.availableInputs = []
        let builtIn = AudioInputDescriptor(uid: "built-in", portName: "iPhone Microphone", portType: .builtInMic)
        audio.inputsOnRefresh = [builtIn]
        let (pipeline, _, _) = makePipeline(audio: audio)
        #expect(pipeline.availableInputs.isEmpty)

        pipeline.refreshInputs()
        #expect(pipeline.availableInputs == [builtIn])
        #expect(audio.calls == ["refreshInputs"])
        #expect(pipeline.phase == .idle)
    }
}

@Suite("CaptionPipeline dead microphone")
@MainActor
struct CaptionPipelineAudioStallTests {
    private let quickWatchdog = AudioStallWatchdog(stallSeconds: 0.5)

    @Test("a microphone that stops delivering audio becomes a visible audio failure")
    func deadMicrophoneFails() async {
        let (pipeline, audio, _) = makePipeline(audioWatchdog: quickWatchdog)
        await pipeline.start(settings: .default)
        audio.push([Float](repeating: 0, count: 1_600))

        #expect(await eventually { pipeline.phase.failure?.kind == .audioSessionFailed })
        #expect(pipeline.stats.audioStalls == 1)
        #expect(audio.calls.last == "stopCapture")
    }

    @Test("a quiet room still delivers audio, so captions keep listening")
    func silenceIsNotAStall() async throws {
        // A wider window than the other tests, so a busy CI machine that
        // delays one 50 ms sleep past a tick doesn't fail it, while the
        // audio still runs twice as long as the window.
        let (pipeline, audio, _) = makePipeline(audioWatchdog: AudioStallWatchdog(stallSeconds: 1))
        await pipeline.start(settings: .default)
        for _ in 0..<40 {
            audio.push([Float](repeating: 0, count: 800))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(pipeline.phase.isListening)
        #expect(pipeline.stats.audioStalls == 0)
    }

    @Test("no failure while a phone call holds the microphone, and the watch resumes after it")
    func phoneCallIsNotAStall() async throws {
        let (pipeline, _, _) = makePipeline(audioWatchdog: quickWatchdog)
        await pipeline.start(settings: .default)
        pipeline.systemInterruptionChanged(active: true)
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(pipeline.phase.isListening)

        pipeline.systemInterruptionChanged(active: false)
        #expect(await eventually { pipeline.phase.failure?.kind == .audioSessionFailed })
    }

    @Test("automatic recovery starts capture again after a stall")
    func stallRecovers() async {
        let (pipeline, audio, _) = makePipeline(
            recovery: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: []),
            audioWatchdog: quickWatchdog
        )
        await pipeline.start(settings: .default)

        #expect(await eventually { audio.calls.filter { $0 == "startCapture" }.count == 2 })
        #expect(await eventually { pipeline.phase.isListening })
        #expect(pipeline.stats.audioStalls == 1)
    }
}

/// Holds each embedding until the test lets it go (or a second passes).
final class BlockingEmbedder: SpeakerEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    private var finished = false

    var state: (started: Bool, finished: Bool) { lock.withLock { (started, finished) } }

    func letGo() { release.signal() }

    func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + .seconds(1))
        lock.withLock { finished = true }
        return [1, 0, 0]
    }
}

@Suite("CaptionPipeline voice analysis thread")
@MainActor
struct CaptionPipelineEmbeddingThreadTests {
    @Test("the main actor stays free while a voice is being analysed, and the speaker is still assigned")
    func embeddingOffMain() async throws {
        let embedder = BlockingEmbedder()
        let audio = FakeAudioCapturer()
        let pipeline = CaptionPipeline(
            audio: audio,
            engineFactory: { _ in FakeEngine() },
            embedder: embedder,
            recovery: .disabled
        )
        await pipeline.start(settings: .default)
        audio.push([Float](repeating: 0.5, count: 24_000))

        // This loop runs on the main actor. If the analysis ran there too,
        // the loop could only look again after it finished.
        var seenMidAnalysis = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let state = embedder.state
            if state.started {
                seenMidAnalysis = !state.finished
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        embedder.letGo()

        #expect(seenMidAnalysis)
        #expect(await eventually { pipeline.speakerClusters.count == 1 })
    }
}

@MainActor
final class FakeNetworkMonitor: NetworkMonitoring {
    var current: NetworkConditions?
    var onChange: (@MainActor (NetworkConditions) -> Void)?

    init(_ current: NetworkConditions?) {
        self.current = current
    }

    func change(to conditions: NetworkConditions) {
        current = conditions
        onChange?(conditions)
    }
}

@Suite("CaptionPipeline model download and the network")
@MainActor
struct CaptionPipelineDownloadNetworkTests {
    private func makePipeline(
        network: FakeNetworkMonitor?,
        pendingDownload: Int? = 626,
        recovery: AutoRecoveryPolicy = .disabled
    ) -> (CaptionPipeline, FakeEngine) {
        let engine = FakeEngine()
        engine.pendingDownload = pendingDownload
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: recovery,
            network: network
        )
        return (pipeline, engine)
    }

    private func settings(allowCellular: Bool = false) -> AppSettings {
        var settings = AppSettings.default
        settings.allowCellularModelDownload = allowCellular
        return settings
    }

    @Test("on cellular, a model that still has to download waits for Wi-Fi and says how big it is")
    func cellularWaits() async {
        let (pipeline, engine) = makePipeline(network: FakeNetworkMonitor(.cellular), recovery: AutoRecoveryPolicy())
        await pipeline.start(settings: settings())

        let why = pipeline.phase.failure?.engineUnavailability
        #expect(why?.kind == .waitingForWiFi)
        #expect(why?.downloadMegabytes == 626)
        #expect(engine.prepareCount == 0)
        // No timer keeps asking the same cellular connection.
        #expect(pipeline.scheduledRetry == nil)
        #expect(pipeline.phase.failure?.isRetryableInApp == true)
        #expect(pipeline.phase.failure?.suggestsOtherEngine == false)
    }

    @Test("Low Data Mode waits the same way")
    func lowDataModeWaits() async {
        let (pipeline, _) = makePipeline(network: FakeNetworkMonitor(NetworkConditions(isConnected: true, isConstrained: true)))
        await pipeline.start(settings: settings())
        #expect(pipeline.phase.failure?.engineUnavailability?.kind == .waitingForWiFi)
    }

    @Test("on Wi-Fi, with nothing to download, or before the system has reported, it goes ahead")
    func proceeds() async {
        for (network, pending) in [(FakeNetworkMonitor(.wifi), 626), (FakeNetworkMonitor(.cellular), nil), (FakeNetworkMonitor(nil), 626)] as [(FakeNetworkMonitor, Int?)] {
            let (pipeline, engine) = makePipeline(network: network, pendingDownload: pending)
            await pipeline.start(settings: settings())
            #expect(pipeline.phase.isListening)
            #expect(engine.prepareCount == 1)
        }
        let (unmonitored, _) = makePipeline(network: nil)
        await unmonitored.start(settings: settings())
        #expect(unmonitored.phase.isListening)
    }

    @Test("with no connection at all it fails as a download problem without trying")
    func offline() async {
        let (pipeline, engine) = makePipeline(network: FakeNetworkMonitor(.offline))
        await pipeline.start(settings: settings())
        #expect(pipeline.phase.failure?.engineUnavailability?.kind == .modelDownloadFailed)
        #expect(engine.prepareCount == 0)
    }

    @Test("the setting to allow cellular downloads lets it go ahead")
    func settingAllows() async {
        let (pipeline, _) = makePipeline(network: FakeNetworkMonitor(.cellular))
        await pipeline.start(settings: settings(allowCellular: true))
        #expect(pipeline.phase.isListening)
    }

    @Test("download now anyway starts the download over cellular")
    func approveOnce() async {
        let (pipeline, engine) = makePipeline(network: FakeNetworkMonitor(.cellular))
        await pipeline.start(settings: settings())
        #expect(pipeline.phase.failure?.engineUnavailability?.kind == .waitingForWiFi)

        await pipeline.approveCellularDownload()
        #expect(pipeline.phase.isListening)
        #expect(engine.prepareCount == 1)
    }

    @Test("turning on the setting while waiting starts the download")
    func settingTurnedOnWhileWaiting() async {
        let (pipeline, _) = makePipeline(network: FakeNetworkMonitor(.cellular))
        await pipeline.start(settings: settings())
        await pipeline.setAllowCellularModelDownload(true)
        #expect(pipeline.phase.isListening)
    }

    @Test("reaching Wi-Fi starts a waiting download by itself")
    func wifiArrives() async {
        let network = FakeNetworkMonitor(.cellular)
        let (pipeline, engine) = makePipeline(network: network)
        await pipeline.start(settings: settings())

        network.change(to: .cellular)
        #expect(engine.prepareCount == 0)

        network.change(to: .wifi)
        let deadline = ContinuousClock.now + .seconds(2)
        while !pipeline.phase.isListening && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(pipeline.phase.isListening)
        #expect(engine.prepareCount == 1)
    }

    @Test("a download that failed offline starts again when the connection comes back")
    func connectionReturns() async {
        let network = FakeNetworkMonitor(.offline)
        let (pipeline, _) = makePipeline(network: network)
        await pipeline.start(settings: settings())
        #expect(pipeline.phase.failure != nil)

        network.change(to: .wifi)
        let deadline = ContinuousClock.now + .seconds(2)
        while !pipeline.phase.isListening && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(pipeline.phase.isListening)
    }

    @Test("a download that failed on Wi-Fi isn't retried early just because Wi-Fi reported again")
    func sameWiFiAgain() async {
        let network = FakeNetworkMonitor(.wifi)
        let engine = FakeEngine(availability: .unavailable(.modelDownloadFailed, "server said no"))
        engine.pendingDownload = 626
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: .disabled,
            network: network
        )
        await pipeline.start(settings: settings())
        #expect(engine.prepareCount == 1)

        network.change(to: .wifi)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.prepareCount == 1)
    }

    @Test("a connection change doesn't touch captions that are running or failed for other reasons")
    func unrelatedFailuresIgnored() async {
        let network = FakeNetworkMonitor(.offline)
        let (pipeline, engine) = makePipeline(network: network, pendingDownload: nil)
        await pipeline.start(settings: settings())
        #expect(pipeline.phase.isListening)

        engine.endStream(throwing: TestError())
        let deadline = ContinuousClock.now + .seconds(2)
        while pipeline.phase.failure == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        network.change(to: .wifi)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pipeline.phase.failure?.kind == .transcriptionStopped)
        #expect(engine.prepareCount == 1)
    }
}

struct NaNEmbedder: SpeakerEmbedding {
    func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        [.nan, 0, 0]
    }
}

@Suite("CaptionPipeline broken voice prints")
@MainActor
struct CaptionPipelineNaNEmbeddingTests {
    @Test("a voice print full of NaNs is skipped instead of opening a phantom speaker")
    func nanSkipped() async throws {
        let audio = FakeAudioCapturer()
        let pipeline = CaptionPipeline(audio: audio, engineFactory: { _ in FakeEngine() }, embedder: NaNEmbedder(), recovery: .disabled)
        await pipeline.start(settings: .default)
        audio.push([Float](repeating: 0.5, count: 48_000))
        #expect(await eventually { pipeline.stats.audioChunksReceived == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(pipeline.speakerClusters.isEmpty)
    }
}
