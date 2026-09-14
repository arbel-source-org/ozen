import Foundation
import Testing
@testable import OzenKit

@Suite("ControlBarAutoHide")
struct ControlBarAutoHideTests {
    private func hides(
        enabled: Bool = true,
        isListening: Bool = true,
        followingLatest: Bool = true,
        hasLines: Bool = true,
        voiceOverRunning: Bool = false,
        idle: TimeInterval = 10
    ) -> Bool {
        ControlBarAutoHide.hides(
            enabled: enabled,
            isListening: isListening,
            followingLatest: followingLatest,
            hasLines: hasLines,
            voiceOverRunning: voiceOverRunning,
            lastTouchAt: 1_000,
            now: 1_000 + idle
        )
    }

    @Test("captions running on their own, untouched for a few seconds: the buttons go")
    func hidesWhenIdle() {
        #expect(hides())
        #expect(hides(idle: ControlBarAutoHide.idleSeconds))
    }

    @Test("a recent touch keeps them")
    func recentTouch() {
        #expect(!hides(idle: ControlBarAutoHide.idleSeconds - 0.5))
        #expect(!hides(idle: 0))
    }

    @Test("anything that needs the buttons keeps them: not listening, reading back, no lines yet, VoiceOver, switched off")
    func keptWhenNeeded() {
        let kept = [
            hides(isListening: false),
            hides(followingLatest: false),
            hides(hasLines: false),
            hides(voiceOverRunning: true),
            hides(enabled: false),
        ]
        #expect(kept == [false, false, false, false, false])
    }
}
