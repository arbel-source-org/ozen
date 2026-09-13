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
            LiveCaptionView(viewModel: viewModel)
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
    }
}
