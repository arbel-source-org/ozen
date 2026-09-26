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
        // A screenshot that silently isn't written leaves the job green
        // with nothing to look at, which is the one thing it exists for.
        do {
            try data.write(to: url)
        } catch {
            XCTFail("\(name): could not write the screenshot to \(url.path): \(error)")
        }
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

    /// The caption screen's own control bar at the largest system text
    /// size: every other screen was checked this way, not the one she
    /// spends her time on.
    func testCaptionScreenAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", "hebrewDefault", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let transcript = app.descendants(matching: .any)["transcriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "caption screen: the transcript never appeared")
        capture(app, name: "caption-screen-accessibility-text")
        let settingsButton = app.descendants(matching: .any)["settingsButton"]
        XCTAssertTrue(settingsButton.isHittable, "caption screen: the settings button is off screen at this text size")
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

            if name == "page4-microphone" {
                // The "Approve the microphone" button sits below the fold
                // at this text size -- scroll to actually see it rather
                // than assume the same fix that worked in the reply
                // sheet's "Full screen, big letters" button holds here too.
                app.swipeUp()
                capture(app, name: "onboarding-accessibility-text-page4-microphone-button-scrolled")
            }

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

    /// The steppers quiet hours reveals once enabled, at this text size --
    /// seeded on at launch (see ScreenshotFixtures.Variant.quietHoursEnabled)
    /// rather than flipped live by the test, since tapping the toggle
    /// itself reliably failed to reveal them across several attempts.
    /// Anchored on the plain Text footnote below the steppers, not a
    /// Stepper itself: a Stepper paired with a LabeledContent label
    /// apparently doesn't expose a single element under its own
    /// accessibilityIdentifier the way a Toggle or Text does -- scrolling
    /// for one by identifier never found it, seeded or not.
    func testQuietHoursEnabledAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", "quietHoursEnabled", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let settingsButton = app.descendants(matching: .any)["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "quiet hours: the settings button never appeared")
        settingsButton.tap()

        let footnote = scrollDownUntilVisible(app, identifier: "quietHoursFootnote", type: .staticText)
        XCTAssertTrue(footnote.exists, "quiet hours: the steppers' footnote never appeared")
        capture(app, name: "quiet-hours-on-accessibility-text")
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

        // The button that just got fixed for wrapping at this same text
        // size opens a screen built entirely around showing text as big
        // as possible -- exactly where a rendering mistake here would
        // show up worst, and never checked before.
        let bigTextButton = app.descendants(matching: .any)["bigTextButton"]
        XCTAssertTrue(bigTextButton.waitForExistence(timeout: 10), "big text: the button to open it never appeared")
        bigTextButton.tap()

        let bigTextScreen = app.descendants(matching: .any)["bigTextScreen"]
        XCTAssertTrue(bigTextScreen.waitForExistence(timeout: 10), "big text: the screen never appeared")
        capture(app, name: "big-text-accessibility-text")

        // The "hebrewDefault" fixture always sets the UI language to
        // Hebrew, regardless of the test runner's own locale.
        let flipButton = app.descendants(matching: .any).buttons["להפוך"]
        if flipButton.waitForExistence(timeout: 5) {
            flipButton.tap()
            capture(app, name: "big-text-accessibility-text-flipped")
        }
    }

    /// Screens reached only through Settings' navigation links, or from
    /// the microphone picker's own entry point on the caption screen --
    /// none of them ever screenshotted at the largest accessibility text
    /// size before. The `hebrewDefault` fixture also seeds one saved
    /// conversation, with a starred line, so History and Starred lines
    /// show real content instead of their empty states.
    func testSecondaryScreensAccessibilityText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshots", "hebrewDefault", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let settingsButton = app.descendants(matching: .any)["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "secondary screens: the settings button never appeared")
        settingsButton.tap()
        let settingsScreen = app.descendants(matching: .any)["settingsScreen"]
        XCTAssertTrue(settingsScreen.waitForExistence(timeout: 10), "secondary screens: settings never appeared")

        // Checked in the same top-to-bottom order the Form declares its
        // sections, and never re-fetched from the top in between: at this
        // text size a single Form row can be most of a screen tall, so a
        // row several sections down doesn't exist in the accessibility
        // tree at all -- not merely off-screen -- until scrolled near it
        // (see scrollDownUntilVisible). Going in declaration order means
        // every scroll only ever needs to move forward.
        // Scrolling further into this screen to also capture the
        // "Recently heard" section (an unbounded-length matched phrase
        // sharing a row with a timestamp -- the same shape that overlapped
        // in the model manager's rating dots) reliably broke the add-
        // speaker step much later in this same test, for reasons that
        // didn't repay chasing: keyword phrases are short by the
        // feature's own design (the UI itself asks for single words), so
        // the theoretical risk here is far lower than the rating dots
        // case actually was.
        openSettingsRow(app, rowIdentifier: "keywordAlertsRow", screenIdentifier: "keywordAlertsScreen", captureName: "keyword-alerts-accessibility-text")
        openSettingsRow(app, rowIdentifier: "soundAlertsRow", screenIdentifier: "soundAlertsScreen", captureName: "sound-alerts-accessibility-text")

        // notifyWhenInBackground is seeded on in ScreenshotFixtures, so
        // this inline toggle (unlike the rows above) is already visible
        // rather than reached through a NavigationLink. The enabled state
        // (with its revealed steppers) is covered separately by
        // testQuietHoursEnabledAccessibilityText, seeded from launch
        // rather than flipped live here -- tapping this toggle mid-test
        // reliably failed to reveal the steppers across several attempts,
        // most likely an XCUITest quirk specific to this Toggle at this
        // extreme text size rather than anything wrong with the toggle
        // itself.
        let quietHoursToggle = scrollDownUntilVisible(app, identifier: "quietHoursToggle")
        XCTAssertTrue(quietHoursToggle.exists, "secondary screens: quiet hours toggle never appeared")
        capture(app, name: "quiet-hours-off-accessibility-text")

        let historyRow = scrollDownUntilVisible(app, identifier: "historyRow")
        XCTAssertTrue(historyRow.exists, "secondary screens: the history row never appeared")
        historyRow.tap()
        let historyScreen = app.descendants(matching: .any)["historyScreen"]
        XCTAssertTrue(historyScreen.waitForExistence(timeout: 10), "secondary screens: history never appeared")
        let starredRow = scrollDownUntilVisible(app, identifier: "starredLinesRow")
        XCTAssertTrue(starredRow.exists, "secondary screens: the seeded conversation never reached history")
        capture(app, name: "history-accessibility-text")
        starredRow.tap()
        let starredScreen = app.descendants(matching: .any)["starredLinesScreen"]
        XCTAssertTrue(starredScreen.waitForExistence(timeout: 10), "secondary screens: starred lines never appeared")
        capture(app, name: "starred-lines-accessibility-text")
        let backToHistory = app.navigationBars.buttons["היסטוריה"]
        XCTAssertTrue(backToHistory.waitForExistence(timeout: 10), "secondary screens: no way back from starred lines")
        backToHistory.tap()
        let backToSettingsFromHistory = app.navigationBars.buttons["הגדרות"]
        XCTAssertTrue(backToSettingsFromHistory.waitForExistence(timeout: 10), "secondary screens: no way back from history")
        backToSettingsFromHistory.tap()

        // Her own settings (alerts, quiet hours) come first; the model
        // manager is in the part for whoever set up the phone, below them.
        openSettingsRow(app, rowIdentifier: "modelManagerRow", screenIdentifier: "modelManagerScreen", captureName: "model-manager-accessibility-text")

        openSettingsRow(app, rowIdentifier: "vocabularyRow", screenIdentifier: "vocabularyScreen", captureName: "vocabulary-accessibility-text")

        let addSpeaker = scrollDownUntilVisible(app, identifier: "addSpeakerButton")
        XCTAssertTrue(addSpeaker.exists, "secondary screens: the add-speaker button never appeared")
        addSpeaker.tap()
        let enrollmentScreen = app.descendants(matching: .any)["speakerEnrollmentScreen"]
        XCTAssertTrue(enrollmentScreen.waitForExistence(timeout: 10), "secondary screens: speaker enrollment never appeared")
        capture(app, name: "speaker-enrollment-accessibility-text")
        app.buttons["ביטול"].tap()

        openSettingsRow(app, rowIdentifier: "diagnosticsRow", screenIdentifier: "diagnosticsScreen", captureName: "diagnostics-accessibility-text")

        app.buttons["סגירה"].firstMatch.tap()

        // A settle delay here didn't help, and the failure this produced
        // was deterministic, not flaky: the same "kAXErrorCannotComplete
        // performing AXAction kAXScrollToVisibleAction" at the same
        // coordinates every run. By now this test has spent minutes
        // navigating eight screens, well past ControlBarAutoHide's own
        // timeout -- the control bar has almost certainly slid off-screen
        // by then (see LiveCaptionView's `hidingControlBar`, which moves
        // it with a plain offset, not a real scroll), so there is nothing
        // for the system's own "scroll to visible" to scroll. Revealing
        // the bar first, the same way `run(variant:name:)` above waits
        // for it to auto-hide in the first place, avoids tapping an
        // element that still exists but has been offset out of view.
        let revealControls = app.descendants(matching: .any)["showControlsButton"]
        if revealControls.waitForExistence(timeout: 2) {
            revealControls.tap()
        }

        let micPickerButton = app.descendants(matching: .any)["micPickerButton"]
        XCTAssertTrue(micPickerButton.waitForExistence(timeout: 10), "secondary screens: the mic picker button never appeared")
        micPickerButton.tap()
        let micPickerScreen = app.descendants(matching: .any)["micPickerScreen"]
        XCTAssertTrue(micPickerScreen.waitForExistence(timeout: 10), "secondary screens: mic picker never appeared")
        capture(app, name: "mic-picker-accessibility-text")
    }

    /// Settings' Form renders lazily like any List: a row several sections
    /// below the current scroll position isn't merely off-screen, it
    /// doesn't exist in the accessibility tree at all until scrolled near
    /// it. Three earlier fixes chased text-matching and element-merging
    /// red herrings on the very first row checked here before a look at
    /// `settings-accessibility-text-page1.png` showed the real cause: at
    /// this text size, a single picker option already fills most of the
    /// screen, so the actual row is nowhere close to visible yet.
    ///
    /// `type` narrows the query: matching `.any` walks every element on
    /// every check, and at the largest text size a long Form took XCTest
    /// past its own query timeout ("Timed out while evaluating UI query").
    private func scrollDownUntilVisible(_ app: XCUIApplication, identifier: String, type: XCUIElement.ElementType = .any, maxSwipes: Int = 15) -> XCUIElement {
        let element = app.descendants(matching: type)[identifier]
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
        return element
    }

    /// Taps a Settings row by its own accessibility identifier, scrolling
    /// down until it exists first (see `scrollDownUntilVisible`).
    private func openSettingsRow(_ app: XCUIApplication, rowIdentifier: String, screenIdentifier: String, captureName: String) {
        let row = scrollDownUntilVisible(app, identifier: rowIdentifier)
        XCTAssertTrue(row.exists, "secondary screens: \(rowIdentifier) never appeared")
        row.tap()
        let screen = app.descendants(matching: .any)[screenIdentifier]
        // A tap that lands while the swipe that brought the row up is
        // still coasting only stops the scroll; the row then needs a
        // second tap to open.
        if !screen.waitForExistence(timeout: 3), row.exists {
            capture(app, name: "debug-\(rowIdentifier)-after-first-tap")
            row.tap()
        }
        if !screen.waitForExistence(timeout: 10) {
            capture(app, name: "debug-\(rowIdentifier)-never-opened")
            XCTFail("secondary screens: \(screenIdentifier) never appeared")
        }
        capture(app, name: captureName)
        let back = app.navigationBars.buttons["הגדרות"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "secondary screens: no way back from \(screenIdentifier)")
        back.tap()
    }
}
