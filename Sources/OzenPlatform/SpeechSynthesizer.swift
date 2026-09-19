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
    /// False for the first moment after launch, until the voices are read.
    public private(set) var hasHebrewVoice = false

    public var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeakingDelegate()
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    /// For text with no Hebrew in it: English phrases on the Say screen, or
    /// anything typed in English. Spoken by the Hebrew voice they'd be mangled.
    @ObservationIgnored private var englishVoice: AVSpeechSynthesisVoice?
    private static let englishLanguageCode = "en-US"
    private let languageCode: String

    public init(languageCode: String = "he-IL") {
        self.languageCode = languageCode
        synthesizer.delegate = delegate
        delegate.onChange = { [weak self] speaking in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSpeaking = speaking
                self.onSpeakingChanged?(speaking)
            }
        }
        refreshVoice()
    }

    /// Re-reads the installed voice list. Called once at launch and again
    /// whenever the app returns to the foreground (`LiveCaptionViewModel
    /// .sceneActivityChanged`), so installing or removing the Hebrew voice
    /// in iOS Settings and coming straight back is picked up without
    /// needing a relaunch.
    public func refreshVoice() {
        // Listing the installed voices reads their metadata from disk: not
        // on the main thread while the app draws its first screen. Captured
        // as a local so the detached task doesn't need to hop back to the
        // main actor just to read this instance's own immutable property.
        let languageCode = self.languageCode
        Task { [weak self] in
            let identifiers = await Task.detached(priority: .utility) {
                (SpeechSynthesizer.bestVoiceIdentifier(for: languageCode),
                 SpeechSynthesizer.bestVoiceIdentifier(for: SpeechSynthesizer.englishLanguageCode))
            }.value
            guard let self else { return }
            if let english = identifiers.1 { self.englishVoice = AVSpeechSynthesisVoice(identifier: english) }
            guard let identifier = identifiers.0, let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return }
            self.voice = voice
            self.hasHebrewVoice = voice.language == languageCode
        }
    }

    /// The highest quality voice installed for the language (enhanced and
    /// premium voices are downloaded by the user in iOS Settings).
    private nonisolated static func bestVoiceIdentifier(for languageCode: String) -> String? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        let best = candidates.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: languageCode)
        return best?.identifier
    }

    public func speak(_ text: String, rate: Float) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        // Spoken before the voice list was read: ask for the language, so
        // Hebrew never falls back to an English voice.
        if SpeechSynthesizer.containsHebrew(trimmed) {
            utterance.voice = voice ?? AVSpeechSynthesisVoice(language: languageCode)
        } else {
            utterance.voice = englishVoice ?? AVSpeechSynthesisVoice(language: SpeechSynthesizer.englishLanguageCode)
        }
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Any Hebrew letter (the Hebrew block, U+0590...U+05FF) makes it Hebrew.
    nonisolated static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
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
