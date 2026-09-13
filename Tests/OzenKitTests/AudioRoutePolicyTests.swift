import Testing
@testable import OzenKit

@Suite("AudioRoutePolicy")
struct AudioRoutePolicyTests {
    let builtIn = AudioInputDescriptor(uid: "builtin", portName: "iPhone Microphone", portType: .builtInMic)
    let airpods = AudioInputDescriptor(uid: "airpods-123", portName: "Arbel's AirPods", portType: .bluetooth)
    let lavalier = AudioInputDescriptor(uid: "usb-lav-1", portName: "USB-C Lavalier", portType: .usb)

    @Test("the user's preferred input is selected when it's present")
    func preferredInputWins() {
        let selection = AudioRoutePolicy.resolveSelection(
            available: [builtIn, airpods, lavalier],
            preferredUID: airpods.uid,
            currentUID: builtIn.uid
        )
        #expect(selection == airpods.uid)
    }

    @Test("a preferred input that reconnects is picked back up automatically (e.g. AirPods coming back in range)")
    func reconnectingPreferredInputIsPickedUpAgain() {
        // The exact "worked, then stopped working" complaint: preference is
        // set, the device briefly disappears from `available`, then
        // reappears — it should be re-selected without the user doing
        // anything.
        let disappeared = AudioRoutePolicy.resolveSelection(
            available: [builtIn],
            preferredUID: airpods.uid,
            currentUID: builtIn.uid
        )
        #expect(disappeared == builtIn.uid)

        let reappeared = AudioRoutePolicy.resolveSelection(
            available: [builtIn, airpods],
            preferredUID: airpods.uid,
            currentUID: builtIn.uid
        )
        #expect(reappeared == airpods.uid)
    }

    @Test("with no preference, the currently active input is kept rather than switched arbitrarily")
    func noPreferenceKeepsCurrent() {
        let selection = AudioRoutePolicy.resolveSelection(
            available: [builtIn, lavalier],
            preferredUID: nil,
            currentUID: lavalier.uid
        )
        #expect(selection == lavalier.uid)
    }

    @Test("with no preference and no valid current input, falls back to the first available input")
    func fallsBackToFirstAvailable() {
        let selection = AudioRoutePolicy.resolveSelection(
            available: [lavalier, airpods],
            preferredUID: nil,
            currentUID: nil
        )
        #expect(selection == lavalier.uid)
    }

    @Test("with nothing available at all, resolves to nil instead of a fake selection")
    func noInputsAvailable() {
        let selection = AudioRoutePolicy.resolveSelection(
            available: [],
            preferredUID: airpods.uid,
            currentUID: airpods.uid
        )
        #expect(selection == nil)
    }

    @Test("a stale current input that's no longer available falls through to first available")
    func staleCurrentInputIsIgnored() {
        let selection = AudioRoutePolicy.resolveSelection(
            available: [builtIn],
            preferredUID: nil,
            currentUID: lavalier.uid
        )
        #expect(selection == builtIn.uid)
    }
}
