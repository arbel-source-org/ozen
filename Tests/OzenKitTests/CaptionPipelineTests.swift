import Testing
@testable import OzenKit
import Foundation
import Observation

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
    /// Like the real session: capture can't start before one is prepared.
    var requiresPreparedSession = false
    private var isPrepared = false
    var calls: [String] = []
    private var continuation: AsyncStream<[Float]>.Continuation?

    func requestPermission() async -> AudioPermission {
        calls.append("requestPermission")
        return permissionAnswer
    }

    func prepareSession(preferredInputUID: String?) throws {
        calls.append("prepareSession")
        if let prepareError { throw prepareError }
        isPrepared = true
        selectedInputUID = AudioRoutePolicy.resolveSelection(
            available: availableInputs, preferredUID: preferredInputUID, currentUID: selectedInputUID
        )
    }

    func startCapture() throws -> AsyncStream<[Float]> {
        calls.append("startCapture")
        if let startError { throw startError }
        if requiresPreparedSession && !isPrepared { throw NSError(domain: "FakeAudio", code: 2) }
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

    private(set) var pendingDownloadChecks = 0
    /// Free space the download needs at its peak; nil means the download.
    var pendingInstall: Int?

    func pendingInstallMegabytes() async -> Int? {
        lock.withLock { pendingInstall ?? pendingDownload }
    }

    func pendingDownloadMegabytes() async -> Int? {
        lock.withLock {
            pendingDownloadChecks += 1
            return pendingDownload
        }
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

/// Holds every embedding until the test lets it go, like the first one of
/// a session while the model loads.
final class GatedEmbedder: SpeakerEmbedding, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = 0
    var callsStarted: Int { lock.withLock { entered } }

    func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        lock.withLock { entered += 1 }
        gate.wait()
        return FakeEmbedder().embed(samples: samples, sampleRate: sampleRate)
    }

    func release() { gate.signal() }
}

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

/// Every engine a factory built, held weakly, to see which are still alive.
@MainActor
final class BuiltEngines {
    private var references: [() -> FakeEngine?] = []

    var count: Int { references.count }
    var aliveCount: Int { references.filter { $0() != nil }.count }

    func add(_ engine: FakeEngine) {
        references.append { [weak engine] in engine }
    }
}

@MainActor
final class FactoryLog {
    var calls = 0
}

