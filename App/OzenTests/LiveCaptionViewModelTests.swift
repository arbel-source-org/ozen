import Testing
@testable import Ozen
import OzenKit
import Foundation

// Runs only via `xcodebuild test` on a macOS CI runner (needs the real app
// target). Focused on the settings round-trip and view-model-level wiring
// that OzenKitTests can't reach because it lives in the app target itself
// -- the underlying logic (CaptionStabilizer, EmbeddingClusterer,
// AudioRoutePolicy) already has its own unit tests in OzenKitTests.
@Suite("LiveCaptionViewModel")
@MainActor
struct LiveCaptionViewModelTests {
    @Test("a fresh view model loads default settings when no settings file exists yet")
    func loadsDefaultsWithNoExistingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-vm-test-\(UUID()).json")
        let viewModel = LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: url))

        #expect(viewModel.settings.engine == .whisperKit)
        #expect(viewModel.settings.languageCode == "he")
        #expect(viewModel.segments.isEmpty)
        #expect(!viewModel.isListening)
    }

    @Test("switching engines persists to the settings file")
    func settingEnginePersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-vm-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(fileURL: url)
        let viewModel = LiveCaptionViewModel(settingsStore: store)
        viewModel.setEngine(.appleSpeech)

        #expect(store.load().engine == .appleSpeech)
    }
}
