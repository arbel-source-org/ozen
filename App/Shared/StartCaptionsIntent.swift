import AppIntents
import Foundation

/// "Hey Siri, start captions in Ozen", and the Control Center and lock
/// screen button that does the same (`StartCaptionsControl`).
///
/// Compiled into the widget extension as well, because a control names the
/// intent it runs; since it opens the app, iOS performs it in the app's
/// process, which is the only place the note to the live screen means
/// anything.
struct StartCaptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "התחלת כתוביות"
    static let description = IntentDescription("פותח את אוזן ומתחיל להציג כתוביות לשיחה.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !OZEN_WIDGET_EXTENSION
        PendingAppAction.shared.post(.startCaptions)
        #endif
        return .result()
    }
}
