import Foundation

/// A daily window during which alerts stay quiet: her name said again, a
/// keyword, an ordinary sound don't buzz or send a notification. Sounds
/// most likely to matter even asleep — a siren, smoke, anything marked
/// `.critical` — always get through regardless.
///
/// Off by default: nothing about the app is quieter unless she chose it.
public struct QuietHours: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    /// The hour (0...23) it starts and ends, in local time. Wraps past
    /// midnight when `endHour <= startHour` ("22 to 7" is 22:00 tonight
    /// through 07:00 tomorrow); an equal start and end covers the whole day.
    public var startHour: Int
    public var endHour: Int

    public init(isEnabled: Bool = false, startHour: Int = 22, endHour: Int = 7) {
        self.isEnabled = isEnabled
        self.startHour = Self.clamped(startHour)
        self.endHour = Self.clamped(endHour)
    }

    public static let `default` = QuietHours()

    /// Whether `now` falls inside the window, in the timezone
    /// `utcOffsetSeconds` describes.
    public func isQuiet(now: TimeInterval, utcOffsetSeconds: Int) -> Bool {
        guard isEnabled else { return false }
        let localSeconds = Int(now.rounded(.down)) + utcOffsetSeconds
        let secondsIntoDay = ((localSeconds % 86_400) + 86_400) % 86_400
        let hour = secondsIntoDay / 3_600
        guard startHour != endHour else { return true }
        return startHour < endHour
            ? hour >= startHour && hour < endHour
            : hour >= startHour || hour < endHour
    }

    private static func clamped(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, startHour, endHour
    }

    /// A settings file from before this existed has none of these keys;
    /// that must read as off, the same as a freshly created settings file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuietHours.default
        isEnabled = container.lenient(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        startHour = Self.clamped(container.lenient(Int.self, forKey: .startHour) ?? defaults.startHour)
        endHour = Self.clamped(container.lenient(Int.self, forKey: .endHour) ?? defaults.endHour)
    }
}
