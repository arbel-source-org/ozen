import Foundation

/// Whether the app should stop the phone from locking.
public enum ScreenAwakePolicy {
    /// With nothing said for this long, the phone locks as it normally
    /// would. Left listening on a nightstand, the screen used to stay lit
    /// all night: a flat battery by morning and text burned into the
    /// screen. Captions (and doorbell and alarm alerts) keep running after
    /// the phone locks; only the screen goes dark.
    public static let quietLockSeconds: TimeInterval = 15 * 60

    /// `lastActivityAt` is when captions last changed or listening began,
    /// whichever is later; nil means unknown, which keeps the old rule.
    public static func shouldKeepAwake(
        phase: PipelinePhase,
        keepAwakeWhileListening: Bool,
        lastActivityAt: TimeInterval? = nil,
        now: TimeInterval = 0
    ) -> Bool {
        // A first-launch model download stalls if the phone locks (the
        // download is suspended with the app), so preparing always keeps
        // the screen on.
        if phase.isTransitioning { return true }
        guard phase.isListening && keepAwakeWhileListening else { return false }
        guard let lastActivityAt else { return true }
        return now - lastActivityAt < quietLockSeconds
    }
}
