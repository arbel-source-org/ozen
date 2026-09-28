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

    /// UI tests would otherwise meet the system's notification prompt.
    private static var isScreenshotRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestScreenshots")
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
            // A home computer's pairing QR code, scanned with the Camera.
            .onOpenURL { viewModel.openURL($0) }
            .alert(
                tr("להתחבר למחשב בבית?", "Connect to the home computer?"),
                isPresented: Binding(
                    get: { viewModel.pendingPairing != nil },
                    set: { if !$0 { viewModel.pendingPairing = nil } }
                ),
                presenting: viewModel.pendingPairing
            ) { pairing in
                Button(tr("להתחבר", "Connect")) {
                    Task { await viewModel.accept(pairing) }
                }
                Button(tr("ביטול", "Cancel"), role: .cancel) {}
            } message: { pairing in
                Text(tr(
                    "הקול ישלח לכתוביות אל %1. אשרו רק אם זה המחשב של המשפחה.", "The audio will go to %1 for captions. Only connect if this is the family’s computer.", args: ["\(pairing.computerName)"]
                ))
            }
            .alert(
                tr("החיבור למחשב בבית לא נשמר", "The connection to the home computer wasn’t saved"),
                isPresented: Binding(
                    get: { viewModel.pairingSaveFailed },
                    set: { if !$0 { viewModel.pairingSaveFailed = false } }
                )
            ) {
                Button(tr("סגירה", "Close"), role: .cancel) {}
            } message: {
                Text(tr(
                    "הכתוביות ממשיכות כמו קודם. סרקו שוב את הקוד, או בקשו עזרה ממי שהתקין את הטלפון.",
                    "Captions carry on as before. Scan the code again, or ask whoever set up the phone for help."
                ))
            }
            .alert(
                tr("הקישור למחשב בבית לא תקין", "The home computer link didn’t come through"),
                isPresented: Binding(
                    get: { viewModel.pairingLinkBroken },
                    set: { if !$0 { viewModel.pairingLinkBroken = false } }
                )
            ) {
                Button(tr("סגירה", "Close"), role: .cancel) {}
            } message: {
                Text(tr(
                    "חלק מהקישור חסר או השתבש. סרקו שוב את הריבוע במחשב עם מצלמת האייפון, ממש מקרוב.",
                    "Part of the link is missing or garbled. Scan the square on the computer again with the iPhone camera, up close."
                ))
            }
            // Asked once, the first time captions run, if nobody answered
            // during onboarding (see shouldAskPermission).
            .onChange(of: viewModel.phase.isListening) { _, listening in
                guard listening, !Self.isRunningTests, !Self.isScreenshotRun else { return }
                let enabled = viewModel.notifyWhenInBackground
                Task {
                    let allowed = await AlertNotifier.shared.isAllowed()
                    if BackgroundAlertPolicy.shouldAskPermission(alertsWhenScreenOff: enabled, allowed: allowed) {
                        _ = await AlertNotifier.shared.requestAuthorization()
                    }
                }
            }
            // When a free Apple ID install stops opening, and a reminder
            // the day before.
            .task { await InstallExpiryStatus.shared.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { InstallExpiryStatus.shared.refreshReminder() }
                if phase == .active && !Self.isRunningTests { viewModel.applyAppLanguage() }
                if phase != .active { viewModel.flushPendingSettingsSave() }
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
