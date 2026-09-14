import CoreHaptics
import UIKit
import OzenKit

/// Plays an `AlertVibration` on the phone's haptic engine.
///
/// No engine callbacks are used: Core Haptics calls them on its own
/// threads, and a closure made on the main actor would trap there. Instead
/// a play that fails on a stopped or reset engine is tried once more on a
/// fresh one, and after that the phone at least gives its standard warning
/// buzz.
@MainActor
final class AlertHapticPlayer {
    static let shared = AlertHapticPlayer()

    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func play(_ vibration: AlertVibration) {
        guard supportsHaptics else { return }
        do {
            try start(vibration)
        } catch {
            engine = nil
            do {
                try start(vibration)
            } catch {
                engine = nil
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func start(_ vibration: AlertVibration) throws {
        let engine = try runningEngine()
        let pattern = try CHHapticPattern(events: vibration.pulses.map(Self.event), parameters: [])
        try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }

    private func runningEngine() throws -> CHHapticEngine {
        if let engine {
            // Shuts itself down when idle; starting again is cheap.
            try engine.start()
            return engine
        }
        let engine = try CHHapticEngine()
        // Vibration only, set before the first start: the microphone's
        // audio session is left alone.
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        try engine.start()
        self.engine = engine
        return engine
    }

    private static func event(_ pulse: AlertVibration.Pulse) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
        ]
        if pulse.duration > 0 {
            return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: pulse.start, duration: pulse.duration)
        }
        return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: pulse.start)
    }
}
