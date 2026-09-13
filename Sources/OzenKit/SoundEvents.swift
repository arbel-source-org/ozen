import Foundation

/// A household or safety sound the app can recognise and flash on screen.
/// For someone who can't hear the doorbell, the kettle, or — in Israel —
/// the civil-defence siren, this is arguably as important as the captions.
/// `identifier` is the label string of Apple's built-in sound classifier
/// (`SNClassifierIdentifier.version1`); Apple publishes no static list, so
/// these come from a runtime dump cross-checked three ways, and the
/// platform layer additionally verifies each one against
/// `knownClassifications` on the device before enabling it.
public struct SoundEvent: Sendable, Equatable, Identifiable, Hashable {
    public enum Importance: Int, Sendable, Codable, Comparable, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2
        case critical = 3

        public static func < (lhs: Importance, rhs: Importance) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let identifier: String
    /// Hebrew label as shown on the banner and in Settings.
    public let name: String
    public let importance: Importance
    public let systemImage: String

    public var id: String { identifier }

    public init(identifier: String, name: String, importance: Importance, systemImage: String) {
        self.identifier = identifier
        self.name = name
        self.importance = importance
        self.systemImage = systemImage
    }
}

/// The curated subset of the classifier's ~300 labels that matter to a
/// hard-of-hearing person at home. Speech-like labels are deliberately
/// absent: speech is what the captions are for.
public enum SoundEventCatalog {
    public static let events: [SoundEvent] = [
        // Safety first. `civil_defense_siren` is the rocket-alert siren in
        // Israel, which is why it sits at the top.
        SoundEvent(identifier: "civil_defense_siren", name: "אזעקה", importance: .critical, systemImage: "light.beacon.max.fill"),
        SoundEvent(identifier: "smoke_detector", name: "גלאי עשן", importance: .critical, systemImage: "flame.fill"),
        SoundEvent(identifier: "fire", name: "אש", importance: .critical, systemImage: "flame"),
        SoundEvent(identifier: "siren", name: "סירנה", importance: .critical, systemImage: "light.beacon.max"),
        SoundEvent(identifier: "ambulance_siren", name: "סירנת אמבולנס", importance: .critical, systemImage: "cross.case.fill"),
        SoundEvent(identifier: "police_siren", name: "סירנת משטרה", importance: .critical, systemImage: "shield.fill"),
        SoundEvent(identifier: "fire_engine_siren", name: "סירנת כבאית", importance: .critical, systemImage: "flame.circle.fill"),
        SoundEvent(identifier: "gunshot_gunfire", name: "ירי", importance: .critical, systemImage: "exclamationmark.triangle.fill"),
        SoundEvent(identifier: "artillery_fire", name: "פיצוץ", importance: .critical, systemImage: "exclamationmark.triangle.fill"),
        SoundEvent(identifier: "glass_breaking", name: "זכוכית נשברת", importance: .critical, systemImage: "exclamationmark.triangle"),
        SoundEvent(identifier: "screaming", name: "צרחה", importance: .critical, systemImage: "person.wave.2.fill"),
        SoundEvent(identifier: "car_horn", name: "צפירת רכב", importance: .high, systemImage: "car.fill"),
        SoundEvent(identifier: "reverse_beeps", name: "רכב ברוורס", importance: .high, systemImage: "car"),
        SoundEvent(identifier: "shout", name: "צעקה", importance: .high, systemImage: "person.wave.2"),
        SoundEvent(identifier: "yell", name: "צעקה", importance: .high, systemImage: "person.wave.2"),
        SoundEvent(identifier: "children_shouting", name: "ילדים צועקים", importance: .high, systemImage: "figure.and.child.holdinghands"),
        SoundEvent(identifier: "crying_sobbing", name: "בכי", importance: .high, systemImage: "drop.fill"),
        SoundEvent(identifier: "baby_crying", name: "תינוק בוכה", importance: .high, systemImage: "figure.child"),
        SoundEvent(identifier: "door_bell", name: "פעמון דלת", importance: .high, systemImage: "bell.fill"),
        SoundEvent(identifier: "knock", name: "דפיקה בדלת", importance: .high, systemImage: "hand.raised.fill"),
        SoundEvent(identifier: "telephone_bell_ringing", name: "טלפון מצלצל", importance: .high, systemImage: "phone.fill"),
        SoundEvent(identifier: "ringtone", name: "טלפון מצלצל", importance: .high, systemImage: "phone.fill"),
        SoundEvent(identifier: "alarm_clock", name: "שעון מעורר", importance: .high, systemImage: "alarm.fill"),
        SoundEvent(identifier: "dog_bark", name: "כלב נובח", importance: .high, systemImage: "dog.fill"),
        SoundEvent(identifier: "dog_growl", name: "כלב נוהם", importance: .high, systemImage: "dog"),
        SoundEvent(identifier: "dog_howl", name: "כלב מיילל", importance: .medium, systemImage: "dog"),
        SoundEvent(identifier: "thunder", name: "רעם", importance: .medium, systemImage: "cloud.bolt.fill"),
        SoundEvent(identifier: "thunderstorm", name: "סופת רעמים", importance: .medium, systemImage: "cloud.bolt.rain.fill"),
        SoundEvent(identifier: "fireworks", name: "זיקוקים", importance: .medium, systemImage: "sparkles"),
        SoundEvent(identifier: "firecracker", name: "נפצים", importance: .medium, systemImage: "sparkles"),
        SoundEvent(identifier: "door", name: "דלת", importance: .medium, systemImage: "door.left.hand.open"),
        SoundEvent(identifier: "door_slam", name: "טריקת דלת", importance: .medium, systemImage: "door.left.hand.closed"),
        SoundEvent(identifier: "telephone", name: "טלפון", importance: .medium, systemImage: "phone"),
        SoundEvent(identifier: "beep", name: "צפצוף", importance: .medium, systemImage: "waveform.path"),
        SoundEvent(identifier: "microwave_oven", name: "מיקרוגל", importance: .medium, systemImage: "microwave.fill"),
        SoundEvent(identifier: "boiling", name: "מים רותחים", importance: .medium, systemImage: "drop.triangle.fill"),
        SoundEvent(identifier: "water_tap_faucet", name: "ברז פתוח", importance: .medium, systemImage: "drop"),
        SoundEvent(identifier: "dog_whimper", name: "כלב מייבב", importance: .low, systemImage: "dog"),
        SoundEvent(identifier: "door_sliding", name: "דלת הזזה", importance: .low, systemImage: "door.sliding.left.hand.open"),
        SoundEvent(identifier: "toilet_flush", name: "הדחת אסלה", importance: .low, systemImage: "toilet"),
        SoundEvent(identifier: "sink_filling_washing", name: "כיור", importance: .low, systemImage: "sink"),
        SoundEvent(identifier: "vacuum_cleaner", name: "שואב אבק", importance: .low, systemImage: "fan.fill"),
        SoundEvent(identifier: "cat_meow", name: "חתול מיילל", importance: .low, systemImage: "cat.fill"),
        SoundEvent(identifier: "cat", name: "חתול", importance: .low, systemImage: "cat"),
        SoundEvent(identifier: "cough", name: "שיעול", importance: .low, systemImage: "lungs.fill"),
        SoundEvent(identifier: "sneeze", name: "עיטוש", importance: .low, systemImage: "wind"),
        SoundEvent(identifier: "laughter", name: "צחוק", importance: .low, systemImage: "face.smiling"),
        SoundEvent(identifier: "applause", name: "מחיאות כפיים", importance: .low, systemImage: "hands.clap.fill"),
        SoundEvent(identifier: "music", name: "מוזיקה", importance: .low, systemImage: "music.note"),
    ]

