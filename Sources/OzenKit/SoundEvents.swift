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
    public static var events: [SoundEvent] {
        [
            // Safety first. `civil_defense_siren` is the rocket-alert siren in
            // Israel, which is why it sits at the top.
            SoundEvent(identifier: "civil_defense_siren", name: tr("אזעקה", "Air raid siren"), importance: .critical, systemImage: "light.beacon.max.fill"),
            SoundEvent(identifier: "smoke_detector", name: tr("גלאי עשן", "Smoke detector"), importance: .critical, systemImage: "flame.fill"),
            SoundEvent(identifier: "fire", name: tr("אש", "Fire"), importance: .critical, systemImage: "flame"),
            SoundEvent(identifier: "siren", name: tr("סירנה", "Siren"), importance: .critical, systemImage: "light.beacon.max"),
            SoundEvent(identifier: "ambulance_siren", name: tr("סירנת אמבולנס", "Ambulance siren"), importance: .critical, systemImage: "cross.case.fill"),
            SoundEvent(identifier: "police_siren", name: tr("סירנת משטרה", "Police siren"), importance: .critical, systemImage: "shield.fill"),
            SoundEvent(identifier: "fire_engine_siren", name: tr("סירנת כבאית", "Fire engine siren"), importance: .critical, systemImage: "flame.circle.fill"),
            SoundEvent(identifier: "gunshot_gunfire", name: tr("ירי", "Gunfire"), importance: .critical, systemImage: "exclamationmark.triangle.fill"),
            SoundEvent(identifier: "artillery_fire", name: tr("פיצוץ", "Explosion"), importance: .critical, systemImage: "exclamationmark.triangle.fill"),
            SoundEvent(identifier: "glass_breaking", name: tr("זכוכית נשברת", "Glass breaking"), importance: .critical, systemImage: "exclamationmark.triangle"),
            SoundEvent(identifier: "screaming", name: tr("צרחה", "Scream"), importance: .critical, systemImage: "person.wave.2.fill"),
            SoundEvent(identifier: "car_horn", name: tr("צפירת רכב", "Car horn"), importance: .high, systemImage: "car.fill"),
            SoundEvent(identifier: "reverse_beeps", name: tr("רכב ברוורס", "Car reversing"), importance: .high, systemImage: "car"),
            SoundEvent(identifier: "shout", name: tr("צעקה", "Shout"), importance: .high, systemImage: "person.wave.2"),
            SoundEvent(identifier: "yell", name: tr("צעקה", "Yell"), importance: .high, systemImage: "person.wave.2"),
            SoundEvent(identifier: "children_shouting", name: tr("ילדים צועקים", "Children shouting"), importance: .high, systemImage: "figure.and.child.holdinghands"),
            SoundEvent(identifier: "crying_sobbing", name: tr("בכי", "Crying"), importance: .high, systemImage: "drop.fill"),
            SoundEvent(identifier: "baby_crying", name: tr("תינוק בוכה", "Baby crying"), importance: .high, systemImage: "figure.child"),
            SoundEvent(identifier: "door_bell", name: tr("פעמון דלת", "Doorbell"), importance: .high, systemImage: "bell.fill"),
            SoundEvent(identifier: "knock", name: tr("דפיקה בדלת", "Knock at the door"), importance: .high, systemImage: "hand.raised.fill"),
            SoundEvent(identifier: "telephone_bell_ringing", name: tr("טלפון מצלצל", "Phone ringing"), importance: .high, systemImage: "phone.fill"),
            SoundEvent(identifier: "ringtone", name: tr("טלפון מצלצל", "Ringtone"), importance: .high, systemImage: "phone.fill"),
            SoundEvent(identifier: "alarm_clock", name: tr("שעון מעורר", "Alarm clock"), importance: .high, systemImage: "alarm.fill"),
            SoundEvent(identifier: "dog_bark", name: tr("כלב נובח", "Dog barking"), importance: .high, systemImage: "dog.fill"),
            SoundEvent(identifier: "dog_growl", name: tr("כלב נוהם", "Dog growling"), importance: .high, systemImage: "dog"),
            // A kettle can rumble ("boiling") or whistle ("whistling") --
            // two different classifier labels for the same stove hazard, so
            // they share a name and, in `SoundEventPolicy`, a cooldown, the
            // same way "telephone_bell_ringing" and "ringtone" do above.
            // Left at `.medium` this was silenced under "Important and
            // above", the default a family is likely to pick.
            SoundEvent(identifier: "boiling", name: tr("מים רותחים", "Boiling water"), importance: .high, systemImage: "drop.triangle.fill"),
            SoundEvent(identifier: "whistling", name: tr("מים רותחים", "Kettle whistling"), importance: .high, systemImage: "drop.triangle.fill"),
            SoundEvent(identifier: "dog_howl", name: tr("כלב מיילל", "Dog howling"), importance: .medium, systemImage: "dog"),
            SoundEvent(identifier: "thunder", name: tr("רעם", "Thunder"), importance: .medium, systemImage: "cloud.bolt.fill"),
            SoundEvent(identifier: "thunderstorm", name: tr("סופת רעמים", "Thunderstorm"), importance: .medium, systemImage: "cloud.bolt.rain.fill"),
            SoundEvent(identifier: "fireworks", name: tr("זיקוקים", "Fireworks"), importance: .medium, systemImage: "sparkles"),
            SoundEvent(identifier: "firecracker", name: tr("נפצים", "Firecrackers"), importance: .medium, systemImage: "sparkles"),
            SoundEvent(identifier: "door", name: tr("דלת", "Door"), importance: .medium, systemImage: "door.left.hand.open"),
            SoundEvent(identifier: "door_slam", name: tr("טריקת דלת", "Door slamming"), importance: .medium, systemImage: "door.left.hand.closed"),
            SoundEvent(identifier: "telephone", name: tr("טלפון", "Phone"), importance: .medium, systemImage: "phone"),
            SoundEvent(identifier: "beep", name: tr("צפצוף", "Beep"), importance: .medium, systemImage: "waveform.path"),
            SoundEvent(identifier: "microwave_oven", name: tr("מיקרוגל", "Microwave"), importance: .medium, systemImage: "microwave.fill"),
            SoundEvent(identifier: "water_tap_faucet", name: tr("ברז פתוח", "Running tap"), importance: .medium, systemImage: "drop"),
            SoundEvent(identifier: "dog_whimper", name: tr("כלב מייבב", "Dog whimpering"), importance: .low, systemImage: "dog"),
            SoundEvent(identifier: "door_sliding", name: tr("דלת הזזה", "Sliding door"), importance: .low, systemImage: "door.sliding.left.hand.open"),
            SoundEvent(identifier: "toilet_flush", name: tr("הדחת אסלה", "Toilet flush"), importance: .low, systemImage: "toilet"),
            SoundEvent(identifier: "sink_filling_washing", name: tr("כיור", "Sink"), importance: .low, systemImage: "sink"),
            SoundEvent(identifier: "vacuum_cleaner", name: tr("שואב אבק", "Vacuum cleaner"), importance: .low, systemImage: "fan.fill"),
            SoundEvent(identifier: "cat_meow", name: tr("חתול מיילל", "Cat meowing"), importance: .low, systemImage: "cat.fill"),
            SoundEvent(identifier: "cat", name: tr("חתול", "Cat"), importance: .low, systemImage: "cat"),
            SoundEvent(identifier: "cough", name: tr("שיעול", "Cough"), importance: .low, systemImage: "lungs.fill"),
            SoundEvent(identifier: "sneeze", name: tr("עיטוש", "Sneeze"), importance: .low, systemImage: "wind"),
            SoundEvent(identifier: "laughter", name: tr("צחוק", "Laughter"), importance: .low, systemImage: "face.smiling"),
            SoundEvent(identifier: "applause", name: tr("מחיאות כפיים", "Applause"), importance: .low, systemImage: "hands.clap.fill"),
            SoundEvent(identifier: "music", name: tr("מוזיקה", "Music"), importance: .low, systemImage: "music.note"),
        ]
    }

    /// What the phone's own vibration on a hard surface can be heard as: a
    /// ring, a buzzer or alarm clock, a beep, a knock-like tap, an appliance
    /// hum. Never a safety sound, never the doorbell.
    public static let vibrationLookalikes: Set<String> = [
        "telephone_bell_ringing", "ringtone", "telephone", "alarm_clock",
        "beep", "knock", "microwave_oven", "vacuum_cleaner",
    ]

    public static func event(for identifier: String) -> SoundEvent? {
        events.first { $0.identifier == identifier }
    }

    public static var identifiers: Set<String> {
        Set(events.map(\.identifier))
    }

    /// Turns one classifier window's raw candidates into `SoundObservation`s,
    /// keeping every one this app tracks regardless of where it landed in
    /// the window's ranking. Apple's classifier reports ~300 labels; when
    /// family is talking or the TV is on, speech, music and chatter occupy
    /// the top of that ranking, and a doorbell or kettle heard at the same
    /// time can fall to rank four or lower. Filtering by catalog membership
    /// instead of by rank means it is still reported.
    public static func matchingObservations(
        from candidates: some Sequence<(identifier: String, confidence: Double)>,
        minimumConfidence: Double,
        timestamp: TimeInterval
    ) -> [SoundObservation] {
        let known = identifiers
        return candidates
            .filter { known.contains($0.identifier) && $0.confidence >= minimumConfidence }
            .map { SoundObservation(identifier: $0.identifier, confidence: $0.confidence, timestamp: timestamp) }
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

    /// Whether this alert's banner replaces the one on screen: a kettle
    /// heard during a smoke alarm doesn't take its banner away. It still
    /// buzzes and is read out.
    public func takesBanner(from shown: SoundAlert?) -> Bool {
        guard let shown else { return true }
        return event.importance >= shown.event.importance
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
    /// Sounds to alert on even when heard faintly -- set from a near-miss
    /// (`SoundNearMisses`) the reader noticed kept not alerting, e.g. a
    /// doorbell that's always heard around 45% against the usual 60% floor.
    public var sensitiveIdentifiers: Set<String>

    public init(
        isEnabled: Bool = true,
        minimumImportance: SoundEvent.Importance = .medium,
        mutedIdentifiers: Set<String> = [],
        sensitiveIdentifiers: Set<String> = []
    ) {
        self.isEnabled = isEnabled
        self.minimumImportance = minimumImportance
        self.mutedIdentifiers = mutedIdentifiers
        self.sensitiveIdentifiers = sensitiveIdentifiers
    }

    public static let `default` = SoundAlertPreferences()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, minimumImportance, mutedIdentifiers, sensitiveIdentifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SoundAlertPreferences.default
        isEnabled = container.lenient(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        minimumImportance = container.lenient(SoundEvent.Importance.self, forKey: .minimumImportance) ?? defaults.minimumImportance
        mutedIdentifiers = container.lenient(Set<String>.self, forKey: .mutedIdentifiers) ?? defaults.mutedIdentifiers
        sensitiveIdentifiers = container.lenient(Set<String>.self, forKey: .sensitiveIdentifiers) ?? defaults.sensitiveIdentifiers
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
    /// The floor for a sound in `preferences.sensitiveIdentifiers`. Kept
    /// well above pure noise but below `minimumConfidence`, trading more
    /// false alarms on that one sound against never hearing it at all.
    public var sensitiveConfidence: Double
    public var cooldownSeconds: TimeInterval
    /// Above this confidence, a continuous sound (`sustainedIdentifiers`)
    /// alerts on the very first window, the same as any other sound: an
    /// unmistakable siren or smoke alarm should never wait through a second
    /// ~0.75 s window to be confirmed.
    public var emergencyConfidence: Double
    /// How long a first, unconfirmed window of a continuous sound is
    /// remembered while waiting for a second one to confirm it wasn't a
    /// spike from the TV or kitchen clatter.
    public var persistenceWindowSeconds: TimeInterval
    private var lastAlertAt: [String: TimeInterval] = [:]
    private var pendingSince: [String: TimeInterval] = [:]

    /// Sounds that are continuous by nature — a siren, a running tap, an
    /// alarm that keeps sounding — as opposed to a one-shot sound like a
    /// knock or a gunshot, or one whose "continuous" sounding is really a
    /// train of separate beeps with silent gaps between them.
    /// `smoke_detector` is deliberately not here: its beep pattern (three
    /// short beeps, then several seconds of silence, repeating) can leave
    /// no two beeps inside the same short persistence window, so requiring
    /// a second confirming window could delay or even miss a real fire
    /// rather than just filter a TV spike. A single classifier window
    /// catching TV audio or kitchen clatter can briefly spike on one of the
    /// sounds below, which really do keep sounding continuously; every
    /// other identifier, including `smoke_detector`, alerts on its first
    /// window as before.
    static let sustainedIdentifiers: Set<String> = [
        "civil_defense_siren", "siren", "boiling", "whistling", "water_tap_faucet",
    ]

    public init(
        preferences: SoundAlertPreferences = .default,
        minimumConfidence: Double = 0.6,
        sensitiveConfidence: Double = 0.4,
        cooldownSeconds: TimeInterval = 20,
        emergencyConfidence: Double = 0.85,
        persistenceWindowSeconds: TimeInterval = 2.0
    ) {
        self.preferences = preferences
        self.minimumConfidence = minimumConfidence
        self.sensitiveConfidence = sensitiveConfidence
        self.cooldownSeconds = cooldownSeconds
        self.emergencyConfidence = emergencyConfidence
        self.persistenceWindowSeconds = persistenceWindowSeconds
    }

    /// The confidence `identifier` needs to raise an alert right now. Never
    /// stricter than `minimumConfidence`, even if a future setting ever
    /// lowered it below the default `sensitiveConfidence`.
    public func requiredConfidence(for identifier: String) -> Double {
        preferences.sensitiveIdentifiers.contains(identifier)
            ? min(sensitiveConfidence, minimumConfidence)
            : minimumConfidence
    }

    /// The alert to show for this reading, or nil.
    public mutating func evaluate(_ observation: SoundObservation) -> SoundAlert? {
        guard preferences.isEnabled else { return nil }
        guard observation.confidence >= requiredConfidence(for: observation.identifier) else { return nil }
        guard let event = SoundEventCatalog.event(for: observation.identifier) else { return nil }
        guard event.importance >= preferences.minimumImportance else { return nil }
        guard !preferences.mutedIdentifiers.contains(event.identifier) else { return nil }
        // A continuous sound needs a second confirming window within
        // `persistenceWindowSeconds`, unless it's already confident enough
        // to be sure on its own: a real siren or a kettle at a rolling boil
        // keeps sounding, so waiting under a second for the next window
        // costs nothing, while a single TV or clatter spike never gets a
        // second confirmation and never raises the banner.
        if Self.sustainedIdentifiers.contains(event.identifier), observation.confidence < emergencyConfidence {
            guard let pendingAt = pendingSince[event.identifier],
                  observation.timestamp >= pendingAt,
                  observation.timestamp - pendingAt <= persistenceWindowSeconds
            else {
                pendingSince[event.identifier] = observation.timestamp
                return nil
            }
            pendingSince[event.identifier] = nil
        }
        // Keyed by name, not identifier: two classifier labels the catalog
        // shows as the very same sound ("telephone_bell_ringing" and
        // "ringtone" both read "Phone ringing") must share one cooldown,
        // or a ring the classifier flips between the two labels on
        // defeats the cooldown entirely — two banners and two buzzes for
        // what the user heard as one ring.
        // Wall-clock time can go backward (daylight saving ending, an NTP
        // sync); `>= last` keeps a jump from holding back a new siren for
        // as long as the jump, as in `BackgroundAlertPolicy`.
        if let last = lastAlertAt[event.name], observation.timestamp >= last, observation.timestamp - last < cooldownSeconds {
            return nil
        }
        lastAlertAt[event.name] = observation.timestamp
        return SoundAlert(event: event, confidence: observation.confidence, timestamp: observation.timestamp)
    }

    public mutating func resetCooldowns() {
        lastAlertAt = [:]
        pendingSince = [:]
    }
}
