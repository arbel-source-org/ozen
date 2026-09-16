import XCTest

/// Launches the real app with a canned conversation (see
/// `ScreenshotFixtures`, DEBUG-only) and writes PNG screenshots of the
/// caption screen to `/tmp/ozen-screenshots/`, for a human or an agent to
/// actually look at rather than infer from source. The simulator's test
/// runner is a normal macOS process, so writing straight to `/tmp` (rather
/// than through an `.xcresult` attachment) is both simpler and easier to
/// pull out of CI.
///
/// Two moments of the same screen are captured on purpose: right after
/// launch (the bottom buttons visible) and a few seconds later (the
/// buttons auto-hidden) — the exact area a real bug once hid captions
/// under the buttons.
@MainActor
final class OzenScreenshotUITests: XCTestCase {
    // Also opted out of @MainActor: the nonisolated setUp() below reads it.
    private nonisolated static let outputDirectory = URL(fileURLWithPath: "/tmp/ozen-screenshots", isDirectory: true)

    // XCTestCase's class-level setUp isn't main-actor isolated, and this
    // one touches nothing UI-related, so it stays outside the class's own
    // @MainActor default rather than fighting the override's isolation.
    nonisolated override class func setUp() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let data = app.screenshot().pngRepresentation
        let url = Self.outputDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
    }

    private func run(variant: String, name: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", variant]
        app.launch()

        let transcript = app.descendants(matching: .any)["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "\(name): the transcript never appeared")
        capture(app, name: "\(name)-controls-visible")

        let revealChevron = app.descendants(matching: .any)["showControlsButton"]
        XCTAssertTrue(revealChevron.waitForExistence(timeout: 15), "\(name): the control bar never auto-hid")
        capture(app, name: "\(name)-controls-hidden")
    }

    func testHebrewDefault() throws {
        try run(variant: "hebrewDefault", name: "hebrew-default")
    }

    func testHebrewLargeText() throws {
        try run(variant: "hebrewLargeText", name: "hebrew-large-text")
    }

    func testHebrewLightTheme() throws {
        try run(variant: "hebrewLightTheme", name: "hebrew-light-theme")
    }

    func testEnglish() throws {
        try run(variant: "english", name: "english")
    }

    /// Onboarding at the largest accessibility text size iOS offers: a
    /// real setting for exactly the low-vision reader this app is built
    /// for, and a screen no earlier screenshot pass has ever looked at.
    func testOnboardingAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", "onboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let screen = app.descendants(matching: .any)["onboardingScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "onboarding: the first page never appeared")
        capture(app, name: "onboarding-accessibility-text-page1-welcome")

        let next = app.descendants(matching: .any)["onboardingNextButton"]
        for (index, name) in ["page2-how-it-works", "page3-engine", "page4-microphone", "page5-name", "page6-ready"].enumerated() {
            XCTAssertTrue(next.waitForExistence(timeout: 10), "onboarding: no Next button on page \(index + 1)")
            next.tap()
            // The footer's own content (Skip/Next vs. the last page's lone
            // Start button) animates along with the page change; without
            // this, a capture taken mid-crossfade can look like a layout
            // bug that isn't there once the animation settles.
            Thread.sleep(forTimeInterval: 0.5)
            capture(app, name: "onboarding-accessibility-text-\(name)")

            if name == "page5-name" {
                // NameAlertForm's TextField and "Add" button sit below the
                // fold at this text size -- scroll to actually see whether
                // that fixed-direction HStack holds up at the widest word
                // shapes get, rather than assuming it does.
                app.swipeUp()
                capture(app, name: "onboarding-accessibility-text-page5-name-form-scrolled")
            }
        }
    }

    /// Settings is a long Form with over a dozen sections -- rows pairing a
    /// label with a value, a segmented picker, sliders -- none of it ever
    /// seen at the largest accessibility text size before.
    func testSettingsAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", "hebrewDefault", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let settingsButton = app.descendants(matching: .any)["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "settings: the button to open it never appeared")
        settingsButton.tap()

        let screen = app.descendants(matching: .any)["settingsScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "settings: the screen never appeared")
        capture(app, name: "settings-accessibility-text-page1")

        for index in 2...11 {
            app.swipeUp()
            capture(app, name: "settings-accessibility-text-page\(index)")
        }
    }

    /// The reply sheet: a composer with a Stop/Play pair sharing an HStack,
    /// a typed phrase's replay row pairing a full-width button with a
    /// fixed-size "add" button, and a scrollable quick-phrases list below
    /// -- all unseen at the largest accessibility text size before.
    func testTypeToSpeakAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", "hebrewDefault", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let typeToSpeakButton = app.descendants(matching: .any)["typeToSpeakButton"]
        XCTAssertTrue(typeToSpeakButton.waitForExistence(timeout: 10), "type to speak: the button to open it never appeared")
        typeToSpeakButton.tap()

        let screen = app.descendants(matching: .any)["typeToSpeakScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "type to speak: the screen never appeared")
        capture(app, name: "type-to-speak-accessibility-text-empty")

        app.textFields.firstMatch.typeText("תזכירי לי לקחת תרופות")
        capture(app, name: "type-to-speak-accessibility-text-typed")
    }
}
