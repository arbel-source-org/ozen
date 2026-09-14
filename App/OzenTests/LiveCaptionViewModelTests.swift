import Testing
@testable import Ozen
@testable import OzenKit
import Foundation

// Runs only via `xcodebuild test` on a macOS CI runner (needs the real app
// target). The fakes (FakeAudioCapturer, FakeEngine, FakeEmbedder) come
// from Tests/OzenKitTests, which is compiled into this same test bundle,
// so the view model can be driven end to end without a microphone.
@Suite("LiveCaptionViewModel")
@MainActor
struct LiveCaptionViewModelTests {
    private func temporaryStore() -> SettingsStore {
        SettingsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-vm-test-\(UUID()).json"))
    }

    private func fakePipeline(audio: FakeAudioCapturer = FakeAudioCapturer()) -> CaptionPipeline {
        CaptionPipeline(
            audio: audio,
            engineFactory: { settings in FakeEngine(kind: settings.engine) },
            embedder: FakeEmbedder()
        )
    }

    @Test("a fresh view model loads default settings when no settings file exists yet")
    func loadsDefaultsWithNoExistingFile() {
        let viewModel = LiveCaptionViewModel(settingsStore: temporaryStore(), pipeline: fakePipeline())

        #expect(viewModel.settings.engine == .whisperKit)
        #expect(viewModel.settings.languageCode == "he")
        #expect(viewModel.segments.isEmpty)
        #expect(!viewModel.isListening)
        #expect(viewModel.phase == .idle)
    }

    @Test("start() drives the pipeline to listening")
    func startListens() async {
        let viewModel = LiveCaptionViewModel(settingsStore: temporaryStore(), pipeline: fakePipeline())
        await viewModel.start()

        #expect(viewModel.isListening)
        #expect(viewModel.availableInputs.count == 1)
        #expect(viewModel.selectedInput?.portType == .builtInMic)
    }

    @Test("switching engines persists to the settings file and restarts the pipeline on the new engine")
    func settingEnginePersistsAndRestarts() async {
        let store = temporaryStore()
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: fakePipeline())
        await viewModel.start()

        await viewModel.setEngine(.appleSpeech)

        #expect(store.load().engine == .appleSpeech)
        #expect(viewModel.pipeline.activeEngineKind == .appleSpeech)
        #expect(viewModel.isListening)
        #expect(viewModel.stats.engineRestarts == 1)
    }

    @Test("choosing a Whisper model persists, and only restarts when Whisper is the active engine")
    func modelChoice() async {
        let store = temporaryStore()
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: fakePipeline())
        await viewModel.start()

        await viewModel.setWhisperModel(WhisperModelCatalog.recommendedVariant)
        #expect(store.load().whisperModelVariant == WhisperModelCatalog.recommendedVariant)
        #expect(viewModel.stats.engineRestarts == 1)

        await viewModel.setEngine(.appleSpeech)
        await viewModel.setWhisperModel("small")
        #expect(viewModel.stats.engineRestarts == 2)
    }

    @Test("display preferences persist without touching the pipeline")
    func displayPersists() async {
        let store = temporaryStore()
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: fakePipeline())
        await viewModel.start()

        viewModel.display.fontSize = 44
        viewModel.display.theme = .highContrast

        #expect(store.load().display.fontSize == 44)
        #expect(store.load().display.theme == .highContrast)
        #expect(viewModel.stats.engineRestarts == 0)
        #expect(viewModel.isListening)
    }

    @Test("selecting a microphone remembers it for next launch")
    func micSelectionPersists() async {
        let store = temporaryStore()
        let audio = FakeAudioCapturer()
        audio.availableInputs.append(AudioInputDescriptor(uid: "lav", portName: "USB Lavalier", portType: .usb))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: fakePipeline(audio: audio))
        await viewModel.start()

        viewModel.selectInput(uid: "lav")

        #expect(viewModel.selectedInputUID == "lav")
        #expect(store.load().preferredInputUID == "lav")
    }

    @Test("saved speaker profiles are enrolled into the pipeline on launch")
    func profilesEnrolledOnLaunch() throws {
        let store = temporaryStore()
        var settings = AppSettings.default
        settings.speakerProfiles = [SpeakerProfile(name: "דנה", embedding: [1, 0, 0])]
        try store.save(settings)

        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: fakePipeline())

        #expect(viewModel.pipeline.speakerClusters.map(\.name) == ["דנה"])
    }

    @Test("enrolling from samples saves a profile; too little audio saves nothing")
    func enrollFromSamples() {
        let store = temporaryStore()
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: fakePipeline())

        #expect(!viewModel.enroll(name: "ריק", samples: []))
        #expect(viewModel.enroll(name: "סבתא", samples: [Float](repeating: 0.5, count: 96_000)))
        #expect(store.load().speakerProfiles.map(\.name) == ["סבתא"])

        viewModel.removeProfile(id: viewModel.settings.speakerProfiles[0].id)
        #expect(store.load().speakerProfiles.isEmpty)
    }

    @Test("pause and resume round-trip through the pipeline")
    func pauseResume() async {
        let viewModel = LiveCaptionViewModel(settingsStore: temporaryStore(), pipeline: fakePipeline())
        await viewModel.start()

        await viewModel.togglePause()
        #expect(viewModel.phase == .paused)
        await viewModel.togglePause()
        #expect(viewModel.isListening)
    }
}

@Suite("LiveCaptionViewModel alerts and history")
@MainActor
struct LiveCaptionViewModelAlertTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ozen-\(name)-\(UUID())")
    }

    @Test("keyword alerts round-trip through settings and reach the pipeline without a restart")
    func keywordAlertsCRUD() async {
        let store = SettingsStore(fileURL: temporaryURL("vm").appendingPathExtension("json"))
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline)
        await viewModel.start()

        viewModel.addKeywordAlert(phrase: " סבתא ")
        viewModel.addKeywordAlert(phrase: "סבתא")   // duplicate, ignored
        #expect(viewModel.keywordAlerts.count == 1)
        #expect(store.load().keywordAlerts.first?.phrase == "סבתא")
        #expect(viewModel.stats.engineRestarts == 0)

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "שלום לסבתא", isFinal: false, timestamp: 1))
        await eventually { !viewModel.keywordHits.isEmpty }
        #expect(viewModel.keywordHits.count == 1)

        let id = viewModel.keywordAlerts[0].id
        viewModel.setKeywordAlert(id: id, enabled: false)
        #expect(store.load().keywordAlerts.first?.isEnabled == false)
        viewModel.removeKeywordAlert(id: id)
        #expect(store.load().keywordAlerts.isEmpty)
    }

    @Test("sound preferences persist and unsupported sounds are reported as such")
    func soundPreferences() {
        let store = SettingsStore(fileURL: temporaryURL("vm").appendingPathExtension("json"))
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, knownSoundIdentifiers: ["door_bell"])

        viewModel.setSoundEvent("dog_bark", muted: true)
        viewModel.soundAlertPreferences.minimumImportance = .high
        #expect(store.load().soundAlerts.mutedIdentifiers == ["dog_bark"])
        #expect(store.load().soundAlerts.minimumImportance == .high)
        #expect(pipeline.soundPolicy.preferences.mutedIdentifiers == ["dog_bark"])
        #expect(viewModel.isSoundEventSupported("door_bell"))
        #expect(!viewModel.isSoundEventSupported("knock"))
    }

    @Test("a conversation is saved to history when listening stops, and clearing starts a new session")
    func historySaved() async {
        let store = SettingsStore(fileURL: temporaryURL("vm").appendingPathExtension("json"))
        let history = TranscriptHistoryStore(directoryURL: temporaryURL("history"))
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, historyStore: history)
        await viewModel.start()

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "בוקר טוב", isFinal: true, timestamp: 1))
        await eventually { !viewModel.segments.isEmpty }

        await viewModel.togglePause()
        let sessions = history.listSummaries()
        #expect(sessions.count == 1)
        #expect(sessions.first?.preview == "בוקר טוב")
        #expect(sessions.first?.endedAt != nil)

        await viewModel.togglePause()
        viewModel.clearTranscript()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "ערב טוב", isFinal: true, timestamp: 2))
        await eventually { !viewModel.segments.isEmpty }
        viewModel.persistHistory(ended: true)
        #expect(history.listSummaries().count == 2)
    }

    @Test("an autosave still being written never lands on top of the final save")
    func autosaveThenFinalSave() async {
        let store = SettingsStore(fileURL: temporaryURL("vm").appendingPathExtension("json"))
        let history = TranscriptHistoryStore(directoryURL: temporaryURL("history"))
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, historyStore: history)
        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "שלום", isFinal: true, timestamp: 1))
        await eventually { !viewModel.segments.isEmpty }

        viewModel.persistHistory(ended: false, inBackground: true)
        viewModel.persistHistory(ended: true)

        let sessions = history.listSummaries()
        #expect(sessions.count == 1)
        #expect(sessions.first?.endedAt != nil)
    }

    @Test("history is not written when saving is switched off")
    func historyOff() async {
        let store = SettingsStore(fileURL: temporaryURL("vm").appendingPathExtension("json"))
        let history = TranscriptHistoryStore(directoryURL: temporaryURL("history"))
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, historyStore: history)
        viewModel.saveHistory = false
        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "לא לשמור", isFinal: true, timestamp: 1))
        try? await Task.sleep(for: .milliseconds(50))
        await viewModel.togglePause()

        #expect(history.listSummaries().isEmpty)
    }
}

