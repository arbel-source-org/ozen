import Foundation
@testable import OzenKit

/// Scripted stand-in for the phone's voice. Behaves like
/// `AVSpeechSynthesizer` where it matters: a new request while speaking
/// cancels the current utterance, and that cancel's callback arrives
/// later (the test delivers it with `deliverCallbacks`), by which time
/// the new utterance is already queued.
@MainActor
final class FakeSynthesizer: SpeechSynthesizing {
    private(set) var isSpeaking = false
    private(set) var requests: [String] = []
    private var queued: [String] = []
    private var pendingCallbacks: [Bool] = []
    let hasHebrewVoice = true
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    var isBusy: Bool { isSpeaking || !queued.isEmpty }

    func speak(_ text: String, rate: Float) {
        requests.append(text)
        if isSpeaking {
            isSpeaking = false
            pendingCallbacks.append(false)
        }
        queued.append(text)
    }

    func stop() {
        if isSpeaking {
            isSpeaking = false
            pendingCallbacks.append(false)
        }
        queued.removeAll()
    }

    func deliverCallbacks() {
        let callbacks = pendingCallbacks
        pendingCallbacks = []
        for speaking in callbacks {
            onSpeakingChanged?(speaking)
        }
    }

    func startNext() {
        guard !queued.isEmpty else { return }
        queued.removeFirst()
        isSpeaking = true
        onSpeakingChanged?(true)
    }

    func finishCurrent() {
        guard isSpeaking else { return }
        isSpeaking = false
        onSpeakingChanged?(false)
    }
}
