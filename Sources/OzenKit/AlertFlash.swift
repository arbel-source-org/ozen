import Foundation

public struct AlertFlash: Sendable, Equatable {
    public let litSeconds: Double
    public let darkSeconds: Double
    public let count: Int

    public static let maximumFlashesPerSecond: Double = 3

    public var flashesPerSecond: Double {
        1 / (litSeconds + darkSeconds)
    }

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

    public static func takesOver(from flashing: SoundEvent.Importance?, with arriving: SoundEvent.Importance, reduceMotion: Bool) -> Bool {
        guard pattern(for: arriving, reduceMotion: reduceMotion) != nil else { return false }
        guard let flashing else { return true }
        return arriving >= flashing
    }
}
