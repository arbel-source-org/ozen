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

    /// The settings the running (or last-run) session was started with.
    /// Engine/model/language changes need a restart; input changes don't.
    public private(set) var activeSettings: AppSettings?

    public var inputLevel: Float { audio.inputLevel }

    private let audio: any AudioCapturing
    private let engineFactory: @MainActor (AppSettings) -> any TranscriptionEngine
    private let embedder: any SpeakerEmbedding
    private let now: @Sendable () -> TimeInterval
    private var clusterer: EmbeddingClusterer
    private var stabilizer: CaptionStabilizer
    private var engineCache: [String: any TranscriptionEngine] = [:]
    private var fanOut: AudioFanOut?
    private var streamTask: Task<Void, Never>?
    private var embeddingTask: Task<Void, Never>?
    private var staleCommitTask: Task<Void, Never>?
    private var utteranceClusterAssignments: [UUID: Int] = [:]
    /// Every `start()` gets a fresh run id; async continuations from an
    /// earlier run (a progress callback arriving after a restart, say)
    /// compare against it and drop themselves instead of clobbering state.
    private var runID = UUID()

    private static let embeddingWindowSeconds = 1.5
    private static let sampleRate = 16_000.0

    public init(
        audio: any AudioCapturing,
        engineFactory: @escaping @MainActor (AppSettings) -> any TranscriptionEngine,
        embedder: any SpeakerEmbedding,
        clusterer: EmbeddingClusterer = EmbeddingClusterer(),
        stabilizer: CaptionStabilizer = CaptionStabilizer(),
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.audio = audio
        self.engineFactory = engineFactory
        self.embedder = embedder
        self.clusterer = clusterer
        self.stabilizer = stabilizer
        self.now = now
    }

    // MARK: - Lifecycle

    public func start(settings: AppSettings) async {
        guard !phase.isListening, !phase.isTransitioning else { return }
        let run = UUID()
        runID = run
        activeSettings = settings
        clusterer.similarityThreshold = settings.speakerSimilarityThreshold

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

        phase = .startingAudio
        let source: AsyncStream<[Float]>
        do {
            source = try audio.startCapture()
        } catch {
            fail(.audioSessionFailed, detail: String(describing: error))
            return
        }

        let fan = AudioFanOut(source: source, count: 2)
        fanOut = fan
        let tokens = engine.stream(languageCode: settings.languageCode, audio: fan.outputs[0])
        let embedderAudio = fan.outputs[1]

        stats.sessionStartedAt = now()
        phase = .listening

        embeddingTask = Task { [weak self] in
            await self?.consumeEmbeddings(embedderAudio, run: run)
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
        tearDownSession()
        phase = .idle
    }

    public func pause() {
        guard phase.isListening else { return }
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
        tearDownSession()
        phase = .idle
        stats.engineRestarts += 1
        await start(settings: settings)
    }

    /// For the retry button after a failure.
    public func retry() async {
        guard let activeSettings else { return }
        tearDownSession()
        phase = .idle
        await start(settings: activeSettings)
    }

    public func clearTranscript() {
        segments = []
        stabilizer = CaptionStabilizer(silenceCommitThreshold: stabilizer.silenceCommitThreshold)
        utteranceClusterAssignments = [:]
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
    public func refreshInputs() {
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
            enriched.speakerClusterID = utteranceClusterAssignments[token.utteranceID]
        }
        let wasCommitted = stabilizer.segments.first(where: { $0.id == token.utteranceID })?.isCommitted ?? false
        let segment = stabilizer.ingest(enriched)
        if segment.isCommitted && !wasCommitted {
            stats.segmentsCommitted += 1
        }
        upsert(segment)
    }

    private func consumeEmbeddings(_ audioStream: AsyncStream<[Float]>, run: UUID) async {
        var buffer: [Float] = []
        let windowSamples = Int(Self.embeddingWindowSeconds * Self.sampleRate)
        for await chunk in audioStream {
            guard runID == run else { return }
            stats.audioChunksReceived += 1
            stats.audioSecondsReceived += Double(chunk.count) / Self.sampleRate
            stats.lastAudioAt = now()

            buffer.append(contentsOf: chunk)
            guard buffer.count >= windowSamples else { continue }
            let window = buffer
            buffer.removeAll(keepingCapacity: true)

            guard let embedding = embedder.embed(samples: window, sampleRate: Self.sampleRate) else { continue }
            let clusterCountBefore = clusterer.clusters.count
            let clusterID = clusterer.assign(embedding: embedding)
            if clusterer.clusters.count > clusterCountBefore {
                stats.speakerClustersOpened += 1
            }
            speakerClusters = clusterer.clusters

            guard let currentUtteranceID = stabilizer.segments.last(where: { !$0.isCommitted })?.id else { continue }
            utteranceClusterAssignments[currentUtteranceID] = clusterID
            if let index = segments.firstIndex(where: { $0.id == currentUtteranceID }) {
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

    private func cachedEngine(for settings: AppSettings) -> any TranscriptionEngine {
        let key = "\(settings.engine.rawValue)|\(settings.whisperModelVariant)|\(settings.allowServerFallbackForAppleSpeech)"
        if let cached = engineCache[key] { return cached }
        let engine = engineFactory(settings)
        engineCache[key] = engine
        return engine
    }

    private func fail(_ kind: PipelineFailure.Kind, detail: String, engineUnavailability: EngineUnavailability? = nil) {
        tearDownSession()
        phase = .failed(PipelineFailure(kind: kind, detail: detail, engineUnavailability: engineUnavailability))
    }

    private func tearDownSession() {
        runID = UUID()
        streamTask?.cancel()
        streamTask = nil
        embeddingTask?.cancel()
        embeddingTask = nil
        staleCommitTask?.cancel()
        staleCommitTask = nil
        fanOut?.cancel()
        fanOut = nil
        audio.stopCapture()
    }
}
