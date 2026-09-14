import AppIntents
import Foundation
import Observation

/// "Hey Siri, start captions in Ozen" — the whole app is one screen, so the
/// intents just open it and leave a note for the view to act on. They
/// run in the app's own process (`openAppWhenRun`), so nothing has to be
/// shared across an extension boundary.
struct StartCaptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "התחלת כתוביות"
    static let description = IntentDescription("פותח את אוזן ומתחיל לכתב את השיחה.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAppAction.shared.post(.startCaptions)
        return .result()
    }
}

struct StopCaptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "עצירת כתוביות"
    static let description = IntentDescription("מפסיק את הכתוביות ושומר את השיחה בהיסטוריה.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAppAction.shared.post(.stopCaptions)
        return .result()
    }
}

/// "Hey Siri, say in Ozen that I'm coming" — for the moments she can't reach
/// the keyboard.
struct SpeakIntent: AppIntent {
    static let title: LocalizedStringResource = "להגיד משהו בקול"
    static let description = IntentDescription("אוזן אומרת את המשפט בקול רם, בעברית.")
    static let openAppWhenRun = true

    @Parameter(title: "מה להגיד")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("להגיד \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAppAction.shared.post(.speak(text))
        return .result()
    }
}

/// "Write to me": the big-letters pad, straight from Siri or the Action
/// button, for when captions can't keep up and someone needs to type.
struct ShowBigTextIntent: AppIntent {
    static let title: LocalizedStringResource = "כתבו לי"
    static let description = IntentDescription("פותח את אוזן במסך מלא באותיות גדולות, כדי שמישהו יכתוב לך.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAppAction.shared.post(.showBigText)
        return .result()
    }
}

struct OzenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCaptionsIntent(),
            phrases: [
                "התחל כתוביות ב\(.applicationName)",
                "תתחיל כתוביות ב\(.applicationName)",
                "Start captions in \(.applicationName)",
            ],
            shortTitle: "התחלת כתוביות",
            systemImageName: "captions.bubble"
        )
        AppShortcut(
            intent: StopCaptionsIntent(),
            phrases: [
                "עצור כתוביות ב\(.applicationName)",
                "Stop captions in \(.applicationName)",
            ],
            shortTitle: "עצירת כתוביות",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: SpeakIntent(),
            phrases: [
                "תגיד ב\(.applicationName)",
                "Say with \(.applicationName)",
            ],
            shortTitle: "להגיד משהו",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: ShowBigTextIntent(),
            phrases: [
                "כתבו לי ב\(.applicationName)",
                "Big text in \(.applicationName)",
            ],
            shortTitle: "כתבו לי",
            systemImageName: "textformat.size.larger"
        )
    }
}

/// The mailbox between an intent's `perform` and the live screen. The
/// screen drains it when it appears and whenever the app becomes active,
/// which covers both "app was closed" and "app was in the background".
@MainActor
@Observable
final class PendingAppAction {
    static let shared = PendingAppAction()

    /// Every request not yet handed over, oldest first. A Shortcut can run
    /// two Ozen actions back to back ("stop captions", then "say I'm
    /// leaving") before the screen has had a chance to look; keeping only
    /// the newest would silently drop the first.
    private(set) var actions: [AppAction] = []
    /// Bumped on every post so an identical action twice in a row still
    /// triggers `onChange`.
    private(set) var serial = 0

    func post(_ action: AppAction) {
        actions.append(action)
        serial += 1
    }

    /// Hands over everything waiting, in the order it arrived, once.
    func takeAll() -> [AppAction] {
        defer { actions = [] }
        return actions
    }
}
