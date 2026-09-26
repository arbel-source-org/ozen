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
    /// A notice is sitting in Notification Center.
    private var posted = false
    /// She has been told about this stop: by the notice, or by opening the
    /// app and seeing the status. Not told again until captions run.
    private var told = false

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
    ///
    /// Opening the app while captions are still stopped takes the notice
    /// away: the status says the same thing, and a notice left behind sat
    /// in Notification Center for as long as the problem lasted. Putting
    /// the phone away again doesn't post it a second time.
    public mutating func update(for cause: Cause?, appIsActive: Bool, isEnabled: Bool) -> Update? {
        guard cause != nil else {
            told = false
            return withdrawIfPosted()
        }
        if appIsActive {
            return withdrawIfPosted()
        }
        guard isEnabled, !told, let cause else { return nil }
        posted = true
        told = true
        return .post(Self.content(for: cause))
    }

    private mutating func withdrawIfPosted() -> Update? {
        guard posted else { return nil }
        posted = false
        return .withdraw(identifier: Self.identifier)
    }

    static func content(for cause: Cause) -> AlertNotificationContent {
        AlertNotificationContent(
            identifier: identifier,
            title: tr("הכתוביות נעצרו", "Captions stopped"),
            body: body(for: cause),
            threadIdentifier: "status",
            isUrgent: true
        )
    }

    private static func body(for cause: Cause) -> String {
        switch cause {
        case .callEnded:
            return tr(
                "אחרי השיחה הכתוביות לא חזרו לבד. פתחו את אוזן כדי להמשיך.",
                "After the call, captions didn't come back on their own. Open Ozen to continue."
            )
        case .failed(let failure):
            switch (failure.kind, failure.engineUnavailability?.kind) {
            case (.microphonePermissionDenied, _), (_, .permissionDenied?):
                return tr(
                    "לאוזן אין הרשאה להקשיב. פתחו את האפליקציה כדי לתקן.",
                    "Ozen doesn't have permission to listen. Open the app to fix it."
                )
            case (_, .notEnoughStorage?):
                return tr(
                    "אין מספיק מקום בטלפון. פתחו את אוזן לפרטים.",
                    "There isn't enough space on the phone. Open Ozen for details."
                )
            case (.noAudioInputs, _):
                return tr(
                    "לא נמצא מיקרופון. פתחו את אוזן כדי להמשיך.",
                    "No microphone was found. Open Ozen to continue."
                )
            case (_, .cloudKeyNeeded?), (_, .cloudOutOfCredit?):
                return tr(
                    "יש בעיה במפתח של התמלול בענן. פתחו את אוזן לפרטים.",
                    "There's a problem with the cloud transcription key. Open Ozen for details."
                )
            case (_, .noInternet?):
                return tr(
                    "אין אינטרנט, והתמלול בענן צריך אותו. פתחו את אוזן כדי לעבור לזיהוי הדיבור שבטלפון.",
                    "There's no internet, and cloud transcription needs it. Open Ozen to switch to the phone's own speech recognition."
                )
            default:
                return tr("פתחו את אוזן כדי להמשיך.", "Open Ozen to continue.")
            }
        }
    }
}
