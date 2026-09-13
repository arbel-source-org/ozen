import Foundation
import Observation
import OzenKit
import OzenPlatform

/// What the screens talk to. Owns the persisted settings, the
/// `CaptionPipeline`, and the transcript history store, and is the one
/// place that knows which settings changes need a pipeline restart
/// (engine, model, language, server fallback) and which don't (font size,
/// input, speaker names, keywords, sound alerts). All the real sequencing
/// lives in `CaptionPipeline` (OzenKit, unit tested with fakes); this class
/// is deliberately thin wiring.
@MainActor
@Observable
public final class LiveCaptionViewModel {
    public let pipeline: CaptionPipeline
    public let historyStore: TranscriptHistoryStore
    /// Labels this device's sound classifier actually supports, or nil
    /// when unknown (tests, or a device without the classifier).
    public let knownSoundIdentifiers: Set<String>?
    public private(set) var settings: AppSettings
    /// Set while the system has the audio session (an incoming call), so
    /// the screen can say why captions stopped instead of looking broken.
    public private(set) var isInterruptedBySystem = false

    private let settingsStore: SettingsStore
    private let audioManager: AVAudioInputManager?
    private let synthesizer: (any SpeechSynthesizing)?
    /// Pauses captions while the phone talks, and decides when they may
    /// come back (see `SpeechPauseCoordinator`).
    private var speechPause = SpeechPauseCoordinator()
    private var historySessionID = UUID()
    private var historySessionStartedAt: TimeInterval?
    private var autosaveTask: Task<Void, Never>?

    private static let autosaveIntervalSeconds: UInt64 = 20

