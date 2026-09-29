import Foundation

public struct RestartBudget: Sendable, Equatable {
    public let limit: Int
    public let windowSeconds: TimeInterval
    public let minimumSpacingSeconds: TimeInterval
    private var attempts: [TimeInterval] = []

    public init(limit: Int, windowSeconds: TimeInterval, minimumSpacingSeconds: TimeInterval = 0) {
        self.limit = limit
        self.windowSeconds = windowSeconds
        self.minimumSpacingSeconds = minimumSpacingSeconds
    }

    public mutating func spend(at now: TimeInterval) -> Bool {
        attempts.removeAll { now - $0 >= windowSeconds || $0 > now }
        guard attempts.count < limit else { return false }
        if let last = attempts.last, now - last < minimumSpacingSeconds { return false }
        attempts.append(now)
        return true
    }
}