@Suite("LiveCaptionViewModel vocabulary")
@MainActor
struct LiveCaptionViewModelVocabularyTests {
    private func makeViewModel() throws -> (LiveCaptionViewModel, FakeEngine, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder()
        )
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let viewModel = LiveCaptionViewModel(
            settingsStore: store,
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: dir.appendingPathComponent("history", isDirectory: true))
        )
        return (viewModel, engine, dir.appendingPathComponent("settings.json"))
    }

    @Test("adding a name cleans it, persists it, and hands it to the running engine")
    func addTerm() async throws {
        let (viewModel, engine, file) = try makeViewModel()
        await viewModel.start()
        viewModel.addVocabularyTerm("  רותי ")
        viewModel.addVocabularyTerm("רותי")
        #expect(viewModel.vocabulary == ["רותי"])
        let saved = SettingsStore(fileURL: file).load()
        #expect(saved.vocabulary == ["רותי"])
        await eventually { engine.vocabularySeen.last == ["רותי"] }
        #expect(engine.vocabularySeen.last == ["רותי"])
    }

    @Test("speaker profile names can be added in one go, without duplicating names already listed")
    func addSpeakers() throws {
        let (viewModel, _, _) = try makeViewModel()
        viewModel.addVocabularyTerm("אבי")
        // FakeEmbedder keys the voice off the first sample, so two
        // different leading values enroll two different people.
        #expect(viewModel.enroll(name: "אבי", samples: [Float](repeating: 0.2, count: 96_000)))
        #expect(viewModel.enroll(name: "רותי", samples: [Float](repeating: 0.7, count: 96_000)))
        viewModel.addSpeakerNamesToVocabulary()
        #expect(viewModel.vocabulary == ["אבי", "רותי"])
    }
}

@Suite("LiveCaptionViewModel onboarding and app actions")
@MainActor
struct LiveCaptionViewModelOnboardingTests {
    private func makeViewModel() -> (LiveCaptionViewModel, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-onboarding-\(UUID()).json")
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in FakeEngine(kind: settings.engine) },
            embedder: FakeEmbedder()
        )
        return (LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: file), pipeline: pipeline), file)
    }

    @Test("a fresh install shows onboarding; finishing it is remembered on disk")
    func onboardingPersists() {
        let (viewModel, file) = makeViewModel()
        #expect(viewModel.hasCompletedOnboarding == false)
        viewModel.completeOnboarding()
        #expect(viewModel.hasCompletedOnboarding)
        #expect(SettingsStore(fileURL: file).load().hasCompletedOnboarding)
        viewModel.showOnboardingAgain()
        #expect(SettingsStore(fileURL: file).load().hasCompletedOnboarding == false)
    }

    @Test("a Siri start / stop drives the pipeline like the buttons do")
    func appActions() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.perform(.startCaptions)
        #expect(viewModel.phase.isListening)
        // Starting again while listening is a no-op, not a restart.
        await viewModel.perform(.startCaptions)
        #expect(viewModel.phase.isListening)
        await viewModel.perform(.stopCaptions)
        #expect(viewModel.phase == .idle)
        // Without a synthesizer wired in, "say" is harmless.
        await viewModel.perform(.speak("שלום"))
        #expect(viewModel.phase == .idle)
    }

    @Test("the pending-action mailbox hands every action over exactly once, oldest first")
    func mailbox() {
        let box = PendingAppAction.shared
        _ = box.takeAll()
        let before = box.serial
        box.post(.stopCaptions)
        box.post(.speak("יוצאת עכשיו"))
        #expect(box.serial == before + 2)
        #expect(box.takeAll() == [.stopCaptions, .speak("יוצאת עכשיו")])
        #expect(box.takeAll().isEmpty)
    }
}

