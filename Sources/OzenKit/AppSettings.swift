import Foundation

/// One person's saved voice profile: a reference embedding recorded during
/// enrollment, used to seed `EmbeddingClusterer` so their turns are labeled
/// by name from the very first utterance instead of only after the app
/// happens to cluster them correctly on its own.
public struct SpeakerProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var embedding: [Float]

    public init(id: UUID = UUID(), name: String, embedding: [Float]) {
        self.id = id
        self.name = name
        self.embedding = embedding
    }
}

/// How the caption screen looks. Every one of these exists because the
/// primary reader is an older person following a conversation in real
/// time: text size and contrast are accessibility controls here, not
/// cosmetics.
public struct DisplayPreferences: Codable, Sendable, Equatable {
    public enum Theme: String, Codable, Sendable, CaseIterable {
        /// White text on black — the default, easiest on the eyes for a
        /// whole conversation.
        case dark
        /// Yellow text on black — the classic high-contrast caption look,
        /// noticeably easier for many readers with reduced vision.
        case highContrast
        /// Black text on white, for bright rooms.
        case light
    }

    public var fontSize: Double
    public var theme: Theme
    public var boldText: Bool
    public var showSpeakerNames: Bool
    public var keepScreenAwake: Bool

    public static let minimumFontSize: Double = 20
    public static let maximumFontSize: Double = 64

    public init(
        fontSize: Double = 30,
        theme: Theme = .dark,
        boldText: Bool = false,
        showSpeakerNames: Bool = true,
        keepScreenAwake: Bool = true
    ) {
        self.fontSize = fontSize
        self.theme = theme
        self.boldText = boldText
        self.showSpeakerNames = showSpeakerNames
        self.keepScreenAwake = keepScreenAwake
    }

    public static let `default` = DisplayPreferences()

    private enum CodingKeys: String, CodingKey {
        case fontSize, theme, boldText, showSpeakerNames, keepScreenAwake
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplayPreferences.default
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        theme = try container.decodeIfPresent(Theme.self, forKey: .theme) ?? defaults.theme
        boldText = try container.decodeIfPresent(Bool.self, forKey: .boldText) ?? defaults.boldText
        showSpeakerNames = try container.decodeIfPresent(Bool.self, forKey: .showSpeakerNames) ?? defaults.showSpeakerNames
        keepScreenAwake = try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? defaults.keepScreenAwake
        fontSize = min(max(fontSize, Self.minimumFontSize), Self.maximumFontSize)
    }
}

/// Everything Ozen remembers between launches. Small enough that plain
/// `Codable` + a JSON file (see `SettingsStore`) is the right amount of
/// persistence machinery — no database needed for a single-user app.
///
/// Decoding is tolerant of missing keys on purpose: every new setting added
/// in a later build must not throw away the enrolled speaker profiles a
/// previous build saved, so anything absent from the file on disk takes
/// its default instead of failing the whole decode.
public struct AppSettings: Codable, Sendable, Equatable {
    public var engine: TranscriptionEngineKind
    public var languageCode: String
    public var preferredInputUID: String?
    public var speakerProfiles: [SpeakerProfile]
    public var creditLine: String
    /// WhisperKit model variant, e.g. "small" or "large-v3_turbo". See
    /// `WhisperModelCatalog` for the options actually offered.
    public var whisperModelVariant: String
    /// Off by default and only relevant to the Apple engine: iOS may not
    /// ship an on-device Hebrew model on every version, and the only way
    /// to use Apple's recognizer then is to let it send audio to Apple's
    /// servers. That's a privacy decision the user makes explicitly, never
    /// a silent fallback.
    public var allowServerFallbackForAppleSpeech: Bool
    public var display: DisplayPreferences
    /// A short buzz when speech resumes after a quiet stretch — the reader
    /// may have looked away from the screen.
    public var hapticOnSpeechResume: Bool
    /// Cosine-similarity threshold for the speaker clusterer; lower merges
    /// more aggressively (fewer phantom "Speaker 3"s), higher splits more.
    public var speakerSimilarityThreshold: Float
    /// Words and names that buzz and highlight when spoken.
    public var keywordAlerts: [KeywordAlert]
    /// Doorbell, siren, kettle... shown as banners; see `SoundEventCatalog`.
    public var soundAlerts: SoundAlertPreferences
    /// Keep past conversations on the phone for later reading and search.
    public var saveHistory: Bool

