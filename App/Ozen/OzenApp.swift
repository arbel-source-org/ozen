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
        #if DEBUG
        if let variant = Self.screenshotVariant {
            _viewModel = State(initialValue: ScreenshotFixtures.viewModel(variant: variant))
            return
        }
        #endif
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ozen-settings.json")
        let viewModel = LiveCaptionViewModel(settingsStore: SettingsStore(fileURL: url))
        // The unit tests run inside this app and expect the Hebrew words,
        // whatever language the test phone is set to.
        if !Self.isRunningTests {
            viewModel.applyAppLanguage()
        }
        _viewModel = State(initialValue: viewModel)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    /// `-uiTestScreenshots <variant>`: the UI test target launches with
    /// this to get a canned conversation instead of the real pipeline. See
    /// `ScreenshotFixtures`. Debug builds only — a release build never
    /// reads this argument at all, so it can't be triggered by mistake.
    private static var screenshotVariant: ScreenshotFixtures.Variant? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-uiTestScreenshots"),
              flagIndex + 1 < arguments.count
        else { return nil }
        return ScreenshotFixtures.Variant(rawValue: arguments[flagIndex + 1])
    }
    #endif

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
                if phase == .active && !Self.isRunningTests { viewModel.applyAppLanguage() }
            }
            // iOS is about to end apps for memory; see handleMemoryWarning.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                viewModel.pipeline.handleMemoryWarning(footprintBytes: DeviceMemory.footprintBytes())
            }
            // Right to left in Hebrew. Under this, SwiftUI's `.leading` is
            // the right edge: text and a row's icon go on `.leading`, never
            // `.trailing`, and so follow the language. Caption lines are
            // right to left in both (see `CaptionRow`).
            .environment(\.layoutDirection, viewModel.uiLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
            // Every word on screen is picked when it's drawn: a new
            // language draws everything again.
            .id(viewModel.uiLanguage)
        }
    }
}