@Suite("LiveCaptionViewModel speaking over captions")
@MainActor
struct LiveCaptionViewModelSpeechTests {
    private func makeViewModel(audio: FakeAudioCapturer = FakeAudioCapturer()) -> (LiveCaptionViewModel, FakeSynthesizer) {
        let synthesizer = FakeSynthesizer()
        let pipeline = CaptionPipeline(
            audio: audio,
            engineFactory: { settings in FakeEngine(kind: settings.engine) },
            embedder: FakeEmbedder()
        )
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-speech-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, synthesizer: synthesizer)
        return (viewModel, synthesizer)
    }

    @Test("captions pause while the phone talks and come back by themselves afterwards")
    func roundTrip() async {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        #expect(viewModel.phase.isListening)
        viewModel.speak("כן")
        #expect(viewModel.phase == .paused)
        #expect(viewModel.captionsHeldForSpeech)
        synthesizer.startNext()
        synthesizer.finishCurrent()
        await eventually { viewModel.phase.isListening }
        #expect(viewModel.phase.isListening)
        #expect(viewModel.captionsHeldForSpeech == false)
    }

    @Test("a second phrase tapped while the first plays keeps captions paused until the last one ends")
    func secondPhraseDuringFirst() async throws {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        viewModel.speak("כן")
        synthesizer.startNext()
        viewModel.speak("תודה")
        synthesizer.deliverCallbacks()
        try await Task.sleep(for: .seconds(SpeechPauseCoordinator.settleSeconds + 0.3))
        #expect(viewModel.phase == .paused)
        synthesizer.startNext()
        synthesizer.finishCurrent()
        await eventually { viewModel.phase.isListening }
        #expect(viewModel.phase.isListening)
        #expect(synthesizer.requests == ["כן", "תודה"])
    }

    @Test("pausing by hand while the phone talks is respected; captions stay paused afterwards")
    func manualPauseWins() async throws {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        viewModel.speak("רגע")
        synthesizer.startNext()
        // The status control while paused means "resume"; tap it twice:
        // resume, then pause again by hand.
        await viewModel.togglePause()
        await viewModel.togglePause()
        #expect(viewModel.phase == .paused)
        synthesizer.finishCurrent()
        try await Task.sleep(for: .seconds(SpeechPauseCoordinator.settleSeconds + 0.3))
        #expect(viewModel.phase == .paused)
    }

    @Test("a phrase tapped while captions are still starting holds them once they come on, until it ends")
    func phraseDuringStartup() async {
        let (viewModel, synthesizer) = makeViewModel()
        let starting = Task { await viewModel.start() }
        viewModel.speak("רגע")
        synthesizer.startNext()
        await starting.value
        #expect(await eventually { viewModel.phase == .paused })
        synthesizer.finishCurrent()
        #expect(await eventually { viewModel.phase.isListening })
    }

    @Test("stopping the phone mid-phrase from the status line brings captions back by themselves")
    func stopSpeakingResumes() async {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        viewModel.speak("משפט ארוך מאוד")
        synthesizer.startNext()
        viewModel.stopSpeaking()
        synthesizer.deliverCallbacks()
        #expect(await eventually { viewModel.phase.isListening })
    }

    @Test("a call that cuts off the phone's voice doesn't leave captions paused for good; they return after it")
    func callDuringPhrase() async {
        let audio = FakeAudioCapturer()
        let (viewModel, synthesizer) = makeViewModel(audio: audio)
        await viewModel.start()
        viewModel.speak("רגע")
        synthesizer.startNext()
        #expect(viewModel.phase == .paused)

        viewModel.systemInterruptionChanged(began: true)
        #expect(synthesizer.isBusy == false)
        // The call holds the microphone: the try to bring captions back
        // is refused, and nothing is retried while the call goes on.
        audio.prepareError = TestError()
        synthesizer.deliverCallbacks()
        #expect(await eventually { viewModel.phase.failure != nil })
        #expect(viewModel.pipeline.scheduledRetry == nil)

        audio.prepareError = nil
        viewModel.systemInterruptionChanged(began: false)
        #expect(await eventually { viewModel.phase.isListening })
    }

    @Test("launched by Siri to say something: the phone talks first, then captions start")
    func launchWithSpeech() async throws {
        let (viewModel, synthesizer) = makeViewModel()
        let launch = Task { await viewModel.launch(pending: .speak("אני באה")) }
        #expect(await eventually { synthesizer.requests == ["אני באה"] })
        synthesizer.startNext()
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.phase == .idle)
        synthesizer.finishCurrent()
        await launch.value
        #expect(viewModel.phase.isListening)
    }

    @Test("two requests that launched the app together both happen, in order")
    func launchWithTwoRequests() async {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.handle(pending: [.stopCaptions, .speak("יוצאת עכשיו")], isFirstAppearance: true)
        #expect(viewModel.phase == .idle)
        #expect(synthesizer.requests == ["יוצאת עכשיו"])
    }

    @Test("requests arriving while the app is open are all carried out")
    func laterRequests() async {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        await viewModel.handle(pending: [.speak("רגע"), .stopCaptions], isFirstAppearance: false)
        #expect(synthesizer.requests == ["רגע"])
        #expect(viewModel.phase == .idle)
    }

    @Test("\"write to me\" opens the big-letters pad, with captions running behind it")
    func bigText() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.launch(pending: .showBigText)
        #expect(viewModel.isShowingBigText)
        #expect(viewModel.phase.isListening)

        viewModel.isShowingBigText = false
        await viewModel.handle(pending: [.showBigText], isFirstAppearance: false)
        #expect(viewModel.isShowingBigText)
    }

    @Test("launched by Siri to stop: nothing starts")
    func launchWithStop() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.launch(pending: .stopCaptions)
        #expect(viewModel.phase == .idle)
    }

    @Test("empty or blank text is never sent to the voice and never pauses captions")
    func blankText() async {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        viewModel.speak("   ")
        #expect(synthesizer.requests.isEmpty)
        #expect(viewModel.phase.isListening)
    }
}

@Suite("LiveCaptionViewModel saved speakers")
@MainActor
struct LiveCaptionViewModelSpeakerTests {
    private func makeViewModel() -> (LiveCaptionViewModel, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-speakers-\(UUID()).json")
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in FakeEngine(kind: settings.engine) },
            embedder: FakeEmbedder()
        )
        return (LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: file), pipeline: pipeline), file)
    }

    @Test("renaming a speaker updates the profile on disk, the names list and the live label")
    func rename() {
        let (viewModel, file) = makeViewModel()
        #expect(viewModel.enroll(name: "אבי", samples: [Float](repeating: 0.3, count: 96_000)))
        viewModel.addVocabularyTerm("אבי")
        let id = viewModel.settings.speakerProfiles[0].id

        viewModel.renameProfile(id: id, to: "  אביגדור ")
        #expect(viewModel.settings.speakerProfiles[0].name == "אביגדור")
        #expect(viewModel.vocabulary == ["אביגדור"])
        #expect(SettingsStore(fileURL: file).load().speakerProfiles.first?.name == "אביגדור")
        #expect(viewModel.pipeline.speakerClusters.contains { $0.name == "אביגדור" })
        #expect(viewModel.pipeline.speakerClusters.contains { $0.name == "אבי" } == false)
    }

    @Test("a person saved with two voice prints is renamed and deleted as one")
    func twoPrintsOnePerson() {
        let (viewModel, file) = makeViewModel()
        #expect(viewModel.enroll(name: "Dana", samples: [Float](repeating: 0.3, count: 96_000)))
        #expect(viewModel.enroll(name: "Avi", samples: [Float](repeating: 0.3, count: 96_000)))
        #expect(viewModel.enroll(name: "Dana", samples: [Float](repeating: 0.3, count: 96_000)))

        viewModel.renameProfile(id: viewModel.settings.speakerProfiles[2].id, to: "Daniela")
        #expect(viewModel.settings.speakerProfiles.map(\.name) == ["Daniela", "Avi", "Daniela"])
        #expect(SettingsStore(fileURL: file).load().speakerProfiles.map(\.name) == ["Daniela", "Avi", "Daniela"])
        #expect(!viewModel.pipeline.speakerClusters.contains { $0.name == "Dana" })

        viewModel.removeSpeaker(named: "Daniela")
        #expect(viewModel.settings.speakerProfiles.map(\.name) == ["Avi"])
        #expect(SettingsStore(fileURL: file).load().speakerProfiles.map(\.name) == ["Avi"])
        #expect(!viewModel.pipeline.speakerClusters.contains { $0.name == "Daniela" })
    }

    @Test("a blank new name is ignored")
    func blankRename() {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.enroll(name: "רותי", samples: [Float](repeating: 0.3, count: 96_000)))
        viewModel.renameProfile(id: viewModel.settings.speakerProfiles[0].id, to: "   ")
        #expect(viewModel.settings.speakerProfiles[0].name == "רותי")
    }

    @Test("deleting a speaker stops their name from labeling lines")
    func deleteForgets() {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.enroll(name: "רותי", samples: [Float](repeating: 0.3, count: 96_000)))
        viewModel.removeProfile(id: viewModel.settings.speakerProfiles[0].id)
        #expect(viewModel.settings.speakerProfiles.isEmpty)
        #expect(viewModel.pipeline.speakerClusters.contains { $0.name == "רותי" } == false)
    }
}

