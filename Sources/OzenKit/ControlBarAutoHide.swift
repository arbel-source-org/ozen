import Foundation

public enum ControlBarAutoHide {
    public static let idleSeconds: TimeInterval = 5

    public static func hides(
        enabled: Bool,
        isListening: Bool,
        followingLatest: Bool,
        hasLines: Bool,
        voiceOverRunning: Bool,
        pausedForCall: Bool = false,
        lastTouchAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard enabled, isListening, followingLatest, hasLines, !voiceOverRunning, !pausedForCall else { return false }
        return now - lastTouchAt >= idleSeconds
    }
}
