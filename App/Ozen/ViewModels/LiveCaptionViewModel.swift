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
    /// Autosaves off the main thread, final saves in order behind them.
    private let historyWriter: TranscriptHistoryWriter
    /// Labels this device's sound classifier actually supports, or nil
    /// when unknown (tests, a device without the classifier, or the first
    /// moment after launch while they're still being read).
    public private(set) var knownSoundIdentifiers: Set<String>?
    public private(set) var settings: AppSettings
    /// Set while the system has the audio session (an incoming call), so
    /// the screen can say why captions stopped instead of looking broken.
    public private(set) var isInterruptedBySystem = false
    /// A Shortcut or the Action button asked for the big-letters pad (see
    /// `BigTextView`). The caption screen opens it and clears this.
    public var isShowingBigText = false
    /// Why the last settings save failed, for the diagnostics screen; nil
    /// when the last save worked.
    public private(set) var settingsSaveError: String?
    /// Whether the caption screen says saving is failing (a full phone).
    public private(set) var savingTrouble = SavingTroubleNotice()
    /// Where the lines said while the screen was away begin.
    var awayCatchUp = AwayCatchUp()
    @ObservationIgnored private var keywordAttention = KeywordAttentionPolicy()
    @ObservationIgnored private var handledKeywordHitIDs: Set<UUID> = []
    /// The latest keyword hit that got her attention, for screens covering
    /// the captions to show its pill too.
    public private(set) var attentionKeywordHit: KeywordHit?
    /// Lines marked as important in the conversation on screen.
    public private(set) var starredSegmentIDs: Set<UUID> = []

    private let settingsStore: SettingsStore
    private let audioManager: AVAudioInputManager?
    private let synthesizer: (any SpeechSynthesizing)?
    /// Pauses captions while the phone talks, and decides when they may
    /// come back (see `SpeechPauseCoordinator`).
    private var speechPause = SpeechPauseCoordinator()
    /// Whether the app is on screen; alerts become notifications when not.
    public private(set) var isAppActive = true
    private var backgroundAlerts = BackgroundAlertPolicy()
    private let postNotification: ((AlertNotificationContent) -> Void)?
    /// Removes a delivered notification by its identifier.
    private let withdrawNotification: ((String) -> Void)?
    /// Tells her when captions stop while the phone is put away.
    private var stoppedCaptions = StoppedCaptionsNotice()
    private let phoneCalls: PhoneCallMonitor?
    /// A call ended while iOS still holds the microphone for it.
    private var callEndedDuringInterruption = false
    private var reclaimAfterCallTask: Task<Void, Never>?
    /// How long after a call ends iOS gets to hand the microphone back by
    /// itself before the app asks for it.
    var callEndGrace: Duration = .seconds(2)
    /// Tries to take the audio session back after an interruption whose
    /// end was never announced; true when it worked.
    private let reclaimAudioSession: (@MainActor () -> Bool)?
    private var historySessionID = UUID()
    private var historySessionStartedAt: TimeInterval?
    /// Lines before this index in `pipeline.segments` belong to an earlier
    /// saved conversation (see `ConversationBreak`); the screen still
    /// shows them.
    private var historySegmentOffset = 0
    /// Conversations a quiet break closed while their lines are still on
    /// screen, so a star added to one of those lines goes to the right
    /// saved conversation.
    private var closedHistorySessions: [ClosedHistorySession] = []

    private struct ClosedHistorySession {
        let id: UUID
        let lines: Range<Int>
        let startedAt: TimeInterval
        let endedAt: TimeInterval?
        let engine: TranscriptionEngineKind
        let modelVariant: String?
        let inputName: String?
    }
    private var autosaveTask: Task<Void, Never>?
    /// Whether captions were listening the last time history looked.
    @ObservationIgnored private var historySawListening = false
    private var lastRetentionCheck: TimeInterval = 0
    private var launchHousekeeping: Task<Void, Never>?
    private var soundIdentifiersLoad: Task<Void, Never>?
    @ObservationIgnored private var announcer = CaptionAnnouncer()
    @ObservationIgnored private var lockScreen: LockScreenCaptionsCoordinator?
    private static let retentionCheckIntervalSeconds: TimeInterval = 6 * 60 * 60

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
                case .cloud:
                    return CloudSpeechEngine(model: settings.cloudModel, apiKey: { CloudKeyStore.read() })
                case .homeServer:
                    return HomeServerEngine(
                        address: settings.homeServerAddress,
                        token: { HomeServerCodeStore.read() },
                        connector: URLSessionHomeServerConnector()
                    )
                }
            },
            // CAM++ needs its bundled CoreML model to actually load; a
            // corrupt install falls back to the older, always-available
            // MFCC embedder rather than failing to launch.
            embedder: CAMPlusPlusSpeakerEmbedder() ?? MFCCSpeakerEmbedder(),
            soundDetector: SoundAnalysisDetector(),
            network: PathNetworkMonitor(),
            availableStorageBytes: { DeviceStorage.availableBytes() }
        )
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            settingsStore: settingsStore,
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: support.appendingPathComponent("ozen-history", isDirectory: true)),
            // Reading them loads the classifier's model: not on the main
            // thread while the app is trying to draw its first screen.
            loadKnownSoundIdentifiers: { SoundAnalysisDetector.knownIdentifiers() },
            audioManager: audio,
            synthesizer: SpeechSynthesizer(),
            postNotification: { AlertNotifier.shared.post($0) },
            withdrawNotification: { AlertNotifier.shared.withdraw(identifier: $0) },
            phoneCalls: PhoneCallMonitor(),
            lockScreen: LockScreenCaptionsActivity(),
            journal: SessionJournal(fileURL: support.appendingPathComponent("ozen-journal.log"))
        )
    }

    /// Test wiring: any pipeline (typically one built on fakes).
    public init(
        settingsStore: SettingsStore,
        pipeline: CaptionPipeline,
        historyStore: TranscriptHistoryStore? = nil,
        knownSoundIdentifiers: Set<String>? = nil,
        loadKnownSoundIdentifiers: (@Sendable () -> Set<String>?)? = nil,
        audioManager: AVAudioInputManager? = nil,
        synthesizer: (any SpeechSynthesizing)? = nil,
        postNotification: ((AlertNotificationContent) -> Void)? = nil,
        withdrawNotification: ((String) -> Void)? = nil,
        phoneCalls: PhoneCallMonitor? = nil,
        reclaimAudioSession: (@MainActor () -> Bool)? = nil,
        lockScreen: (any LockScreenCaptionsDisplaying)? = nil,
        journal: SessionJournal? = nil
    ) {
        self.settingsStore = settingsStore
        self.pipeline = pipeline
        self.journal = journal
        self.historyStore = historyStore ?? TranscriptHistoryStore(
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-history-\(UUID())")
        )
        self.historyWriter = TranscriptHistoryWriter(store: self.historyStore)
        self.knownSoundIdentifiers = knownSoundIdentifiers
        self.audioManager = audioManager
        self.synthesizer = synthesizer
        self.postNotification = postNotification
        self.withdrawNotification = withdrawNotification
        self.phoneCalls = phoneCalls
        if let reclaimAudioSession {
            self.reclaimAudioSession = reclaimAudioSession
        } else if let audioManager {
            self.reclaimAudioSession = { @MainActor in audioManager.reclaimSessionAfterInterruption() }
        } else {
            self.reclaimAudioSession = nil
        }
        self.settings = settingsStore.load()
        backgroundAlerts.isEnabled = settings.notifyWhenInBackground
        backgroundAlerts.quietHours = settings.quietHours
        for profile in settings.speakerProfiles {
            pipeline.enroll(profile: profile)
        }
        audioManager?.onInterruption = { [weak self] began in
            self?.systemInterruptionChanged(began: began)
        }
        synthesizer?.onSpeakingChanged = { [weak self] speaking in
            self?.speakingDidChange(speaking)
        }
        pipeline.onEvent = { [weak self] event in
            self?.journal?.append(event.description, at: event.at)
        }
        startJournal()
        pipeline.onSoundAlert = { [weak self] alert in
            self?.alertRaised(sound: alert)
        }
        pipeline.onKeywordHits = { [weak self] hits, segment in
            self?.alertRaised(keywords: hits, in: segment)
        }
        pipeline.onPhaseChange = { [weak self] _ in
            // A failure's automatic retry is lined up right after its phase
            // is set, so look once the pipeline has finished reacting.
            Task { @MainActor [weak self] in
                // Here and not only after this class's own start or pause:
                // captions an automatic retry brought back must be saved
                // too, with or without the caption screen watching. Only
                // when listening began or ended since history last looked,
                // so a start this class already handled isn't handled again
                // a moment later.
                if let self, self.pipeline.phase.isListening != self.historySawListening {
                    self.historySessionDidChangePhase()
                }
                self?.holdCaptionsIfStillSpeaking()
                self?.checkCaptionsStillRunning()
                self?.refreshLockScreen()
            }
        }
        if let lockScreen {
            self.lockScreen = LockScreenCaptionsCoordinator(
                display: lockScreen,
                situation: { [weak self] in
                    guard let self else {
                        return .init(enabled: false, phase: .idle, interruptedByCall: false, pausedForSpeech: false, captionSize: 0)
                    }
                    return .init(
                        enabled: self.settings.display.lockScreenCaptions,
                        phase: self.pipeline.phase,
                        interruptedByCall: self.isInterruptedBySystem,
                        pausedForSpeech: self.captionsHeldForSpeech,
                        captionSize: self.settings.display.fontSize
                    )
                },
                lines: { [weak self] count, textSize in
                    guard let self else { return [] }
                    let pipeline = self.pipeline
                    let namesShown = self.settings.display.showSpeakerNames
                    return LockScreenCaptions.lines(from: pipeline.segments, count: count, textSize: textSize) { segment in
                        namesShown && segment.speakerClusterID != nil ? pipeline.displayName(for: segment) : nil
                    }
                }
            )
        }
        pipeline.onCaptionsChanged = { [weak self] in
            self?.refreshLockScreen()
        }
        phoneCalls?.onChange = { [weak self] inProgress in
            self?.phoneCallsChanged(inProgress: inProgress)
        }
        if let loadKnownSoundIdentifiers {
            soundIdentifiersLoad = Task { [weak self] in
                let identifiers = await Task.detached(priority: .utility) { loadKnownSoundIdentifiers() }.value
                self?.knownSoundIdentifiers = identifiers
            }
        }
        launchHousekeeping = Task { [weak self] in
            await self?.deleteExpiredHistory()
            await self?.loadRecentConversation()
        }
    }

    // MARK: - Journal

    /// What happened, kept on disk for the diagnostics report; see
    /// `SessionJournal`. Nil in tests that don't look at it.
    public let journal: SessionJournal?
    /// When a problem was last marked, for the caption screen to confirm.
    public private(set) var problemMarkedAt: TimeInterval?
    @ObservationIgnored private var journalObservers: [NSObjectProtocol] = []

    private func note(_ text: String) {
        journal?.append(text, at: Date().timeIntervalSince1970)
    }

    private static var deviceStateText: String {
        let process = ProcessInfo.processInfo
        let memory = DeviceMemory.footprintBytes().map { " memory \($0 / 1_048_576)MB" } ?? ""
        return "thermal \(process.thermalState.rawValue) low power \(process.isLowPowerModeEnabled)\(memory)"
    }

    /// The line a new run of the app opens with, and the slow facts no
    /// pipeline event carries: heat and Low Power Mode, which both slow the
    /// captions down without anything on screen saying so.
    private func startJournal() {
        guard journal != nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        note("APP STARTED: \(version) iOS \(ProcessInfo.processInfo.operatingSystemVersionString) engine \(settings.engine.rawValue) model \(settings.modelDescription ?? "-") \(Self.deviceStateText)")
        let center = NotificationCenter.default
        journalObservers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.note("heat: \(LiveCaptionViewModel.deviceStateText)") }
        })
        journalObservers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.note("power: \(LiveCaptionViewModel.deviceStateText)") }
        })
    }

    /// "Something went wrong" on the caption screen: what was running and
    /// what the captions last said goes into the journal, where the next
    /// diagnostics report finds it even if the app is closed first.
    public func markProblem() {
        let now = Date().timeIntervalSince1970
        let lines = ProblemSnapshot.lines(
            settings: settings,
            activeEngine: pipeline.activeEngineKind,
            input: selectedInput,
            stats: pipeline.stats,
            segments: pipeline.segments,
            device: Self.deviceStateText
        )
        for line in lines {
            journal?.append(line, at: now)
        }
        problemMarkedAt = now
        Task { [weak self] in
            guard let self, let engine = await self.pipeline.engineDiagnostics() else { return }
            self.journal?.append("  engine: \(engine)", at: now)
        }
    }

    /// Returns once the history tidying started at launch has finished.
    func finishLaunchHousekeeping() async {
        await launchHousekeeping?.value
    }

    /// Returns once the sound classifier's labels, read in the background at
    /// launch, have arrived.
    func finishLoadingSoundIdentifiers() async {
        await soundIdentifiersLoad?.value
    }

    // MARK: - Alerts while the app isn't on screen

    public func sceneActivityChanged(isActive: Bool) {
        if isActive != isAppActive {
            note(isActive ? "app back on screen" : "app left the screen (phase \(pipeline.phase.isListening ? "listening" : "not listening"))")
        }
        isAppActive = isActive
        let now = Date().timeIntervalSince1970
        if isActive {
            awayCatchUp.screenReturned(at: now)
            // Coming back from installing or removing the Hebrew voice in
            // iOS Settings: without this, hasHebrewVoice stays whatever it
            // was at launch until the app relaunches.
            synthesizer?.refreshVoice()
        } else {
            awayCatchUp.screenLeft(at: now)
        }
        lockScreen?.appActivityChanged(isActive: isActive)
        // Captions that failed with the app open were on screen for her to
        // see; putting the phone away with them still stopped is when she
        // needs telling, and no pipeline event will come along to say so.
        checkCaptionsStillRunning()
        // After a phone call iOS may never say the interruption ended.
        // Back on screen, try to take the microphone back: if that works
        // the call is over, and captions (and automatic recovery) resume.
        // The phone may stay on the nightstand with the app open for days;
        // old conversations still expire on schedule.
        if isActive, Date().timeIntervalSince1970 - lastRetentionCheck > Self.retentionCheckIntervalSeconds {
            Task { await deleteExpiredHistory() }
        }
        if isActive, isInterruptedBySystem, reclaimAudioSession?() == true {
            systemInterruptionChanged(began: false)
        }
        // Back from freeing up room in the Settings app: the model download
        // starts by itself if it fits now.
        if isActive, pipeline.phase.failure?.engineUnavailability?.kind == .notEnoughStorage {
            Task {
                await pipeline.appDidBecomeActive()
                if pipeline.phase.failure?.engineUnavailability?.kind != .notEnoughStorage {
                    historySessionDidChangePhase()
                }
            }
        }
    }

    /// The system took (`true`) or gave back (`false`) the audio session.
    func systemInterruptionChanged(began: Bool) {
        isInterruptedBySystem = began
        callEndedDuringInterruption = false
        // A call cuts the phone off mid-phrase, and the voice can be left
        // paused rather than finished: never saying it's done, it would
        // hold captions paused for good. The rest of a phrase said after
        // the call is no use to anyone, so end it; captions then come back
        // the way running captions do after a call.
        if began, speechPause.isHoldingCaptions {
            synthesizer?.stop()
        }
        if !began {
            reclaimAfterCallTask?.cancel()
            reclaimAfterCallTask = nil
        }
        pipeline.systemInterruptionChanged(active: began)
        checkCaptionsStillRunning()
        refreshLockScreen()
    }

    /// A phone call started (`true`) or the last one ended (`false`).
    ///
    /// iOS usually hands the microphone back as a call ends, but doesn't
    /// promise to, and with the phone locked nobody opens the app to take
    /// it back. So a moment after the call, if the microphone is still
    /// held, the app asks for it; if that doesn't work, she gets a
    /// notification instead of silently losing her alerts.
    func phoneCallsChanged(inProgress: Bool) {
        reclaimAfterCallTask?.cancel()
        reclaimAfterCallTask = nil
        if inProgress {
            callEndedDuringInterruption = false
            checkCaptionsStillRunning()
            return
        }
        guard isInterruptedBySystem else { return }
        reclaimAfterCallTask = Task { [weak self, callEndGrace] in
            try? await Task.sleep(for: callEndGrace)
            guard let self, !Task.isCancelled else { return }
            self.reclaimAfterCallTask = nil
            self.reclaimMicrophoneAfterCall()
        }
    }

    /// Returns once the check that follows the end of a call has run.
    func finishReclaimAfterCall() async {
        await reclaimAfterCallTask?.value
    }

    private func reclaimMicrophoneAfterCall() {
        guard isInterruptedBySystem else { return }
        callEndedDuringInterruption = true
        // Only for captions that were running: taking the audio session
        // for paused captions would stop her music for nothing.
        let phase = pipeline.phase
        guard phase.isListening || phase.failure != nil else {
            // Paused captions have nothing to take back, but the call is
            // over: left marked as interrupted, the status kept saying
            // "paused because of a call" with nothing to tap, whenever iOS
            // didn't say the interruption ended and the app never left the
            // screen (a call answered from the banner). Resuming asks for
            // the microphone then, and a microphone still held is a failure
            // automatic recovery handles.
            systemInterruptionChanged(began: false)
            return
        }
        if reclaimAudioSession?() == true {
            systemInterruptionChanged(began: false)
        } else {
            checkCaptionsStillRunning()
        }
    }

    /// Posts or withdraws the "captions stopped" notification to match what
    /// the pipeline is doing now (see `StoppedCaptionsNotice`).
    private func checkCaptionsStillRunning() {
        let cause = StoppedCaptionsNotice.cause(
            phase: pipeline.phase,
            retryScheduled: pipeline.scheduledRetry != nil,
            systemInterrupted: isInterruptedBySystem,
            callEndedDuringInterruption: callEndedDuringInterruption
        )
        switch stoppedCaptions.update(for: cause, appIsActive: isAppActive, isEnabled: settings.notifyWhenInBackground) {
        case .post(let content)?:
            postNotification?(content)
        case .withdraw(let identifier)?:
            withdrawNotification?(identifier)
        case nil:
            break
        }
    }

    /// Speech models may download over cellular data.
    public var allowCellularModelDownload: Bool {
        get { settings.allowCellularModelDownload }
        set {
            settings.allowCellularModelDownload = newValue
            persist()
            Task { await pipeline.setAllowCellularModelDownload(newValue) }
        }
    }

    /// "Download now" while the model waits for Wi-Fi.
    public func approveCellularDownload() async {
        await pipeline.approveCellularDownload()
    }

    public var notifyWhenInBackground: Bool {
        get { settings.notifyWhenInBackground }
        set {
            settings.notifyWhenInBackground = newValue
            backgroundAlerts.isEnabled = newValue
            persist()
        }
    }

    public var quietHours: QuietHours {
        get { settings.quietHours }
        set {
            settings.quietHours = newValue
            backgroundAlerts.quietHours = newValue
            persist()
        }
    }

    /// The battery is running low while captions run. On screen the
    /// banner says so; with the phone put away it becomes a notification.
    public func batteryWarningRaised(_ warning: BatteryWarning) {
        guard !isAppActive, settings.notifyWhenInBackground else { return }
        postNotification?(warning.notificationContent)
    }

    private func alertRaised(sound alert: SoundAlert) {
        let now = Date().timeIntervalSince1970
        guard let content = backgroundAlerts.notification(
            for: alert, appIsActive: isAppActive, now: now, utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: now))
        ) else { return }
        postNotification?(content)
    }

    private func alertRaised(keywords hits: [KeywordHit], in segment: TranscriptSegment) {
        let now = Date().timeIntervalSince1970
        let utcOffsetSeconds = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: now))
        for hit in hits {
            if let content = backgroundAlerts.notification(
                for: hit, lineText: segment.text, appIsActive: isAppActive, now: now, utcOffsetSeconds: utcOffsetSeconds
            ) {
                postNotification?(content)
            }
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
    /// For views that only need to hear of finished lines (see
    /// `CaptionPipeline.committedLineCount`).
    public var committedLineCount: Int { pipeline.committedLineCount }
    public var keywordHits: [KeywordHit] { pipeline.keywordHits }
    public var keywordHitSegmentIDs: Set<UUID> { pipeline.keywordHitSegmentIDs }
    public var soundAlerts: [SoundAlert] { pipeline.soundAlerts }

    public var selectedInput: AudioInputDescriptor? {
        availableInputs.first { $0.uid == selectedInputUID }
    }

    // MARK: - Onboarding

    public var hasCompletedOnboarding: Bool { settings.hasCompletedOnboarding }

    /// The language the app's words are in right now: the setting, with
    /// "like the phone" worked out from the phone's languages.
    public private(set) var uiLanguage: UILanguage = Localization.language

    /// Puts the language setting into effect. Called at launch, when the
    /// setting changes and when the app comes back (the phone's language
    /// may have changed meanwhile).
    public func applyAppLanguage(preferredLanguages: [String] = Locale.preferredLanguages) {
        let language = settings.appLanguage.resolved(preferredLanguages: preferredLanguages)
        Localization.language = language
        if uiLanguage != language { uiLanguage = language }
    }

    public func setAppLanguage(_ language: AppLanguage) {
        guard settings.appLanguage != language else { return }
        settings.appLanguage = language
        persist()
        applyAppLanguage()
    }

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
    /// Siri and Shortcuts requests that arrived together, in order. On the
    /// first appearance the first one decides how the app starts (see
    /// `launch(pending:)`); the rest follow as ordinary requests.
    public func handle(pending actions: [AppAction], isFirstAppearance: Bool) async {
        var remaining = actions[...]
        if isFirstAppearance {
            await launch(pending: remaining.popFirst())
        }
        for action in remaining {
            await perform(action)
        }
    }

    public func launch(pending: AppAction?) async {
        switch pending {
        case .stopCaptions:
            return
        case .speak(let text):
            speak(text)
            await waitUntilSpeechEnds()
            await start()
        case .showBigText:
            // Captions run behind the pad, as they would have anyway.
            isShowingBigText = true
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
            // Paused while the phone talks: captions come back by themselves
            // when it's done. Opening the microphone now would caption the
            // phone's own sentence. A phone that has gone quiet without
            // saying so is not talking, and asking is then the way out.
            if captionsHeldForSpeech {
                if synthesizer?.isBusy == true { break }
                speechPause.userTookControl()
            }
            if pipeline.phase == .paused {
                await pipeline.resume(settings: settings)
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
        case .showBigText:
            isShowingBigText = true
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        await pipeline.start(settings: settings)
        historySessionDidChangePhase()
    }

    public func retry() async {
        await pipeline.retry(settings: settings)
        historySessionDidChangePhase()
    }

    public func togglePause() async {
        speechPause.userTookControl()
        if pipeline.phase == .paused {
            await pipeline.resume(settings: settings)
        } else if pipeline.phase.isListening {
            pipeline.pause()
        } else if pipeline.phase == .idle {
            await pipeline.start(settings: settings)
        }
        historySessionDidChangePhase()
    }

    /// Marks a line as important, or unmarks it, and saves right away so
    /// the mark isn't lost if the app is closed before the next autosave.
    public func toggleStar(_ segment: TranscriptSegment) {
        if starredSegmentIDs.remove(segment.id) == nil {
            starredSegmentIDs.insert(segment.id)
        }
        if let index = pipeline.segments.firstIndex(where: { $0.id == segment.id }),
           index < historySegmentOffset,
           let closed = closedHistorySessions.last(where: { $0.lines.contains(index) }) {
            saveClosed(closed)
        } else {
            persistHistory(ended: false, inBackground: true)
        }
    }

    private func saveClosed(_ session: ClosedHistorySession) {
        guard settings.saveHistory else { return }
        let segments = pipeline.segments
        let lines = session.lines.clamped(to: segments.indices)
        let record = TranscriptSessionRecord.make(
            from: Array(segments[lines]),
            speakerName: { [pipeline] in pipeline.displayName(for: $0) },
            id: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            engine: session.engine,
            modelVariant: session.modelVariant,
            inputName: session.inputName,
            starred: starredSegmentIDs
        )
        saveInBackground(record)
    }

    // MARK: - Lock screen

    /// Brings the lock screen captions up to date (see
    /// `LockScreenCaptionsCoordinator`). Called whenever a line changes,
    /// the phase changes, or the display settings change.
    func refreshLockScreen() {
        lockScreen?.refresh()
    }

    /// False when iOS Settings has Live Activities off for Ozen, so the
    /// lock screen captions setting can't show anything. Read when the
    /// settings screen appears; it isn't observed.
    public var lockScreenCaptionsAllowedBySystem: Bool {
        lockScreen?.display.isAllowedBySystem ?? true
    }

    /// Whether the lines are on the lock screen as far as the app knows,
    /// for the diagnostics report.
    public var lockScreenCaptionsShowing: Bool { lockScreen?.isShowing ?? false }

    /// Why iOS last refused to put them there, for the diagnostics report.
    public var lockScreenCaptionsLastStartFailure: String? { lockScreen?.display.lastStartFailure }

    /// She has seen where the lines she missed begin.
    func acknowledgeAwayLines() {
        guard !awayCatchUp.isAcknowledged else { return }
        awayCatchUp.acknowledge()
    }

    public func clearTranscript() {
        recentConversation = nil
        awayCatchUp.clear()
        persistHistory(ended: true)
        starredSegmentIDs = []
        closedHistorySessions = []
        pipeline.clearTranscript()
        historySessionID = UUID()
        historySegmentOffset = 0
        historySessionStartedAt = pipeline.phase.isListening ? Date().timeIntervalSince1970 : nil
    }

    // MARK: - Inputs

    /// Switches microphone and remembers the choice, even when the switch
    /// didn't take: a microphone still connecting is used as soon as the
    /// system offers it. Returns whether it is in use now.
    @discardableResult
    public func selectInput(uid: String) -> Bool {
        let switched = pipeline.selectInput(uid: uid)
        settings.preferredInputUID = uid
        persist()
        return switched
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

    public func setCloudModel(_ model: String) async {
        guard settings.cloudModel != model else { return }
        settings.cloudModel = model
        persist()
        if settings.engine == .cloud {
            await restartIfRunning()
        }
    }

    /// The OpenRouter key was saved or removed in Settings. The engine reads
    /// it at every start, so a running or failed session just starts again.
    public func cloudKeyChanged() async {
        if settings.engine == .cloud {
            await restartIfRunning()
        }
    }

    public func setHomeServerAddress(_ address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.homeServerAddress != trimmed else { return }
        settings.homeServerAddress = trimmed
        persist()
        if settings.engine == .homeServer {
            await restartIfRunning()
        }
    }

    /// A pairing link from a home computer's QR code, waiting for someone
    /// to confirm it (see `HomeServerPairing`).
    public var pendingPairing: HomeServerPairing?

    public func openURL(_ url: URL) {
        pendingPairing = HomeServerPairing(url: url)
    }

    /// Saves the confirmed pairing and switches captions to that computer.
    /// False when the phone refused to keep the code.
    @discardableResult
    public func acceptPendingPairing() async -> Bool {
        guard let pairing = pendingPairing else { return false }
        pendingPairing = nil
        guard HomeServerCodeStore.save(pairing.code) else { return false }
        settings.homeServerAddress = pairing.address
        settings.engine = .homeServer
        persist()
        await restartIfRunning()
        return true
    }

    /// "Test connection": says hello to the saved address with the saved
    /// code, the way captions would, and times the answer.
    public func checkHomeServer() async -> HomeServerCheck {
        let engine = HomeServerEngine(
            address: settings.homeServerAddress,
            token: { HomeServerCodeStore.read() },
            connector: URLSessionHomeServerConnector()
        )
        let clock = ContinuousClock()
        let start = clock.now
        let availability = await engine.checkAvailability(languageCode: settings.languageCode)
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return HomeServerCheck(availability: availability, seconds: seconds)
    }

    /// The home server's pairing code was saved or removed in Settings.
    public func homeServerCodeChanged() async {
        if settings.engine == .homeServer {
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
            schedulePersist()
            refreshLockScreen()
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
            schedulePersist()
        }
    }

    public var saveHistory: Bool {
        get { settings.saveHistory }
        set {
            settings.saveHistory = newValue
            persist()
        }
    }

    /// When captions last changed, or listening last began if later: what
    /// "nothing has been said for a while" is measured from.
    public var lastCaptionActivityAt: TimeInterval? {
        [pipeline.segments.last?.lastUpdateTimestamp, pipeline.listeningStartedAt].compactMap { $0 }.max()
    }

    /// What VoiceOver should read out for lines finished since the last
    /// call, or nil. Lines that finish while VoiceOver is off, or the
    /// setting is, are skipped for good, so turning either on later
    /// doesn't read out the backlog.
    public func captionAnnouncement(voiceOverRunning: Bool) -> String? {
        let segments = pipeline.segments
        guard voiceOverRunning, settings.display.announceNewLines else {
            announcer.skipLinesSoFar(segments)
            return nil
        }
        let namesShown = settings.display.showSpeakerNames
        return announcer.announcement(for: segments) { [pipeline] segment in
            namesShown && segment.speakerClusterID != nil ? pipeline.displayName(for: segment) : nil
        }
    }

    /// The saved conversation that was still going moments ago, offered on
    /// the empty screen after iOS closed the app mid-conversation. See
    /// `RecentConversation`.
    public private(set) var recentConversation: TranscriptSessionSummary?

    /// Looks for a conversation cut off moments ago, off the main thread.
    public func loadRecentConversation(now: TimeInterval = Date().timeIntervalSince1970) async {
        let store = historyStore
        let current = historySessionID
        let cutoff = RecentConversation.oldestQualifyingSave(now: now)
        let summaries = await Task.detached(priority: .utility) { store.summaries(modifiedSince: cutoff) }.value
        recentConversation = RecentConversation.resumable(in: summaries, now: now, excluding: current)
    }

    public func dismissRecentConversation() {
        recentConversation = nil
    }

    /// How long saved conversations are kept. Changing it doesn't delete
    /// anything by itself; `deleteExpiredHistory()` does.
    public var historyRetention: HistoryRetention {
        get { settings.historyRetention }
        set {
            settings.historyRetention = newValue
            persist()
        }
    }

    /// Deletes saved conversations the retention setting says have expired,
    /// off the main thread and after any save in flight. The conversations
    /// still on screen are never touched. Returns how many were deleted.
    @discardableResult
    public func deleteExpiredHistory(now: TimeInterval = Date().timeIntervalSince1970) async -> Int {
        lastRetentionCheck = now
        let retention = settings.historyRetention
        guard retention != .forever else { return 0 }
        let onScreen = Set([historySessionID] + closedHistorySessions.map(\.id))
        let writer = historyWriter
        return await Task.detached(priority: .utility) {
            writer.deleteExpiredNow(retention: retention, now: now, protecting: onScreen)
        }.value
    }

    // MARK: - Keyword alerts

    /// The first keyword hit since the last call that should buzz, show its
    /// pill and be announced, or nil when they should only highlight their
    /// lines (see `KeywordAttentionPolicy`). Every new hit is considered,
    /// not just the newest: one line can hold two words from the list
    /// ("grandma, call an ambulance"), and each starts its own quiet period.
    public func claimAttentionForNewKeywordHits() -> KeywordHit? {
        let fresh = keywordHits.filter { !handledKeywordHitIDs.contains($0.id) }
        // keywordHits is capped, so this set stays small.
        handledKeywordHitIDs = Set(keywordHits.map(\.id))
        var claimed: KeywordHit?
        for hit in fresh where keywordAttention.claimAttention(for: hit) {
            claimed = claimed ?? hit
        }
        if let claimed { attentionKeywordHit = claimed }
        return claimed
    }

    public var keywordAlerts: [KeywordAlert] { settings.keywordAlerts }

    /// Adds a word to the list; one already there that was switched off is
    /// switched back on instead of being listed twice.
    public func addKeywordAlert(phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let listed = listedKeywordAlert(matching: trimmed) {
            if !listed.isEnabled { setKeywordAlert(id: listed.id, enabled: true) }
            return
        }
        settings.keywordAlerts.append(KeywordAlert(phrase: trimmed))
        keywordAlertsChanged()
    }

    /// The word on the list that `phrase` would duplicate, if any.
    public func listedKeywordAlert(matching phrase: String) -> KeywordAlert? {
        let typed = HebrewText.normalize(phrase)
        guard !typed.isEmpty else { return nil }
        return settings.keywordAlerts.first { HebrewText.normalize($0.phrase) == typed }
    }

    /// Captions are paused only while the phone says something aloud, and
    /// come back by themselves after.
    public var captionsHeldForSpeech: Bool {
        speechPause.isHoldingCaptions && pipeline.phase == .paused
    }

    /// "Not now" on the caption screen's offer to set up her name alert.
    public func dismissNameAlertOffer() {
        settings.nameAlertOfferDismissed = true
        persist()
    }

    /// The caption screen's offer of the recommended Whisper model, taken:
    /// the model switches (and downloads, on Wi-Fi) like a pick in Settings.
    public func acceptBetterModelOffer() async {
        await setWhisperModel(WhisperModelCatalog.recommendedVariant)
    }

    /// "Not now" on that offer: it comes back later, see
    /// `AppSettings.snoozeBetterModelOffer`.
    public func dismissBetterModelOffer() {
        settings.snoozeBetterModelOffer()
        persist()
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

    public func setSoundEvent(_ identifier: String, sensitive: Bool) {
        var preferences = soundAlertPreferences
        if sensitive {
            preferences.sensitiveIdentifiers.insert(identifier)
        } else {
            preferences.sensitiveIdentifiers.remove(identifier)
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
            schedulePersist()
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

    /// What the phone says for "ask them to repeat that" on a caption line.
    public static var repeatRequest: String { tr("סליחה, אפשר לחזור על זה?", "Sorry, could you say that again?") }

    /// Asks the room to say that again, aloud, straight from a caption line.
    public func askToRepeat() {
        speak(Self.repeatRequest)
    }

    public func stopSpeaking() {
        synthesizer?.stop()
    }

    /// Captions that come on while the phone is still talking (they were
    /// starting up when she tapped a phrase) would caption the phone's own
    /// voice; they pause until it's done, like captions already running.
    private func holdCaptionsIfStillSpeaking() {
        guard pipeline.phase.isListening, synthesizer?.isBusy == true,
              speechPause.captionsCameOnWhileSpeaking()
        else { return }
        pipeline.pause()
        historySessionDidChangePhase()
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
            await self.pipeline.resume(settings: self.settings)
            self.historySessionDidChangePhase()
        }
    }

    /// The phrases the Say screen lists, in the app's language while the list
    /// is still the built-in one (see `AppSettings.displayedQuickPhrases`).
    public var quickPhrases: [String] {
        AppSettings.displayedQuickPhrases(stored: settings.quickPhrases, language: uiLanguage)
    }

    /// Keeps the list she sees as her own list before she changes it, so
    /// editing an English built-in list doesn't bring the Hebrew one back.
    private func adoptDisplayedQuickPhrases() {
        settings.quickPhrases = quickPhrases
    }

    public func addQuickPhrase(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !quickPhrases.contains(trimmed) else { return }
        adoptDisplayedQuickPhrases()
        settings.quickPhrases.append(trimmed)
        persist()
    }

    public func removeQuickPhrases(at offsets: IndexSet) {
        adoptDisplayedQuickPhrases()
        settings.quickPhrases.remove(atOffsets: offsets)
        persist()
    }

    public func moveQuickPhrases(from source: IndexSet, to destination: Int) {
        adoptDisplayedQuickPhrases()
        settings.quickPhrases.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    public func resetQuickPhrases() {
        settings.quickPhrases = AppSettings.defaultQuickPhrases(for: uiLanguage)
        persist()
    }

    // MARK: - Speakers

    /// Records `seconds` of the person talking and saves them as a named
    /// profile. Returns false if the recording was too short/quiet to get
    /// a usable voice print.
    public func enroll(name: String, seconds: Double, onProgress: @MainActor (Double) -> Void) async -> Bool {
        let samples = await pipeline.captureEnrollmentSamples(seconds: seconds, onProgress: onProgress)
        // Stopped midway: the part recorded isn't kept as her voice.
        guard !Task.isCancelled else { return false }
        guard let embedding = await pipeline.embeddingInBackground(forEnrollmentSamples: samples),
              !Task.isCancelled
        else { return false }
        return save(name: name, embedding: embedding)
    }

    @discardableResult
    public func enroll(name: String, samples: [Float]) -> Bool {
        guard let embedding = pipeline.embedding(forEnrollmentSamples: samples) else { return false }
        return save(name: name, embedding: embedding)
    }

    private func save(name: String, embedding: [Float]) -> Bool {
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
        speakerLabelsChanged()
    }

    /// Deletes a person from the saved speakers: every voice print with
    /// that name.
    public func removeSpeaker(named name: String) {
        guard settings.speakerProfiles.contains(where: { $0.name == name }) else { return }
        settings.speakerProfiles.removeAll { $0.name == name }
        persist()
        pipeline.forgetSpeakerName(name)
        speakerLabelsChanged()
    }

    public func removeProfile(id: UUID) {
        guard let removed = settings.speakerProfiles.first(where: { $0.id == id }) else { return }
        settings.speakerProfiles.removeAll { $0.id == id }
        persist()
        // Another saved profile may share the name; only forget it when
        // nobody by that name is left.
        if !settings.speakerProfiles.contains(where: { $0.name == removed.name }) {
            pipeline.forgetSpeakerName(removed.name)
        } else {
            pipeline.forgetProfile(id: removed.id)
        }
        speakerLabelsChanged()
    }

    /// Fixes a misspelled or changed name: the saved profile, the lines on
    /// screen, and the names list all follow.
    /// Renames the person `id` belongs to: every saved voice print with
    /// that name, like the labels on screen.
    public func renameProfile(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = settings.speakerProfiles.firstIndex(where: { $0.id == id }),
              settings.speakerProfiles[index].name != trimmed
        else { return }
        let oldName = settings.speakerProfiles[index].name
        for other in settings.speakerProfiles.indices where settings.speakerProfiles[other].name == oldName {
            settings.speakerProfiles[other].name = trimmed
        }
        if let term = settings.vocabulary.firstIndex(of: oldName) {
            settings.vocabulary[term] = trimmed
            settings.vocabulary = VocabularyHints.normalized(settings.vocabulary)
            vocabularyChanged()
        } else {
            persist()
        }
        pipeline.renameSpeakers(named: oldName, to: trimmed)
        speakerLabelsChanged()
    }

    /// A name was given, changed or removed. The lines on screen show the
    /// new labels at once; the saved copies of their conversations have to
    /// be written again to match. The open conversation's autosave would
    /// catch up, but one that a quiet break had already closed and saved
    /// kept the old names in History for good.
    private func speakerLabelsChanged() {
        for closed in closedHistorySessions {
            saveClosed(closed)
        }
        if !currentHistorySegments.isEmpty {
            persistHistory(ended: false, inBackground: true)
        }
        refreshLockScreen()
    }

    public func displayName(for segment: TranscriptSegment) -> String {
        pipeline.displayName(for: segment)
    }

    /// Who said the line a keyword hit matched, respecting the same
    /// show-speaker-names setting the caption rows themselves do -- a
    /// keyword banner shouldn't reveal a name the rest of the screen is
    /// hiding.
    public func speakerName(for hit: KeywordHit) -> String? {
        guard display.showSpeakerNames,
              let segment = segments.first(where: { $0.id == hit.segmentID }),
              segment.speakerClusterID != nil
        else { return nil }
        return displayName(for: segment)
    }

    // MARK: - History

    /// Writes the current transcript to history (if there is anything and
    /// history is on). Called by the autosave loop, on every phase change,
    /// and when the app goes to the background — so a conversation is never
    /// lost to a crash or a force-quit.
    ///
    /// `inBackground` is for the periodic autosave: the conversation is
    /// encoded and written off the main thread so a long one doesn't
    /// stutter the captions. Every other save waits until it is on disk.
    /// What is actually writing the captions: her settings, or the phone's
    /// own model while it covers for the cloud (see `isCoveringForCloud`).
    /// A saved conversation says which engine wrote it.
    private var transcribingSettings: AppSettings {
        pipeline.isCoveringForCloud ? (pipeline.activeSettings ?? settings) : settings
    }

    public func persistHistory(ended: Bool, endedAt: TimeInterval? = nil, inBackground: Bool = false) {
        // After a conversation break the next conversation starts at its
        // first line, not at the moment the break was noticed.
        guard settings.saveHistory,
              let startedAt = historySessionStartedAt ?? currentHistorySegments.first?.startTimestamp
        else { return }
        let record = TranscriptSessionRecord.make(
            from: currentHistorySegments,
            speakerName: { [pipeline] in pipeline.displayName(for: $0) },
            id: historySessionID,
            startedAt: startedAt,
            endedAt: ended ? (endedAt ?? Date().timeIntervalSince1970) : nil,
            engine: transcribingSettings.engine,
            modelVariant: transcribingSettings.modelDescription,
            inputName: selectedInput?.portName,
            starred: starredSegmentIDs
        )
        if inBackground {
            saveInBackground(record)
        } else {
            historyWriter.saveNow(record)
            refreshSavingTrouble()
        }
    }

    /// Saves without holding up the captions, and has the saving-failed
    /// banner reflect this save as soon as it lands, not at the next one.
    private func saveInBackground(_ record: TranscriptSessionRecord) {
        historyWriter.saveInBackground(record) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshSavingTrouble() }
        }
    }

    /// Returns once every history save already asked for has finished.
    func waitForHistorySaves() {
        historyWriter.waitUntilIdle()
    }

    /// Why the latest history save didn't reach the disk, or nil when it
    /// did. Read when a screen draws; it isn't observed.
    public var historySaveFailure: String? { historyWriter.lastFailure }

    /// Names a saved conversation, in order with any autosave in flight.
    public func renameConversation(id: UUID, title: String) {
        historyWriter.renameNow(id: id, title: title)
        refreshSavingTrouble()
    }

    /// Hides the saving-failed banner until saving works and fails again.
    public func dismissSavingTrouble() {
        savingTrouble.dismiss()
    }

    private func refreshSavingTrouble() {
        var next = savingTrouble
        next.update(
            settingsFailed: settingsSaveError != nil,
            historyFailed: settings.saveHistory && historySaveFailure != nil
        )
        // Only a real change redraws the caption screen.
        if next != savingTrouble { savingTrouble = next }
    }

    /// Deletes a saved conversation. If it is the one still being
    /// captioned, the lines already on screen stay there but are no longer
    /// saved: the next words start a new conversation, so the autosave
    /// can't quietly bring the deleted one back.
    public func deleteConversation(id: UUID) throws {
        // Disk first: if the delete fails, the conversation on screen keeps
        // saving to the record that is still there. Nothing can queue an
        // autosave in between, since this runs on the main actor.
        try historyWriter.deleteNow(id: id)
        closedHistorySessions.removeAll { $0.id == id }
        if id == historySessionID {
            forgetCurrentConversation()
        }
    }

    /// The saved conversation the line at `index` belongs to, so the
    /// caption screen can open it; nil when saving is off or failing (it
    /// might never have reached the disk) or that conversation was deleted.
    public func savedConversationID(holdingLineAt index: Int) -> UUID? {
        guard settings.saveHistory, historySaveFailure == nil, pipeline.segments.indices.contains(index) else { return nil }
        if index >= historySegmentOffset { return historySessionID }
        return closedHistorySessions.last(where: { $0.lines.contains(index) })?.id
    }

    /// Whether `id` is the conversation still being captioned right now --
    /// its saved copy keeps changing underneath a screen that opened it,
    /// unlike every other (closed) conversation's, which is fixed for good.
    public func isCurrentConversation(_ id: UUID) -> Bool {
        id == historySessionID
    }

    /// Deletes every saved conversation, including the one in progress.
    public func deleteAllConversations() throws {
        try historyWriter.deleteAllNow()
        closedHistorySessions = []
        forgetCurrentConversation()
    }

    private func forgetCurrentConversation() {
        historySessionID = UUID()
        historySegmentOffset = pipeline.segments.count
        historySessionStartedAt = nil
    }

    private var currentHistorySegments: [TranscriptSegment] {
        let segments = pipeline.segments
        guard historySegmentOffset > 0 else { return segments }
        return Array(segments.dropFirst(min(historySegmentOffset, segments.count)))
    }

    /// Closes the saved conversation after a long quiet stretch, so the
    /// next words start a new one. Returns whether it did.
    @discardableResult
    public func checkForConversationBreak(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let lastCaptionAt = currentHistorySegments.map(\.lastUpdateTimestamp).max()
        guard ConversationBreak.shouldStartNew(lastCaptionAt: lastCaptionAt, now: now) else { return false }
        persistHistory(ended: true, endedAt: lastCaptionAt)
        if let startedAt = historySessionStartedAt ?? currentHistorySegments.first?.startTimestamp {
            closedHistorySessions.append(ClosedHistorySession(
                id: historySessionID,
                lines: historySegmentOffset..<pipeline.segments.count,
                startedAt: startedAt,
                endedAt: lastCaptionAt,
                engine: transcribingSettings.engine,
                modelVariant: transcribingSettings.modelDescription,
                inputName: selectedInput?.portName
            ))
        }
        historySessionID = UUID()
        historySegmentOffset = pipeline.segments.count
        historySessionStartedAt = nil
        pipeline.startNewConversation()
        return true
    }

    /// Keeps the autosave loop matched to whether we're listening.
    public func historySessionDidChangePhase() {
        historySawListening = pipeline.phase.isListening
        if pipeline.phase.isListening {
            checkForConversationBreak()
            if historySessionStartedAt == nil {
                historySessionStartedAt = Date().timeIntervalSince1970
            }
            if autosaveTask == nil {
                autosaveTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: Self.autosaveIntervalSeconds * 1_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        if !self.checkForConversationBreak() {
                            self.persistHistory(ended: false, inBackground: true)
                        }
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

    private var pendingPersistTask: Task<Void, Never>?

    private func persist() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        do {
            try settingsStore.save(settings)
            if settingsSaveError != nil { settingsSaveError = nil }
        } catch {
            settingsSaveError = String(describing: error)
        }
        refreshSavingTrouble()
    }

    /// Coalesces rapid-fire settings changes into one write instead of
    /// many: a Slider fires its binding's setter at every step while
    /// dragging, not only on release, so a property driven by one (font
    /// size, speech rate, the speaker-similarity threshold) would
    /// otherwise trigger a full synchronous settings-file write per step.
    /// `flushPendingSettingsSave()` writes immediately if the app leaves
    /// the foreground before the debounce fires, so a change made right
    /// before backgrounding is never lost.
    private func schedulePersist() {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    public func flushPendingSettingsSave() {
        guard pendingPersistTask != nil else { return }
        persist()
    }
}

/// What the outside world (Siri, Shortcuts, a URL) can ask the app to do.
public enum AppAction: Equatable, Sendable {
    case startCaptions
    case stopCaptions
    case speak(String)
    /// The full-screen pad in big letters, for someone to type to her.
    case showBigText
}
