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

    @Test("a Bluetooth headset nobody picked doesn't take the recording over from the phone's own microphone")
    func unchosenHeadsetGivesWay() {
        let connected = AudioRoutePolicy.resolveSelection(
            available: [builtIn, airpods],
            preferredUID: nil,
            currentUID: airpods.uid
        )
        #expect(connected == builtIn.uid)

        let besideWiredMic = AudioRoutePolicy.resolveSelection(
            available: [airpods, lavalier],
            preferredUID: nil,
            currentUID: airpods.uid
        )
        #expect(besideWiredMic == lavalier.uid)
    }

    @Test("a hearing aid nobody chose gives way to the phone's microphone, like a headset; chosen, it stays")
    func unchosenHearingAidGivesWay() {
        let hearingAid = AudioInputDescriptor(uid: "hearing-aid", portName: "Phonak Audéo", portType: .hearingAid)
        let unchosen = AudioRoutePolicy.resolveSelection(available: [builtIn, hearingAid], preferredUID: nil, currentUID: hearingAid.uid)
        #expect(unchosen == builtIn.uid)
        let chosen = AudioRoutePolicy.resolveSelection(available: [builtIn, hearingAid], preferredUID: hearingAid.uid, currentUID: builtIn.uid)
        #expect(chosen == hearingAid.uid)
        let alone = AudioRoutePolicy.resolveSelection(available: [hearingAid], preferredUID: nil, currentUID: hearingAid.uid)
        #expect(alone == hearingAid.uid)
    }

    @Test("a headset that is the only microphone here is still used")
    func onlyHeadset() {
        let selection = AudioRoutePolicy.resolveSelection(
            available: [airpods],
            preferredUID: nil,
            currentUID: airpods.uid
        )
        #expect(selection == airpods.uid)
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

    @Test("a remote assistive microphone (Phonak Roger) is not an ear-worn device, and isn't given way to like one")
    func remoteMicIsNotOnTheEar() {
        #expect(!AudioPortType.remoteMic.isOnTheListenersEar)

        let rogerMic = AudioInputDescriptor(uid: "roger-1", portName: "Roger Table Mic", portType: .remoteMic)
        let chosenByIOS = AudioRoutePolicy.resolveSelection(
            available: [builtIn, rogerMic],
            preferredUID: nil,
            currentUID: rogerMic.uid
        )
        #expect(chosenByIOS == rogerMic.uid)
    }
}