    public init(
        engine: TranscriptionEngineKind,
        languageCode: String,
        preferredInputUID: String?,
        speakerProfiles: [SpeakerProfile],
        creditLine: String,
        whisperModelVariant: String = "small",
        allowServerFallbackForAppleSpeech: Bool = false,
        display: DisplayPreferences = .default,
        hapticOnSpeechResume: Bool = true,
        speakerSimilarityThreshold: Float = 0.75,
        keywordAlerts: [KeywordAlert] = [],
        soundAlerts: SoundAlertPreferences = .default,
        saveHistory: Bool = true
    ) {
        self.engine = engine
        self.languageCode = languageCode
        self.preferredInputUID = preferredInputUID
        self.speakerProfiles = speakerProfiles
        self.creditLine = creditLine
        self.whisperModelVariant = whisperModelVariant
        self.allowServerFallbackForAppleSpeech = allowServerFallbackForAppleSpeech
        self.display = display
        self.hapticOnSpeechResume = hapticOnSpeechResume
        self.speakerSimilarityThreshold = speakerSimilarityThreshold
        self.keywordAlerts = keywordAlerts
        self.soundAlerts = soundAlerts
        self.saveHistory = saveHistory
    }

    public static let `default` = AppSettings(
        engine: .whisperKit,
        languageCode: "he",
        preferredInputUID: nil,
        speakerProfiles: [],
        creditLine: "Made by Arbel"
    )

    private enum CodingKeys: String, CodingKey {
        case engine, languageCode, preferredInputUID, speakerProfiles, creditLine
        case whisperModelVariant, allowServerFallbackForAppleSpeech, display
        case hapticOnSpeechResume, speakerSimilarityThreshold
        case keywordAlerts, soundAlerts, saveHistory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default
        engine = try container.decodeIfPresent(TranscriptionEngineKind.self, forKey: .engine) ?? defaults.engine
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode) ?? defaults.languageCode
        preferredInputUID = try container.decodeIfPresent(String.self, forKey: .preferredInputUID)
        speakerProfiles = try container.decodeIfPresent([SpeakerProfile].self, forKey: .speakerProfiles) ?? []
        // The credit line is not user-editable; whatever an old file says,
        // the current build's text wins.
        creditLine = defaults.creditLine
        whisperModelVariant = try container.decodeIfPresent(String.self, forKey: .whisperModelVariant) ?? defaults.whisperModelVariant
        allowServerFallbackForAppleSpeech = try container.decodeIfPresent(Bool.self, forKey: .allowServerFallbackForAppleSpeech) ?? defaults.allowServerFallbackForAppleSpeech
        display = try container.decodeIfPresent(DisplayPreferences.self, forKey: .display) ?? defaults.display
        hapticOnSpeechResume = try container.decodeIfPresent(Bool.self, forKey: .hapticOnSpeechResume) ?? defaults.hapticOnSpeechResume
        speakerSimilarityThreshold = try container.decodeIfPresent(Float.self, forKey: .speakerSimilarityThreshold) ?? defaults.speakerSimilarityThreshold
        keywordAlerts = try container.decodeIfPresent([KeywordAlert].self, forKey: .keywordAlerts) ?? defaults.keywordAlerts
        soundAlerts = try container.decodeIfPresent(SoundAlertPreferences.self, forKey: .soundAlerts) ?? defaults.soundAlerts
        saveHistory = try container.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? defaults.saveHistory
    }
}

/// Loads/saves `AppSettings` as JSON at a caller-supplied file URL. Kept
/// separate from `AppSettings` itself, and taking the URL as a parameter
/// rather than reaching for `FileManager` defaults internally, purely so
/// tests can point it at a temp file instead of touching real app storage.
public struct SettingsStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
