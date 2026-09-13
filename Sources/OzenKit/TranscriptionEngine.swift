import Foundation

/// Which speech-to-text engine is producing tokens. Kept as a plain enum
/// (rather than inferring it from the concrete type) so it can be stored in
/// `AppSettings`, shown in Settings, and switched by the user at runtime.
public enum TranscriptionEngineKind: String, Codable, Sendable, CaseIterable {
    case whisperKit
    case appleSpeech

    public var displayName: String {
        switch self {
        case .whisperKit: return "Whisper (on-device)"
        case .appleSpeech: return "Apple Speech"
        }
    }
}

/// One update from an engine about a single in-progress or finished
/// utterance. Engines emit many of these per utterance as more audio
/// arrives — the same `utteranceID` with growing/changing `text` — and
/// mark the last one `isFinal` when the utterance is done. `CaptionStabilizer`
/// is what turns this stream into stable, displayable segments.
public struct TranscriptToken: Sendable, Equatable {
    public let utteranceID: UUID
    public let text: String
    public let isFinal: Bool
    public let timestamp: TimeInterval
    public var speakerClusterID: Int?

    public init(
        utteranceID: UUID,
        text: String,
        isFinal: Bool,
        timestamp: TimeInterval,
        speakerClusterID: Int? = nil
    ) {
        self.utteranceID = utteranceID
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.speakerClusterID = speakerClusterID
    }
}

/// Whether an engine can actually be used right now, in this language, on
/// this device. Distinct from "engine exists" — e.g. Apple's on-device
/// Hebrew model may simply not be installed on a given iOS version, and the
/// app needs to say so rather than silently falling back to a server-based
/// mode that would break the on-device-only requirement without telling
/// anyone.
public enum EngineAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// A live, streaming speech-to-text engine. Implementations that touch
/// Apple-only frameworks (WhisperKit, `SFSpeechRecognizer`) live in
/// `OzenPlatform`; this protocol itself has no platform dependency so the
/// rest of the pipeline (`CaptionStabilizer`, the view model) can be tested
/// against a fake engine with no audio or CoreML involved.
public protocol TranscriptionEngine: Sendable {
    var kind: TranscriptionEngineKind { get }

    func checkAvailability(languageCode: String) async -> EngineAvailability

    /// Consumes rolling PCM float buffers and yields tokens as they become
    /// available. `audio` is expected to be short, sequential chunks (a
    /// couple hundred ms to a couple seconds each) rather than one big
    /// buffer per utterance — that's what makes the result "live".
    func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error>
}
