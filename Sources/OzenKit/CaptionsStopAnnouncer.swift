import Foundation

/// When VoiceOver says that captions stopped by themselves, and that they
/// came back.
///
/// Alerts and finished lines are read out as they happen, but the status
/// control only speaks when it is focused: someone who can't see the
/// screen would keep waiting for lines that won't come. A stop she chose
/// (pause, stop) is no news, and neither is each retry of the same stop.
public struct CaptionsStopAnnouncer: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// Captions failed; say why.
        case stopped
        /// Listening again after a failure.
        case back
    }

    private var stoppedByFailure = false

    public init() {}

    /// Call with every new phase; returns what to announce, if anything.
    public mutating func phaseChanged(to phase: PipelinePhase) -> Event? {
        switch phase {
        case .failed:
            guard !stoppedByFailure else { return nil }
            stoppedByFailure = true
            return .stopped
        case .listening:
            guard stoppedByFailure else { return nil }
            stoppedByFailure = false
            return .back
        case .idle, .paused:
            // Paused or stopped on purpose: starting again later is no
            // recovery to announce.
            stoppedByFailure = false
            return nil
        case .requestingMicrophonePermission, .preparingEngine, .startingAudio:
            return nil
        }
    }
}
