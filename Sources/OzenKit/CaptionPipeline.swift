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
    public private(set) var phase: PipelinePhase = .idle {
        didSet {
            // Download progress moves many times a second; only a change
            // of step is news.
            guard oldValue.preparationProgress == nil || phase.preparationProgress == nil else { return }
            onPhaseChange?(phase)
        }
    }
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var availableInputs: [AudioInputDescriptor] = []
    public private(set) var selectedInputUID: String?
    public private(set) var activeEngineKind: TranscriptionEngineKind?
    public private(set) var speakerClusters: [SpeakerCluster] = []
    public private(set) var stats = PipelineStats()
    /// Alert sounds heard too faintly to alert, for the diagnostics report.
    public private(set) var soundNearMisses = SoundNearMisses()
    /// The classifier confidence a sound needs to raise an alert.
    public var soundAlertConfidence: Double { soundPolicy.minimumConfidence }
    /// Failures, retries and recoveries in order, for the diagnostics report.
    public private(set) var eventLog = PipelineEventLog()

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
    private var soundsIgnoredUntil: TimeInterval = 0

    /// The settings the running (or last-run) session was started with.
    /// Engine/model/language changes need a restart; input changes don't.
    public private(set) var activeSettings: AppSettings?
    /// Set while a failure is waiting to be retried automatically.
    public private(set) var scheduledRetry: ScheduledRetry?
    /// How long the model download has left at its current pace, while
    /// one runs and there's enough to go on (see `DownloadEstimator`).
    public private(set) var downloadSecondsRemaining: Double?
    @ObservationIgnored private var downloadEstimator = DownloadEstimator()
    /// Called for every new sound alert, e.g. to post a notification while
    /// the app isn't on screen.
    public var onSoundAlert: ((SoundAlert) -> Void)?
    /// Called with the fresh keyword hits in a line, and the line itself.
    public var onKeywordHits: (([KeywordHit], TranscriptSegment) -> Void)?
    /// Called when `phase` moves to another step (not for each bit of
    /// download progress). Runs as the phase is set, before the pipeline
    /// has finished reacting to it: a failure's retry, for one, is lined up
    /// just after.
    public var onPhaseChange: ((PipelinePhase) -> Void)?
    /// A caption line was added or changed, or the transcript was cleared.
    /// For what follows the captions outside the app's own screen (the
    /// lock screen), which SwiftUI's observation doesn't reach while the
    /// app is in the background.
    public var onCaptionsChanged: (() -> Void)?

    public var inputLevel: Float { audio.inputLevel }
    /// The connection as last reported, for diagnostics; nil when unknown.
    public var networkConditions: NetworkConditions? { network?.current }

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
    /// The speaker of the most recent window that held speech. A short reply
    /// ("ken" — "yes") is often over before its caption line exists, so a new
    /// line with no speaker yet takes this one if it is recent.
    private var recentSpeechCluster: (id: Int, at: TimeInterval)?
    private static let minimumSpeechFractionForEmbedding = 0.4
    private static let recentSpeechClusterSeconds: TimeInterval = 4
    /// Every `start()` gets a fresh run id; async continuations from an
    /// earlier run (a progress callback arriving after a restart, say)
    /// compare against it and drop themselves instead of clobbering state.
    private var runID = UUID()
    private var recovery: AutoRecoveryPolicy
    /// Notices capture that died while the screen still says "listening".
    private var audioWatchdog: AudioStallWatchdog
    private var retryTask: Task<Void, Never>?
    private var retryToken: UUID?
    private var listeningSince: TimeInterval?
    /// A phone call (or another app) holds the audio session. Retrying
    /// then would only use up attempts; recovery waits for it to end.
    private var systemInterrupted = false
    private let network: (any NetworkMonitoring)?
    /// The person said this session's model may download over cellular.
    private var cellularDownloadApproved = false
    private var lastNetwork: NetworkConditions?
    private var networkRetryTask: Task<Void, Never>?
    /// Free space on the phone in bytes, or nil when it can't be read.
    private let availableStorageBytes: (@Sendable () -> Int64?)?

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
        audioWatchdog: AudioStallWatchdog = AudioStallWatchdog(),
        network: (any NetworkMonitoring)? = nil,
        availableStorageBytes: (@Sendable () -> Int64?)? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.recovery = recovery
        self.audioWatchdog = audioWatchdog
        self.audio = audio
        self.engineFactory = engineFactory
        self.embedder = embedder
        self.soundDetector = soundDetector
        self.soundPolicy = soundPolicy
        self.clusterer = clusterer
        self.stabilizer = stabilizer
        self.now = now
        self.network = network
        self.availableStorageBytes = availableStorageBytes
        lastNetwork = network?.current
        network?.onChange = { [weak self] conditions in
            self?.networkConditionsChanged(conditions)
        }
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
        // A download that failed earlier and is starting again is timed afresh.
        downloadEstimator.reset()
        downloadSecondsRemaining = nil
        if let megabytes = await engine.pendingDownloadMegabytes() {
            guard runID == run else { return }
            let allowCellular = settings.allowCellularModelDownload || cellularDownloadApproved
            switch ModelDownloadGate.decide(network: network?.current, allowCellular: allowCellular) {
            case .proceed:
                break
            case .waitForWiFi:
                fail(
                    .engineUnavailable,
                    detail: "\(megabytes) MB to download, waiting for Wi-Fi",
                    engineUnavailability: EngineUnavailability(kind: .waitingForWiFi, detail: "cellular or Low Data Mode", downloadMegabytes: megabytes)
                )
                return
            case .offline:
                fail(
                    .engineUnavailable,
                    detail: "\(megabytes) MB to download, no internet connection",
                    engineUnavailability: EngineUnavailability(kind: .modelDownloadFailed, detail: "offline", downloadMegabytes: megabytes)
                )
                return
            }
            if let missing = storageShortfall(forDownloadOf: megabytes) {
                fail(
                    .engineUnavailable,
                    detail: "\(megabytes) MB to download, \(missing) MB more free space needed",
                    engineUnavailability: EngineUnavailability(kind: .notEnoughStorage, detail: "checked before download", downloadMegabytes: megabytes, missingMegabytes: missing)
                )
                return
            }
        }
        let availability = await engine.prepare(languageCode: settings.languageCode) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.runID == run, case .preparingEngine = self.phase else { return }
                self.phase = .preparingEngine(progress)
                self.trackDownload(progress)
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
        eventLog.record(.listening, at: now())
        listeningSince = now()
        audioWatchdog.reset()

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
                try? await Task.sleep(for: .seconds(AudioStallWatchdog.tickSeconds))
                guard let self, self.runID == run else { return }
                self.commitStaleSegments()
                self.checkAudioIsArriving()
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

    /// iOS is short of memory and ends the biggest apps first; a loaded
    /// speech model makes this one of the biggest. The warning goes in the
    /// diagnostics timeline, since an app iOS ended leaves no other trace.
    /// With captions not running, the engine kept loaded for a quick start
    /// is let go too: the next start spends a few seconds loading the model
    /// again, where iOS ending the app would lose the conversation on
    /// screen. While captions run, or are paused to be resumed, it stays.
    public func handleMemoryWarning(footprintBytes: Int64? = nil) {
        eventLog.record(.memoryWarning(footprintMegabytes: footprintBytes.map { Int($0 / 1_048_576) }), at: now())
        switch phase {
        case .idle:
            engineCache.removeAll()
        case .failed where scheduledRetry == nil:
            engineCache.removeAll()
        default:
            break
        }
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
    /// Starts again after a failure. Anything but a failure is left alone:
    /// retrying in the middle of a start would begin a second model
    /// download or load on the same engine while the first is still going.
    public func retry() async {
        guard case .failed = phase, let activeSettings else { return }
        cancelScheduledRetry()
        tearDownSession()
        phase = .idle
        await start(settings: activeSettings)
    }

    public func clearTranscript() {
        segments = []
        defer { onCaptionsChanged?() }
        stabilizer = CaptionStabilizer(silenceCommitThreshold: stabilizer.silenceCommitThreshold)
        startNewConversation()
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

    /// Stops taking a buzz for a sound while the phone vibrates for an
    /// alert, and for a moment after, since the classifier reports what it
    /// heard a little late. A phone buzzing on a table is, to the
    /// classifier, a phone ringing or an alarm clock: without this the
    /// vibration raises an alert of its own, which vibrates again. Only
    /// `SoundEventCatalog.vibrationLookalikes` are ignored; a siren, a smoke
    /// alarm or the doorbell in the same moment still comes through.
    public func ignoreSounds(whileVibrating vibration: AlertVibration) {
        soundsIgnoredUntil = max(soundsIgnoredUntil, now() + vibration.totalSeconds + Self.soundReportDelaySeconds)
    }

    /// How long after a sound the classifier may still be reporting it: its
    /// window is about a second long.
    static let soundReportDelaySeconds: TimeInterval = 1.5

    private func handle(soundObservation observation: SoundObservation) {
        // Judged by when the classifier produced the reading, not when it
        // got here, and dropped before the policy, so the phone's own buzz
        // doesn't start a cooldown that would hide a real ring right after.
        if observation.timestamp < soundsIgnoredUntil,
           SoundEventCatalog.vibrationLookalikes.contains(observation.identifier) {
            return
        }
        soundNearMisses.record(observation, alertConfidence: soundPolicy.minimumConfidence)
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

    /// Switches to the input `uid`. Returns whether that input is the one
    /// in use afterwards: the system can refuse it, or settle on another.
    @discardableResult
    public func selectInput(uid: String) -> Bool {
        do {
            try audio.selectInput(uid: uid)
            stats.inputChanges += 1
            syncInputs()
        } catch {
            // A failed switch leaves the previous input active, which is
            // strictly better than dropping a live conversation over a mic
            // the system refused. The caller says so on screen.
        }
        return selectedInputUID == uid
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
        // Made the way live speech is matched: 1.5 s windows, only those
        // with enough speech in them, averaged. One print of the whole
        // recording mixed the pauses between sentences into the voice,
        // and a recording nobody spoke in still became a "voice".
        var sum: [Float] = []
        var count = 0
        for window in Self.speechWindows(in: samples) {
            // A print with a NaN in it can't be compared, and can't be
            // saved either (JSON has no NaN): one would make every later
            // settings save fail.
            guard let embedding = embedder.embed(samples: window, sampleRate: Self.sampleRate),
                  !embedding.isEmpty,
                  embedding.allSatisfy(\.isFinite),
                  sum.isEmpty || embedding.count == sum.count
            else { continue }
            if sum.isEmpty {
                sum = embedding
            } else {
                for index in sum.indices { sum[index] += embedding[index] }
            }
            count += 1
        }
        guard count >= Self.minimumEnrollmentWindows else { return nil }
        return sum.map { $0 / Float(count) }
    }

    /// How far past its length an enrollment recording may run before it
    /// is given up on.
    var enrollmentStallSeconds: Double = 5

    /// A voice print needs this many windows of speech, about 4.5 seconds
    /// of someone talking, to be worth keeping.
    static let minimumEnrollmentWindows = 3

    /// `samples` cut into embedding windows, keeping those that hold as
    /// much speech as live matching asks for. Fed through a voice detector
    /// in chunks about the size the microphone delivers.
    static func speechWindows(in samples: [Float]) -> [[Float]] {
        let chunkSize = 800
        let windowSamples = Int(embeddingWindowSeconds * sampleRate)
        var detector = EnergyVoiceDetector()
        var windows: [[Float]] = []
        var buffer: [Float] = []
        var speechSamples = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let chunk = Array(samples[offset..<end])
            buffer.append(contentsOf: chunk)
            if detector.isSpeech(chunk) {
                speechSamples += chunk.count
            }
            if buffer.count >= windowSamples {
                if Double(speechSamples) / Double(buffer.count) >= minimumSpeechFractionForEmbedding {
                    windows.append(buffer)
                }
                buffer.removeAll(keepingCapacity: true)
                speechSamples = 0
            }
            offset = end
        }
        return windows
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
        if let stream = await enrollmentCapture() {
            // A microphone that stops delivering would keep the recording
            // screen up for good, its cancel button disabled. Stopping
            // capture ends the stream, and a short recording is refused
            // like a quiet one.
            let deadline = Task { @MainActor [audio, enrollmentStallSeconds] in
                try? await Task.sleep(for: .seconds(seconds + enrollmentStallSeconds))
                guard !Task.isCancelled else { return }
                audio.stopCapture()
            }
            for await chunk in stream {
                collected.append(contentsOf: chunk)
                onProgress(min(Double(collected.count) / Double(target), 1))
                if collected.count >= target { break }
            }
            deadline.cancel()
            audio.stopCapture()
        }

        if wasListening {
            await resume()
        }
        return collected
    }

    /// Starts capture for enrollment. Captions may never have run since the
    /// app opened (it's done from Settings), and then there is no audio
    /// session to capture from: set one up first, instead of recording
    /// nothing and blaming a quiet room.
    private func enrollmentCapture() async -> AsyncStream<[Float]>? {
        if let stream = try? audio.startCapture() { return stream }
        guard await audio.requestPermission() == .granted else { return nil }
        let preferredInput = activeSettings?.preferredInputUID ?? audio.selectedInputUID
        guard (try? audio.prepareSession(preferredInputUID: preferredInput)) != nil else { return nil }
        return try? audio.startCapture()
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

    /// A conversation ended: the next one's unnamed voices are numbered
    /// from 1 again (see `EmbeddingClusterer.startNewConversation`), and the
    /// record of which finished line belongs to whom is let go.
    public func startNewConversation() {
        clusterer.startNewConversation()
        speakerClusters = clusterer.clusters
        recentSpeechCluster = nil
        utteranceClusterAssignments = [:]
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
        // Searched from the end, where the line being written is: a phone
        // left listening for days holds thousands of lines.
        let isKnown = stabilizer.segments.lastIndex { $0.id == token.utteranceID } != nil
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
        let wasCommitted = stabilizer.segments.last(where: { $0.id == token.utteranceID })?.isCommitted ?? false
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
            let isSpeech = embeddingVoiceDetector.isSpeech(chunk)
            stats.inputLevels.add(rms: embeddingVoiceDetector.lastLevel)
            if isSpeech {
                speechSamples += chunk.count
                stats.speechChunks += 1
            }
            guard buffer.count >= windowSamples else { continue }
            let window = buffer
            let speechFraction = Double(speechSamples) / Double(window.count)
            buffer.removeAll(keepingCapacity: true)
            speechSamples = 0
            guard speechFraction >= Self.minimumSpeechFractionForEmbedding else { continue }

            // A few hundred spectrum frames per window: real work, done off
            // the main thread so the caption screen stays smooth while
            // people talk. Chunks arriving meanwhile wait in the stream.
            let embedder = self.embedder
            let sampleRate = Self.sampleRate
            let computed = await Task.detached(priority: .userInitiated) {
                embedder.embed(samples: window, sampleRate: sampleRate)
            }.value
            guard runID == run else { return }
            // A glitched buffer can make NaNs; one NaN centroid would never
            // match anything again and open a new "speaker" every window.
            guard let embedding = computed, embedding.allSatisfy(\.isFinite) else { continue }
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
            if let index = segments.lastIndex(where: { $0.id == currentUtteranceID }),
               segments[index].speakerClusterID != clusterID {
                segments[index].speakerClusterID = clusterID
            }
        }
    }

    private func upsert(_ segment: TranscriptSegment) {
        if let index = segments.lastIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
        onCaptionsChanged?()
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

    private func trackDownload(_ progress: EnginePreparationProgress) {
        guard progress.stage == .downloadingModel, let fraction = progress.fraction else {
            downloadEstimator.reset()
            downloadSecondsRemaining = nil
            return
        }
        downloadEstimator.record(fraction: fraction, at: now())
        downloadSecondsRemaining = downloadEstimator.secondsRemaining()
    }

    private func cachedEngine(for settings: AppSettings) -> any TranscriptionEngine {
        let key = "\(settings.engine.rawValue)|\(settings.whisperModelVariant)|\(settings.allowServerFallbackForAppleSpeech)"
        if let cached = engineCache[key] { return cached }
        // Only the engine in use is kept. A Whisper engine holds its loaded
        // model, hundreds of megabytes to 3 GB; every model tried once in
        // the model list used to stay loaded for as long as the app ran,
        // until iOS ended the app for using too much memory. Going back to
        // an earlier one loads it again, which takes seconds; restarts and
        // retries on the same settings still reuse it.
        engineCache.removeAll()
        let engine = engineFactory(settings)
        engineCache[key] = engine
        return engine
    }

    /// A tap that stopped delivering (see `AudioStallWatchdog`) becomes a
    /// visible failure, which automatic recovery answers with a fresh
    /// audio engine: the same thing a manual stop and start would do.
    private func checkAudioIsArriving() {
        guard phase.isListening else { return }
        guard audioWatchdog.tick(chunksReceived: stats.audioChunksReceived, systemInterrupted: systemInterrupted) else { return }
        stats.audioStalls += 1
        eventLog.record(.microphoneStalled, at: now())
        fail(.audioSessionFailed, detail: "no audio from the microphone for \(Int(audioWatchdog.stallSeconds)) s")
    }

    private func fail(_ kind: PipelineFailure.Kind, detail: String, engineUnavailability: EngineUnavailability? = nil) {
        tearDownSession()
        let failure = PipelineFailure(kind: kind, detail: detail, engineUnavailability: engineUnavailability)
        phase = .failed(failure)
        eventLog.record(.failed(failure), at: now())
        scheduleAutoRecovery(for: failure)
    }

    // MARK: - Downloads and the network

    /// "Download now anyway": this session's model may use cellular data.
    public func approveCellularDownload() async {
        cellularDownloadApproved = true
        guard isWaitingForWiFi else { return }
        await retry()
    }

    /// The Settings switch for downloading over cellular changed.
    public func setAllowCellularModelDownload(_ allowed: Bool) async {
        activeSettings?.allowCellularModelDownload = allowed
        guard allowed, isWaitingForWiFi else { return }
        await retry()
    }

    /// The app is back on screen. If the model was waiting for room on the
    /// phone and there is room now (she freed some up in the Settings
    /// app), the download starts without anyone having to tap.
    public func appDidBecomeActive() async {
        guard let why = phase.failure?.engineUnavailability,
              why.kind == .notEnoughStorage,
              !phase.isTransitioning
        else { return }
        if let megabytes = why.downloadMegabytes, storageShortfall(forDownloadOf: megabytes) != nil {
            return
        }
        await retry()
    }

    private func storageShortfall(forDownloadOf megabytes: Int) -> Int? {
        StorageSpaceGate.shortfallMegabytes(downloadMegabytes: megabytes, availableBytes: availableStorageBytes?())
    }

    private var isWaitingForWiFi: Bool {
        phase.failure?.engineUnavailability?.kind == .waitingForWiFi
    }

    /// A download that was waiting for Wi-Fi, or failed for want of a
    /// connection, starts as soon as the connection allows it, without
    /// waiting out the retry timer.
    private func networkConditionsChanged(_ conditions: NetworkConditions) {
        let allowCellular = (activeSettings?.allowCellularModelDownload ?? false) || cellularDownloadApproved
        let wasUsable = lastNetwork.map { ModelDownloadGate.canRetryDownload(on: $0, allowCellular: allowCellular) } ?? false
        lastNetwork = conditions
        guard !wasUsable,
              ModelDownloadGate.canRetryDownload(on: conditions, allowCellular: allowCellular),
              networkRetryTask == nil,
              let kind = phase.failure?.engineUnavailability?.kind,
              kind == .waitingForWiFi || kind == .modelDownloadFailed
        else { return }
        recovery.reset()
        networkRetryTask = Task { [weak self] in
            await self?.retry()
            self?.networkRetryTask = nil
        }
    }

    // MARK: - Automatic recovery

    /// Tells the pipeline a phone call (or another app) took or released
    /// the audio session. While it's held no retry runs; when it's
    /// released a failed pipeline gets a fresh set of attempts.
    public func systemInterruptionChanged(active: Bool) {
        if active != systemInterrupted {
            eventLog.record(.phoneCall(began: active), at: now())
        }
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
        eventLog.record(.retryScheduled(attempt: recovery.attempts, afterSeconds: delay), at: now())
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
        finishOpenLines()
    }

    /// The words of a line cut off mid-sentence (paused, stopped, the
    /// microphone failed) are as final as they will get. Left open, the
    /// line stayed dimmed like text still arriving, was saved unfinished,
    /// and was never read out to VoiceOver.
    private func finishOpenLines() {
        let finished = stabilizer.commitAll()
        guard !finished.isEmpty else { return }
        for segment in finished {
            upsert(segment)
            stats.segmentsCommitted += 1
        }
        stats.hasOpenLine = false
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
