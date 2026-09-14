import Foundation
import Observation

/// The live pipeline: microphone permission → audio session and input list
/// → engine preparation (with progress) → capture → tokens fanned into
/// caption segments and speaker clusters. Every step lands in `phase`, in
/// order, so the screen always reflects what's actually happening.
///
/// Why the order matters: the first build prepared the engine *before*
/// touching audio, which meant the mic picker sat empty and the status
/// said "not checked" for the whole multi-minute Whisper download. Here the
/// audio session (cheap) comes first, so microphones are listed within a
/// second of launch, and the slow engine step reports progress the whole
/// time.
///
/// Portable on purpose: every dependency is a protocol, so this entire
/// sequence — including failure paths and engine hot-swapping — is unit
/// tested on Linux with fakes before it ever meets a real device.
@MainActor
@Observable
public final class CaptionPipeline {
    public private(set) var phase: PipelinePhase = .idle
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var availableInputs: [AudioInputDescriptor] = []
    public private(set) var selectedInputUID: String?
    public private(set) var activeEngineKind: TranscriptionEngineKind?
    public private(set) var speakerClusters: [SpeakerCluster] = []
    public private(set) var stats = PipelineStats()

    /// Keywords the reader asked to be told about, as they're spotted in
    /// captions. Each entry fires once per utterance (partial updates of
    /// the same sentence don't re-fire), newest last, capped so a long
    /// evening never grows this without bound.
    public private(set) var keywordHits: [KeywordHit] = []
    /// Segments that contain at least one keyword hit, for highlighting.
    public private(set) var keywordHitSegmentIDs: Set<UUID> = []
    /// Doorbell/siren/kettle alerts that passed `soundPolicy`, newest last.
    public private(set) var soundAlerts: [SoundAlert] = []

    /// Tunable from Settings without a restart.
    public var soundPolicy: SoundEventPolicy

    /// The settings the running (or last-run) session was started with.
    /// Engine/model/language changes need a restart; input changes don't.
    public private(set) var activeSettings: AppSettings?
    /// Set while a failure is waiting to be retried automatically.
    public private(set) var scheduledRetry: ScheduledRetry?
    /// Called for every new sound alert, e.g. to post a notification while
    /// the app isn't on screen.
    public var onSoundAlert: ((SoundAlert) -> Void)?
    /// Called with the fresh keyword hits in a line, and the line itself.
    public var onKeywordHits: (([KeywordHit], TranscriptSegment) -> Void)?

    public var inputLevel: Float { audio.inputLevel }

    private let audio: any AudioCapturing
    private let engineFactory: @MainActor (AppSettings) -> any TranscriptionEngine
    /// The engine of the current run, so vocabulary edits reach it live.
    private var currentEngine: (any TranscriptionEngine)?
    private let embedder: any SpeakerEmbedding
    private let soundDetector: (any SoundEventDetecting)?
    private var keywordMatcher = KeywordAlertMatcher(alerts: [])
    private var keywordDeduplicator = KeywordAlertDeduplicator()
    private let now: @Sendable () -> TimeInterval
    private var clusterer: EmbeddingClusterer
    private var stabilizer: CaptionStabilizer
    private var engineCache: [String: any TranscriptionEngine] = [:]
    private var fanOut: AudioFanOut?
    private var streamTask: Task<Void, Never>?
    private var embeddingTask: Task<Void, Never>?
    private var soundTask: Task<Void, Never>?
    private var staleCommitTask: Task<Void, Never>?
    private var utteranceClusterAssignments: [UUID: Int] = [:]
    /// Decides whether an embedding window holds a voice at all. Silence
    /// and background noise must not open phantom speakers or drag a real
    /// person's voice profile toward the fridge hum.
    private var embeddingVoiceDetector = EnergyVoiceDetector()
    /// The speaker of the most recent window that held speech. A short
    /// reply ("כן") is often over before its caption line exists, so a new
    /// line with no speaker yet takes this one if it is recent.
    private var recentSpeechCluster: (id: Int, at: TimeInterval)?
    private static let minimumSpeechFractionForEmbedding = 0.4
    private static let recentSpeechClusterSeconds: TimeInterval = 4
    /// Every `start()` gets a fresh run id; async continuations from an
    /// earlier run (a progress callback arriving after a restart, say)
    /// compare against it and drop themselves instead of clobbering state.
    private var runID = UUID()
    private var recovery: AutoRecoveryPolicy
    private var retryTask: Task<Void, Never>?
    private var retryToken: UUID?
    private var listeningSince: TimeInterval?
    /// A phone call (or another app) holds the audio session. Retrying
    /// then would only use up attempts; recovery waits for it to end.
    private var systemInterrupted = false

