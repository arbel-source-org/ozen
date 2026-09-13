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
    /// Engine-reported confidence in 0...1 when the engine has one (Apple
    /// Speech reports per-segment confidence; Whisper exposes log-probs that
    /// get mapped into this range). Nil means the engine said nothing.
    public var confidence: Float?

    public init(
        utteranceID: UUID,
        text: String,
        isFinal: Bool,
        timestamp: TimeInterval,
        speakerClusterID: Int? = nil,
        confidence: Float? = nil
    ) {
        self.utteranceID = utteranceID
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.speakerClusterID = speakerClusterID
        self.confidence = confidence
    }
}

/// What an engine is doing while it gets ready. Whisper has to download
/// hundreds of megabytes of model on first launch and then compile it for
/// the Neural Engine — that can take minutes, and the very first version of
/// the app showed nothing at all during that time, which read as "broken".
/// Every stage is reported so the screen can say exactly what's happening.
public struct EnginePreparationProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable, CaseIterable {
        case checkingSupport
        case requestingPermission
        case downloadingModel
        case loadingModel
        case warmingUp
    }

    public var stage: Stage
    /// 0...1 when the engine can measure it (downloads), nil when it can't
    /// (CoreML compilation gives no progress at all).
    public var fraction: Double?
    /// Free-form technical detail for the diagnostics screen, e.g. the
    /// model variant being fetched. Not user-facing copy.
    public var detail: String?

    public init(stage: Stage, fraction: Double? = nil, detail: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

/// Why an engine can't be used, structured so the UI can decide what to
/// offer (a retry button, a "open Settings" button, a suggestion to try the
/// other engine) instead of pattern-matching on English error text.
public struct EngineUnavailability: Sendable, Equatable, Error {
    public enum Kind: String, Sendable, Equatable {
        case permissionDenied
        case languageNotSupportedOnDevice
        case modelDownloadFailed
        case modelLoadFailed
        case temporarilyUnavailable
        case other
    }

    public var kind: Kind
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
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
    case unavailable(EngineUnavailability)

    public static func unavailable(_ kind: EngineUnavailability.Kind, _ detail: String) -> EngineAvailability {
        .unavailable(EngineUnavailability(kind: kind, detail: detail))
    }

    public var unavailability: EngineUnavailability? {
        if case .unavailable(let why) = self { return why }
        return nil
    }
}

/// A live, streaming speech-to-text engine. Implementations that touch
/// Apple-only frameworks (WhisperKit, `SFSpeechRecognizer`) live in
/// `OzenPlatform`; this protocol itself has no platform dependency so the
/// rest of the pipeline (`CaptionStabilizer`, `CaptionPipeline`) can be
/// tested against a fake engine with no audio or CoreML involved.
public protocol TranscriptionEngine: Sendable {
    var kind: TranscriptionEngineKind { get }

    /// Does whatever slow work is needed before `stream` can produce
    /// tokens (permissions, model download, model load), reporting each
    /// stage through `progress`. Must be safe to call again on an engine
    /// that's already prepared — the pipeline caches engine instances
    /// across restarts precisely so a second call is instant.
    func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability

    /// Consumes rolling PCM float buffers and yields tokens as they become
    /// available. `audio` is expected to be short, sequential chunks (a
    /// couple hundred ms to a couple seconds each) rather than one big
    /// buffer per utterance — that's what makes the result "live".
    func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error>
}

public extension TranscriptionEngine {
    /// `prepare` without caring about progress — for callers (and tests)
    /// that only want the yes/no answer.
    func checkAvailability(languageCode: String) async -> EngineAvailability {
        await prepare(languageCode: languageCode, progress: { _ in })
    }
}
