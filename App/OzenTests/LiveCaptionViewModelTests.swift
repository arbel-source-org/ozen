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
        #expect(viewModel.enroll(name: "סבתא", samples: [Float](repeating: 0.5, count: 16_000)))
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
        let deadline = ContinuousClock.now + .seconds(2)
        while viewModel.keywordHits.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
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
        let deadline = ContinuousClock.now + .seconds(2)
        while viewModel.segments.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        await viewModel.togglePause()
        let sessions = history.listSummaries()
        #expect(sessions.count == 1)
        #expect(sessions.first?.preview == "בוקר טוב")
        #expect(sessions.first?.endedAt != nil)

        await viewModel.togglePause()
        viewModel.clearTranscript()
        engine.emit(TranscriptToken(utteranceID: UUID(), text: "ערב טוב", isFinal: true, timestamp: 2))
        let deadline2 = ContinuousClock.now + .seconds(2)
        while viewModel.segments.isEmpty && ContinuousClock.now < deadline2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        viewModel.persistHistory(ended: true)
        #expect(history.listSummaries().count == 2)
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
        let deadline = Date().addingTimeInterval(2)
        while engine.vocabularySeen.last != ["רותי"], Date() < deadline {
            await Task.yield()
        }
        #expect(engine.vocabularySeen.last == ["רותי"])
    }

    @Test("speaker profile names can be added in one go, without duplicating names already listed")
    func addSpeakers() throws {
        let (viewModel, _, _) = try makeViewModel()
        viewModel.addVocabularyTerm("אבי")
        // FakeEmbedder keys the voice off the first sample, so two
        // different leading values enroll two different people.
        #expect(viewModel.enroll(name: "אבי", samples: [Float](repeating: 0.2, count: 16_000)))
        #expect(viewModel.enroll(name: "רותי", samples: [Float](repeating: 0.7, count: 16_000)))
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

    @Test("the pending-action mailbox hands each action over exactly once")
    func mailbox() {
        let box = PendingAppAction.shared
        _ = box.take()
        let before = box.serial
        box.post(.stopCaptions)
        #expect(box.serial == before + 1)
        #expect(box.take() == .stopCaptions)
        #expect(box.take() == nil)
    }
}

@Suite("LiveCaptionViewModel speaking over captions")
@MainActor
struct LiveCaptionViewModelSpeechTests {
    private func makeViewModel() -> (LiveCaptionViewModel, FakeSynthesizer) {
        let synthesizer = FakeSynthesizer()
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in FakeEngine(kind: settings.engine) },
            embedder: FakeEmbedder()
        )
        let store = SettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ozen-speech-\(UUID()).json"))
        let viewModel = LiveCaptionViewModel(settingsStore: store, pipeline: pipeline, synthesizer: synthesizer)
        return (viewModel, synthesizer)
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("captions pause while the phone talks and come back by themselves afterwards")
    func roundTrip() async {
        let (viewModel, synthesizer) = makeViewModel()
        await viewModel.start()
        #expect(viewModel.phase.isListening)
        viewModel.speak("כן")
        #expect(viewModel.phase == .paused)
        synthesizer.startNext()
        synthesizer.finishCurrent()
        await waitFor { viewModel.phase.isListening }
        #expect(viewModel.phase.isListening)
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
        await waitFor { viewModel.phase.isListening }
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

    @Test("launched by Siri to say something: the phone talks first, then captions start")
    func launchWithSpeech() async throws {
        let (viewModel, synthesizer) = makeViewModel()
        let launch = Task { await viewModel.launch(pending: .speak("אני באה")) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(synthesizer.requests == ["אני באה"])
        synthesizer.startNext()
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.phase == .idle)
        synthesizer.finishCurrent()
        await launch.value
        #expect(viewModel.phase.isListening)
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
        #expect(viewModel.enroll(name: "אבי", samples: [Float](repeating: 0.3, count: 16_000)))
        viewModel.addVocabularyTerm("אבי")
        let id = viewModel.settings.speakerProfiles[0].id

        viewModel.renameProfile(id: id, to: "  אביגדור ")
        #expect(viewModel.settings.speakerProfiles[0].name == "אביגדור")
        #expect(viewModel.vocabulary == ["אביגדור"])
        #expect(SettingsStore(fileURL: file).load().speakerProfiles.first?.name == "אביגדור")
        #expect(viewModel.pipeline.speakerClusters.contains { $0.name == "אביגדור" })
        #expect(viewModel.pipeline.speakerClusters.contains { $0.name == "אבי" } == false)
    }

    @Test("a blank new name is ignored")
    func blankRename() {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.enroll(name: "רותי", samples: [Float](repeating: 0.3, count: 16_000)))
        viewModel.renameProfile(id: viewModel.settings.speakerProfiles[0].id, to: "   ")
        #expect(viewModel.settings.speakerProfiles[0].name == "רותי")
    }

    @Test("deleting a speaker stops their name from labeling lines")
    func deleteForgets() {
        let (viewModel, _) = makeViewModel()
        #expect(viewModel.enroll(name: "רותי", samples: [Float](repeating: 0.3, count: 16_000)))
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
        let deadline = Date().addingTimeInterval(2)
        while posted.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(posted.count == 1)
        #expect(posted.first?.title == "נאמר: סבתא")
        #expect(posted.first?.body == "סבתא, את ערה?")
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
