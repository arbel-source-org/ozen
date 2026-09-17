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
        case hebrewLightTheme
        case english
        /// Onboarding itself, never completed: the one screen every
        /// install passes through before any of the others exist.
        case onboarding
    }

    @MainActor
    static func viewModel(variant: Variant) -> LiveCaptionViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-screenshot-\(UUID().uuidString).json")
        let viewModel = LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: url))

        guard variant != .onboarding else {
            viewModel.setAppLanguage(.hebrew)
            return viewModel
        }

        viewModel.completeOnboarding()
        let segments = viewModel.pipeline.seedForScreenshots()
        if let starred = segments.first {
            viewModel.toggleStar(starred)
        }
        if let first = segments.first {
            let record = TranscriptSessionRecord.make(
                from: segments,
                speakerName: { [pipeline = viewModel.pipeline] in pipeline.displayName(for: $0) },
                id: UUID(),
                startedAt: first.startTimestamp,
                endedAt: segments.last?.lastUpdateTimestamp,
                engine: .whisperKit,
                modelVariant: viewModel.settings.whisperModelVariant,
                inputName: nil,
                starred: [first.id]
            )
            _ = try? viewModel.historyStore.save(record)
        }
        viewModel.addKeywordAlert(phrase: tr("שני כדורים", "two pills"))
        viewModel.addVocabularyTerm(tr("דנה אברהמי", "Dana Abrahami"))
        // Seeded directly rather than through the Settings toggle, which
        // also kicks off a real notification-permission request -- not
        // something a screenshot test should be poking.
        viewModel.notifyWhenInBackground = true

        switch variant {
        case .hebrewDefault:
            viewModel.setAppLanguage(.hebrew)
        case .hebrewLargeText:
            viewModel.setAppLanguage(.hebrew)
            viewModel.display.fontSize = 50
        case .hebrewLightTheme:
            viewModel.setAppLanguage(.hebrew)
            viewModel.display.fontSize = 50
            viewModel.display.theme = .light
        case .english:
            viewModel.setAppLanguage(.english)
        case .onboarding:
            break
        }

        return viewModel
    }
}
#endif