@Suite("LiveCaptionViewModel notifications in the background")
@MainActor
struct LiveCaptionViewModelBackgroundAlertTests {
    @Test("a keyword heard while the app is in the background posts one notification; in front it posts none")
    func keywordNotification() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        var posted: [AlertNotificationContent] = []
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-bg-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, postNotification: { posted.append($0) })
        viewModel.addKeywordAlert(phrase: "סבתא")
        await viewModel.start()

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "סבתא, הגענו", isFinal: true, timestamp: Date().timeIntervalSince1970))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(posted.isEmpty)

        viewModel.sceneActivityChanged(isActive: false)
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "סבתא, את ערה?", isFinal: true, timestamp: Date().timeIntervalSince1970))
        await eventually { !posted.isEmpty }
        #expect(posted.count == 1)
        #expect(posted.first?.title == "נאמר: סבתא")
        #expect(posted.first?.body == "סבתא, את ערה?")
    }

    @Test("lines said while the app was away are marked from the first of them; clearing removes the mark")
    func awayLinesMarked() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-away-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, postNotification: { _ in })
        viewModel.awayCatchUp = AwayCatchUp(minimumAwaySeconds: 0)
        await viewModel.start()

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "read before leaving", isFinal: true, timestamp: Date().timeIntervalSince1970 - 60))
        await eventually { viewModel.segments.count == 1 }
        viewModel.sceneActivityChanged(isActive: false)
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "missed one", isFinal: true, timestamp: Date().timeIntervalSince1970))
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "missed two", isFinal: true, timestamp: Date().timeIntervalSince1970))
        await eventually { viewModel.segments.count == 3 }
        #expect(viewModel.awayCatchUp.firstMissedIndex(in: viewModel.segments) == nil)

        viewModel.sceneActivityChanged(isActive: true)
        #expect(viewModel.awayCatchUp.firstMissedIndex(in: viewModel.segments) == 1)
        #expect(viewModel.awayCatchUp.offersJump(in: viewModel.segments))
        viewModel.acknowledgeAwayLines()
        #expect(!viewModel.awayCatchUp.offersJump(in: viewModel.segments))

        viewModel.clearTranscript()
        #expect(viewModel.awayCatchUp.away == nil)
    }

    @Test("a low battery becomes a notification only while the app is in the background")
    func batteryNotification() {
        var posted: [AlertNotificationContent] = []
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-bg-\(UUID()).json"))
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, postNotification: { posted.append($0) })

        viewModel.batteryWarningRaised(.low(percent: 20))
        #expect(posted.isEmpty)

        viewModel.sceneActivityChanged(isActive: false)
        viewModel.batteryWarningRaised(.critical(percent: 10))
        #expect(posted.map(\.title) == ["הסוללה ב-10%"])

        viewModel.notifyWhenInBackground = false
        viewModel.batteryWarningRaised(.critical(percent: 9))
        #expect(posted.count == 1)
    }

    @Test("switching the setting off stops notifications")
    func settingOff() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        var posted: [AlertNotificationContent] = []
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-bg-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, postNotification: { posted.append($0) })
        viewModel.addKeywordAlert(phrase: "סבתא")
        viewModel.notifyWhenInBackground = false
        viewModel.sceneActivityChanged(isActive: false)
        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "סבתא", isFinal: true, timestamp: Date().timeIntervalSince1970))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(posted.isEmpty)
        #expect(store.load().notifyWhenInBackground == false)
    }
}

@Suite("LiveCaptionViewModel conversation breaks")
@MainActor
struct LiveCaptionViewModelConversationBreakTests {
    @Test("after twenty quiet minutes the saved conversation closes and new lines save separately, screen untouched")
    func splitsAfterLongQuiet() async throws {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-break-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory)
        let store = SettingsStore(fileURL: directory.appendingPathExtension("json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, historyStore: history)
        await viewModel.start()

        let longAgo = Date().timeIntervalSince1970 - 30 * 60
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "בוקר טוב", isFinal: true, timestamp: longAgo))
        await eventually { !viewModel.segments.isEmpty }

        #expect(viewModel.checkForConversationBreak())
        #expect(history.listSummaries().count == 1)
        #expect(history.listSummaries().first?.durationSeconds != nil)

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "ערב טוב", isFinal: true, timestamp: Date().timeIntervalSince1970))
        await eventually { viewModel.segments.count >= 2 }
        viewModel.persistHistory(ended: false)

        let summaries = history.listSummaries()
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.preview)) == ["בוקר טוב", "ערב טוב"])
        // The new conversation starts at its first line, not at the check.
        let evening = summaries.first { $0.preview == "ערב טוב" }
        #expect(evening.map { abs($0.startedAt - viewModel.segments[1].startTimestamp) < 0.001 } == true)
        // The screen still shows both lines.
        #expect(viewModel.segments.count == 2)
        // And a second check right away doesn't split again.
        #expect(viewModel.checkForConversationBreak() == false)
    }
}

@Suite("LiveCaptionViewModel interruption whose end was never announced")
@MainActor
struct LiveCaptionViewModelMissedInterruptionEndTests {
    private final class Reclaimer {
        var answer: Bool
        var calls = 0
        init(answer: Bool) { self.answer = answer }
    }

    private func makeViewModel(reclaimer: Reclaimer, engine: FakeEngine = FakeEngine()) -> LiveCaptionViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-interrupt-\(UUID())", isDirectory: true)
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: [])
        )
        return LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathExtension("json")),
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: directory),
            reclaimAudioSession: {
                reclaimer.calls += 1
                return reclaimer.answer
            }
        )
    }

    @Test("back on screen after the call, captions that failed during it recover")
    func reclaimsAndRecovers() async {
        let reclaimer = Reclaimer(answer: true)
        let engine = FakeEngine()
        let viewModel = makeViewModel(reclaimer: reclaimer, engine: engine)
        await viewModel.start()
        viewModel.sceneActivityChanged(isActive: false)
        viewModel.systemInterruptionChanged(began: true)
        engine.endStream(throwing: TestError())
        #expect(await eventually { viewModel.pipeline.phase.failure != nil })
        // No retry while the call holds the microphone.
        #expect(viewModel.pipeline.scheduledRetry == nil)

        viewModel.sceneActivityChanged(isActive: true)

        #expect(reclaimer.calls == 1)
        #expect(viewModel.isInterruptedBySystem == false)
        #expect(await eventually { viewModel.pipeline.phase.isListening })
    }

    @Test("while the call still holds the microphone, it stays interrupted")
    func callStillGoing() async {
        let reclaimer = Reclaimer(answer: false)
        let viewModel = makeViewModel(reclaimer: reclaimer)
        viewModel.systemInterruptionChanged(began: true)

        viewModel.sceneActivityChanged(isActive: true)

        #expect(reclaimer.calls == 1)
        #expect(viewModel.isInterruptedBySystem)
    }

    @Test("the audio session is left alone when nothing was interrupted, or when leaving the screen")
    func leftAlone() async {
        let reclaimer = Reclaimer(answer: true)
        let viewModel = makeViewModel(reclaimer: reclaimer)
        viewModel.sceneActivityChanged(isActive: true)
        viewModel.systemInterruptionChanged(began: true)
        viewModel.sceneActivityChanged(isActive: false)

        #expect(reclaimer.calls == 0)
        #expect(viewModel.isInterruptedBySystem)
    }
}

