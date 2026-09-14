import Testing
@testable import OzenKit

@Suite("AlertVibration")
struct AlertVibrationTests {
    private let kinds: [AlertVibration] = SoundEvent.Importance.allCases.map(AlertVibration.pattern(for:)) + [AlertVibration.keyword, AlertVibration.speechResumed]

    @Test("a siren, the door, anything else, her name and someone starting to talk each feel different")
    func eachKindFeelsDifferent() {
        let distinct = [
            AlertVibration.pattern(for: .critical),
            AlertVibration.pattern(for: .high),
            AlertVibration.pattern(for: .medium),
            AlertVibration.keyword,
            AlertVibration.speechResumed,
        ]
        for (index, pattern) in distinct.enumerated() {
            for other in distinct[(index + 1)...] {
                #expect(pattern != other)
                // Told apart by feel: a different number of pulses, or a
                // buzz against taps.
                let differsInCount = pattern.pulses.count != other.pulses.count
                let differsInKind = pattern.pulses.contains { $0.duration > 0 } != other.pulses.contains { $0.duration > 0 }
                #expect(differsInCount || differsInKind)
            }
        }
    }

    @Test("a more important sound never vibrates for less time or with fewer pulses")
    func moreImportantIsNeverLess() {
        let ordered = SoundEvent.Importance.allCases.sorted().map(AlertVibration.pattern(for:))
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(higher.totalSeconds >= lower.totalSeconds)
            #expect(higher.pulses.count >= lower.pulses.count)
        }
    }

    @Test("someone starting to talk is gentler than any alert")
    func speechResumedIsGentlest() {
        let strongest = AlertVibration.speechResumed.pulses.map(\.intensity).max() ?? 0
        let alerts = SoundEvent.Importance.allCases.map(AlertVibration.pattern(for:)) + [AlertVibration.keyword]
        for alert in alerts {
            #expect(strongest < alert.pulses.map(\.intensity).min() ?? 0)
        }
    }

    @Test("a safety sound buzzes for a few seconds, then stops")
    func criticalLastsSeconds() {
        let critical = AlertVibration.pattern(for: .critical)
        #expect(critical.totalSeconds >= 2)
        #expect(critical.totalSeconds <= 4)
        #expect(critical.pulses.allSatisfy { $0.duration >= 0.3 })
    }

    @Test("every pattern has pulses in order that don't overlap, at strengths the hardware accepts")
    func wellFormed() {
        for pattern in kinds {
            #expect(!pattern.pulses.isEmpty)
            for (earlier, later) in zip(pattern.pulses, pattern.pulses.dropFirst()) {
                // Taps closer than a tenth of a second blur into one.
                #expect(later.start >= earlier.end + 0.1)
            }
            #expect(pattern.pulses.allSatisfy { (0...1).contains($0.intensity) && (0...1).contains($0.sharpness) && $0.start >= 0 })
        }
    }
}
