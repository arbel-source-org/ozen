import SwiftUI
import UIKit
import Combine
import OzenKit
import OzenPlatform
import Foundation

@main
struct OzenApp: App {
    @State private var viewModel: LiveCaptionViewModel
    @Environment(\.scenePhase) private var scenePhase

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
            // When a free Apple ID install stops opening, and a reminder
            // the day before.
            .task { await InstallExpiryStatus.shared.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { InstallExpiryStatus.shared.refreshReminder() }
            }
            // iOS is about to end apps for memory; see handleMemoryWarning.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                viewModel.pipeline.handleMemoryWarning(footprintBytes: DeviceMemory.footprintBytes())
            }
            // Hebrew first, whatever the phone's language. Under this,
            // SwiftUI's `.leading` is the right edge: Hebrew text and a
            // row's icon go on `.leading`, never `.trailing` (the left).
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
