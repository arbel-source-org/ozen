import Foundation

/// How often something that keeps failing is set up again: at most `limit`
/// times in any `windowSeconds`.
///
/// A plain lifetime count gives up for good. The sound classifier used to
/// have one: five failures early in an evening, a rough patch while the
/// phone was busy, and doorbell and alarm alerts stayed off until the app
/// was restarted, with captions still running so nothing looked wrong.
/// Counting only recent attempts still stops a classifier that can't work
/// from being rebuilt for every chunk of audio, and tries again once the
/// bad patch has passed.
public struct RestartBudget: Sendable, Equatable {
    public let limit: Int
    public let windowSeconds: TimeInterval
    private var attempts: [TimeInterval] = []

    public init(limit: Int, windowSeconds: TimeInterval) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }

    /// Whether a restart may happen at `now` (seconds on any clock that
    /// only moves forward); when it may, it's counted.
    public mutating func spend(at now: TimeInterval) -> Bool {
        // An attempt "from the future" means the clock was reset; it
        // mustn't hold restarts back for however long that jump was.
        attempts.removeAll { now - $0 >= windowSeconds || $0 > now }
        guard attempts.count < limit else { return false }
        attempts.append(now)
        return true
    }
}
