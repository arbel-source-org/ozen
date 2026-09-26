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
            noteStep(from: oldValue)
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
    /// Lines finished since launch, as `stats.segmentsCommitted`, but
    /// observed on its own: `stats` changes with every chunk of audio, and
    /// a caption screen that read it to hear of finished lines was drawn
    /// again ten or more times a second, silence included.
    public private(set) var committedLineCount = 0
    /// When listening last began, as `stats.sessionStartedAt`, observed on
    /// its own for the same reason.
    public private(set) var listeningStartedAt: TimeInterval?
    /// Alert sounds heard too faintly to alert, for the diagnostics report.
    public private(set) var soundNearMisses = SoundNearMisses()
    /// The classifier confidence a sound needs to raise an alert.
    public var soundAlertConfidence: Double { soundPolicy.minimumConfidence }
    /// Failures, retries and recoveries in order, for the diagnostics report.
    public private(set) var eventLog = PipelineEventLog()
    /// Called with each event as it is kept, for the journal on disk.
    public var onEvent: ((PipelineEvent) -> Void)?
    @ObservationIgnored private var stepBeganAt: TimeInterval?

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
    /// Cloud captions stopped for something only a person can fix (no
    /// key, no credit) or no internet, and the phone's own model, already
    /// downloaded, took over. Lasts until captions are next started with
    /// the chosen settings; the saved choice itself is never changed.
    public private(set) var isCoveringForCloud = false
    /// Why the phone's model took over, while it covers: a refused home
    /// server pairing code needs someone to re-enter it, an unreachable
    /// server doesn't.
    public private(set) var coverReason: EngineUnavailability.Kind?
    /// While the phone covers for a home computer it couldn't reach, how
    /// often to look whether the computer is back. Without it a single
    /// dropped connection kept a phone that is never stopped on its own
    /// model for good.
    public var homeServerRecheckSeconds: Double = 60
    /// Only switch back after this long without new words, so a sentence
    /// isn't cut in half.
    public var homeServerSwitchBackQuietSeconds: Double = 2
    private var coveredSettings: AppSettings?
    private var homeServerRecheck: Task<Void, Never>?
    /// The room the last download refused for want of space needed, so a
    /// return to the app only retries once that much is free.
    private var storageNeededMegabytes: Int?
    private var nextStartCoversCloud = false
    /// Set while a failure is waiting to be retried automatically.
    public private(set) var scheduledRetry: ScheduledRetry?
    /// How long the model download has left at its current pace, while
    /// one runs and there's enough to go on (see `DownloadEstimator`).
    public private(set) var downloadSecondsRemaining: Double?
    /// When the preparation progress on screen was last replaced.
    @ObservationIgnored private var progressShownAt: TimeInterval = -.infinity
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
    private var silencePhraseGuard = SilencePhraseGuard()
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
        isCoveringForCloud = nextStartCoversCloud
        nextStartCoversCloud = false
        if !isCoveringForCloud {
            coverReason = nil
            coveredSettings = nil
            homeServerRecheck?.cancel()
            homeServerRecheck = nil
        }
        storageNeededMegabytes = nil
        // The stored threshold is the person's own choice once they've
        // touched it, but at the untouched app default it's specifically
        // calibrated for CAM++; a silent fallback to a different embedder
        // (see SpeakerEmbedding.recommendedSimilarityThreshold) needs its
        // own default instead of inheriting one tuned for a completely
        // different score scale.
        clusterer.similarityThreshold = settings.speakerSimilarityThreshold == AppSettings.default.speakerSimilarityThreshold
            ? embedder.recommendedSimilarityThreshold
            : settings.speakerSimilarityThreshold
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
            // The room it needs, not only the download: a model compiled on
            // the phone needs about twice its download for a while, and
            // checking the download alone let one start that couldn't finish.
            let neededMegabytes = await engine.pendingInstallMegabytes() ?? megabytes
            guard runID == run else { return }
            if let missing = storageShortfall(forDownloadOf: neededMegabytes) {
                storageNeededMegabytes = neededMegabytes
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
                guard let self, self.runID == run, case .preparingEngine(let shown) = self.phase else { return }
                let time = self.now()
                guard progress.isNews(after: shown, shownAt: self.progressShownAt, now: time) else { return }
                self.progressShownAt = time
                self.phase = .preparingEngine(progress)
                self.trackDownload(progress, at: time)
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

        let fan = AudioFanOut(source: source, count: soundDetector == nil ? 2 : 3) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.runID == run else { return }
                self.stats.glitchedAudioChunks += 1
            }
        }
        fanOut = fan
        let tokens = engine.stream(languageCode: settings.languageCode, audio: fan.outputs[0])
        let embedderAudio = fan.outputs[1]
        let soundObservations = soundDetector.map { $0.observations(audio: fan.outputs[2]) }

        stats.sessionStartedAt = now()
        listeningStartedAt = stats.sessionStartedAt
        phase = .listening
        logEvent(.listening)
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
            var knownFailure: EngineUnavailability?
            var stopReason: String? = nil
            do {
                for try await token in tokens {
                    guard self.runID == run else { break }
                    self.handle(token: token)
                }
            } catch let error as CloudSpeechError {
                knownFailure = error.unavailability
                stopReason = String(describing: error)
            } catch let error as EngineUnavailability {
                knownFailure = error
                stopReason = error.detail
            } catch {
                stopReason = String(describing: error)
            }
            // Reaching here while still "listening" means the engine gave up
            // on its own (recognizer error, model crash) while audio is
            // still flowing. That's a failure the user should see and be
            // able to retry, not a silent stop.
            guard self.runID == run, self.phase.isListening else { return }
            // A mid-stream failure the engine already named (a rejected
            // key, no credit, the home server gone) -- reporting it
            // generically would show the wrong message, let
            // AutoRecoveryPolicy auto-retry a problem only a person can fix,
            // and keep CloudCover from handing over to the phone.
            if let knownFailure {
                self.fail(.engineUnavailable, detail: stopReason ?? "engine stream ended", engineUnavailability: knownFailure)
            } else {
                self.fail(.transcriptionStopped, detail: stopReason ?? "engine stream ended")
            }
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
        homeServerRecheck?.cancel()
        homeServerRecheck = nil
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
        logEvent(.memoryWarning(footprintMegabytes: footprintBytes.map { Int($0 / 1_048_576) }))
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

    /// `settings` defaults to the snapshot from the last `start(settings:)`,
    /// but a caller that tracks its own live settings (the app's view
    /// model) should pass its current value: any engine, model, keyword
    /// alert, sound preference, or speaker threshold change made while
    /// paused would otherwise vanish on resume, silently restarting with
    /// whatever was in effect before the pause.
    public func resume(settings: AppSettings? = nil) async {
        guard phase == .paused, var effective = settings ?? activeSettings else { return }
        // A pause is not a new start: the phone's model that was covering
        // for the cloud (the caller's settings still say cloud) carries on,
        // rather than trying the cloud again and reloading the model.
        if isCoveringForCloud, effective.engine == .cloud {
            effective.engine = .whisperKit
            nextStartCoversCloud = true
        }
        phase = .idle
        await start(settings: effective)
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
    /// See `resume(settings:)`: defaults to the last-started snapshot, but
    /// a caller with its own live settings should pass the current value
    /// so a change made while failed isn't silently dropped on retry.
    public func retry(settings: AppSettings? = nil) async {
        guard case .failed = phase, let effective = settings ?? activeSettings else { return }
        cancelScheduledRetry()
        tearDownSession()
        // Straight from the failure to starting, never through .idle, which
        // means stopped on purpose (the "captions came back" announcement
        // forgets the failure there).
        await start(settings: effective)
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
        soundNearMisses.record(observation, alertConfidence: soundPolicy.requiredConfidence(for: observation.identifier))
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
        let previous = selectedInputUID
        selectedInputUID = audio.selectedInputUID
        if selectedInputUID != previous, let input = availableInputs.first(where: { $0.uid == selectedInputUID }) {
            journalOnly(.input(name: input.portName, type: input.portType))
        }
    }

    /// What the running engine says about its own work; see
    /// `TranscriptionEngine.diagnosticsSummary`.
    public func engineDiagnostics() async -> String? {
        await currentEngine?.diagnosticsSummary()
    }

    private func logEvent(_ kind: PipelineEvent.Kind) {
        let count = eventLog.events.count
        let last = eventLog.events.last
        eventLog.record(kind, at: now())
        if let event = eventLog.events.last, eventLog.events.count != count || event != last {
            onEvent?(event)
        }
    }

    /// Steps and microphone changes would crowd the short in-memory log out
    /// of the failures it is there to tell in order; the journal has room.
    private func journalOnly(_ kind: PipelineEvent.Kind) {
        onEvent?(PipelineEvent(at: now(), kind: kind))
    }

    /// A line for each step of getting ready, with how long the one before
    /// took. Download percentages aren't steps.
    private func noteStep(from old: PipelinePhase) {
        let name = Self.stepName(phase)
        guard name != Self.stepName(old) else { return }
        let time = now()
        let took = stepBeganAt.map { time - $0 }
        stepBeganAt = time
        // Listening, failures and pauses have their own, fuller lines.
        guard phase.isTransitioning else { return }
        journalOnly(.step(name, afterSeconds: old.isTransitioning ? took : nil))
    }

    private static func stepName(_ phase: PipelinePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .requestingMicrophonePermission: return "asking for the microphone"
        case .preparingEngine(let progress):
            let model = progress.detail.map { " \($0)" } ?? ""
            return "engine: \(progress.stage.rawValue)\(model)\(progress.isFirstTime ? " (first time on this phone)" : "")"
        case .startingAudio: return "starting audio"
        case .listening: return "listening"
        case .paused: return "paused"
        case .failed: return "failed"
        }
    }

    // MARK: - Speakers

    /// What the active embedder's output looks like: what it declares, or
    /// else probed on silence (enrollment is rare, not on the hot audio
    /// path). Declaring it matters: this runs at launch, on the main
    /// thread, and a probe loads the model.
    /// A profile saved by a since-replaced embedder (see
    /// `EmbeddingClusterer.assign`) is a different length and can never be
    /// matched against live speech; seeding it anyway would still count as
    /// a real "speaker identified" in diagnostics forever.
    private var expectedEmbeddingLength: Int? {
        if let length = embedder.embeddingLength { return length }
        return embedder.embed(
            samples: [Float](repeating: 0, count: Int(Self.embeddingWindowSeconds * Self.sampleRate)),
            sampleRate: Self.sampleRate
        )?.count
    }

    /// Seeds the clusterer with a saved profile so that person is named
    /// from their first utterance. Does nothing for a profile whose voice
    /// print predates the current embedder — see `expectedEmbeddingLength`.
    public func enroll(profile: SpeakerProfile) {
        guard expectedEmbeddingLength == nil || profile.embedding.count == expectedEmbeddingLength else { return }
        profileClusters[profile.id] = clusterer.enroll(name: profile.name, embedding: profile.embedding)
        speakerClusters = clusterer.clusters
    }

    /// Which voice each saved profile was seeded as, so deleting one of
    /// several prints under the same name stops that one being listened for.
    private var profileClusters: [UUID: Int] = [:]

    /// A saved voice print was deleted while the person keeps another one:
    /// the deleted print (a recording of the wrong person, say) no longer
    /// puts their name on anyone for the rest of this session.
    public func forgetProfile(id: UUID) {
        guard let clusterID = profileClusters.removeValue(forKey: id) else { return }
        clusterer.forgetName(ofCluster: clusterID)
        speakerClusters = clusterer.clusters
    }

    /// Computes an embedding from an enrollment recording, or nil if the
    /// recording was too short to say anything about the voice.
    public func embedding(forEnrollmentSamples samples: [Float]) -> [Float]? {
        Self.averagePrint(of: Self.speechWindows(in: samples), embedder: embedder, sampleRate: Self.sampleRate)
    }

    /// The same, with the model run off the main thread. Enrolling can be
    /// the first time the speaker model is needed, and its first load can
    /// take seconds: the screen stays responsive meanwhile.
    public func embeddingInBackground(forEnrollmentSamples samples: [Float]) async -> [Float]? {
        let windows = Self.speechWindows(in: samples)
        let embedder = self.embedder
        let sampleRate = Self.sampleRate
        return await Task.detached(priority: .userInitiated) {
            Self.averagePrint(of: windows, embedder: embedder, sampleRate: sampleRate)
        }.value
    }

    nonisolated private static func averagePrint(of windows: [[Float]], embedder: any SpeakerEmbedding, sampleRate: Double) -> [Float]? {
        // Made the way live speech is matched: 1.5 s windows, only those
        // with enough speech in them, averaged. One print of the whole
        // recording mixed the pauses between sentences into the voice,
        // and a recording nobody spoke in still became a "voice".
        var sum: [Float] = []
        var count = 0
        for window in windows {
            // A print with a NaN in it can't be compared, and can't be
            // saved either (JSON has no NaN): one would make every later
            // settings save fail.
            guard let embedding = embedder.embed(samples: window, sampleRate: sampleRate),
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
        guard count >= minimumEnrollmentWindows else { return nil }
        return sum.map { $0 / Float(count) }
    }

    /// How far past its length an enrollment recording may run before it
    /// is given up on.
    var enrollmentStallSeconds: Double = 5

    /// A voice print needs this many windows of speech, about 4.5 seconds
    /// of someone talking, to be worth keeping.
    nonisolated static let minimumEnrollmentWindows = 3

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
                collected.append(contentsOf: AudioFanOut.withoutGlitches(chunk))
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

    #if DEBUG
    /// A canned conversation for UI screenshot tests: one named speaker,
    /// one not yet named, a starred line, a number-emphasis line and a
    /// still-pending one — bypassing audio, the engine and the embedder
    /// entirely. Debug builds only; never reachable from a release build.
    /// Returns the segments, so a caller can star one by id.
    @discardableResult
    public func seedForScreenshots() -> [TranscriptSegment] {
        let namedID = clusterer.enroll(name: tr("דנה", "Dana"), embedding: [1, 0, 0])
        let strangerID = clusterer.assign(embedding: [0, 1, 0])
        speakerClusters = clusterer.clusters

        let now = Date().timeIntervalSince1970
        segments = [
            TranscriptSegment(
                id: UUID(), text: tr("בוקר טוב, איך ישנת הלילה?", "Good morning, how did you sleep?"),
                isCommitted: true, speakerClusterID: namedID,
                startTimestamp: now, lastUpdateTimestamp: now, confidence: 0.95
            ),
            TranscriptSegment(
                id: UUID(),
                text: tr(
                    "די טוב, תודה. יש לי תור לרופא ב-10:30 ואני צריכה לקחת שני כדורים לפני.",
                    "Pretty good, thanks. I have a doctor's appointment at 10:30 and I need to take two pills before."
                ),
                isCommitted: true, speakerClusterID: strangerID,
                startTimestamp: now + 4, lastUpdateTimestamp: now + 4, confidence: 0.3
            ),
            TranscriptSegment(
                id: UUID(), text: tr("אני יכולה לקחת אותך, אין בעיה.", "I can take you, no problem."),
                isCommitted: true, speakerClusterID: namedID,
                startTimestamp: now + 9, lastUpdateTimestamp: now + 9, confidence: 0.9
            ),
            TranscriptSegment(
                id: UUID(), text: tr("עוד לא ברור לי אם", "I'm still not sure if"),
                isCommitted: false, speakerClusterID: strangerID,
                startTimestamp: now + 13, lastUpdateTimestamp: now + 13, confidence: nil
            ),
        ]
        committedLineCount = 3
        activeEngineKind = .whisperKit
        listeningStartedAt = now
        phase = .listening
        keywordHits = [
            KeywordHit(
                segmentID: segments[1].id,
                match: KeywordMatch(alertID: UUID(), phrase: tr("תרופות", "medications"), matchedText: tr("שני כדורים", "two pills"), wordIndex: 0),
                timestamp: now + 4
            )
        ]
        // Mirrors what scanForKeywords does for a real match: the caption
        // row's highlight and bell icon key off this set, not off
        // keywordHits itself.
        keywordHitSegmentIDs = [segments[1].id]
        return segments
    }
    #endif

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
            countCommittedLine()
        }
        if !committed.isEmpty {
            stats.hasOpenLine = stabilizer.segments.contains { !$0.isCommitted }
        }
    }

    private func handle(token incoming: TranscriptToken) {
        stats.tokensReceived += 1
        // ivrit.ai's model starts some lines with an invisible direction
        // mark; kept, it would travel into saved conversations and search.
        let cleaned = HebrewText.removingDirectionMarks(incoming.text)
        let token = cleaned == incoming.text ? incoming : TranscriptToken(
            utteranceID: incoming.utteranceID,
            text: cleaned,
            isFinal: incoming.isFinal,
            timestamp: incoming.timestamp,
            speakerClusterID: incoming.speakerClusterID,
            confidence: incoming.confidence,
            startsNewSpeakerTurn: incoming.startsNewSpeakerTurn,
            uncertainWords: incoming.uncertainWords.map(HebrewText.removingDirectionMarks)
        )
        stats.lastTokenAt = now()
        // A brand-new utterance with nothing to show yet isn't worth an
        // (empty) row on screen; wait for text before creating it.
        // Searched from the end, where the line being written is: a phone
        // left listening for days holds thousands of lines.
        let isKnown = stabilizer.segments.lastIndex { $0.id == token.utteranceID } != nil
        if !isKnown && token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        // "toda. toda. toda." ("thanks") invented window after window on a
        // quiet room: see `SilencePhraseGuard`. Suppressing this token
        // still must not swallow a true final: the words already shown
        // are good, so commit them now instead of leaving the line
        // "still settling" until the stale-commit safety net catches up.
        guard silencePhraseGuard.admits(token, at: now()) else {
            if token.isFinal, let segment = stabilizer.commit(id: token.utteranceID) {
                upsert(segment)
                countCommittedLine()
                stats.hasOpenLine = stabilizer.segments.contains { !$0.isCommitted }
            }
            return
        }
        var enriched = token
        if enriched.speakerClusterID == nil {
            if let assigned = utteranceClusterAssignments[token.utteranceID] {
                enriched.speakerClusterID = assigned
            } else if !isKnown, !token.startsNewSpeakerTurn, let recent = recentSpeechCluster, now() - recent.at <= Self.recentSpeechClusterSeconds {
                enriched.speakerClusterID = recent.id
                utteranceClusterAssignments[token.utteranceID] = recent.id
            }
        }
        let wasCommitted = stabilizer.segments.last(where: { $0.id == token.utteranceID })?.isCommitted ?? false
        let segment = stabilizer.ingest(enriched)
        if segment.isCommitted && !wasCommitted {
            countCommittedLine()
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
            if embeddingVoiceDetector.noiseFloor > 0 {
                stats.noiseFloorDecibels = Double(20 * log10(embeddingVoiceDetector.noiseFloor))
            }
            stats.noiseMarginDecibels = Double(20 * log10(embeddingVoiceDetector.currentNoiseFloorRatio))
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
            // The line being written while this audio was heard, taken now:
            // the first embedding loads the model and can take many seconds,
            // and asking afterwards gave the voice to whichever line had
            // started meanwhile, leaving the speaker's own line unnamed.
            let heardDuring = stabilizer.segments.last(where: { !$0.isCommitted })?.id
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

            guard let currentUtteranceID = heardDuring else { continue }
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

    private func countCommittedLine() {
        stats.segmentsCommitted += 1
        committedLineCount += 1
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

    private func trackDownload(_ progress: EnginePreparationProgress, at time: TimeInterval) {
        guard progress.stage == .downloadingModel, let fraction = progress.fraction else {
            downloadEstimator.reset()
            downloadSecondsRemaining = nil
            return
        }
        downloadEstimator.record(fraction: fraction, at: time)
        downloadSecondsRemaining = downloadEstimator.secondsRemaining()
    }

    private func cachedEngine(for settings: AppSettings) -> any TranscriptionEngine {
        let key = "\(settings.engine.rawValue)|\(settings.whisperModelVariant)|\(settings.allowServerFallbackForAppleSpeech)|\(settings.cloudModel)|\(settings.homeServerAddress)"
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
        logEvent(.microphoneStalled)
        fail(.audioSessionFailed, detail: "no audio from the microphone for \(Int(audioWatchdog.stallSeconds)) s")
    }

    private func fail(_ kind: PipelineFailure.Kind, detail: String, engineUnavailability: EngineUnavailability? = nil) {
        tearDownSession()
        let failure = PipelineFailure(kind: kind, detail: detail, engineUnavailability: engineUnavailability)
        phase = .failed(failure)
        logEvent(.failed(failure))
        if let settings = activeSettings, let onPhone = CloudCover.phoneSettings(replacing: settings, after: failure) {
            Task { [weak self] in await self?.coverForCloud(with: onPhone, after: failure) }
            return
        }
        scheduleAutoRecovery(for: failure)
    }

    /// See `isCoveringForCloud`. Only a model that is already on the phone
    /// takes over: a surprise download of hundreds of megabytes is not a
    /// fair way to find out the cloud stopped.
    private func coverForCloud(with settings: AppSettings, after failure: PipelineFailure) async {
        // Someone may have stopped, retried or restarted captions since
        // the failure; then the engine cache is theirs to fill, not ours.
        guard case .failed(let before) = phase, before == failure else { return }
        let engine = cachedEngine(for: settings)
        let needsDownload = await engine.pendingDownloadMegabytes() != nil
        guard case .failed(let current) = phase, current == failure else { return }
        guard !needsDownload else {
            scheduleAutoRecovery(for: failure)
            return
        }
        logEvent(.note("cloud unavailable, the phone's own model took over"))
        nextStartCoversCloud = true
        coverReason = failure.engineUnavailability?.kind
        coveredSettings = activeSettings
        await start(settings: settings)
        if coverReason == .homeServerUnreachable, coveredSettings?.engine == .homeServer {
            recheckHomeServer()
        }
    }

    /// See `homeServerRecheckSeconds`. Goes back to the chosen settings
    /// once the computer answers and nobody is mid-sentence.
    private func recheckHomeServer() {
        homeServerRecheck?.cancel()
        homeServerRecheck = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = self?.homeServerRecheckSeconds else { return }
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.isCoveringForCloud,
                      let chosen = self.coveredSettings, chosen.engine == .homeServer
                else { return }
                guard self.phase == .listening else { continue }
                let server = self.cachedEngine(for: chosen)
                guard await server.checkAvailability(languageCode: chosen.languageCode) == .available,
                      !Task.isCancelled, self.isCoveringForCloud, self.phase == .listening,
                      self.isBetweenSentences
                else { continue }
                self.logEvent(.note("the home computer answers again, switching back to it"))
                self.homeServerRecheck = nil
                await self.restart(settings: chosen)
                return
            }
        }
    }

    private var isBetweenSentences: Bool {
        if stabilizer.segments.last.map({ !$0.isCommitted }) ?? false { return false }
        guard let lastTokenAt = stats.lastTokenAt else { return true }
        return now() - lastTokenAt >= homeServerSwitchBackQuietSeconds
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
        if let megabytes = storageNeededMegabytes ?? why.downloadMegabytes, storageShortfall(forDownloadOf: megabytes) != nil {
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
            logEvent(.phoneCall(began: active))
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
        logEvent(.retryScheduled(attempt: recovery.attempts, afterSeconds: delay))
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
            countCommittedLine()
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