    private static let embeddingWindowSeconds = 1.5
    private static let sampleRate = 16_000.0
    private static let maxKeywordHits = 50
    private static let maxSoundAlerts = 30

    public init(
        audio: any AudioCapturing,
        engineFactory: @escaping @MainActor (AppSettings) -> any TranscriptionEngine,
        embedder: any SpeakerEmbedding,
        soundDetector: (any SoundEventDetecting)? = nil,
        soundPolicy: SoundEventPolicy = SoundEventPolicy(),
        clusterer: EmbeddingClusterer = EmbeddingClusterer(),
        stabilizer: CaptionStabilizer = CaptionStabilizer(),
        recovery: AutoRecoveryPolicy = AutoRecoveryPolicy(),
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.recovery = recovery
        self.audio = audio
        self.engineFactory = engineFactory
        self.embedder = embedder
        self.soundDetector = soundDetector
        self.soundPolicy = soundPolicy
        self.clusterer = clusterer
        self.stabilizer = stabilizer
        self.now = now
    }

    // MARK: - Lifecycle

    /// Asks for the microphone up front (the onboarding walkthrough does
    /// this on its own page, with an explanation, instead of the system
    /// prompt ambushing the user on top of a black screen).
    public func requestMicrophonePermission() async -> AudioPermission {
        await audio.requestPermission()
    }

