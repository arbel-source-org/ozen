import Foundation

/// When a failed pipeline should try again by itself.
///
/// The reader of this app is not going to diagnose a hiccup. If the
/// recognizer drops out in the middle of a conversation, captions that stay
/// dead until someone notices the red status and taps it are, for her,
/// captions that stopped working. So failures that can clear up on their
/// own get retried automatically, sooner for a glitch and patiently for a
/// download waiting on Wi-Fi. Failures only a person can fix (a denied
/// permission, a language the device doesn't have) never are.
public struct AutoRecoveryPolicy: Sendable, Equatable {
    public enum Schedule: Sendable, Equatable {
        /// Audio or recognizer glitch: retry quickly a few times.
        case glitch
        /// Download failed, usually no connection: retry for a long while.
        case download
        /// A model that failed to load rarely fixes itself: try twice.
        case loadFailure
        /// Needs the person (system Settings, a different engine).
        case never
    }

    public var glitchDelays: [Double]
    public var downloadDelays: [Double]
    /// Listening this long without trouble means the next failure is a new
    /// problem, not the same one again, so the attempt count starts over.
    public var healthyListeningSeconds: Double
    public private(set) var attempts = 0

    public init(
        glitchDelays: [Double] = [1, 3, 8, 20],
        downloadDelays: [Double] = [15, 30, 60, 120, 300, 600],
        healthyListeningSeconds: Double = 60
    ) {
        self.glitchDelays = glitchDelays
        self.downloadDelays = downloadDelays
        self.healthyListeningSeconds = healthyListeningSeconds
    }

    /// Never retries. For tests that want a failure to stay put.
    public static let disabled = AutoRecoveryPolicy(glitchDelays: [], downloadDelays: [])

    public static func schedule(for failure: PipelineFailure) -> Schedule {
        switch failure.kind {
        case .microphonePermissionDenied:
            return .never
        case .audioSessionFailed, .noAudioInputs, .transcriptionStopped:
            return .glitch
        case .engineUnavailable:
            switch failure.engineUnavailability?.kind {
            case .permissionDenied, .languageNotSupportedOnDevice:
                return .never
            case .waitingForWiFi:
                // Retrying on a timer would only ask the same question of
                // the same cellular connection. The pipeline retries when
                // the connection changes instead.
                return .never
            case .notEnoughStorage:
                // Only the person can free up room; a timer would just fill
                // the phone again. The pipeline checks again when the app
                // comes back on screen.
                return .never
            case .modelDownloadFailed:
                return .download
            case .modelLoadFailed:
                return .loadFailure
            case .temporarilyUnavailable, .other, .none:
                return .glitch
            }
        }
    }

    /// Seconds to wait before retrying `failure`, or nil when it's time to
    /// stop and let the person decide. Each call counts as one attempt.
    public mutating func nextDelay(for failure: PipelineFailure) -> Double? {
        let delays: [Double]
        switch Self.schedule(for: failure) {
        case .never: return nil
        case .glitch: delays = glitchDelays
        case .download: delays = downloadDelays
        case .loadFailure: delays = Array(glitchDelays.prefix(2))
        }
        guard attempts < delays.count else { return nil }
        let delay = delays[attempts]
        attempts += 1
        return delay
    }

    public mutating func reset() {
        attempts = 0
    }
}

/// An automatic retry the pipeline has lined up.
public struct ScheduledRetry: Sendable, Equatable {
    /// Wall-clock time the retry will run.
    public let at: TimeInterval
    /// 1 for the first automatic retry after a failure, and so on.
    public let attempt: Int

    public init(at: TimeInterval, attempt: Int) {
        self.at = at
        self.attempt = attempt
    }
}
