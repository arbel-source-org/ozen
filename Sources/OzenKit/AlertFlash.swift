import Foundation

/// How the screen flashes when a sound alert arrives.
///
/// The banner sits at the top of the screen, which is easy to miss with
/// the phone on the table and her eyes on the person talking. A flash of
/// the whole screen edge is caught from the corner of the eye. Safety
/// sounds (a siren, a smoke alarm) flash for a few seconds; the door and a
/// crying baby flash twice; everything else stays a quiet banner.
public struct AlertFlash: Sendable, Equatable {
    /// Seconds each flash stays lit.
    public let litSeconds: Double
    /// Seconds of dark after each flash.
    public let darkSeconds: Double
    public let count: Int

    /// Flashing faster than three times a second can set off a seizure
    /// (WCAG 2.3.1). Every pattern here stays well under it.
    public static let maximumFlashesPerSecond: Double = 3

    public var flashesPerSecond: Double {
        1 / (litSeconds + darkSeconds)
    }

    /// The flash for an alert, or nil when it shouldn't flash. With Reduce
    /// Motion on, the edge lights once and stays lit instead of blinking.
    public static func pattern(for importance: SoundEvent.Importance, reduceMotion: Bool) -> AlertFlash? {
        switch importance {
        case .critical:
            return reduceMotion
                ? AlertFlash(litSeconds: 4, darkSeconds: 0, count: 1)
                : AlertFlash(litSeconds: 0.4, darkSeconds: 0.4, count: 6)
        case .high:
            return reduceMotion
                ? AlertFlash(litSeconds: 1.5, darkSeconds: 0, count: 1)
                : AlertFlash(litSeconds: 0.4, darkSeconds: 0.4, count: 2)
        case .medium, .low:
            return nil
        }
    }
}
