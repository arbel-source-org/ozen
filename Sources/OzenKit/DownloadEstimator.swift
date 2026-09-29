import Foundation

public struct DownloadEstimator: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        let time: TimeInterval
        let fraction: Double
    }

    public static let windowSeconds: TimeInterval = 30
    public static let minimumSpanSeconds: TimeInterval = 5

    private var samples: [Sample] = []

    public init() {}

    public mutating func record(fraction: Double, at time: TimeInterval) {
        let fraction = min(max(fraction, 0), 1)
        if let last = samples.last, fraction < last.fraction - 0.01 {
            samples.removeAll()
        }
        if fraction > 0, samples.allSatisfy({ $0.fraction == 0 }) {
            samples.removeAll()
        }
        samples.append(Sample(time: time, fraction: fraction))
        while samples.count > 2, time - samples[0].time >= Self.windowSeconds {
            samples.removeFirst()
        }
    }

    public func secondsRemaining() -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        let progress = last.fraction - first.fraction
        guard span >= Self.minimumSpanSeconds, progress > 0 else { return nil }
        return (1 - last.fraction) / (progress / span)
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
