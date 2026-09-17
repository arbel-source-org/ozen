import Foundation

/// How hot the phone is, in the four steps iOS reports
/// (`ProcessInfo.ThermalState`), without importing anything Apple-only.
public enum DeviceHeat: Int, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public static func < (lhs: DeviceHeat, rhs: DeviceHeat) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How often Whisper re-reads the sentence still being spoken.
///
/// Every live pass re-decodes the whole utterance so far, so over a long
/// dinner the model runs thousands of times. A phone that gets hot slows
/// its own chips down, and then each pass takes longer and the captions
/// fall further behind: running flat out makes things worse. So the
/// in-progress text refreshes less often when the phone is hot or in Low
/// Power Mode, and never more often than the last pass took. The final,
/// careful pass at the end of each sentence is never skipped; only the
/// live preview slows down.
public enum InferenceCadence {
    public static let baseSeconds = 0.6

    public static func secondsBetweenLivePasses(
        heat: DeviceHeat,
        lowPowerMode: Bool,
        lastPassSeconds: Double?
    ) -> Double {
        var interval: Double
        switch heat {
        case .nominal, .fair: interval = baseSeconds
        case .serious: interval = 1.5
        case .critical: interval = 4.0
        }
        if lowPowerMode {
            interval = max(interval, 1.2)
        }
        // Give the chip at least as long to rest as it just worked, so a
        // struggling phone settles at half duty instead of running hot.
        // The caller (WhisperKitEngine.runStreaming) measures `interval`
        // from the start of one pass to the start of the next, and audio
        // keeps arriving in real time while a pass runs — so by the time a
        // lastPassSeconds-long pass finishes, that much new audio has
        // already piled up. Only doubling it leaves an actual rest after
        // the pass ends instead of firing the next one back to back.
        if let lastPassSeconds, lastPassSeconds.isFinite, lastPassSeconds > 0 {
            interval = max(interval, lastPassSeconds * 2)
        }
        return interval
    }
}