@MainActor
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

    @Test("a download's progress replaces what's on screen only at another whole percent")
    func progressShownByWholePercent() async {
        let updates = [0.100, 0.101, 0.104, 0.106, 0.107].map {
            EnginePreparationProgress(stage: .downloadingModel, fraction: $0, detail: "small")
        }
        let engine = FakeEngine(progressUpdates: updates)
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        var shown: Double?
        engine.duringPrepare = { shown = pipeline.phase.preparationProgress?.fraction }

        await pipeline.start(settings: .default)

        #expect(shown == 0.106)
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
    final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test("audio coming in doesn't wake what watches for finished lines; a finished line does")
    func committedLineCountIsObservedOnItsOwn() async {
        let audio = FakeAudioCapturer()
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(audio: audio, engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        let chunksBefore = pipeline.stats.audioChunksReceived

        #expect(pipeline.listeningStartedAt == pipeline.stats.sessionStartedAt)
        let woken = Flag()
        withObservationTracking {
            _ = pipeline.committedLineCount
            _ = pipeline.listeningStartedAt
        } onChange: { woken.raised = true }
        for _ in 0..<5 {
            audio.push([Float](repeating: 0.01, count: 1_600))
        }
        #expect(await eventually { pipeline.stats.audioChunksReceived >= chunksBefore + 5 })
        #expect(!woken.raised)

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "שלום", isFinal: true, timestamp: 1_000))
        #expect(await eventually { pipeline.committedLineCount == 1 })
        #expect(woken.raised)
    }

    @Test("the invisible direction mark the Hebrew model starts some lines with never reaches the saved line")
    func directionMarksAreDropped() async {
        let engine = FakeEngine()
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)
        engine.emit(token(UUID(), "\u{202B}שלום סבתא\u{202C}", final: true))
        #expect(await eventually { pipeline.segments.first?.isCommitted == true })
        #expect(pipeline.segments.first?.text == "שלום סבתא")
    }

    @Test("the last sound heard is kept in memory for a marked problem, and forgotten when captions stop")
    func keepsRecentAudio() async {
        let audio = FakeAudioCapturer()
        let (pipeline, _, _) = makePipeline(audio: audio, engines: [.whisperKit: FakeEngine()])
        await pipeline.start(settings: .default)
        #expect(await eventually { pipeline.phase == .listening })
        audio.push([0.25, -0.5, 0.75])
        #expect(await eventually { pipeline.recentAudioSamples == [0.25, -0.5, 0.75] })
        pipeline.stop()
        #expect(pipeline.recentAudioSamples.isEmpty)
    }

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
        #expect(pipeline.committedLineCount == 1)
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

    @Test("a slow embedding names the line that was being said, not one that started meanwhile")
    func slowEmbeddingKeepsItsLine() async {
        let engine = FakeEngine()
        let audio = FakeAudioCapturer()
        let embedder = GatedEmbedder()
        let pipeline = CaptionPipeline(audio: audio, engineFactory: { _ in engine }, embedder: embedder, recovery: .disabled)
        await pipeline.start(settings: .default)

        let first = UUID()
        engine.emit(token(first, "שלום"))
        #expect(await eventually { pipeline.segments.count == 1 })
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { embedder.callsStarted == 1 })

        let second = UUID()
        engine.emit(token(first, "שלום", final: true))
        engine.emit(token(second, "מה נשמע"))
        #expect(await eventually { pipeline.segments.count == 2 })
        embedder.release()

        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })
        #expect(pipeline.segments.last?.speakerClusterID == nil)
    }

    @Test("deleting one of two saved prints under a name stops only that print naming anyone")
    func forgetOneProfile() {
        let (pipeline, _, _) = makePipeline()
        let good = SpeakerProfile(name: "Savta", embedding: [1, 0, 0])
        let wrong = SpeakerProfile(name: "Savta", embedding: [0, 1, 0])
        pipeline.enroll(profile: good)
        pipeline.enroll(profile: wrong)
        pipeline.forgetProfile(id: wrong.id)
        #expect(pipeline.speakerClusters.filter { $0.name == "Savta" }.count == 1)
        #expect(pipeline.speakerClusters.first { $0.name == "Savta" }?.centroid == [1, 0, 0])
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

    @Test("a custom embedder's own recommended threshold is used at the untouched app default, not CAM++'s")
    func embedderRecommendedThresholdUsedAtDefault() async {
        struct ThresholdTestEmbedder: SpeakerEmbedding {
            let recommendedSimilarityThreshold: Float = 0.75
            func embed(samples: [Float], sampleRate: Double) -> [Float]? {
                guard let first = samples.first else { return nil }
                // Cosine similarity of exactly 0.6 to each other: below this
                // embedder's own 0.75, but above CAM++'s 0.45 default.
                return first > 0 ? [1, 0] : [0.6, 0.8]
            }
        }
        let engine = FakeEngine()
        let audio = FakeAudioCapturer()
        let pipeline = CaptionPipeline(audio: audio, engineFactory: { _ in engine }, embedder: ThresholdTestEmbedder(), recovery: .disabled)
        await pipeline.start(settings: .default)

        let id = UUID()
        engine.emit(token(id, "מי מדבר"))
        #expect(await eventually { pipeline.segments.count == 1 })
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })
        #expect(pipeline.speakerClusters.count == 1)

        let id2 = UUID()
        engine.emit(token(id, "מי מדבר", final: true))
        engine.emit(token(id2, "אני"))
        #expect(await eventually { pipeline.segments.count == 2 })
        // Below its own threshold but not by much: two windows of the new
        // voice make a speaker (a single one is held as a doubtful window).
        audio.push([Float](repeating: -0.5, count: 24_000))
        audio.push([Float](repeating: -0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.last?.speakerClusterID == 1 })
        #expect(pipeline.speakerClusters.count == 2)
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

    @Test("a profile saved by a different, since-replaced embedder is not seeded as a phantom speaker")
    func mismatchedProfileLengthIsNotEnrolled() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        // FakeEmbedder always returns length-3 vectors; this profile is
        // from a shorter, older embedder and can never match live speech.
        pipeline.enroll(profile: SpeakerProfile(name: "דנה", embedding: [1, 0]))
        #expect(pipeline.speakerClusters.isEmpty)

        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(token(id, "היי"))
        #expect(await eventually { pipeline.segments.count == 1 })
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.segments.first?.speakerClusterID != nil })

        #expect(pipeline.displayName(for: pipeline.segments[0]) != "דנה")
        #expect(pipeline.stats.speakerClustersOpened == 1)
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

    @Test("switching to another model lets go of the one before, so two models are never kept loaded")
    func switchingModelReleasesPrevious() async {
        let built = BuiltEngines()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                let engine = FakeEngine(kind: settings.engine)
                built.add(engine)
                return engine
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await pipeline.start(settings: .default)
        var turbo = AppSettings.default
        turbo.whisperModelVariant = "large-v3_turbo"
        await pipeline.restart(settings: turbo)
        #expect(pipeline.phase == .listening)
        #expect(await eventually { built.aliveCount == 1 })

        // Going back builds the first one again rather than having kept it.
        await pipeline.restart(settings: .default)
        #expect(built.count == 3)
        #expect(pipeline.phase == .listening)
    }

    @Test("a memory warning with captions stopped lets go of the loaded engine; starting again builds it anew")
    func memoryWarningWhileStoppedReleasesEngine() async {
        let built = BuiltEngines()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                let engine = FakeEngine(kind: settings.engine)
                built.add(engine)
                return engine
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await pipeline.start(settings: .default)
        pipeline.stop()
        pipeline.handleMemoryWarning(footprintBytes: 812 * 1_048_576)
        #expect(await eventually { built.aliveCount == 0 })
        #expect(pipeline.eventLog.events.last?.kind == .memoryWarning(footprintMegabytes: 812))

        await pipeline.start(settings: .default)
        #expect(built.count == 2)
        #expect(pipeline.phase == .listening)
    }

    @Test("a memory warning while captions run or are paused keeps the engine, so resuming is instant")
    func memoryWarningWhileRunningKeepsEngine() async {
        let built = BuiltEngines()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                let engine = FakeEngine(kind: settings.engine)
                built.add(engine)
                return engine
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await pipeline.start(settings: .default)
        pipeline.handleMemoryWarning()
        #expect(pipeline.phase == .listening)

        pipeline.pause()
        pipeline.handleMemoryWarning()
        await pipeline.resume()
        #expect(pipeline.phase == .listening)
        #expect(built.count == 1)
        #expect(built.aliveCount == 1)
    }

    @Test("a memory warning after a failure lets the engine go, unless a retry is on its way")
    func memoryWarningAfterFailure() async throws {
        for retryComing in [false, true] {
            let built = BuiltEngines()
            let audio = FakeAudioCapturer()
            audio.startError = TestError()
            let pipeline = CaptionPipeline(
                audio: audio,
                engineFactory: { settings in
                    let engine = FakeEngine(kind: settings.engine)
                    built.add(engine)
                    return engine
                },
                embedder: FakeEmbedder(),
                recovery: retryComing ? AutoRecoveryPolicy(glitchDelays: [600], downloadDelays: []) : .disabled
            )
            await pipeline.start(settings: .default)
            #expect(pipeline.phase.failure?.kind == .audioSessionFailed)
            #expect((pipeline.scheduledRetry != nil) == retryComing)
            #expect(await eventually { built.aliveCount == 1 })

            pipeline.handleMemoryWarning()
            if retryComing {
                try await Task.sleep(for: .milliseconds(200))
                #expect(built.aliveCount == 1)
                pipeline.stop()
            } else {
                #expect(await eventually { built.aliveCount == 0 })
            }
        }
    }

    @Test("retry after a failure starts again with the same settings")
    func retryAfterFailure() async {
        let audio = FakeAudioCapturer()
        audio.startError = TestError()
        let (pipeline, _, _) = makePipeline(audio: audio)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure?.kind == .audioSessionFailed)

        audio.startError = nil
        var phases: [PipelinePhase] = []
        pipeline.onPhaseChange = { phases.append($0) }
        await pipeline.retry()

        #expect(pipeline.phase == .listening)
        #expect(!phases.contains(.idle))
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

    @Test("resume picks up settings changed while paused, not the ones from before the pause")
    func resumeWithFreshSettingsPicksUpAChange() async {
        let (pipeline, _, _) = makePipeline(engines: [.whisperKit: FakeEngine(kind: .whisperKit), .appleSpeech: FakeEngine(kind: .appleSpeech)])
        await pipeline.start(settings: .default)
        pipeline.pause()

        var changed = AppSettings.default
        changed.engine = .appleSpeech
        await pipeline.resume(settings: changed)

        #expect(pipeline.phase == .listening)
        #expect(pipeline.activeSettings?.engine == .appleSpeech)
    }

    @Test("retry picks up settings changed while failed, not the ones from before the failure")
    func retryWithFreshSettingsPicksUpAChange() async {
        let audio = FakeAudioCapturer()
        audio.startError = TestError()
        let (pipeline, _, _) = makePipeline(audio: audio, engines: [.whisperKit: FakeEngine(kind: .whisperKit), .appleSpeech: FakeEngine(kind: .appleSpeech)])
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure?.kind == .audioSessionFailed)

        audio.startError = nil
        var changed = AppSettings.default
        changed.engine = .appleSpeech
        await pipeline.retry(settings: changed)

        #expect(pipeline.phase == .listening)
        #expect(pipeline.activeSettings?.engine == .appleSpeech)
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

        #expect(pipeline.selectInput(uid: "airpods"))

        #expect(pipeline.selectedInputUID == "airpods")
        #expect(pipeline.stats.inputChanges == 1)
    }

    @Test("a failed selection keeps the previous input and doesn't fail the pipeline")
    func selectUnknownInputIsHarmless() async {
        let (pipeline, _, _) = makePipeline()
        await pipeline.start(settings: .default)

        #expect(pipeline.selectInput(uid: "ghost") == false)

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

    @Test("a glitched buffer during enrollment is recorded as silence, so the voice print can still be made")
    func enrollmentGlitch() async {
        let (pipeline, audio, _) = makePipeline()
        let recording = Task { @MainActor in
            await pipeline.captureEnrollmentSamples(seconds: 0.5)
        }
        #expect(await eventually { audio.calls.contains("startCapture") })
        var glitched = [Float](repeating: 0.1, count: 8_000)
        glitched[100] = .nan
        glitched[200] = .infinity
        audio.push(glitched)
        let samples = await recording.value

        #expect(samples.count == 8_000)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples[100] == 0 && samples[101] == 0.1)
    }

    @Test("enrollment before captions ever ran sets up the audio session itself")
    func enrollmentWithoutSession() async {
        let (pipeline, audio, _) = makePipeline()
        audio.requiresPreparedSession = true
        let recording = Task { @MainActor in
            await pipeline.captureEnrollmentSamples(seconds: 0.5)
        }
        #expect(await eventually { audio.calls.filter { $0 == "startCapture" }.count == 2 })
        audio.push([Float](repeating: 0.1, count: 8_000))
        let samples = await recording.value

        #expect(samples.count == 8_000)
        #expect(audio.calls.prefix(4) == ["startCapture", "requestPermission", "prepareSession", "startCapture"])
    }

    @Test("a microphone that delivers nothing ends the recording instead of hanging it", .timeLimit(.minutes(1)))
    func enrollmentStalls() async {
        let (pipeline, audio, _) = makePipeline()
        pipeline.enrollmentStallSeconds = 0.1
        let started = ContinuousClock.now
        let recording = Task { @MainActor in
            await pipeline.captureEnrollmentSamples(seconds: 0.1)
        }
        #expect(await eventually { audio.calls.contains("startCapture") })
        audio.push([Float](repeating: 0.1, count: 400))
        let samples = await recording.value

        #expect(samples.count == 400)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(pipeline.phase == .idle)
    }

    @Test("stopping an enrollment midway ends the recording at once and brings captions back", .timeLimit(.minutes(1)))
    func enrollmentCancelled() async {
        let (pipeline, audio, _) = makePipeline()
        await pipeline.start(settings: .default)
        var heard = 0.0
        let recording = Task { @MainActor in
            await pipeline.captureEnrollmentSamples(seconds: 30) { heard = $0 }
        }
        #expect(await eventually { audio.calls.filter { $0 == "startCapture" }.count == 2 })
        audio.push([Float](repeating: 0.1, count: 8_000))
        #expect(await eventually { heard > 0 })

        let stopped = ContinuousClock.now
        recording.cancel()
        let samples = await recording.value

        #expect(ContinuousClock.now - stopped < .seconds(2))
        #expect(samples.count == 8_000)
        #expect(pipeline.phase == .listening)
    }

    @Test("without microphone permission enrollment records nothing and sets nothing up")
    func enrollmentWithoutPermission() async {
        let (pipeline, audio, _) = makePipeline()
        audio.requiresPreparedSession = true
        audio.permissionAnswer = .denied
        let samples = await pipeline.captureEnrollmentSamples(seconds: 0.5)

        #expect(samples.isEmpty)
        #expect(!audio.calls.contains("prepareSession"))
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

    @Test("while the phone vibrates for an alert, what the microphone hears of the buzz is not an alert")
    func ownVibrationIsNotAnAlert() async {
        let clock = TestClock()
        let detector = FakeSoundDetector()
        let (pipeline, audio, _) = makePipeline(soundDetector: detector, now: { clock.now })
        await pipeline.start(settings: .default)
        audio.push([Float](repeating: 0.1, count: 1_024))
        #expect(await eventually { detector.chunksSeen == 1 })

        let vibration = AlertVibration.pattern(for: .critical)
        pipeline.ignoreSounds(whileVibrating: vibration)
        detector.push(SoundObservation(identifier: "telephone_bell_ringing", confidence: 0.9, timestamp: clock.now))
        clock.advance(vibration.totalSeconds + 1)
        detector.push(SoundObservation(identifier: "alarm_clock", confidence: 0.9, timestamp: clock.now))
        // A real smoke alarm in the same moment is never taken for the buzz.
        detector.push(SoundObservation(identifier: "smoke_detector", confidence: 0.9, timestamp: clock.now))
        #expect(await eventually { !pipeline.soundAlerts.isEmpty })
        #expect(pipeline.soundAlerts.map(\.event.identifier) == ["smoke_detector"])

        // The ignored ring started no cooldown: a real one right after counts.
        clock.advance(1)
        detector.push(SoundObservation(identifier: "telephone_bell_ringing", confidence: 0.9, timestamp: clock.now))
        #expect(await eventually { pipeline.soundAlerts.count == 2 })
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
        // About -70 dBFS: a quiet room, below the -60 dBFS speech threshold.
        audio.push([Float](repeating: 0.0003, count: 24_000))
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

    @Test("a second speaker split out of the same audio doesn't take the voice heard just before")
    func splitTurnKeepsNoVoice() async {
        let engine = FakeEngine()
        let (pipeline, audio, _) = makePipeline(engines: [.whisperKit: engine])
        await pipeline.start(settings: .default)

        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.speakerClusters.count == 1 })
        let voice = pipeline.speakerClusters[0].id

        engine.emit(token(UUID(), "מה שלומך?", final: true))
        var reply = token(UUID(), "טוב, תודה", final: true)
        reply.startsNewSpeakerTurn = true
        engine.emit(reply)
        #expect(await eventually { pipeline.segments.count == 2 })
        #expect(pipeline.segments.first?.speakerClusterID == voice)
        #expect(pipeline.segments.last?.speakerClusterID == nil)
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

        // The report tells the story in order.
        let story = pipeline.eventLog.events.prefix(5).map { event -> String in
            switch event.kind {
            case .listening: return "listening"
            case .microphoneStalled: return "stalled"
            case .failed(let failure): return "failed \(failure.kind.rawValue)"
            case .retryScheduled(let attempt, _): return "retry \(attempt)"
            case .phoneCall: return "call"
            case .memoryWarning: return "memory"
            case .step, .input, .note: return "journal only"
            }
        }
        #expect(Array(story) == ["listening", "stalled", "failed audioSessionFailed", "retry 1", "listening"])
    }

    @Test("the journal is told each step of getting ready and how long the one before took, the microphone, and every logged event")
    func journalLines() async {
        let (pipeline, _, _) = makePipeline(audioWatchdog: .disabled)
        var lines: [String] = []
        pipeline.onEvent = { lines.append($0.description) }
        await pipeline.start(settings: .default)

        #expect(lines.contains { $0.hasPrefix("engine: checkingSupport") })
        #expect(lines.contains { $0.hasPrefix("starting audio (previous step took ") })
        #expect(lines.contains { $0.hasPrefix("microphone: ") })
        #expect(lines.last == "listening")
        #expect(pipeline.eventLog.events.map(\.description) == ["listening"])
    }

    @Test("a phone call is logged when it starts and ends, once each")
    func phoneCallLogged() async {
        let (pipeline, _, _) = makePipeline(audioWatchdog: .disabled)
        await pipeline.start(settings: .default)
        pipeline.systemInterruptionChanged(active: true)
        pipeline.systemInterruptionChanged(active: true)
        pipeline.systemInterruptionChanged(active: false)
        let calls = pipeline.eventLog.events.compactMap { event -> Bool? in
            if case .phoneCall(let began) = event.kind { return began }
            return nil
        }
        #expect(calls == [true, false])
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
        await eventually { embedder.state.started }
        let seenMidAnalysis = embedder.state.started && !embedder.state.finished
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
        #expect(await eventually { pipeline.phase.isListening })
        #expect(engine.prepareCount == 1)
    }

    @Test("a download that failed offline starts again when the connection comes back")
    func connectionReturns() async {
        let network = FakeNetworkMonitor(.offline)
        let (pipeline, _) = makePipeline(network: network)
        await pipeline.start(settings: settings())
        #expect(pipeline.phase.failure != nil)

        network.change(to: .wifi)
        #expect(await eventually { pipeline.phase.isListening })
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
        await eventually { pipeline.phase.failure != nil }
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

@Suite("CaptionPipeline thanks on a quiet room")
@MainActor
struct CaptionPipelineSilencePhraseTests {
    @Test("thanks invented again and again while nobody talks shows once, and real speech after it shows")
    func thanksLoop() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder(), recovery: .disabled)
        await pipeline.start(settings: .default)
        for _ in 0..<4 {
            engine.emit(TranscriptToken(utteranceID: UUID(), text: "תודה.", isFinal: true, timestamp: 1))
        }
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "תודה. תודה. תודה.", isFinal: true, timestamp: 2))
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "מה שלומך היום?", isFinal: true, timestamp: 3))
        #expect(await eventually { pipeline.segments.map(\.text) == ["תודה.", "מה שלומך היום?"] })
    }

    @Test("a final suppressed as a repeated thanks still commits the words already shown, without waiting on the stale-commit safety net")
    func suppressedFinalStillCommits() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder(), recovery: .disabled)
        await pipeline.start(settings: .default)
        let id = UUID()
        engine.emit(TranscriptToken(utteranceID: id, text: "תודה", isFinal: false, timestamp: 0))
        #expect(await eventually { pipeline.segments.count == 1 })
        engine.emit(TranscriptToken(utteranceID: id, text: "תודה. תודה.", isFinal: true, timestamp: 1))
        #expect(await eventually { pipeline.segments.first?.isCommitted == true })
        #expect(pipeline.segments.first?.text == "תודה")
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

    @Test("damaged audio from the microphone is counted for the diagnostics report")
    func glitchedAudioCounted() async {
        let audio = FakeAudioCapturer()
        let pipeline = CaptionPipeline(audio: audio, engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder(), recovery: .disabled)
        await pipeline.start(settings: .default)
        var glitched = [Float](repeating: 0.1, count: 1_600)
        glitched[7] = .nan
        audio.push(glitched)
        audio.push([Float](repeating: 0.1, count: 1_600))
        audio.push(glitched)
        #expect(await eventually { pipeline.stats.audioChunksReceived == 3 })
        #expect(await eventually { pipeline.stats.glitchedAudioChunks == 2 })
    }
}

