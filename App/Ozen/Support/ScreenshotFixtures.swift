#if DEBUG
import Foundation
import OzenKit

/// Builds a view model seeded with a canned conversation, for the UI test
/// target to screenshot. Reuses the real production `CaptionPipeline` (real
/// audio input manager, real WhisperKit/embedder factories) but never calls
/// `start()`, so nothing real ever records; `CaptionPipeline.seedForScreenshots()`
/// fills in the transcript directly. Debug builds only, and only reached at
/// all behind the `-uiTestScreenshots` launch argument (see `OzenApp`).
enum ScreenshotFixtures {
    /// `variant` selects what to seed beyond the base conversation, so one
    /// launch argument can drive several screenshot configurations without
    /// separate app builds. See `OzenApp` for the argument that sets this.
    enum Variant: String {
        case hebrewDefault
        case hebrewLargeText
        case english
    }

    @MainActor
    static func viewModel(variant: Variant) -> LiveCaptionViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-screenshot-\(UUID().uuidString).json")
        let viewModel = LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: url))
        viewModel.completeOnboarding()

        let segments = viewModel.pipeline.seedForScreenshots()
        if let starred = segments.first {
            viewModel.toggleStar(starred)
        }

        switch variant {
        case .hebrewDefault:
            viewModel.setAppLanguage(.hebrew)
        case .hebrewLargeText:
            viewModel.setAppLanguage(.hebrew)
            viewModel.display.fontSize = 50
        case .english:
            viewModel.setAppLanguage(.english)
        }

        return viewModel
    }
}
#endif
