import SwiftUI
import OzenKit
import Foundation

@main
struct OzenApp: App {
    @State private var viewModel: LiveCaptionViewModel

    init() {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ozen-settings.json")
        _viewModel = State(initialValue: LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: url)))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if viewModel.hasCompletedOnboarding {
                    LiveCaptionView(viewModel: viewModel)
                } else {
                    OnboardingView(viewModel: viewModel)
                }
            }
            .animation(.default, value: viewModel.hasCompletedOnboarding)
            // Hebrew first, whatever the phone's language. Under this,
            // SwiftUI's `.leading` is the right edge: Hebrew text and a
            // row's icon go on `.leading`, never `.trailing` (the left).
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