    public static func event(for identifier: String) -> SoundEvent? {
        events.first { $0.identifier == identifier }
    }

    public static var identifiers: Set<String> {
        Set(events.map(\.identifier))
    }
}

/// One classifier reading: "this window sounds like X with confidence c".
public struct SoundObservation: Sendable, Equatable {
    public let identifier: String
    public let confidence: Double
    public let timestamp: TimeInterval

    public init(identifier: String, confidence: Double, timestamp: TimeInterval) {
        self.identifier = identifier
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// An alert that made it through `SoundEventPolicy` and should be shown.
public struct SoundAlert: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let event: SoundEvent
    public let confidence: Double
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), event: SoundEvent, confidence: Double, timestamp: TimeInterval) {
        self.id = id
        self.event = event
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// A source of sound classifications. The real one (`SoundAnalysisDetector`
/// in OzenPlatform) wraps Apple's SoundAnalysis framework; tests use a
/// scripted fake.
public protocol SoundEventDetecting: Sendable {
    func observations(audio: AsyncStream<[Float]>) -> AsyncStream<SoundObservation>
}

/// The user's choices about sound alerts, persisted in `AppSettings`.
public struct SoundAlertPreferences: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var minimumImportance: SoundEvent.Importance
    public var mutedIdentifiers: Set<String>

    public init(isEnabled: Bool = true, minimumImportance: SoundEvent.Importance = .medium, mutedIdentifiers: Set<String> = []) {
        self.isEnabled = isEnabled
        self.minimumImportance = minimumImportance
        self.mutedIdentifiers = mutedIdentifiers
    }

    public static let `default` = SoundAlertPreferences()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, minimumImportance, mutedIdentifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SoundAlertPreferences.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        minimumImportance = try container.decodeIfPresent(SoundEvent.Importance.self, forKey: .minimumImportance) ?? defaults.minimumImportance
        mutedIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .mutedIdentifiers) ?? defaults.mutedIdentifiers
    }
}

/// Decides which classifier readings become alerts. The classifier fires
/// on every ~0.75 s window, so without a per-sound cooldown a ringing
/// phone would produce a new banner every window for as long as it rings;
/// and a reading below the confidence floor, an unlisted label, a muted
/// sound, or one below the importance the user asked for is dropped.
public struct SoundEventPolicy: Sendable, Equatable {
    public var preferences: SoundAlertPreferences
    public var minimumConfidence: Double
    public var cooldownSeconds: TimeInterval
    private var lastAlertAt: [String: TimeInterval] = [:]

    public init(
        preferences: SoundAlertPreferences = .default,
        minimumConfidence: Double = 0.6,
        cooldownSeconds: TimeInterval = 20
    ) {
        self.preferences = preferences
        self.minimumConfidence = minimumConfidence
        self.cooldownSeconds = cooldownSeconds
    }

    /// The alert to show for this reading, or nil.
    public mutating func evaluate(_ observation: SoundObservation) -> SoundAlert? {
        guard preferences.isEnabled else { return nil }
        guard observation.confidence >= minimumConfidence else { return nil }
        guard let event = SoundEventCatalog.event(for: observation.identifier) else { return nil }
        guard event.importance >= preferences.minimumImportance else { return nil }
        guard !preferences.mutedIdentifiers.contains(event.identifier) else { return nil }
        if let last = lastAlertAt[event.identifier], observation.timestamp - last < cooldownSeconds {
            return nil
        }
        lastAlertAt[event.identifier] = observation.timestamp
        return SoundAlert(event: event, confidence: observation.confidence, timestamp: observation.timestamp)
    }

    public mutating func resetCooldowns() {
        lastAlertAt = [:]
    }
}
