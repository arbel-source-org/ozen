import Foundation

/// Something that stopped the caption pipeline from reaching (or staying
/// in) the listening state. Structured by kind so the screen can show the
/// right recovery action: a permission denial can only be fixed in the
/// system Settings app, while a failed model download just needs a retry
/// once there's Wi-Fi.
public struct PipelineFailure: Sendable, Equatable, Error {
    public enum Kind: String, Sendable, Equatable {
        case microphonePermissionDenied
        case engineUnavailable
        case audioSessionFailed
        case noAudioInputs
        case transcriptionStopped
    }

    public var kind: Kind
    /// Technical detail (underlying error text, model name) for the
    /// diagnostics screen. Never shown as the primary message.
    public var detail: String
    public var engineUnavailability: EngineUnavailability?

    public init(kind: Kind, detail: String, engineUnavailability: EngineUnavailability? = nil) {
        self.kind = kind
        self.detail = detail
        self.engineUnavailability = engineUnavailability
    }

    /// True when a "try again" button inside the app can plausibly help.
    /// A denied permission can't be fixed from inside the app at all, so
    /// offering a retry there would just be a button that does nothing.
    public var isRetryableInApp: Bool {
        switch kind {
        case .microphonePermissionDenied:
            return false
        case .engineUnavailable:
            return engineUnavailability?.kind != .permissionDenied
        case .audioSessionFailed, .noAudioInputs, .transcriptionStopped:
            return true
        }
    }

    public var needsSystemSettings: Bool { !isRetryableInApp }

    /// Whether switching to the other engine is a sensible suggestion —
    /// e.g. Apple's on-device Hebrew model missing on this iOS version is
    /// exactly the case Whisper exists for.
    public var suggestsOtherEngine: Bool {
        guard kind == .engineUnavailable, let why = engineUnavailability else { return false }
        switch why.kind {
        case .languageNotSupportedOnDevice, .modelDownloadFailed, .modelLoadFailed, .notEnoughStorage:
            return true
        case .noInternet:
            return true
        case .permissionDenied, .waitingForWiFi, .cloudKeyNeeded, .cloudOutOfCredit, .temporarilyUnavailable, .other:
            return false
        }
    }
}

/// The single source of truth for what the live screen should show in its
/// status slot. Every transition the pipeline makes lands here, in order,
/// so there's no moment where the app is doing something (like a multi-
/// minute model download) that the screen doesn't reflect.
public enum PipelinePhase: Sendable, Equatable {
    case idle
    case requestingMicrophonePermission
    case preparingEngine(EnginePreparationProgress)
    case startingAudio
    case listening
    case paused
    case failed(PipelineFailure)

    public var isListening: Bool { self == .listening }

    /// True while `start()` is still working through its steps; the UI
    /// uses this to disable actions that would race the startup sequence.
    public var isTransitioning: Bool {
        switch self {
        case .requestingMicrophonePermission, .preparingEngine, .startingAudio:
            return true
        case .idle, .listening, .paused, .failed:
            return false
        }
    }

    public var failure: PipelineFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    public var preparationProgress: EnginePreparationProgress? {
        if case .preparingEngine(let progress) = self { return progress }
        return nil
    }

    /// The phase without a download's fraction, for work to do when a step
    /// begins or ends: the fraction changes many times a second, and a
    /// screen reacting to each one rescanned the disk or saved the
    /// conversation with every percent.
    public var step: PipelinePhase {
        guard case .preparingEngine(var progress) = self else { return self }
        progress.fraction = nil
        return .preparingEngine(progress)
    }
}

/// Running counters for the diagnostics screen. Cheap to keep and
/// genuinely useful when the owner reports "it went quiet" — the numbers
/// say whether audio stopped arriving, tokens stopped arriving, or the
/// screen stopped updating.
public struct PipelineStats: Sendable, Equatable {
    public var sessionStartedAt: TimeInterval?
    public var audioChunksReceived: Int = 0
    public var audioSecondsReceived: Double = 0
    public var tokensReceived: Int = 0
    public var segmentsCommitted: Int = 0
    public var lastTokenAt: TimeInterval?
    public var lastAudioAt: TimeInterval?
    public var engineRestarts: Int = 0
    public var inputChanges: Int = 0
    public var speakerClustersOpened: Int = 0
    /// Times the microphone stopped delivering audio mid-session and
    /// capture was restarted because of it.
    public var audioStalls: Int = 0
    /// Chunks with a NaN or infinite sample in them, passed on as silence
    /// (see `AudioFanOut`). Climbing means a microphone sending damaged
    /// audio.
    public var glitchedAudioChunks: Int = 0
    /// A caption line is still being written (not yet final).
    public var hasOpenLine = false
    /// Sound alerts are being listened for right now. False while
    /// captions run means the classifier stopped on its own.
    public var soundDetectionRunning = false
    /// How loud the microphone's chunks have been since launch.
    public var inputLevels = AudioLevelHistogram()
    /// Chunks the voice detector counted as someone talking.
    public var speechChunks: Int = 0
    /// The voice detector's noise floor and the margin above it speech
    /// needs, in dB, as of the latest chunk (see `EnergyVoiceDetector`).
    public var noiseFloorDecibels: Double?
    public var noiseMarginDecibels: Double?

    /// The share of audio the voice detector counted as speech, 0...1.
    /// Near zero through a conversation means speech arrives too quietly
    /// to clear its threshold.
    public var speechShare: Double? {
        guard inputLevels.total > 0 else { return nil }
        return Double(speechChunks) / Double(inputLevels.total)
    }

    public init() {}

    /// Seconds between the newest audio and the newest token while a line
    /// is still being written: a rough, honest "how far behind is the
    /// caption" number. With every line final, the captions have caught up
    /// and the lag is 0; measuring then would count the silence since the
    /// last word as delay.
    public var captionLagSeconds: Double? {
        guard let lastAudioAt, let lastTokenAt else { return nil }
        guard hasOpenLine else { return 0 }
        return max(0, lastAudioAt - lastTokenAt)
    }
}