@Suite("LiveCaptionViewModel captions that stop while the phone is put away")
@MainActor
struct LiveCaptionViewModelStoppedCaptionsTests {
    private final class Phone {
        var reclaimAnswer: Bool
        var reclaims = 0
        var posted: [AlertNotificationContent] = []
        var withdrawn: [String] = []
        init(reclaimAnswer: Bool) { self.reclaimAnswer = reclaimAnswer }
    }

    private func makeViewModel(
        phone: Phone,
        engine: FakeEngine = FakeEngine(),
        recovery: AutoRecoveryPolicy = .disabled
    ) -> LiveCaptionViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-stopped-\(UUID())", isDirectory: true)
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: recovery,
            audioWatchdog: .disabled
        )
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathExtension("json")),
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: directory),
            postNotification: { phone.posted.append($0) },
            withdrawNotification: { phone.withdrawn.append($0) },
            reclaimAudioSession: {
                phone.reclaims += 1
                return phone.reclaimAnswer
            }
        )
        viewModel.callEndGrace = .zero
        return viewModel
    }

    @Test("after a call iOS never ended, running captions take the microphone back by themselves")
    func reclaimsAfterCall() async {
        let phone = Phone(reclaimAnswer: true)
        let viewModel = makeViewModel(phone: phone)
        await viewModel.start()
        viewModel.sceneActivityChanged(isActive: false)
        viewModel.systemInterruptionChanged(began: true)
        viewModel.phoneCallsChanged(inProgress: true)
        #expect(phone.reclaims == 0)

        viewModel.phoneCallsChanged(inProgress: false)
        await viewModel.finishReclaimAfterCall()

        #expect(phone.reclaims == 1)
        #expect(viewModel.isInterruptedBySystem == false)
        #expect(phone.posted.isEmpty)
    }

    @Test("when the microphone can't be taken back she is told once, and the notice goes once captions return")
    func tellsWhenStuck() async {
        let phone = Phone(reclaimAnswer: false)
        let viewModel = makeViewModel(phone: phone)
        await viewModel.start()
        viewModel.sceneActivityChanged(isActive: false)
        viewModel.systemInterruptionChanged(began: true)
        viewModel.phoneCallsChanged(inProgress: true)
        viewModel.phoneCallsChanged(inProgress: false)
        await viewModel.finishReclaimAfterCall()

        #expect(viewModel.isInterruptedBySystem)
        #expect(phone.posted.map(\.identifier) == [StoppedCaptionsNotice.identifier])
        #expect(phone.withdrawn.isEmpty)

        // She opens the app from the notification; now it works.
        phone.reclaimAnswer = true
        viewModel.sceneActivityChanged(isActive: true)
        #expect(viewModel.isInterruptedBySystem == false)
        #expect(phone.posted.count == 1)
        #expect(phone.withdrawn == [StoppedCaptionsNotice.identifier])
    }

    @Test("captions paused before the call leave the audio session and her notifications alone")
    func pausedLeftAlone() async {
        let phone = Phone(reclaimAnswer: true)
        let viewModel = makeViewModel(phone: phone)
        await viewModel.start()
        await viewModel.togglePause()
        #expect(viewModel.phase == .paused)
        viewModel.sceneActivityChanged(isActive: false)
        viewModel.systemInterruptionChanged(began: true)
        viewModel.phoneCallsChanged(inProgress: true)
        viewModel.phoneCallsChanged(inProgress: false)
        await viewModel.finishReclaimAfterCall()

        #expect(phone.reclaims == 0)
        #expect(phone.posted.isEmpty)
        // The call is over: the status can offer to resume again.
        #expect(viewModel.isInterruptedBySystem == false)
        #expect(viewModel.phase == .paused)
    }

    @Test("a failure nothing will retry, while the app is in the background, posts one notice")
    func failureInBackground() async {
        let phone = Phone(reclaimAnswer: true)
        let engine = FakeEngine()
        let viewModel = makeViewModel(phone: phone, engine: engine)
        await viewModel.start()
        viewModel.sceneActivityChanged(isActive: false)

        engine.endStream(throwing: TestError())

        #expect(await eventually { phone.posted.count == 1 })
        #expect(phone.posted.first?.identifier == StoppedCaptionsNotice.identifier)
    }

    @Test("captions that failed with the app open post the notice once the phone is put away, and only once")
    func failureBeforeBackground() async {
        let phone = Phone(reclaimAnswer: true)
        let engine = FakeEngine()
        let viewModel = makeViewModel(phone: phone, engine: engine)
        await viewModel.start()
        viewModel.sceneActivityChanged(isActive: true)
        engine.endStream(throwing: TestError())
        #expect(await eventually { viewModel.phase.failure != nil })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(phone.posted.isEmpty)

        viewModel.sceneActivityChanged(isActive: false)
        #expect(phone.posted.map(\.identifier) == [StoppedCaptionsNotice.identifier])

        // Opened while still failed: the status says it, so the notice goes.
        viewModel.sceneActivityChanged(isActive: true)
        #expect(phone.withdrawn == [StoppedCaptionsNotice.identifier])
        viewModel.sceneActivityChanged(isActive: false)
        #expect(phone.posted.count == 1)
    }

    @Test("a failure that will be retried posts nothing")
    func retriedFailureQuiet() async {
        let phone = Phone(reclaimAnswer: true)
        let engine = FakeEngine()
        let viewModel = makeViewModel(phone: phone, engine: engine, recovery: AutoRecoveryPolicy(glitchDelays: [30], downloadDelays: []))
        await viewModel.start()
        viewModel.sceneActivityChanged(isActive: false)

        engine.endStream(throwing: TestError())

        #expect(await eventually { viewModel.pipeline.scheduledRetry != nil })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(phone.posted.isEmpty)
    }
}

@Suite("LiveCaptionViewModel settings save errors")
@MainActor
struct LiveCaptionViewModelSettingsSaveTests {
    @Test("a settings save that fails is recorded for diagnostics, and cleared once a save works")
    func recordsFailure() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-save-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A file where the settings folder should be: saving can't create it.
        let blocker = base.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder())

        let broken = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: blocker.appendingPathComponent("ozen-settings.json")),
            pipeline: pipeline
        )
        broken.hapticOnSpeechResume = false
        #expect(broken.settingsSaveError != nil)

        let working = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: base.appendingPathComponent("ozen-settings.json")),
            pipeline: pipeline
        )
        working.hapticOnSpeechResume = false
        #expect(working.settingsSaveError == nil)
    }
}

@Suite("LiveCaptionViewModel starred lines")
@MainActor
struct LiveCaptionViewModelStarTests {
    @Test("starring a line saves it starred, unstarring clears it, and a new conversation starts with none")
    func starAndUnstar() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-star-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            historyStore: history
        )
        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "כדור אחד בבוקר", isFinal: true, timestamp: Date().timeIntervalSince1970))
        await eventually { !viewModel.segments.isEmpty }
        guard let line = viewModel.segments.first else {
            Issue.record("no caption line arrived")
            return
        }

        viewModel.toggleStar(line)
        #expect(viewModel.starredSegmentIDs == [line.id])
        viewModel.persistHistory(ended: false)
        #expect(history.listSummaries().first?.starredCount == 1)

        viewModel.toggleStar(line)
        #expect(viewModel.starredSegmentIDs.isEmpty)
        viewModel.persistHistory(ended: false)
        #expect(history.listSummaries().first?.starredCount == 0)

        viewModel.toggleStar(line)
        viewModel.clearTranscript()
        #expect(viewModel.starredSegmentIDs.isEmpty)
    }
}

