import Foundation

/// How the phone vibrates for an alert while the app is open.
///
/// One short system tap for every alert made a smoke alarm feel exactly
/// like a knock, and a single tap is easy to miss with the phone in a
/// pocket. Each kind here can be told apart by feel alone, without looking:
/// safety sounds buzz long and hard for a few seconds, the door and a
/// crying baby knock twice, anything else taps once, and her name (or
/// another word she asked for) is three quick taps, like a hand on the
/// shoulder.
public struct AlertVibration: Sendable, Equatable {
    public struct Pulse: Sendable, Equatable {
        /// Seconds from the start of the pattern.
        public let start: Double
        /// Seconds the buzz lasts; zero is a single sharp tap.
        public let duration: Double
        /// 0...1.
        public let intensity: Float
        /// 0...1: how crisp the pulse feels, from a dull rumble to a click.
        public let sharpness: Float

        public init(start: Double, duration: Double, intensity: Float, sharpness: Float) {
            self.start = start
            self.duration = duration
            self.intensity = intensity
            self.sharpness = sharpness
        }

        public var end: Double { start + duration }
    }

    public let pulses: [Pulse]

    public init(pulses: [Pulse]) {
        self.pulses = pulses
    }

    public var totalSeconds: Double { pulses.map(\.end).max() ?? 0 }

    /// The vibration for a sound alert. Every pulse is a real buzz at full
    /// strength, not an instantaneous click: a click, even at full intensity,
    /// is a moment long and easy to miss in a pocket or on a table.
    public static func pattern(for importance: SoundEvent.Importance) -> AlertVibration {
        switch importance {
        case .critical:
            // Five long hard buzzes, back to back, for three and a half seconds.
            return AlertVibration(pulses: stride(from: 0.0, to: 3.5, by: 0.75).map {
                Pulse(start: $0, duration: 0.6, intensity: 1, sharpness: 0.8)
            })
        case .high:
            // Knock-knock, knock-knock.
            return AlertVibration(pulses: [0, 0.3, 1.0, 1.3].map {
                Pulse(start: $0, duration: 0.16, intensity: 1, sharpness: 1)
            })
        case .medium, .low:
            // Two firm buzzes.
            return AlertVibration(pulses: [0, 0.32].map {
                Pulse(start: $0, duration: 0.2, intensity: 1, sharpness: 0.8)
            })
        }
    }

    /// The vibration for a word from her keyword list: three quick, hard
    /// taps, like a hand on the shoulder.
    public static let keyword = AlertVibration(pulses: [0, 0.24, 0.48].map {
        Pulse(start: $0, duration: 0.13, intensity: 1, sharpness: 0.6)
    })

    /// Someone started talking after a long quiet (an optional setting): one
    /// short hum, gentler than any alert and unlike their taps.
    public static let speechResumed = AlertVibration(pulses: [
        Pulse(start: 0, duration: 0.3, intensity: 0.7, sharpness: 0.2),
    ])
}