    /// Production wiring: real microphone, real engines, MFCC embedder,
    /// Apple's sound classifier, history under Application Support.
    public convenience init(settingsStore: SettingsStore) {
        let audio = AVAudioInputManager()
        let pipeline = CaptionPipeline(
            audio: audio,
            engineFactory: { settings in
                switch settings.engine {
                case .whisperKit:
                    return WhisperKitEngine(modelVariant: settings.whisperModelVariant)
                case .appleSpeech:
                    return AppleSpeechEngine(allowServerFallback: settings.allowServerFallbackForAppleSpeech)
                }
            },
            embedder: MFCCSpeakerEmbedder(),
            soundDetector: SoundAnalysisDetector()
        )
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            settingsStore: settingsStore,
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: support.appendingPathComponent("ozen-history", isDirectory: true)),
            knownSoundIdentifiers: SoundAnalysisDetector.knownIdentifiers(),
            audioManager: audio,
            synthesizer: SpeechSynthesizer()
        )
    }

    /// Test wiring: any pipeline (typically one built on fakes).
    public init(
        settingsStore: SettingsStore,
        pipeline: CaptionPipeline,
        historyStore: TranscriptHistoryStore? = nil,
        knownSoundIdentifiers: Set<String>? = nil,
        audioManager: AVAudioInputManager? = nil,
        synthesizer: (any SpeechSynthesizing)? = nil
    ) {
        self.settingsStore = settingsStore
        self.pipeline = pipeline
        self.historyStore = historyStore ?? TranscriptHistoryStore(
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-history-\(UUID())")
        )
        self.knownSoundIdentifiers = knownSoundIdentifiers
        self.audioManager = audioManager
        self.synthesizer = synthesizer
        self.settings = settingsStore.load()
        for profile in settings.speakerProfiles {
            pipeline.enroll(profile: profile)
        }
        audioManager?.onInterruption = { [weak self] began in
            self?.isInterruptedBySystem = began
        }
        synthesizer?.onSpeakingChanged = { [weak self] speaking in
            self?.speakingDidChange(speaking)
        }
    }

    // MARK: - Passthroughs the views read constantly

    public var phase: PipelinePhase { pipeline.phase }
    public var segments: [TranscriptSegment] { pipeline.segments }
    public var availableInputs: [AudioInputDescriptor] { pipeline.availableInputs }
    public var selectedInputUID: String? { pipeline.selectedInputUID }
    public var isListening: Bool { pipeline.phase.isListening }
    public var inputLevel: Float { pipeline.inputLevel }
    public var stats: PipelineStats { pipeline.stats }
    public var keywordHits: [KeywordHit] { pipeline.keywordHits }
    public var keywordHitSegmentIDs: Set<UUID> { pipeline.keywordHitSegmentIDs }
    public var soundAlerts: [SoundAlert] { pipeline.soundAlerts }

    public var selectedInput: AudioInputDescriptor? {
        availableInputs.first { $0.uid == selectedInputUID }
    }

    // MARK: - Onboarding

    public var hasCompletedOnboarding: Bool { settings.hasCompletedOnboarding }

    public func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        persist()
    }

    /// Leaving the caption screen for the walkthrough: captions stop (and
    /// the conversation so far is saved) rather than keep the microphone
    /// open behind a screen that isn't showing them.
    public func showOnboardingAgain() {
        if pipeline.phase != .idle {
            speechPause.userTookControl()
            pipeline.stop()
            historySessionDidChangePhase()
        }
        settings.hasCompletedOnboarding = false
        persist()
    }

    /// What the caption screen does the first time it appears. A Siri
    /// request that launched the app shapes it: "stop" starts nothing,
    /// "say" talks first and only then opens the microphone, anything
    /// else starts captions as usual.
    public func launch(pending: AppAction?) async {
        switch pending {
        case .stopCaptions:
            return
        case .speak(let text):
            speak(text)
            await waitUntilSpeechEnds()
            await start()
        case .startCaptions, nil:
            await start()
        }
    }

    /// Polls rather than listens: the synthesizer's callbacks already
    /// drive the resume logic, and this is only used once, at launch.
    public func waitUntilSpeechEnds(timeoutSeconds: Double = 120) async {
        guard let synthesizer else { return }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        // Give a just-queued utterance a moment to register as busy.
        try? await Task.sleep(for: .milliseconds(100))
        while synthesizer.isBusy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .seconds(SpeechPauseCoordinator.settleSeconds))
    }

    public func requestMicrophonePermission() async -> AudioPermission {
        await pipeline.requestMicrophonePermission()
    }

    // MARK: - App actions (Siri, Shortcuts)

    /// Something asked for from outside the UI — a Siri phrase, a
    /// Shortcuts automation — carried out as if the matching button had
    /// been tapped.
    public func perform(_ action: AppAction) async {
        switch action {
        case .startCaptions:
            if pipeline.phase == .paused {
                await pipeline.resume()
            } else if !pipeline.phase.isListening && !pipeline.phase.isTransitioning {
                await pipeline.start(settings: settings)
            }
            historySessionDidChangePhase()
        case .stopCaptions:
            speechPause.userTookControl()
            pipeline.stop()
            historySessionDidChangePhase()
        case .speak(let text):
            speak(text)
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        await pipeline.start(settings: settings)
        historySessionDidChangePhase()
    }

    public func retry() async {
        await pipeline.retry()
        historySessionDidChangePhase()
    }

    public func togglePause() async {
        speechPause.userTookControl()
        if pipeline.phase == .paused {
            await pipeline.resume()
        } else if pipeline.phase.isListening {
            pipeline.pause()
        } else if pipeline.phase == .idle {
            await pipeline.start(settings: settings)
        }
        historySessionDidChangePhase()
    }

    /// Ends the current history session (saving it) and starts a fresh,
    /// empty one.
    public func clearTranscript() {
        persistHistory(ended: true)
        pipeline.clearTranscript()
        historySessionID = UUID()
        historySessionStartedAt = pipeline.phase.isListening ? Date().timeIntervalSince1970 : nil
    }

    // MARK: - Inputs

    public func selectInput(uid: String) {
        pipeline.selectInput(uid: uid)
        settings.preferredInputUID = uid
        persist()
    }

    public func refreshInputs() {
        pipeline.refreshInputs()
    }

    // MARK: - Engine & model (restart the pipeline)

    public func setEngine(_ kind: TranscriptionEngineKind) async {
        guard settings.engine != kind else { return }
        settings.engine = kind
        persist()
        await restartIfRunning()
    }

    public func setWhisperModel(_ variant: String) async {
        guard settings.whisperModelVariant != variant else { return }
        settings.whisperModelVariant = variant
        persist()
        if settings.engine == .whisperKit {
            await restartIfRunning()
        }
    }

    public func setAllowServerFallback(_ allowed: Bool) async {
        guard settings.allowServerFallbackForAppleSpeech != allowed else { return }
        settings.allowServerFallbackForAppleSpeech = allowed
        persist()
        if settings.engine == .appleSpeech {
            await restartIfRunning()
        }
    }

    private func restartIfRunning() async {
        switch pipeline.phase {
        case .idle, .paused:
            return
        default:
            await pipeline.restart(settings: settings)
            historySessionDidChangePhase()
        }
    }

    // MARK: - Display & behaviour (no restart needed)

    public var display: DisplayPreferences {
        get { settings.display }
        set {
            settings.display = newValue
            persist()
        }
    }

    public var hapticOnSpeechResume: Bool {
        get { settings.hapticOnSpeechResume }
        set {
            settings.hapticOnSpeechResume = newValue
            persist()
        }
    }

    public var speakerSimilarityThreshold: Float {
        get { settings.speakerSimilarityThreshold }
        set {
            settings.speakerSimilarityThreshold = newValue
            pipeline.setSpeakerSimilarityThreshold(newValue)
            persist()
        }
    }

    public var saveHistory: Bool {
        get { settings.saveHistory }
        set {
            settings.saveHistory = newValue
            persist()
        }
    }

    // MARK: - Keyword alerts

    public var keywordAlerts: [KeywordAlert] { settings.keywordAlerts }

    public func addKeywordAlert(phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !settings.keywordAlerts.contains(where: { HebrewText.normalize($0.phrase) == HebrewText.normalize(trimmed) })
        else { return }
        settings.keywordAlerts.append(KeywordAlert(phrase: trimmed))
        keywordAlertsChanged()
    }

    public func setKeywordAlert(id: UUID, enabled: Bool) {
        guard let index = settings.keywordAlerts.firstIndex(where: { $0.id == id }) else { return }
        settings.keywordAlerts[index].isEnabled = enabled
        keywordAlertsChanged()
    }

    public func removeKeywordAlert(id: UUID) {
        settings.keywordAlerts.removeAll { $0.id == id }
        keywordAlertsChanged()
    }

    private func keywordAlertsChanged() {
        pipeline.setKeywordAlerts(settings.keywordAlerts)
        persist()
    }

    // MARK: - Sound alerts

    public var soundAlertPreferences: SoundAlertPreferences {
        get { settings.soundAlerts }
        set {
            settings.soundAlerts = newValue
            pipeline.soundPolicy.preferences = newValue
            persist()
        }
    }

    public func setSoundEvent(_ identifier: String, muted: Bool) {
        var preferences = soundAlertPreferences
        if muted {
            preferences.mutedIdentifiers.insert(identifier)
        } else {
            preferences.mutedIdentifiers.remove(identifier)
        }
        soundAlertPreferences = preferences
    }

    public func isSoundEventSupported(_ identifier: String) -> Bool {
        knownSoundIdentifiers?.contains(identifier) ?? true
    }

    public func dismissSoundAlert(id: UUID) {
        pipeline.dismissSoundAlert(id: id)
    }

    // MARK: - Vocabulary (names the engines should expect)

    public var vocabulary: [String] { settings.vocabulary }

    public func addVocabularyTerm(_ term: String) {
        let cleaned = VocabularyHints.normalized(settings.vocabulary + [term])
        guard cleaned != settings.vocabulary else { return }
        settings.vocabulary = cleaned
        vocabularyChanged()
    }

    public func removeVocabulary(at offsets: IndexSet) {
        settings.vocabulary.remove(atOffsets: offsets)
        vocabularyChanged()
    }

    public func moveVocabulary(from source: IndexSet, to destination: Int) {
        settings.vocabulary.move(fromOffsets: source, toOffset: destination)
        vocabularyChanged()
    }

    /// Everyone with a saved voice profile is by definition someone whose
    /// name comes up — one tap adds them all.
    public func addSpeakerNamesToVocabulary() {
        let names = settings.speakerProfiles.map(\.name)
        let cleaned = VocabularyHints.normalized(settings.vocabulary + names)
        guard cleaned != settings.vocabulary else { return }
        settings.vocabulary = cleaned
        vocabularyChanged()
    }

    private func vocabularyChanged() {
        persist()
        let terms = settings.vocabulary
        Task { [weak self] in
            await self?.pipeline.setVocabulary(terms)
        }
    }

    // MARK: - Type to speak

    public var isSpeaking: Bool { synthesizer?.isSpeaking ?? false }
    public var hasHebrewVoice: Bool { synthesizer?.hasHebrewVoice ?? false }

    public var speechRate: Float {
        get { settings.speechRate }
        set {
            settings.speechRate = newValue
            persist()
        }
    }

    /// Says `text` aloud. Captions pause while the phone talks so the
    /// microphone doesn't caption the phone's own voice, and resume by
    /// themselves when it's done.
    public func speak(_ text: String) {
        guard let synthesizer else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if speechPause.willSpeak(captionsListening: pipeline.phase.isListening) {
            pipeline.pause()
        }
        synthesizer.speak(trimmed, rate: settings.speechRate)
    }

    public func stopSpeaking() {
        synthesizer?.stop()
    }

    private func speakingDidChange(_ speaking: Bool) {
        guard !speaking, let generation = speechPause.speechWentQuiet() else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(SpeechPauseCoordinator.settleSeconds))
            guard let self else { return }
            let resume = self.speechPause.shouldResume(
                generation: generation,
                synthesizerBusy: self.synthesizer?.isBusy ?? false,
                captionsPaused: self.pipeline.phase == .paused
            )
            guard resume else { return }
            await self.pipeline.resume()
            self.historySessionDidChangePhase()
        }
    }

    public func addQuickPhrase(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.quickPhrases.contains(trimmed) else { return }
        settings.quickPhrases.append(trimmed)
        persist()
    }

    public func removeQuickPhrases(at offsets: IndexSet) {
        settings.quickPhrases.remove(atOffsets: offsets)
        persist()
    }

    public func moveQuickPhrases(from source: IndexSet, to destination: Int) {
        settings.quickPhrases.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    public func resetQuickPhrases() {
        settings.quickPhrases = AppSettings.defaultQuickPhrases
        persist()
    }

    // MARK: - Speakers

    /// Records `seconds` of the person talking and saves them as a named
    /// profile. Returns false if the recording was too short/quiet to get
    /// a usable voice print.
    public func enroll(name: String, seconds: Double, onProgress: @MainActor (Double) -> Void) async -> Bool {
        let samples = await pipeline.captureEnrollmentSamples(seconds: seconds, onProgress: onProgress)
        return enroll(name: name, samples: samples)
    }

    @discardableResult
    public func enroll(name: String, samples: [Float]) -> Bool {
        guard let embedding = pipeline.embedding(forEnrollmentSamples: samples) else { return false }
        let profile = SpeakerProfile(name: name, embedding: embedding)
        pipeline.enroll(profile: profile)
        settings.speakerProfiles.append(profile)
        persist()
        return true
    }

    /// The "who is this?" flow: tag an already-inferred cluster by name
    /// using one of its own segments, after the fact.
    public func nameSpeaker(of segment: TranscriptSegment, name: String) {
        guard let centroid = pipeline.nameSpeaker(of: segment, name: name) else { return }
        settings.speakerProfiles.append(SpeakerProfile(name: name, embedding: centroid))
        persist()
    }

    public func removeProfile(id: UUID) {
        settings.speakerProfiles.removeAll { $0.id == id }
        persist()
    }

    public func displayName(for segment: TranscriptSegment) -> String {
        pipeline.displayName(for: segment)
    }

    // MARK: - History

    /// Writes the current transcript to history (if there is anything and
    /// history is on). Called by the autosave loop, on every phase change,
    /// and when the app goes to the background — so a conversation is never
    /// lost to a crash or a force-quit.
    public func persistHistory(ended: Bool) {
        guard settings.saveHistory, let startedAt = historySessionStartedAt else { return }
        let record = TranscriptSessionRecord.make(
            from: pipeline.segments,
            speakerName: { [pipeline] in pipeline.displayName(for: $0) },
            id: historySessionID,
            startedAt: startedAt,
            endedAt: ended ? Date().timeIntervalSince1970 : nil,
            engine: settings.engine,
            modelVariant: settings.engine == .whisperKit ? settings.whisperModelVariant : nil,
            inputName: selectedInput?.portName
        )
        try? historyStore.save(record)
    }

    /// Keeps the autosave loop matched to whether we're listening.
    public func historySessionDidChangePhase() {
        if pipeline.phase.isListening {
            if historySessionStartedAt == nil {
                historySessionStartedAt = Date().timeIntervalSince1970
            }
            if autosaveTask == nil {
                autosaveTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: Self.autosaveIntervalSeconds * 1_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.persistHistory(ended: false)
                    }
                }
            }
        } else {
            autosaveTask?.cancel()
            autosaveTask = nil
            persistHistory(ended: true)
        }
    }

    // MARK: - Persistence

    private func persist() {
        try? settingsStore.save(settings)
    }
}

/// What the outside world (Siri, Shortcuts, a URL) can ask the app to do.
public enum AppAction: Equatable, Sendable {
    case startCaptions
    case stopCaptions
    case speak(String)
}