@Suite("LiveCaptionViewModel stars across a conversation break")
@MainActor
struct LiveCaptionViewModelStarAcrossBreakTests {
    @Test("a star on a line from before a quiet break is saved with that earlier conversation")
    func starGoesToEarlierConversation() async throws {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-star-break-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory)
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathExtension("json")),
            pipeline: pipeline,
            historyStore: history
        )
        await viewModel.start()

        let longAgo = Date().timeIntervalSince1970 - 30 * 60
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "הרופא אמר כדור אחד", isFinal: true, timestamp: longAgo))
        await eventually { !viewModel.segments.isEmpty }
        #expect(viewModel.checkForConversationBreak())
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "ערב טוב", isFinal: true, timestamp: Date().timeIntervalSince1970))
        await eventually { viewModel.segments.count >= 2 }

        viewModel.toggleStar(viewModel.segments[0])
        // A save that must finish now waits behind the star's background save.
        viewModel.persistHistory(ended: false)

        let summaries = history.listSummaries()
        #expect(summaries.count == 2)
        let earlier = summaries.first { $0.preview == "הרופא אמר כדור אחד" }
        let later = summaries.first { $0.preview == "ערב טוב" }
        #expect(earlier?.starredCount == 1)
        #expect(earlier?.endedAt != nil)
        #expect(later?.starredCount == 0)
        #expect(later?.segmentCount == 1)
    }
}

@Suite("LiveCaptionViewModel ask to repeat")
@MainActor
struct LiveCaptionViewModelAskToRepeatTests {
    @Test("asking to repeat says the request aloud and pauses captions so the phone doesn't caption itself")
    func asksAloud() async {
        let synthesizer = FakeSynthesizer()
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-repeat-\(UUID())", isDirectory: true)
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            synthesizer: synthesizer
        )
        await viewModel.start()
        #expect(pipeline.phase.isListening)

        viewModel.askToRepeat()

        #expect(synthesizer.requests.last == LiveCaptionViewModel.repeatRequest)
        #expect(pipeline.phase == .paused)
    }
}

@Suite("LiveCaptionViewModel startup work")
@MainActor
struct LiveCaptionViewModelStartupTests {
    @Test("the sound classifier's labels are read in the background after launch, not while building the screen")
    func labelsLoadInBackground() async {
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-startup-\(UUID())", isDirectory: true)
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            loadKnownSoundIdentifiers: { ["door_bell", "siren"] }
        )
        // Not read yet: building the view model didn't wait for it.
        #expect(viewModel.knownSoundIdentifiers == nil)

        // Waits on the load itself rather than a clock: a busy simulator can
        // take longer than any fixed deadline to run a utility-priority task.
        await viewModel.finishLoadingSoundIdentifiers()
        #expect(viewModel.knownSoundIdentifiers == ["door_bell", "siren"])
    }
}

@Suite("LiveCaptionViewModel deleting conversations")
@MainActor
struct LiveCaptionViewModelDeleteConversationTests {
    private func makeViewModel() -> (LiveCaptionViewModel, FakeEngine, TranscriptHistoryStore) {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-delete-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            historyStore: history
        )
        return (viewModel, engine, history)
    }

    private func say(_ text: String, at timestamp: TimeInterval, into engine: FakeEngine, until viewModel: LiveCaptionViewModel, count: Int) async {
        engine.emit(TranscriptToken(utteranceID: UUID(), text: text, isFinal: true, timestamp: timestamp))
        await eventually { viewModel.segments.count >= count }
    }

    @Test("deleting the conversation still being captioned keeps it deleted through autosaves and stopping")
    func deleteLiveConversation() async throws {
        let (viewModel, engine, history) = makeViewModel()
        await viewModel.start()
        await say("סוד בינינו", at: Date().timeIntervalSince1970, into: engine, until: viewModel, count: 1)
        viewModel.persistHistory(ended: false)
        let saved = try #require(history.listSummaries().first)

        try viewModel.deleteConversation(id: saved.id)
        viewModel.persistHistory(ended: false, inBackground: true)
        await viewModel.togglePause()
        #expect(history.listSummaries().isEmpty)
        // The words stay on screen; only the saved copy is gone.
        #expect(viewModel.segments.count == 1)

        await viewModel.togglePause()
        await say("מה שלומך", at: Date().timeIntervalSince1970, into: engine, until: viewModel, count: 2)
        viewModel.persistHistory(ended: false)
        let next = history.listSummaries()
        #expect(next.count == 1)
        #expect(next.first?.id != saved.id)
        #expect(next.first?.preview == "מה שלומך")
        #expect(next.first?.segmentCount == 1)
    }

    @Test("starring a line from an earlier, deleted conversation doesn't bring it back")
    func starOnDeletedEarlierConversation() async throws {
        let (viewModel, engine, history) = makeViewModel()
        await viewModel.start()
        await say("הרופא אמר כדור אחד", at: Date().timeIntervalSince1970 - 30 * 60, into: engine, until: viewModel, count: 1)
        #expect(viewModel.checkForConversationBreak())
        await say("ערב טוב", at: Date().timeIntervalSince1970, into: engine, until: viewModel, count: 2)
        viewModel.persistHistory(ended: false)
        let earlier = try #require(history.listSummaries().first(where: { $0.preview == "הרופא אמר כדור אחד" }))

        try viewModel.deleteConversation(id: earlier.id)
        viewModel.toggleStar(viewModel.segments[0])
        viewModel.persistHistory(ended: false)

        let summaries = history.listSummaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.preview == "ערב טוב")
    }

    @Test("naming a voice after a quiet break renames it in the earlier conversation's saved copy too")
    func nameReachesClosedConversation() async throws {
        let engine = FakeEngine()
        let audio = FakeAudioCapturer()
        let pipeline = CaptionPipeline(audio: audio, engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-names-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            historyStore: history
        )
        await viewModel.start()
        audio.push([Float](repeating: 0.5, count: 24_000))
        #expect(await eventually { pipeline.speakerClusters.count == 1 })
        await say("the doctor said one pill", at: Date().timeIntervalSince1970 - 30 * 60, into: engine, until: viewModel, count: 1)
        #expect(viewModel.segments.first?.speakerClusterID != nil)
        #expect(viewModel.checkForConversationBreak())
        let earlier = try #require(history.listSummaries().first)
        #expect(history.load(id: earlier.id)?.segments.first?.speakerName != "Dr. Cohen")

        viewModel.nameSpeaker(of: viewModel.segments[0], name: "Dr. Cohen")
        viewModel.waitForHistorySaves()

        #expect(history.load(id: earlier.id)?.segments.first?.speakerName == "Dr. Cohen")
    }

    @Test("delete all also retires the conversation in progress")
    func deleteAllIncludesLive() async throws {
        let (viewModel, engine, history) = makeViewModel()
        await viewModel.start()
        await say("שלום", at: Date().timeIntervalSince1970, into: engine, until: viewModel, count: 1)
        viewModel.persistHistory(ended: false)
        #expect(history.listSummaries().count == 1)

        try viewModel.deleteAllConversations()
        viewModel.persistHistory(ended: false, inBackground: true)
        viewModel.persistHistory(ended: true)
        #expect(history.listSummaries().isEmpty)
    }
}

