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

    /// The vibration for a sound alert.
    public static func pattern(for importance: SoundEvent.Importance) -> AlertVibration {
        switch importance {
        case .critical:
            // Four long buzzes over three seconds.
            return AlertVibration(pulses: stride(from: 0.0, to: 3.0, by: 0.8).map {
                Pulse(start: $0, duration: 0.5, intensity: 1, sharpness: 0.7)
            })
        case .high:
            // Knock-knock, knock-knock.
            return AlertVibration(pulses: [0, 0.18, 0.7, 0.88].map {
                Pulse(start: $0, duration: 0, intensity: 1, sharpness: 0.9)
            })
        case .medium, .low:
            return AlertVibration(pulses: [Pulse(start: 0, duration: 0, intensity: 0.8, sharpness: 0.6)])
        }
    }

    /// The vibration for a word from her keyword list.
    public static let keyword = AlertVibration(pulses: [0, 0.14, 0.28].map {
        Pulse(start: $0, duration: 0, intensity: 0.9, sharpness: 0.4)
    })
}