    public func start(settings: AppSettings) async {
        guard !phase.isListening, !phase.isTransitioning else { return }
        cancelScheduledRetry()
        let run = UUID()
        runID = run
        activeSettings = settings
        clusterer.similarityThreshold = settings.speakerSimilarityThreshold
        keywordMatcher = KeywordAlertMatcher(alerts: settings.keywordAlerts)
        soundPolicy.preferences = settings.soundAlerts

        phase = .requestingMicrophonePermission
        let permission = await audio.requestPermission()
        guard runID == run else { return }
        guard permission == .granted else {
            fail(.microphonePermissionDenied, detail: "AVAudioApplication record permission denied")
            return
        }

        do {
            try audio.prepareSession(preferredInputUID: settings.preferredInputUID)
        } catch {
            fail(.audioSessionFailed, detail: String(describing: error))
            return
        }
        audio.onInputsChanged = { [weak self] in self?.inputsChanged() }
        syncInputs()
        guard !availableInputs.isEmpty else {
            fail(.noAudioInputs, detail: "AVAudioSession reported no available inputs")
            return
        }

        let engine = cachedEngine(for: settings)
        activeEngineKind = engine.kind
        phase = .preparingEngine(EnginePreparationProgress(stage: .checkingSupport))
        let availability = await engine.prepare(languageCode: settings.languageCode) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.runID == run, case .preparingEngine = self.phase else { return }
                self.phase = .preparingEngine(progress)
            }
        }
        guard runID == run else { return }
        if case .unavailable(let why) = availability {
            fail(.engineUnavailable, detail: why.detail, engineUnavailability: why)
            return
        }
        await engine.setVocabulary(VocabularyHints.normalized(settings.vocabulary))
        guard runID == run else { return }
        currentEngine = engine

        phase = .startingAudio
        let source: AsyncStream<[Float]>
        do {
            source = try audio.startCapture()
        } catch {
            fail(.audioSessionFailed, detail: String(describing: error))
            return
        }

        let fan = AudioFanOut(source: source, count: soundDetector == nil ? 2 : 3)
        fanOut = fan
        let tokens = engine.stream(languageCode: settings.languageCode, audio: fan.outputs[0])
        let embedderAudio = fan.outputs[1]
        let soundObservations = soundDetector.map { $0.observations(audio: fan.outputs[2]) }

        stats.sessionStartedAt = now()
        phase = .listening
        listeningSince = now()

        embeddingTask = Task { [weak self] in
            await self?.consumeEmbeddings(embedderAudio, run: run)
        }

        if let soundObservations {
            stats.soundDetectionRunning = true
            soundTask = Task { [weak self] in
                for await observation in soundObservations {
                    guard let self, self.runID == run else { return }
                    self.handle(soundObservation: observation)
                }
                // The classifier's stream can end on its own (the request
                // failed); captions carry on, but diagnostics should say
                // sound alerts are off rather than let them look armed.
                guard let self, self.runID == run else { return }
                self.stats.soundDetectionRunning = false
            }
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            var stopReason: String? = nil
            do {
                for try await token in tokens {
                    guard self.runID == run else { break }
                    self.handle(token: token)
                }
            } catch {
                stopReason = String(describing: error)
            }
            // Reaching here while still "listening" means the engine gave up
            // on its own (recognizer error, model crash) while audio is
            // still flowing. That's a failure the user should see and be
            // able to retry, not a silent stop.
            guard self.runID == run, self.phase.isListening else { return }
            self.fail(.transcriptionStopped, detail: stopReason ?? "engine stream ended")
        }

        staleCommitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.runID == run else { return }
                self.commitStaleSegments()
            }
        }
    }

    public func stop() {
        cancelScheduledRetry()
        recovery.reset()
        listeningSince = nil
        tearDownSession()
        phase = .idle
    }

    public func pause() {
        guard phase.isListening else { return }
        listeningSince = nil
        tearDownSession()
        phase = .paused
    }

    public func resume() async {
        guard phase == .paused, let activeSettings else { return }
        phase = .idle
        await start(settings: activeSettings)
    }

    /// Stops and starts again with new settings — the engine, model, or
    /// language changed. The transcript is kept; a switch mid-conversation
    /// shouldn't wipe what was already read.
    public func restart(settings: AppSettings) async {
        cancelScheduledRetry()
        recovery.reset()
        tearDownSession()
        phase = .idle
        stats.engineRestarts += 1
        await start(settings: settings)
    }

    /// For the retry button after a failure.
    public func retry() async {
        guard let activeSettings else { return }
        cancelScheduledRetry()
        tearDownSession()
        phase = .idle
        await start(settings: activeSettings)
    }

    public func clearTranscript() {
        segments = []
        stabilizer = CaptionStabilizer(silenceCommitThreshold: stabilizer.silenceCommitThreshold)
        utteranceClusterAssignments = [:]
        keywordHits = []
        keywordHitSegmentIDs = []
        keywordDeduplicator.forgetAll()
    }

    // MARK: - Alerts

    /// Replaces the keyword list without a restart; the deduplicator is
    /// reset so a newly added word can fire on a sentence still pending.
    public func setKeywordAlerts(_ alerts: [KeywordAlert]) {
        keywordMatcher = KeywordAlertMatcher(alerts: alerts)
        keywordDeduplicator.forgetAll()
    }

    public func dismissSoundAlert(id: UUID) {
        soundAlerts.removeAll { $0.id == id }
    }

    public func clearSoundAlerts() {
        soundAlerts = []
    }

    private func handle(soundObservation observation: SoundObservation) {
        guard let alert = soundPolicy.evaluate(observation) else { return }
        soundAlerts.append(alert)
        onSoundAlert?(alert)
        if soundAlerts.count > Self.maxSoundAlerts {
            soundAlerts.removeFirst(soundAlerts.count - Self.maxSoundAlerts)
        }
    }

    private func scanForKeywords(in segment: TranscriptSegment) {
        let matches = keywordMatcher.matches(in: segment.text)
        guard !matches.isEmpty else { return }
        let fresh = keywordDeduplicator.newMatches(utteranceID: segment.id, matches: matches)
        guard !fresh.isEmpty else { return }
        let timestamp = now()
        let hits = fresh.map { KeywordHit(segmentID: segment.id, match: $0, timestamp: timestamp) }
        keywordHits.append(contentsOf: hits)
        onKeywordHits?(hits, segment)
        if keywordHits.count > Self.maxKeywordHits {
            keywordHits.removeFirst(keywordHits.count - Self.maxKeywordHits)
        }
        keywordHitSegmentIDs.insert(segment.id)
    }

    // MARK: - Inputs

    public func selectInput(uid: String) {
        do {
            try audio.selectInput(uid: uid)
            stats.inputChanges += 1
            syncInputs()
        } catch {
            // Deliberately swallowed: a failed switch leaves the previous
            // input active, which is strictly better than dropping a live
            // conversation over a mic the system refused.
        }
    }

    /// Re-reads the input list from the audio layer. Public so the mic
    /// picker can refresh on demand ("I just plugged it in").
    /// For the mic picker's refresh button: asks the system again rather
    /// than re-reading the last list, which is empty if captions never got
    /// as far as setting up the microphone.
    public func refreshInputs() {
        audio.refreshInputs()
        syncInputs()
    }

    private func inputsChanged() {
        stats.inputChanges += 1
        syncInputs()
    }

    private func syncInputs() {
        availableInputs = audio.availableInputs
        selectedInputUID = audio.selectedInputUID
    }

    // MARK: - Speakers

    /// Seeds the clusterer with a saved profile so that person is named
    /// from their first utterance.
    public func enroll(profile: SpeakerProfile) {
        _ = clusterer.enroll(name: profile.name, embedding: profile.embedding)
        speakerClusters = clusterer.clusters
    }

    /// Computes an embedding from an enrollment recording, or nil if the
    /// recording was too short to say anything about the voice.
    public func embedding(forEnrollmentSamples samples: [Float]) -> [Float]? {
        embedder.embed(samples: samples, sampleRate: Self.sampleRate)
    }

    /// Records `seconds` of audio for voice enrollment through the *same*
    /// capture path live captioning uses — same input, same 16 kHz format
    /// the embedder is calibrated for. (The first build used a separate
    /// recorder at the hardware's native rate, so enrolled profiles were
    /// computed on 48 kHz audio and could never match live 16 kHz
    /// embeddings.) Live captioning is paused for the duration and
    /// resumed afterwards if it was running.
    public func captureEnrollmentSamples(
        seconds: Double,
        onProgress: @MainActor (Double) -> Void = { _ in }
    ) async -> [Float] {
        let wasListening = phase.isListening
        if wasListening || phase.isTransitioning {
            tearDownSession()
            phase = .paused
        }

        var collected: [Float] = []
        let target = Int(seconds * Self.sampleRate)
        if let stream = try? audio.startCapture() {
            for await chunk in stream {
                collected.append(contentsOf: chunk)
                onProgress(min(Double(collected.count) / Double(target), 1))
                if collected.count >= target { break }
            }
            audio.stopCapture()
        }

        if wasListening {
            await resume()
        }
        return collected
    }

    /// Tags an inferred cluster with a real name after the fact, returning
    /// the cluster centroid so the caller can persist it as a profile.
    @discardableResult
    public func nameSpeaker(of segment: TranscriptSegment, name: String) -> [Float]? {
        guard let clusterID = segment.speakerClusterID else { return nil }
        clusterer.nameCluster(id: clusterID, name: name)
        speakerClusters = clusterer.clusters
        return clusterer.clusters.first(where: { $0.id == clusterID })?.centroid
    }

    public func displayName(for segment: TranscriptSegment) -> String {
        clusterer.displayName(forClusterID: segment.speakerClusterID)
    }

    /// A saved speaker was renamed; lines already on screen follow.
    public func renameSpeakers(named oldName: String, to newName: String) {
        clusterer.renameClusters(named: oldName, to: newName)
        speakerClusters = clusterer.clusters
    }

    /// A saved speaker was deleted; lines stop showing the name.
    public func forgetSpeakerName(_ name: String) {
        clusterer.forgetName(name)
        speakerClusters = clusterer.clusters
    }

    public func setSpeakerSimilarityThreshold(_ threshold: Float) {
        clusterer.similarityThreshold = threshold
    }

    // MARK: - Tokens

    /// Commits segments the engine never marked final once they've been
    /// quiet long enough. Called on a timer while listening; exposed so
    /// tests can drive it with a controlled clock.
    public func commitStaleSegments(now override: TimeInterval? = nil) {
        let committed = stabilizer.commitStale(now: override ?? now())
        for segment in committed {
            upsert(segment)
            stats.segmentsCommitted += 1
        }
        if !committed.isEmpty {
            stats.hasOpenLine = stabilizer.segments.contains { !$0.isCommitted }
        }
    }

    private func handle(token: TranscriptToken) {
        stats.tokensReceived += 1
        stats.lastTokenAt = now()
        // A brand-new utterance with nothing to show yet isn't worth an
        // (empty) row on screen; wait for text before creating it.
        let isKnown = stabilizer.segments.contains { $0.id == token.utteranceID }
        if !isKnown && token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        var enriched = token
        if enriched.speakerClusterID == nil {
            if let assigned = utteranceClusterAssignments[token.utteranceID] {
                enriched.speakerClusterID = assigned
            } else if !isKnown, let recent = recentSpeechCluster, now() - recent.at <= Self.recentSpeechClusterSeconds {
                enriched.speakerClusterID = recent.id
                utteranceClusterAssignments[token.utteranceID] = recent.id
            }
        }
        let wasCommitted = stabilizer.segments.first(where: { $0.id == token.utteranceID })?.isCommitted ?? false
        let segment = stabilizer.ingest(enriched)
        if segment.isCommitted && !wasCommitted {
            stats.segmentsCommitted += 1
        }
        upsert(segment)
        stats.hasOpenLine = stabilizer.segments.contains { !$0.isCommitted }
        scanForKeywords(in: segment)
    }

    private func consumeEmbeddings(_ audioStream: AsyncStream<[Float]>, run: UUID) async {
        var buffer: [Float] = []
        var speechSamples = 0
        let windowSamples = Int(Self.embeddingWindowSeconds * Self.sampleRate)
        for await chunk in audioStream {
            guard runID == run else { return }
            stats.audioChunksReceived += 1
            stats.audioSecondsReceived += Double(chunk.count) / Self.sampleRate
            stats.lastAudioAt = now()

            buffer.append(contentsOf: chunk)
            if embeddingVoiceDetector.isSpeech(chunk) {
                speechSamples += chunk.count
            }
            guard buffer.count >= windowSamples else { continue }
            let window = buffer
            let speechFraction = Double(speechSamples) / Double(window.count)
            buffer.removeAll(keepingCapacity: true)
            speechSamples = 0
            guard speechFraction >= Self.minimumSpeechFractionForEmbedding else { continue }

            guard let embedding = embedder.embed(samples: window, sampleRate: Self.sampleRate) else { continue }
            let clusterCountBefore = clusterer.clusters.count
            let clusterID = clusterer.assign(embedding: embedding)
            if clusterer.clusters.count > clusterCountBefore {
                stats.speakerClustersOpened += 1
            }
            speakerClusters = clusterer.clusters
            recentSpeechCluster = (clusterID, now())

            guard let currentUtteranceID = stabilizer.segments.last(where: { !$0.isCommitted })?.id else { continue }
            utteranceClusterAssignments[currentUtteranceID] = clusterID
            // Writing an unchanged value still tells every observer the
            // transcript changed and redraws the caption list, every 1.5 s
            // of speech; only write when the speaker actually changed.
            if let index = segments.firstIndex(where: { $0.id == currentUtteranceID }),
               segments[index].speakerClusterID != clusterID {
                segments[index].speakerClusterID = clusterID
            }
        }
    }

    private func upsert(_ segment: TranscriptSegment) {
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
    }

    // MARK: - Plumbing

    /// Applies a new hint list to the running engine (and remembers it for
    /// the next start) without restarting — a name added mid-conversation
    /// should help from the next sentence on.
    public func setVocabulary(_ terms: [String]) async {
        let cleaned = VocabularyHints.normalized(terms)
        activeSettings?.vocabulary = cleaned
        guard let currentEngine, phase.isListening || phase == .paused else { return }
        await currentEngine.setVocabulary(cleaned)
    }

    private func cachedEngine(for settings: AppSettings) -> any TranscriptionEngine {
        let key = "\(settings.engine.rawValue)|\(settings.whisperModelVariant)|\(settings.allowServerFallbackForAppleSpeech)"
        if let cached = engineCache[key] { return cached }
        let engine = engineFactory(settings)
        engineCache[key] = engine
        return engine
    }

    private func fail(_ kind: PipelineFailure.Kind, detail: String, engineUnavailability: EngineUnavailability? = nil) {
        tearDownSession()
        let failure = PipelineFailure(kind: kind, detail: detail, engineUnavailability: engineUnavailability)
        phase = .failed(failure)
        scheduleAutoRecovery(for: failure)
    }

    // MARK: - Automatic recovery

    /// Tells the pipeline a phone call (or another app) took or released
    /// the audio session. While it's held no retry runs; when it's
    /// released a failed pipeline gets a fresh set of attempts.
    public func systemInterruptionChanged(active: Bool) {
        systemInterrupted = active
        if active {
            cancelScheduledRetry()
        } else if let failure = phase.failure {
            recovery.reset()
            scheduleAutoRecovery(for: failure)
        }
    }

    private func scheduleAutoRecovery(for failure: PipelineFailure) {
        if let since = listeningSince, now() - since >= recovery.healthyListeningSeconds {
            recovery.reset()
        }
        listeningSince = nil
        cancelScheduledRetry()
        guard !systemInterrupted, let delay = recovery.nextDelay(for: failure) else { return }

        let token = UUID()
        retryToken = token
        scheduledRetry = ScheduledRetry(at: now() + delay, attempt: recovery.attempts)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.retryToken == token, case .failed = self.phase else { return }
            // Detach from this task before retrying: `retry` cancels any
            // scheduled retry, and cancelling the task it's running on
            // would cancel the model download it's about to start.
            self.retryTask = nil
            self.retryToken = nil
            self.scheduledRetry = nil
            await self.retry()
        }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryToken = nil
        scheduledRetry = nil
    }

    private func tearDownSession() {
        runID = UUID()
        stats.soundDetectionRunning = false
        currentEngine = nil
        recentSpeechCluster = nil
        streamTask?.cancel()
        streamTask = nil
        embeddingTask?.cancel()
        embeddingTask = nil
        soundTask?.cancel()
        soundTask = nil
        staleCommitTask?.cancel()
        staleCommitTask = nil
        fanOut?.cancel()
        fanOut = nil
        audio.stopCapture()
    }
}

/// One keyword spotted in one caption line, as shown in the alert strip.
public struct KeywordHit: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let segmentID: UUID
    public let match: KeywordMatch
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), segmentID: UUID, match: KeywordMatch, timestamp: TimeInterval) {
        self.id = id
        self.segmentID = segmentID
        self.match = match
        self.timestamp = timestamp
    }
}
