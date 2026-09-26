import Foundation

/// Warns her, once, that leaving the app pauses the first-time model
/// download.
///
/// The model download runs over a foreground URLSession (see
/// `WhisperModelStore.download`), so putting the phone away or switching
/// to another app while the file is still arriving stops it mid-transfer;
/// nothing moves the progress bar again until Ozen is back on screen, and
/// nothing else says so. Compiling the model afterwards needs no network
/// and isn't affected, so this only watches the download step itself.
public struct DownloadBackgroundedNotice: Sendable, Equatable {
    public enum Update: Sendable, Equatable {
        case post(AlertNotificationContent)
        case withdraw(identifier: String)
    }

    public static let identifier = "download-backgrounded"
    /// A notice is sitting in Notification Center.
    private var posted = false
    /// She has been told about this download's pause already; not told
    /// again until it ends (finishes or fails) and a later one starts.
    private var told = false

    public init() {}

    /// Whether `phase` is the model download itself, as opposed to the
    /// checks and compiling steps around it.
    public static func isDownloading(_ phase: PipelinePhase) -> Bool {
        phase.preparationProgress?.stage == .downloadingModel
    }

    /// What to do with the phone's notifications given whether a download
    /// is running now. Nothing is posted while the app is on screen (the
    /// progress bar already says it), or when she turned notifications
    /// from the app off.
    public mutating func update(isDownloading: Bool, appIsActive: Bool, isEnabled: Bool) -> Update? {
        guard isDownloading else {
            told = false
            return withdrawIfPosted()
        }
        if appIsActive {
            return withdrawIfPosted()
        }
        guard isEnabled, !told else { return nil }
        posted = true
        told = true
        return .post(Self.content)
    }

    private mutating func withdrawIfPosted() -> Update? {
        guard posted else { return nil }
        posted = false
        return .withdraw(identifier: Self.identifier)
    }

    static var content: AlertNotificationContent {
        AlertNotificationContent(
            identifier: identifier,
            title: tr("ההורדה נעצרה", "The download paused"),
            body: tr(
                "כדי שההורדה החד-פעמית של קובץ השפה תמשיך, אוזן צריכה להישאר פתוחה על המסך. אפשר לפתוח אותה שוב כדי להמשיך.",
                "For the one-time language file download to continue, Ozen needs to stay open on screen. Open it again to continue."
            ),
            threadIdentifier: "status",
            isUrgent: false
        )
    }
}