/// Free space the test can change while the pipeline holds on to it.
final class FakeStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64?

    init(megabytes: Int64?) {
        bytes = megabytes.map { $0 * 1_048_576 }
    }

    func set(megabytes: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        bytes = megabytes.map { $0 * 1_048_576 }
    }

    func available() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

@Suite("CaptionPipeline model download and free space")
@MainActor
struct CaptionPipelineStorageTests {
    private func makePipeline(storage: FakeStorage?, pendingDownload: Int? = 626) -> (CaptionPipeline, FakeEngine, FakeAudioCapturer) {
        let engine = FakeEngine()
        let audio = FakeAudioCapturer()
        engine.pendingDownload = pendingDownload
        var freeSpace: (@Sendable () -> Int64?)?
        if let storage {
            freeSpace = { storage.available() }
        }
        let pipeline = CaptionPipeline(
            audio: audio,
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(),
            network: FakeNetworkMonitor(.wifi),
            availableStorageBytes: freeSpace
        )
        return (pipeline, engine, audio)
    }

    @Test("a phone without room for the model says so, with how much to free, and doesn't start the download")
    func notEnoughRoom() async {
        let storage = FakeStorage(megabytes: 300)
        let (pipeline, engine, _) = makePipeline(storage: storage)
        await pipeline.start(settings: .default)

        let why = pipeline.phase.failure?.engineUnavailability
        #expect(why?.kind == .notEnoughStorage)
        #expect(why?.downloadMegabytes == 626)
        #expect(why?.missingMegabytes == StorageSpaceGate.requiredMegabytes(forDownloadOf: 626) - 300)
        #expect(engine.prepareCount == 0)
        // Retrying on a timer can't free up space.
        #expect(pipeline.scheduledRetry == nil)
        #expect(pipeline.phase.failure?.suggestsOtherEngine == true)
        #expect(pipeline.phase.failure?.isRetryableInApp == true)
    }

