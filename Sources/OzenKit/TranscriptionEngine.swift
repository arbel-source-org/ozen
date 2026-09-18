import Foundation

/// Which speech-to-text engine is producing tokens. Kept as a plain enum
/// (rather than inferring it from the concrete type) so it can be stored in
/// `AppSettings`, shown in Settings, and switched by the user at runtime.
public enum TranscriptionEngineKind: String, Codable, Sendable, CaseIterable {
    case whisperKit
    case appleSpeech
    /// A speech model on the internet (see `CloudSpeech`).
    case cloud

    public var displayName: String {
        switch self {
        case .whisperKit: return "Whisper (on-device)"
        case .appleSpeech: return "Apple Speech"
        case .cloud: return "Cloud (OpenRouter)"
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
    /// The engine heard a different person start talking here, in the same
    /// stretch of audio as the line before (see `CloudSpeech.turns`). The
    /// voice heard just before belongs to that other line, not this one.
    public var startsNewSpeakerTurn: Bool
    /// The words the engine was least sure of, when it can tell one word
    /// from another (see `UncertainWords`). Empty means nothing to mark.
    public var uncertainWords: [String]

    public init(
        utteranceID: UUID,
        text: String,
        isFinal: Bool,
        timestamp: TimeInterval,
        speakerClusterID: Int? = nil,
        confidence: Float? = nil,
        startsNewSpeakerTurn: Bool = false,
        uncertainWords: [String] = []
    ) {
        self.utteranceID = utteranceID
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.speakerClusterID = speakerClusterID
        self.confidence = confidence
        self.startsNewSpeakerTurn = startsNewSpeakerTurn
        self.uncertainWords = uncertainWords
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
    /// The model has never been loaded on this phone: the load compiles it
    /// for the chip and takes minutes instead of seconds, and the screen
    /// should say it is a one-time wait rather than look stuck.
    public var isFirstTime: Bool

    public init(stage: Stage, fraction: Double? = nil, detail: String? = nil, isFirstTime: Bool = false) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
        self.isFirstTime = isFirstTime
    }

    /// How often a download's fraction alone is put on screen when it
    /// hasn't reached another whole percent, so the time left stays fresh.
    public static let fractionIntervalSeconds: TimeInterval = 1

    /// Whether this update is worth showing after `shown`, which went on
    /// screen at `shownAt`: another step or model, another whole percent
    /// (what the screen shows), or a second later. A download reports every
    /// chunk off the network, and each report redrew the caption screen.
    public func isNews(after shown: EnginePreparationProgress, shownAt: TimeInterval, now: TimeInterval) -> Bool {
        guard stage == shown.stage, detail == shown.detail, let fraction, let shownFraction = shown.fraction else {
            return self != shown
        }
        return Self.percent(fraction) != Self.percent(shownFraction)
            || now - shownAt >= Self.fractionIntervalSeconds
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
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
        /// The model still has to be downloaded, the phone is on cellular
        /// data or Low Data Mode, and nobody said that's fine.
        case waitingForWiFi
        /// The phone doesn't have room for the model (see `StorageSpaceGate`).
        case notEnoughStorage
        /// Cloud captions have no key, or OpenRouter turned the key down.
        case cloudKeyNeeded
        /// The OpenRouter key has used up its credit or spending limit.
        case cloudOutOfCredit
        /// Cloud captions can't reach the internet.
        case noInternet
        case temporarilyUnavailable
        case other
    }

    public var kind: Kind
    public var detail: String
    /// For `waitingForWiFi` and `notEnoughStorage`: how big the download
    /// is, so the screen can say.
    public var downloadMegabytes: Int?
    /// For `notEnoughStorage`: how much more room has to be freed, when known.
    public var missingMegabytes: Int?

    public init(kind: Kind, detail: String, downloadMegabytes: Int? = nil, missingMegabytes: Int? = nil) {
        self.kind = kind
        self.detail = detail
        self.downloadMegabytes = downloadMegabytes
        self.missingMegabytes = missingMegabytes
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

    /// How much `prepare` would have to download first, in megabytes, or
    /// nil when nothing big is needed (the model is already on the phone,
    /// or the engine doesn't download). Asked before `prepare` so a large
    /// download can wait for Wi-Fi.
    func pendingDownloadMegabytes() async -> Int?

    /// Names and words to bias recognition towards (see `VocabularyHints`).
    /// Called before every `stream` and again whenever the user edits the
    /// list mid-conversation; engines that can't use hints ignore it.
    func setVocabulary(_ terms: [String]) async
}

public extension TranscriptionEngine {
    func setVocabulary(_ terms: [String]) async {}

    func pendingDownloadMegabytes() async -> Int? { nil }

    /// `prepare` without caring about progress — for callers (and tests)
    /// that only want the yes/no answer.
    func checkAvailability(languageCode: String) async -> EngineAvailability {
        await prepare(languageCode: languageCode, progress: { _ in })
    }
}
