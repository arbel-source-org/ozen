import Testing
import Foundation
@testable import OzenKit

@Suite("Keeping the lock screen in step with the captions")
@MainActor
struct LockScreenCaptionsCoordinatorTests {
    final class FakeDisplay: LockScreenCaptionsDisplaying {
        var shown: [LockScreenCaptionContent] = []
        var isRunning = false
        var ends = 0
        var isAllowedBySystem = true
        var refusesStarts = false
        var startAttempts = 0
        var lastStartFailure: String?

        func show(_ content: LockScreenCaptionContent, mayStart: Bool) -> Bool {
            if !isRunning {
                guard mayStart, isAllowedBySystem else { return false }
                startAttempts += 1
                guard !refusesStarts else {
                    lastStartFailure = "refused"
                    return false
                }
                isRunning = true
            }
            shown.append(content)
            return true
        }

        func end() {
            ends += 1
            isRunning = false
        }
    }

    final class Captions {
        var situation = LockScreenCaptionsCoordinator.Situation(
            enabled: true, phase: .listening, interruptedByCall: false, pausedForSpeech: false, captionSize: 30
        )
        var texts: [String] = []
        var askedCounts: [Int] = []
        /// How long ago the lines were said.
        var age: TimeInterval = 0
    }

    private func make(keepAliveSeconds: TimeInterval = 50) -> (LockScreenCaptionsCoordinator, FakeDisplay, Captions) {
        let display = FakeDisplay()
        let captions = Captions()
        let coordinator = LockScreenCaptionsCoordinator(
            display: display,
            keepAliveSeconds: keepAliveSeconds,
            situation: { captions.situation },
            lines: { count, _ in
                captions.askedCounts.append(count)
                let at = Date().timeIntervalSince1970 - captions.age
                return captions.texts.suffix(count).map { LockScreenCaptionLine(speaker: nil, text: $0, isFinal: true, lastUpdate: at) }
            }
        )
        return (coordinator, display, captions)
    }

    @Test("listening shows the lines; pausing on purpose, stopping or the setting off ends them")
    func showsAndEnds() {
        let (coordinator, display, captions) = make()
        coordinator.refresh()
        #expect(display.isRunning && coordinator.isShowing)
        #expect(display.shown.last?.lines == [])

        captions.situation.phase = .paused
        coordinator.refresh()
        #expect(display.ends == 1 && !coordinator.isShowing)

        captions.situation.phase = .listening
        coordinator.refresh()
        #expect(coordinator.isShowing)
        captions.situation.enabled = false
        coordinator.refresh()
        #expect(display.ends == 2 && !coordinator.isShowing)
        captions.situation.enabled = true
        captions.situation.phase = .idle
        coordinator.refresh()
        #expect(!display.isRunning && display.ends == 2)
    }

    @Test("a call keeps them up with its note and room for the newest line only")
    func callKeepsThemWithOneLine() {
        let (coordinator, display, captions) = make()
        captions.texts = ["one", "two"]
        coordinator.refresh()
        #expect(display.shown.last?.lines.map(\.text) == ["one", "two"])
        captions.situation.interruptedByCall = true
        coordinator.refresh()
        #expect(display.shown.last?.status != nil)
        #expect(display.shown.last?.lines.map(\.text) == ["two"])
        #expect(captions.askedCounts.last == 1)
        #expect(display.ends == 0)
    }

    @Test("in the background none can be started; back in front it starts")
    func startsOnlyInFront() {
        let (coordinator, display, _) = make()
        coordinator.appActivityChanged(isActive: false)
        #expect(!display.isRunning && display.startAttempts == 0)
        coordinator.appActivityChanged(isActive: true)
        #expect(display.isRunning)
    }

    @Test("a refused start isn't asked for again with every line; back in front it is, and the reason is kept")
    func refusedStartBacksOff() {
        let (coordinator, display, captions) = make()
        display.refusesStarts = true
        coordinator.refresh()
        for n in 1...5 {
            captions.texts.append("line \(n)")
            coordinator.refresh()
        }
        #expect(display.startAttempts == 1)
        #expect(display.lastStartFailure == "refused")

        display.refusesStarts = false
        coordinator.appActivityChanged(isActive: false)
        coordinator.appActivityChanged(isActive: true)
        #expect(display.startAttempts == 2 && coordinator.isShowing)
    }

    @Test("in front new lines wait; leaving the app sends them at once; a new note never waits")
    func pace() async {
        let (coordinator, display, captions) = make()
        coordinator.refresh()
        let sentBefore = display.shown.count
        captions.texts = ["coffee is ready"]
        coordinator.refresh()
        #expect(display.shown.count == sentBefore)

        captions.situation.interruptedByCall = true
        coordinator.refresh()
        #expect(display.shown.count == sentBefore + 1)
        captions.situation.interruptedByCall = false

        coordinator.appActivityChanged(isActive: false)
        #expect(await eventually { display.shown.last?.lines.last?.text == "coffee is ready" && display.shown.last?.status == nil })
    }

    @Test("with nothing new, the same lines are sent again now and then, until captions stop")
    func keepAlive() async throws {
        let (coordinator, display, captions) = make(keepAliveSeconds: 0.2)
        coordinator.refresh()
        let first = display.shown.count
        #expect(await eventually { display.shown.count >= first + 2 })

        captions.situation.phase = .paused
        coordinator.refresh()
        let afterStop = display.shown.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(display.shown.count == afterStop)
    }

    @Test("after a quiet minute only the newest line shows, saying how long ago; after a quarter of an hour none")
    func quietRoom() async {
        let (coordinator, display, captions) = make()
        captions.texts = ["the pills are on the table", "see you tomorrow"]
        coordinator.refresh()
        #expect(display.shown.last?.lines.count == 2)
        #expect(display.shown.last?.ageNote == nil)
        // Out of sight, at the lock screen's own pace.
        coordinator.appActivityChanged(isActive: false)

        captions.age = 3.5 * 60
        coordinator.refresh()
        #expect(await eventually { display.shown.last?.ageNote == LockScreenCaptions.ageNote(minutes: 3) })
        #expect(display.shown.last?.lines.map(\.text) == ["see you tomorrow"])
        #expect(display.shown.last?.status == nil)

        captions.age = 16 * 60
        coordinator.refresh()
        #expect(await eventually { display.shown.last?.lines == [] })
        #expect(display.shown.last?.ageNote == nil)
        #expect(display.isRunning)

        // A call's note takes the room; no age is added under it.
        captions.age = 3.5 * 60
        captions.situation.interruptedByCall = true
        coordinator.refresh()
        #expect(display.shown.last?.status != nil && display.shown.last?.ageNote == nil)
    }

    @Test("captions large in the app make the lock screen large")
    func textSize() {
        let (coordinator, display, captions) = make()
        captions.situation.captionSize = 40
        coordinator.refresh()
        #expect(display.shown.last?.textSize == .large)
    }
}