    @Test("enough room, nothing to download, an unknown size, or no way to check: it goes ahead")
    func proceeds() async {
        let cases: [(FakeStorage?, Int?)] = [
            (FakeStorage(megabytes: 20_000), 626),
            (FakeStorage(megabytes: 10), nil),
            (FakeStorage(megabytes: 10), 0),
            (FakeStorage(megabytes: nil), 626),
            (nil, 626),
        ]
        for (storage, pending) in cases {
            let (pipeline, engine, _) = makePipeline(storage: storage, pendingDownload: pending)
            await pipeline.start(settings: .default)
            #expect(pipeline.phase.isListening)
            #expect(engine.prepareCount == 1)
        }
    }

    @Test("a model compiled on the phone needs room for twice its download, and a return to the app waits for that much")
    func roomForTheCompile() async {
        let storage = FakeStorage(megabytes: 1_400)
        let (pipeline, engine, _) = makePipeline(storage: storage, pendingDownload: 819)
        engine.pendingInstall = 1_638
        await pipeline.start(settings: .default)
        let why = pipeline.phase.failure?.engineUnavailability
        #expect(why?.kind == .notEnoughStorage)
        #expect(why?.missingMegabytes == StorageSpaceGate.requiredMegabytes(forDownloadOf: 1_638) - 1_400)
        #expect(engine.prepareCount == 0)

        storage.set(megabytes: Int64(StorageSpaceGate.requiredMegabytes(forDownloadOf: 819) + 10))
        await pipeline.appDidBecomeActive()
        #expect(engine.prepareCount == 0)

        storage.set(megabytes: Int64(StorageSpaceGate.requiredMegabytes(forDownloadOf: 1_638) + 10))
        await pipeline.appDidBecomeActive()
        #expect(pipeline.phase.isListening)
    }

