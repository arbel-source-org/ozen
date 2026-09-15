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
final class OzenScreenshotUITests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/ozen-screenshots", isDirectory: true)

    override class func setUp() {
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

        Thread.sleep(forTimeInterval: 6)
        capture(app, name: "\(name)-controls-hidden")
    }

    func testHebrewDefault() throws {
        try run(variant: "hebrewDefault", name: "hebrew-default")
    }

    func testHebrewLargeText() throws {
        try run(variant: "hebrewLargeText", name: "hebrew-large-text")
    }

    func testEnglish() throws {
        try run(variant: "english", name: "english")
    }
}
