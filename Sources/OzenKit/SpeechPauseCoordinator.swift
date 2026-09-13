import Foundation

/// Anything that can say text aloud. The real one wraps
/// `AVSpeechSynthesizer` (OzenPlatform); tests use a scripted fake.
@MainActor
public protocol SpeechSynthesizing: AnyObject {
    /// Speaking right now (drives the UI's speaker icon).
    var isSpeaking: Bool { get }
    /// Speaking *or* holding a queued utterance that hasn't started yet.
    /// A cancel callback can arrive while the next phrase is already
    /// queued, and only this tells the two apart.
    var isBusy: Bool { get }
    var hasHebrewVoice: Bool { get }
    var onSpeakingChanged: (@MainActor (Bool) -> Void)? { get set }
    func speak(_ text: String, rate: Float)
    func stop()
}

/// Decides when captions pause for the phone's own voice and when they
/// come back.
///
/// The naive rule, "resume when the synthesizer says it stopped", fails in
/// the most common case: tapping a second ready-made phrase while the
/// first is still playing. Starting the second cancels the first, the
/// cancel reports "stopped", captions resume, and the microphone captions
/// the phone saying the second phrase. So every request to speak bumps a
/// generation, a "went quiet" report waits a short settle time, and
/// captions resume only if nothing new was asked for in the meantime and
/// the synthesizer really is idle.
public struct SpeechPauseCoordinator: Sendable, Equatable {
    /// Long enough for the speaker's tail to die away before the
    /// microphone opens again.
    public static let settleSeconds: Double = 0.35

    /// True while captions are paused because of speech (and not by hand).
    public private(set) var isHoldingCaptions = false
    public private(set) var generation = 0

    public init() {}

    /// Call before speaking. Returns true when captions are live and the
    /// caller should pause them now.
    public mutating func willSpeak(captionsListening: Bool) -> Bool {
        generation += 1
        guard captionsListening else { return false }
        isHoldingCaptions = true
        return true
    }

    /// The synthesizer reported it stopped (finished or cancelled).
    /// Returns the generation to re-check after `settleSeconds`, or nil
    /// when these captions aren't ours to bring back.
    public func speechWentQuiet() -> Int? {
        isHoldingCaptions ? generation : nil
    }

    /// After the settle delay. True means: resume captions now.
    public mutating func shouldResume(generation checked: Int, synthesizerBusy: Bool, captionsPaused: Bool) -> Bool {
        guard isHoldingCaptions, checked == generation, !synthesizerBusy else { return false }
        isHoldingCaptions = false
        return captionsPaused
    }

    /// The user paused, resumed, stopped or restarted by hand. Their
    /// choice wins over any automatic resume still pending.
    public mutating func userTookControl() {
        isHoldingCaptions = false
    }
}