    @Test("coming back to the app after freeing up room starts the download by itself")
    func freedUpRoom() async {
        let storage = FakeStorage(megabytes: 300)
        let (pipeline, engine, audio) = makePipeline(storage: storage)
        await pipeline.start(settings: .default)
        #expect(pipeline.phase.failure?.engineUnavailability?.kind == .notEnoughStorage)

        // Back on screen without having freed anything: stays put, quietly,
        // without even restarting the microphone to find out again.
        let callsBefore = audio.calls.count
        await pipeline.appDidBecomeActive()
        #expect(pipeline.phase.failure?.engineUnavailability?.kind == .notEnoughStorage)
        #expect(engine.prepareCount == 0)
        #expect(audio.calls.count == callsBefore)

        storage.set(megabytes: 20_000)
        await pipeline.appDidBecomeActive()
        #expect(pipeline.phase.isListening)
        #expect(engine.prepareCount == 1)
    }

    @Test("coming back to the app leaves every other state alone")
    func otherStatesUntouched() async {
        let (listening, engine, _) = makePipeline(storage: FakeStorage(megabytes: 20_000))
        await listening.start(settings: .default)
        await listening.appDidBecomeActive()
        #expect(listening.phase.isListening)
        #expect(engine.prepareCount == 1)

        let (idle, idleEngine, _) = makePipeline(storage: FakeStorage(megabytes: 20_000))
        await idle.appDidBecomeActive()
        #expect(idle.phase == .idle)
        #expect(idleEngine.prepareCount == 0)
    }
}

