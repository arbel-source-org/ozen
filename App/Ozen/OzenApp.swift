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
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
