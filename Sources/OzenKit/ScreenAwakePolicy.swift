/// When the phone's screen must not lock by itself.
///
/// While listening it's the reader's choice (on by default: captions are
/// read, not glanced at). While the model is being prepared it isn't a
/// choice at all: a download of hundreds of megabytes only runs while the
/// app is on screen, and an auto-lock a minute in would quietly stall it
/// until someone opened the app again.
public enum ScreenAwakePolicy {
    public static func shouldKeepAwake(phase: PipelinePhase, keepAwakeWhileListening: Bool) -> Bool {
        if phase.isTransitioning { return true }
        return phase.isListening && keepAwakeWhileListening
    }
}
