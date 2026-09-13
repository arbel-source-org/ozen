import Foundation
import AVFoundation
import Observation
import OzenKit

/// Type-to-speak: the reader types (or taps a ready-made phrase) and the
/// phone says it aloud in Hebrew. Wraps `AVSpeechSynthesizer`, picks the
/// best available Hebrew voice, and reports when speaking starts and stops
/// so the caption pipeline can pause — otherwise the microphone would
/// caption the phone's own voice.
@MainActor
@Observable
public final class SpeechSynthesizer: SpeechSynthesizing {
    public private(set) var isSpeaking = false
    /// `AVSpeechSynthesizer.isSpeaking` is also true while an utterance is
    /// queued but not started, which is exactly the state a cancel
    /// callback needs to see.
    public var isBusy: Bool { synthesizer.isSpeaking }
    /// Whether any Hebrew voice is installed at all; without one iOS
    /// falls back to a voice that mangles Hebrew, and the UI should say so.
    public let hasHebrewVoice: Bool

    public var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeakingDelegate()
    private let voice: AVSpeechSynthesisVoice?

    public init(languageCode: String = "he-IL") {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        // Prefer the highest quality voice installed (enhanced/premium
        // voices are downloaded by the user in iOS Settings).
        voice = candidates.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: languageCode)
        hasHebrewVoice = voice?.language == languageCode
        synthesizer.delegate = delegate
        delegate.onChange = { [weak self] speaking in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSpeaking = speaking
                self.onSpeakingChanged?(speaking)
            }
        }
    }

    public func speak(_ text: String, rate: Float) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// `AVSpeechSynthesizerDelegate` callbacks arrive on an arbitrary queue;
/// this bridges them to one `Bool` the main-actor owner can consume.
private final class SpeakingDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onChange: (@Sendable (Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onChange?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onChange?(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onChange?(false)
    }
}
