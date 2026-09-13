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
