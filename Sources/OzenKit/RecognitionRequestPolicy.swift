import Foundation

/// The decisions behind Apple's recognizer session, kept apart from the
/// Speech framework so they can be tested.
///
/// Apple's recognizer works in requests that each end with one final
/// result, so a live session rolls from one request to the next. Two
/// questions decide whether that feels continuous: when to end a request,
/// and what an error on the current request means.
public enum RecognitionRequestPolicy {
    public static let sampleRate = 16_000
    /// A pause this long after speech ends the utterance.
    public static let pauseSeconds = 1.2
    /// Roll over before Apple's own limits bite, so one runaway utterance
    /// can't grow without bound.
    public static let maxRequestSeconds = 45.0
    /// Pure silence for this long restarts the request quietly, before the
    /// recognizer times out with "no speech detected".
    public static let idleRestartSeconds = 8.0
    /// An error this soon after a request opened means the recognizer
    /// can't work right now, not that the room was quiet.
    public static let fastFailureSeconds = 2.0
    public static let maxConsecutiveFailures = 3

    public enum RolloverReason: Sendable, Equatable {
        case pauseAfterSpeech
        case tooLong
        case idle
    }

    public static func rollover(samplesInRequest: Int, samplesSinceSpeech: Int, requestHasSpeech: Bool) -> RolloverReason? {
        if requestHasSpeech && samplesSinceSpeech >= samples(pauseSeconds) { return .pauseAfterSpeech }
        if samplesInRequest >= samples(maxRequestSeconds) { return .tooLong }
        if !requestHasSpeech && samplesInRequest >= samples(idleRestartSeconds) { return .idle }
        return nil
    }

    public enum ErrorResponse: Sendable, Equatable {
        /// An error from a request already ended on purpose; expected.
        case ignore
        /// A quiet request that timed out: open the next one, no strike.
        case restartQuietly
        /// A real problem: open the next one and count a strike.
        case restartCounting
        /// Strikes ran out: end the stream so the pipeline can recover.
        case giveUp
    }

    /// `consecutiveFailures` is the count *before* this error.
    public static func respond(
        isCurrentRequest: Bool,
        requestHadSpeech: Bool,
        requestAudioSeconds: Double,
        consecutiveFailures: Int
    ) -> ErrorResponse {
        guard isCurrentRequest else { return .ignore }
        // Silence that ran a while is the recognizer giving up on a quiet
        // room. Counting it would make a quiet evening look like a broken
        // engine. A request that fails fast, or fails mid-speech, counts,
        // which also stops a broken recognizer from spinning in a tight
        // restart loop.
        if !requestHadSpeech && requestAudioSeconds >= fastFailureSeconds {
            return .restartQuietly
        }
        return consecutiveFailures + 1 >= maxConsecutiveFailures ? .giveUp : .restartCounting
    }

    static func samples(_ seconds: Double) -> Int {
        Int(seconds * Double(sampleRate))
    }
}
