import Foundation

/// Tells her, once, that captions stopped while the phone was put away.
///
/// With the phone in a pocket or on the table with the screen off, the
/// doorbell and name alerts are the whole point of leaving captions on.
/// When captions stop there and nothing will bring them back by itself,
/// those alerts stop too, and nothing on a dark screen says so. Two ways
/// that happens:
///
/// - a failure automatic recovery won't retry, or has given up on;
/// - a phone call ends but iOS never hands the microphone back, which it
///   doesn't promise to do.
///
/// The notice is withdrawn from Notification Center once captions run
/// again, or are paused or stopped on purpose, so an old "stopped" never
/// sits under a working app.
public struct StoppedCaptionsNotice: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        /// Failed, and nothing is going to retry.
        case failed(PipelineFailure)
        /// The call is over, but the microphone didn't come back.
        case callEnded
    }

    public enum Update: Sendable, Equatable {
        case post(AlertNotificationContent)
        case withdraw(identifier: String)
    }

    public static let identifier = "captions-stopped"
    private var posted = false

    public init() {}

    /// Why captions are stopped for good right now, or nil when they run,
    /// are on their way back, or were paused on purpose.
    ///
    /// `callEndedDuringInterruption` is true once a call that took the
    /// microphone is known to be over while iOS still hasn't said the
    /// interruption ended. Until then an interruption is someone on the
    /// phone, which is no news to her.
    public static func cause(
        phase: PipelinePhase,
        retryScheduled: Bool,
        systemInterrupted: Bool,
        callEndedDuringInterruption: Bool
    ) -> Cause? {
        if systemInterrupted {
            // A failure during the call is retried once the call gives the
            // microphone back, so what matters is only whether it did.
            guard callEndedDuringInterruption, phase.isListening || phase.failure != nil else { return nil }
            return .callEnded
        }
        guard let failure = phase.failure, !retryScheduled else { return nil }
        // Starts by itself as soon as the phone is on Wi-Fi.
        if failure.engineUnavailability?.kind == .waitingForWiFi { return nil }
        return .failed(failure)
    }

    /// What to do with the phone's notifications given the current `cause`.
    /// Nothing is posted while the app is on screen (the status already
    /// says it), or when she turned notifications from the app off.
    public mutating func update(for cause: Cause?, appIsActive: Bool, isEnabled: Bool) -> Update? {
        guard let cause else {
            guard posted else { return nil }
            posted = false
            return .withdraw(identifier: Self.identifier)
        }
        guard !appIsActive, isEnabled, !posted else { return nil }
        posted = true
        return .post(Self.content(for: cause))
    }

    static func content(for cause: Cause) -> AlertNotificationContent {
        AlertNotificationContent(
            identifier: identifier,
            title: "הכתוביות נעצרו",
            body: body(for: cause),
            threadIdentifier: "status",
            isUrgent: true
        )
    }

    private static func body(for cause: Cause) -> String {
        switch cause {
        case .callEnded:
            return "אחרי השיחה הכתוביות לא חזרו לבד. פתחו את אוזן כדי להמשיך."
        case .failed(let failure):
            switch (failure.kind, failure.engineUnavailability?.kind) {
            case (.microphonePermissionDenied, _), (_, .permissionDenied?):
                return "לאוזן אין הרשאה להקשיב. פתחו את האפליקציה כדי לתקן."
            case (_, .notEnoughStorage?):
                return "אין מספיק מקום בטלפון. פתחו את אוזן לפרטים."
            case (.noAudioInputs, _):
                return "לא נמצא מיקרופון. פתחו את אוזן כדי להמשיך."
            default:
                return "פתחו את אוזן כדי להמשיך."
            }
        }
    }
}