@Suite("CaptionPipeline lines cut off mid-sentence")
@MainActor
struct CaptionPipelineOpenLineTests {
    private func startWithOpenLine() async -> (CaptionPipeline, FakeEngine, UUID) {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: .disabled,
            audioWatchdog: .disabled
        )
        await pipeline.start(settings: .default)
        let utterance = UUID()
        engine.emit(TranscriptToken(utteranceID: utterance, text: "הרופא אמר ש", isFinal: false, timestamp: Date().timeIntervalSince1970))
        _ = await eventually { pipeline.segments.count == 1 }
        return (pipeline, engine, utterance)
    }

    @Test("pausing finishes the line that was being written")
    func pauseFinishesLine() async {
        let (pipeline, _, _) = await startWithOpenLine()
        #expect(pipeline.segments.first?.isCommitted == false)
        #expect(pipeline.stats.hasOpenLine)

        pipeline.pause()
        #expect(pipeline.segments.first?.isCommitted == true)
        #expect(pipeline.segments.first?.text == "הרופא אמר ש")
        #expect(pipeline.stats.segmentsCommitted == 1)
        #expect(pipeline.stats.hasOpenLine == false)
    }

    @Test("stopping finishes it too, and a line already final isn't counted twice")
    func stopFinishesLine() async {
        let (pipeline, engine, _) = await startWithOpenLine()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "כן", isFinal: true, timestamp: Date().timeIntervalSince1970))
        _ = await eventually { pipeline.segments.count == 2 }
        #expect(pipeline.stats.segmentsCommitted == 1)

        pipeline.stop()
        let allFinished = pipeline.segments.allSatisfy { $0.isCommitted }
        #expect(allFinished)
        #expect(pipeline.stats.segmentsCommitted == 2)
    }
}

@Suite("CaptionPipeline retry only after a failure")
@MainActor
struct CaptionPipelineRetryGuardTests {
    @Test("a retry asked for while starting or listening is ignored, so nothing prepares twice")
    func retryIgnoredUnlessFailed() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: .disabled,
            audioWatchdog: .disabled
        )
        var phaseWhenAsked: PipelinePhase?
        engine.duringPrepare = {
            phaseWhenAsked = pipeline.phase
            Task { await pipeline.retry() }
        }
        await pipeline.start(settings: .default)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(phaseWhenAsked?.isTransitioning == true)
        #expect(pipeline.phase.isListening)
        #expect(engine.prepareCount == 1)

        await pipeline.retry()
        #expect(engine.prepareCount == 1)
        #expect(pipeline.phase.isListening)
    }
}
