import Foundation

/// How loud the microphone's audio has been, chunk by chunk, as a
/// histogram of levels in decibels below full scale.
///
/// Whether speech clears the voice detector's thresholds depends on how
/// loud it arrives, and that depends on the phone, the microphone, and
/// how far away people sit: nothing a test here can know. The quiet,
/// middle and loud ends of this histogram in the diagnostics report say
/// what a real table sounds like to the app.
public struct AudioLevelHistogram: Sendable, Equatable {
    /// Levels are counted in 2 dB steps from -100 dBFS to 0 dBFS; anything
    /// quieter lands in the lowest step, anything louder in the highest.
    public static let lowestDecibels = -100
    public static let stepDecibels = 2
    static let stepCount = 50

    private var counts = [Int](repeating: 0, count: AudioLevelHistogram.stepCount)
    public private(set) var total = 0

    public init() {}

    public mutating func add(rms: Float) {
        let decibels = rms > 0 ? 20 * log10(Double(rms)) : -.infinity
        let step = decibels.isFinite
            ? Int(((decibels - Double(Self.lowestDecibels)) / Double(Self.stepDecibels)).rounded(.down))
            : 0
        counts[min(max(step, 0), Self.stepCount - 1)] += 1
        total += 1
    }

    /// The level at or below which `fraction` of the chunks were, as the
    /// top of its 2 dB step; nil before any audio.
    public func decibels(atFraction fraction: Double) -> Int? {
        guard total > 0 else { return nil }
        let wanted = max(1, Int((min(max(fraction, 0), 1) * Double(total)).rounded(.up)))
        var seen = 0
        for (step, count) in counts.enumerated() {
            seen += count
            if seen >= wanted {
                return Self.lowestDecibels + (step + 1) * Self.stepDecibels
            }
        }
        return 0
    }

    /// "quiet -72 / middle -58 / loud -44 dBFS": the 10th, 50th and 90th
    /// percentiles, for the report.
    public var summary: String? {
        guard let quiet = decibels(atFraction: 0.1),
              let middle = decibels(atFraction: 0.5),
              let loud = decibels(atFraction: 0.9)
        else { return nil }
        return "quiet \(quiet) / middle \(middle) / loud \(loud) dBFS"
    }
}