@Suite("LiveCaptionViewModel history retention")
@MainActor
struct LiveCaptionViewModelHistoryRetentionTests {
    @Test("old conversations expire by the setting; the one on screen and starred ones stay, and the choice is remembered")
    func expiresOldConversations() async throws {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-retention-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        let settingsStore = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let viewModel = LiveCaptionViewModel(settingsStore: settingsStore, pipeline: pipeline, historyStore: history)
        await viewModel.finishLaunchHousekeeping()

        let day: TimeInterval = 86_400
        let now = Date().timeIntervalSince1970
        func oldRecord(starred: Bool) -> TranscriptSessionRecord {
            TranscriptSessionRecord(
                id: UUID(), startedAt: now - 40 * day, endedAt: now - 40 * day, engine: .whisperKit, modelVariant: nil, inputName: nil,
                segments: [SavedSegment(id: UUID(), text: "מזמן", speakerName: nil, speakerClusterID: nil, startTimestamp: now - 40 * day, isCommitted: true, isStarred: starred)]
            )
        }
        let old = oldRecord(starred: false)
        let oldStarred = oldRecord(starred: true)
        try history.save(old)
        try history.save(oldStarred)

        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "היום", isFinal: true, timestamp: now))
        await eventually { !viewModel.segments.isEmpty }
        viewModel.persistHistory(ended: false)
        #expect(history.listSummaries().count == 3)

        let underForever = await viewModel.deleteExpiredHistory()
        #expect(underForever == 0)

        viewModel.historyRetention = .month
        #expect(settingsStore.load().historyRetention == .month)
        // Two months on, today's conversation is old too, but it's still on
        // screen, so it stays.
        let deleted = await viewModel.deleteExpiredHistory(now: now + 60 * day)
        #expect(deleted == 1)
        let left = Set(history.listSummaries().map(\.id))
        #expect(left.count == 2)
        #expect(!left.contains(old.id))
        #expect(left.contains(oldStarred.id))
    }
}

@Suite("LiveCaptionViewModel conversation cut off by iOS")
@MainActor
struct LiveCaptionViewModelRecentConversationTests {
    @Test("a conversation still going minutes before launch is offered, and clearing or dismissing hides it")
    func offersRecentConversation() async throws {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-recent-\(UUID())", isDirectory: true)
        let history = TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        let now = Date().timeIntervalSince1970
        // What the autosave left behind: never closed, last line 4 minutes ago.
        let cutOff = TranscriptSessionRecord(
            id: UUID(), startedAt: now - 50 * 60, endedAt: nil, engine: .whisperKit, modelVariant: nil, inputName: nil,
            segments: [
                SavedSegment(id: UUID(), text: "התחלנו", speakerName: nil, speakerClusterID: nil, startTimestamp: now - 50 * 60, isCommitted: true),
                SavedSegment(id: UUID(), text: "והרופא אמר", speakerName: nil, speakerClusterID: nil, startTimestamp: now - 4 * 60, isCommitted: true),
            ]
        )
        try history.save(cutOff)

        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            historyStore: history
        )
        await viewModel.finishLaunchHousekeeping()
        #expect(viewModel.recentConversation?.id == cutOff.id)
        await viewModel.loadRecentConversation(now: now)
        #expect(viewModel.recentConversation?.id == cutOff.id)

        viewModel.dismissRecentConversation()
        #expect(viewModel.recentConversation == nil)

        await viewModel.loadRecentConversation(now: now)
        #expect(viewModel.recentConversation != nil)
        viewModel.clearTranscript()
        #expect(viewModel.recentConversation == nil)

        // Half an hour later it's no longer "moments ago".
        await viewModel.loadRecentConversation(now: now + 30 * 60)
        #expect(viewModel.recentConversation == nil)
    }
}

@Suite("LiveCaptionViewModel VoiceOver announcements")
@MainActor
struct LiveCaptionViewModelAnnouncementTests {
    @Test("finished lines are announced once with VoiceOver on; lines finished while it's off, or with the setting off, are never read later")
    func announcesFinishedLines() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-announce-\(UUID())", isDirectory: true)
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        )
        viewModel.display.showSpeakerNames = false
        await viewModel.start()

        func say(_ text: String, count: Int) async {
            engine.emit(TranscriptToken(utteranceID: UUID(), text: text, isFinal: true, timestamp: Date().timeIntervalSince1970))
            await eventually { viewModel.segments.count >= count }
        }

        await say("בוקר טוב", count: 1)
        #expect(viewModel.captionAnnouncement(voiceOverRunning: true) == "בוקר טוב")
        #expect(viewModel.captionAnnouncement(voiceOverRunning: true) == nil)

        await say("זה נאמר כש-VoiceOver כבוי", count: 2)
        #expect(viewModel.captionAnnouncement(voiceOverRunning: false) == nil)
        #expect(viewModel.captionAnnouncement(voiceOverRunning: true) == nil)

        viewModel.display.announceNewLines = false
        await say("וזה עם ההגדרה כבויה", count: 3)
        #expect(viewModel.captionAnnouncement(voiceOverRunning: true) == nil)

        viewModel.display.announceNewLines = true
        await say("ועכשיו שוב", count: 4)
        #expect(viewModel.captionAnnouncement(voiceOverRunning: true) == "ועכשיו שוב")
    }
}

@Suite("LiveCaptionViewModel caption activity")
@MainActor
struct LiveCaptionViewModelActivityTests {
    @Test("the last activity is when listening began, then when captions last changed")
    func lastActivity() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-activity-\(UUID())", isDirectory: true)
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: directory.appendingPathComponent("history", isDirectory: true))
        )
        #expect(viewModel.lastCaptionActivityAt == nil)

        await viewModel.start()
        let started = viewModel.lastCaptionActivityAt
        #expect(started != nil)

        let spokenAt = (started ?? 0) + 120
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "שלום", isFinal: true, timestamp: spokenAt))
        await eventually { !viewModel.segments.isEmpty }
        #expect(viewModel.lastCaptionActivityAt == spokenAt)
    }
}

@Suite("LiveCaptionViewModel saving trouble")
@MainActor
struct LiveCaptionViewModelSavingTroubleTests {
    /// A plain file where a folder should be: creating the folder fails the
    /// way a save does on a phone with no space left.
    private func blockedFolder() throws -> URL {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-blocked-\(UUID())")
        try Data("x".utf8).write(to: blocker)
        return blocker
    }

    @Test("a settings save that can't reach the disk puts the banner up, and a working save takes it down")
    func settingsSaveFailure() throws {
        let blocker = try blockedFolder()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in FakeEngine() }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: blocker.appendingPathComponent("settings.json")),
            pipeline: pipeline
        )
        #expect(!viewModel.savingTrouble.shouldShow)

        viewModel.hapticOnSpeechResume.toggle()
        #expect(viewModel.settingsSaveError != nil)
        #expect(viewModel.savingTrouble.shouldShow)

        viewModel.dismissSavingTrouble()
        #expect(!viewModel.savingTrouble.shouldShow)

        try FileManager.default.removeItem(at: blocker)
        viewModel.hapticOnSpeechResume.toggle()
        #expect(viewModel.settingsSaveError == nil)
        #expect(!viewModel.savingTrouble.isFailing)
    }

    @Test("a conversation that can't be saved puts the banner up")
    func historySaveFailure() async throws {
        let blocker = try blockedFolder()
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-settings-\(UUID()).json")),
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: blocker.appendingPathComponent("history", isDirectory: true))
        )
        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "בוקר טוב", isFinal: true, timestamp: 1))
        await eventually { !viewModel.segments.isEmpty }

        viewModel.persistHistory(ended: false)
        #expect(viewModel.historySaveFailure != nil)
        #expect(viewModel.savingTrouble.shouldShow)
    }

    @Test("an autosave that fails in the background puts the banner up by itself, without waiting for the next save")
    func backgroundSaveFailure() async throws {
        let blocker = try blockedFolder()
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let viewModel = LiveCaptionViewModel(
            settingsStore: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-settings-\(UUID()).json")),
            pipeline: pipeline,
            historyStore: TranscriptHistoryStore(directoryURL: blocker.appendingPathComponent("history", isDirectory: true))
        )
        await viewModel.start()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "בוקר טוב", isFinal: true, timestamp: 1))
        await eventually { !viewModel.segments.isEmpty }

        viewModel.persistHistory(ended: false, inBackground: true)
        #expect(await eventually { viewModel.savingTrouble.shouldShow })
    }
}

