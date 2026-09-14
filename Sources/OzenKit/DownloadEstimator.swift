import Foundation

/// How long a download has left, from its progress so far.
///
/// The first speech model is hundreds of megabytes, and "37%" doesn't say
/// whether to wait by the phone or make tea. The rate is taken over the
/// last half minute rather than since the start, so a download that sped
/// up on better Wi-Fi (or slowed down) is estimated as it is going now.
public struct DownloadEstimator: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        let time: TimeInterval
        let fraction: Double
    }

    /// Progress older than this doesn't count towards the rate.
    public static let windowSeconds: TimeInterval = 30
    /// No estimate until progress has been watched this long: the first
    /// seconds of a download say little about the rest.
    public static let minimumSpanSeconds: TimeInterval = 5

    private var samples: [Sample] = []

    public init() {}

    public mutating func record(fraction: Double, at time: TimeInterval) {
        let fraction = min(max(fraction, 0), 1)
        // Went backwards: the download started over.
        if let last = samples.last, fraction < last.fraction - 0.01 {
            samples.removeAll()
        }
        samples.append(Sample(time: time, fraction: fraction))
        // Keep one sample from before the window so the span stays full.
        while samples.count > 2, time - samples[1].time >= Self.windowSeconds {
            samples.removeFirst()
        }
    }

    /// Seconds left at the current pace, or nil while there isn't enough
    /// to go on (too soon, or no progress in the window).
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