@Suite("LiveCaptionViewModel keyword attention")
@MainActor
struct LiveCaptionViewModelKeywordAttentionTests {
    @Test("her name said twice in a row buzzes once; both lines stay highlighted")
    func repeatedNameBuzzesOnce() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-attention-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline)
        viewModel.addKeywordAlert(phrase: "סבתא")
        await viewModel.start()

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "סבתא, בואי", isFinal: true, timestamp: 1))
        await eventually { viewModel.keywordHits.count == 1 }
        let first = viewModel.claimAttentionForNewKeywordHits()
        #expect(first?.id == viewModel.keywordHits.first?.id)
        // Screens over the captions show the one that got her attention.
        #expect(viewModel.attentionKeywordHit?.id == first?.id)

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "סבתא, את שומעת?", isFinal: true, timestamp: 2))
        await eventually { viewModel.keywordHits.count == 2 }
        #expect(viewModel.claimAttentionForNewKeywordHits() == nil)
        #expect(viewModel.keywordHitSegmentIDs.count == 2)
        // Asking again with nothing new is not a second buzz either.
        #expect(viewModel.claimAttentionForNewKeywordHits() == nil)
    }

    @Test("two words from the list in one line both count, and the first one leads")
    func twoWordsInOneLine() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-attention-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline)
        viewModel.addKeywordAlert(phrase: "סבתא")
        viewModel.addKeywordAlert(phrase: "אמבולנס")
        await viewModel.start()

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "סבתא, קראי לאמבולנס", isFinal: true, timestamp: 1))
        await eventually { viewModel.keywordHits.count == 2 }
        #expect(viewModel.claimAttentionForNewKeywordHits()?.match.phrase == "סבתא")

        // Both words started their quiet period, not only the one shown.
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "האמבולנס בדרך", isFinal: true, timestamp: 2))
        await eventually { viewModel.keywordHits.count == 3 }
        #expect(viewModel.claimAttentionForNewKeywordHits() == nil)
    }
}

@Suite("LiveCaptionViewModel lock screen captions")
@MainActor
struct LiveCaptionViewModelLockScreenTests {
    @MainActor
    final class FakeLockScreen: LockScreenCaptionsDisplaying {
        var shown: [LockScreenCaptionContent] = []
        var isShowing = false
        var ends = 0
        var isAllowedBySystem = true
        /// iOS refuses to start one even though they are allowed.
        var refusesStarts = false
        var startAttempts = 0
        var lastStartFailure: String?

        func show(_ content: LockScreenCaptionContent, mayStart: Bool) -> Bool {
            if !isShowing {
                guard mayStart, isAllowedBySystem else { return false }
                startAttempts += 1
                guard !refusesStarts else {
                    lastStartFailure = "refused"
                    return false
                }
                isShowing = true
            }
            shown.append(content)
            return true
        }

        func end() {
            ends += 1
            isShowing = false
        }
    }

    private func makeViewModel(lockScreen: FakeLockScreen) -> (LiveCaptionViewModel, FakeEngine) {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-lock-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, postNotification: { _ in }, lockScreen: lockScreen)
        return (viewModel, engine)
    }

    @Test("listening puts the newest lines on the lock screen; pausing by hand or turning the setting off takes them away")
    func showsAndEnds() async {
        let lockScreen = FakeLockScreen()
        let (viewModel, engine) = makeViewModel(lockScreen: lockScreen)
        await viewModel.start()
        #expect(await eventually { lockScreen.isShowing })

        engine.emit(TranscriptToken(utteranceID: UUID(), text: "the pills at eight", isFinal: true, timestamp: Date().timeIntervalSince1970))
        #expect(await eventually { lockScreen.shown.last?.lines.last?.text == "the pills at eight" })
        #expect(lockScreen.shown.last?.status == nil)

        await viewModel.togglePause()
        #expect(await eventually { lockScreen.ends == 1 })
        await viewModel.togglePause()
        #expect(await eventually { lockScreen.isShowing })

        viewModel.display.lockScreenCaptions = false
        #expect(lockScreen.ends == 2)
        #expect(!lockScreen.isShowing)
    }

    @Test("with the app in the background none can be started; back in front it starts")
    func startsOnlyInFront() async {
        let lockScreen = FakeLockScreen()
        let (viewModel, _) = makeViewModel(lockScreen: lockScreen)
        viewModel.sceneActivityChanged(isActive: false)
        await viewModel.start()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!lockScreen.isShowing)

        viewModel.sceneActivityChanged(isActive: true)
        #expect(lockScreen.isShowing)
    }

    @Test("with Live Activities off in iOS Settings nothing shows, and settings can say so")
    func offInSystemSettings() async {
        let lockScreen = FakeLockScreen()
        lockScreen.isAllowedBySystem = false
        let (viewModel, _) = makeViewModel(lockScreen: lockScreen)
        #expect(!viewModel.lockScreenCaptionsAllowedBySystem)
        await viewModel.start()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!lockScreen.isShowing)

        // Switched on in Settings: coming back to the app starts them.
        lockScreen.isAllowedBySystem = true
        viewModel.sceneActivityChanged(isActive: false)
        viewModel.sceneActivityChanged(isActive: true)
        #expect(viewModel.lockScreenCaptionsAllowedBySystem)
        #expect(lockScreen.isShowing)
    }

    @Test("a start iOS refuses isn't asked for again with every new line; back in front it is")
    func refusedStartIsNotRetriedPerLine() async {
        let lockScreen = FakeLockScreen()
        lockScreen.refusesStarts = true
        let (viewModel, engine) = makeViewModel(lockScreen: lockScreen)
        await viewModel.start()
        #expect(await eventually { lockScreen.startAttempts == 1 })
        for n in 1...5 {
            engine.emit(TranscriptToken(utteranceID: UUID(), text: "line \(n)", isFinal: true, timestamp: Date().timeIntervalSince1970))
        }
        #expect(await eventually { viewModel.segments.last?.text == "line 5" })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(lockScreen.startAttempts == 1)
        #expect(viewModel.lockScreenCaptionsLastStartFailure == "refused")

        lockScreen.refusesStarts = false
        viewModel.sceneActivityChanged(isActive: false)
        viewModel.sceneActivityChanged(isActive: true)
        #expect(lockScreen.startAttempts == 2)
        #expect(lockScreen.isShowing)
    }

    @Test("a call keeps the lock screen captions, saying why they paused")
    func callKeepsThem() async {
        let lockScreen = FakeLockScreen()
        let (viewModel, _) = makeViewModel(lockScreen: lockScreen)
        await viewModel.start()
        #expect(await eventually { lockScreen.isShowing })
        viewModel.systemInterruptionChanged(began: true)
        #expect(await eventually { lockScreen.shown.last?.status != nil })
        #expect(lockScreen.ends == 0)
    }
}
