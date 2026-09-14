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

/// One person in the saved speakers list, however many voice prints they
/// have. Naming a second voice with a name already saved (the same person
/// heard from across the room, or on a cold day) adds a print rather than
/// a person, so the list shows the name once, and renaming or deleting it
/// covers every print: renaming just one left the other to bring the old
/// name back on the next launch.
public struct SavedSpeaker: Sendable, Equatable, Identifiable {
    public let name: String
    public let profileIDs: [UUID]
    public var id: String { name }

    /// The profiles grouped by name, in the order each name was first saved.
    public static func grouping(_ profiles: [SpeakerProfile]) -> [SavedSpeaker] {
        var order: [String] = []
        var ids: [String: [UUID]] = [:]
        for profile in profiles {
            if ids[profile.name] == nil { order.append(profile.name) }
            ids[profile.name, default: []].append(profile.id)
        }
        return order.map { SavedSpeaker(name: $0, profileIDs: ids[$0] ?? []) }
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
    /// A small question mark on finished lines the engine was unsure of.
    public var markUncertainLines: Bool
    /// With VoiceOver on, finished lines are read out (or sent to a braille
    /// display) as they arrive. See `CaptionAnnouncer`.
    public var announceNewLines: Bool
    /// Numbers (times, amounts, phone numbers) drawn heavier and in their
    /// own colour. See `NumberEmphasis`.
    public var emphasizeNumbers: Bool
    /// The newest lines on the lock screen, as a Live Activity, while
    /// captions run. See `LockScreenCaptions`.
    public var lockScreenCaptions: Bool

    public static let minimumFontSize: Double = 20
    public static let maximumFontSize: Double = 64

    public init(
        fontSize: Double = 30,
        theme: Theme = .dark,
        boldText: Bool = false,
        showSpeakerNames: Bool = true,
        keepScreenAwake: Bool = true,
        markUncertainLines: Bool = true,
        announceNewLines: Bool = true,
        emphasizeNumbers: Bool = true,
        lockScreenCaptions: Bool = true
    ) {
        self.fontSize = fontSize
        self.theme = theme
        self.boldText = boldText
        self.showSpeakerNames = showSpeakerNames
        self.keepScreenAwake = keepScreenAwake
        self.markUncertainLines = markUncertainLines
        self.announceNewLines = announceNewLines
        self.emphasizeNumbers = emphasizeNumbers
        self.lockScreenCaptions = lockScreenCaptions
    }

    public static let `default` = DisplayPreferences()

    /// The text size a pinch of `scale` lands on: clamped to the readable
    /// range and rounded to whole points, so a pinch never leaves the
    /// setting at 31.847 or pushes it off either end.
    public static func fontSize(_ base: Double, scaledBy scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return min(max(base, minimumFontSize), maximumFontSize) }
        return min(max((base * scale).rounded(), minimumFontSize), maximumFontSize)
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize, theme, boldText, showSpeakerNames, keepScreenAwake, markUncertainLines, announceNewLines, emphasizeNumbers
        case lockScreenCaptions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplayPreferences.default
        fontSize = container.lenient(Double.self, forKey: .fontSize) ?? defaults.fontSize
        theme = container.lenient(Theme.self, forKey: .theme) ?? defaults.theme
        boldText = container.lenient(Bool.self, forKey: .boldText) ?? defaults.boldText
        showSpeakerNames = container.lenient(Bool.self, forKey: .showSpeakerNames) ?? defaults.showSpeakerNames
        keepScreenAwake = container.lenient(Bool.self, forKey: .keepScreenAwake) ?? defaults.keepScreenAwake
        markUncertainLines = container.lenient(Bool.self, forKey: .markUncertainLines) ?? defaults.markUncertainLines
        announceNewLines = container.lenient(Bool.self, forKey: .announceNewLines) ?? defaults.announceNewLines
        emphasizeNumbers = container.lenient(Bool.self, forKey: .emphasizeNumbers) ?? defaults.emphasizeNumbers
        lockScreenCaptions = container.lenient(Bool.self, forKey: .lockScreenCaptions) ?? defaults.lockScreenCaptions
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
    /// Type-to-speak: ready-made replies the reader can tap instead of
    /// typing, and how fast the phone reads them out.
    public var quickPhrases: [String]
    /// 0...1 as AVSpeechUtterance understands it; 0.45 is a calm pace.
    public var speechRate: Float
    /// Family names, places, medicines — words both engines are told to
    /// expect so they come out spelled right. See `VocabularyHints`.
    public var vocabulary: [String]
    /// The first-launch walkthrough (what the app does, engine choice,
    /// microphone permission) has been seen once.
    public var hasCompletedOnboarding: Bool
    /// Doorbell, siren or her name while the app isn't on screen (pocket,
    /// locked phone) also becomes a phone notification.
    public var notifyWhenInBackground: Bool
    /// Speech models may download over cellular data or in Low Data Mode.
    /// Off by default: a model is hundreds of megabytes.
    public var allowCellularModelDownload: Bool
    /// Saved conversations delete themselves after this long; see
    /// `HistoryRetention`.
    public var historyRetention: HistoryRetention
    /// "Not now" was tapped on the caption screen's offer to set up the
    /// alert for her name; see `offersNameAlert`.
    public var nameAlertOfferDismissed: Bool

    /// Whether the caption screen should offer to set up the alert for her
    /// name. The walkthrough asks for it, but only on a fresh install;
    /// phones set up before it did never had the name asked for, and
    /// without it the buzz for her name never comes.
    public var offersNameAlert: Bool {
        hasCompletedOnboarding && keywordAlerts.isEmpty && !nameAlertOfferDismissed
    }

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
        saveHistory: Bool = true,
        quickPhrases: [String] = AppSettings.defaultQuickPhrases,
        speechRate: Float = 0.45,
        vocabulary: [String] = [],
        hasCompletedOnboarding: Bool = false,
        notifyWhenInBackground: Bool = true,
        allowCellularModelDownload: Bool = false,
        historyRetention: HistoryRetention = .forever,
        nameAlertOfferDismissed: Bool = false
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
        self.quickPhrases = quickPhrases
        self.speechRate = speechRate
        self.vocabulary = VocabularyHints.normalized(vocabulary)
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.notifyWhenInBackground = notifyWhenInBackground
        self.allowCellularModelDownload = allowCellularModelDownload
        self.historyRetention = historyRetention
        self.nameAlertOfferDismissed = nameAlertOfferDismissed
    }

    /// The phrases a hard-of-hearing person needs most often in
    /// conversation, ready before she has typed anything.
    public static let defaultQuickPhrases: [String] = [
        "רגע, לא הבנתי",
        "אפשר לחזור על זה?",
        "לאט יותר בבקשה",
        "דברו קרוב יותר לטלפון, בבקשה",
        "אני קוראת את הכתוביות, תנו לי רגע",
        "כן",
        "לא",
        "תודה",
        "בואו נדבר אחד אחד",
    ]

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
        case quickPhrases, speechRate, vocabulary, hasCompletedOnboarding
        case notifyWhenInBackground, allowCellularModelDownload, historyRetention
        case nameAlertOfferDismissed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default
        engine = container.lenient(TranscriptionEngineKind.self, forKey: .engine) ?? defaults.engine
        languageCode = container.lenient(String.self, forKey: .languageCode) ?? defaults.languageCode
        preferredInputUID = container.lenient(String.self, forKey: .preferredInputUID)
        speakerProfiles = container.lenientArray(of: SpeakerProfile.self, forKey: .speakerProfiles)?
            .filter(\.isUsable)
            .map(\.withCurrentVoicePrint) ?? []
        // The credit line is not user-editable; whatever an old file says,
        // the current build's text wins.
        creditLine = defaults.creditLine
        whisperModelVariant = container.lenient(String.self, forKey: .whisperModelVariant) ?? defaults.whisperModelVariant
        allowServerFallbackForAppleSpeech = container.lenient(Bool.self, forKey: .allowServerFallbackForAppleSpeech) ?? defaults.allowServerFallbackForAppleSpeech
        display = container.lenient(DisplayPreferences.self, forKey: .display) ?? defaults.display
        hapticOnSpeechResume = container.lenient(Bool.self, forKey: .hapticOnSpeechResume) ?? defaults.hapticOnSpeechResume
        speakerSimilarityThreshold = container.lenient(Float.self, forKey: .speakerSimilarityThreshold) ?? defaults.speakerSimilarityThreshold
        // The Settings slider's range; a file saying otherwise gets the nearest edge.
        speakerSimilarityThreshold = speakerSimilarityThreshold.isFinite
            ? min(max(speakerSimilarityThreshold, 0.5), 0.95)
            : defaults.speakerSimilarityThreshold
        keywordAlerts = container.lenientArray(of: KeywordAlert.self, forKey: .keywordAlerts) ?? defaults.keywordAlerts
        soundAlerts = container.lenient(SoundAlertPreferences.self, forKey: .soundAlerts) ?? defaults.soundAlerts
        saveHistory = container.lenient(Bool.self, forKey: .saveHistory) ?? defaults.saveHistory
        quickPhrases = container.lenient([String].self, forKey: .quickPhrases) ?? defaults.quickPhrases
        speechRate = container.lenient(Float.self, forKey: .speechRate) ?? defaults.speechRate
        speechRate = min(max(speechRate, 0.2), 0.7)
        vocabulary = VocabularyHints.normalized(container.lenient([String].self, forKey: .vocabulary) ?? [])
        hasCompletedOnboarding = container.lenient(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        notifyWhenInBackground = container.lenient(Bool.self, forKey: .notifyWhenInBackground) ?? defaults.notifyWhenInBackground
        allowCellularModelDownload = container.lenient(Bool.self, forKey: .allowCellularModelDownload) ?? defaults.allowCellularModelDownload
        historyRetention = container.lenient(HistoryRetention.self, forKey: .historyRetention) ?? defaults.historyRetention
        nameAlertOfferDismissed = container.lenient(Bool.self, forKey: .nameAlertOfferDismissed) ?? defaults.nameAlertOfferDismissed
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

    /// Creates the folder first: on a fresh install iOS hasn't made
    /// Application Support yet, and without this the very first saves
    /// (finishing the walkthrough, say) fail and are forgotten on relaunch.
    public func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension SpeakerProfile {
    /// A voice print that can be compared and written back to disk: JSON
    /// has no NaN, so one non-finite number would make every later settings
    /// save fail.
    var isUsable: Bool {
        !embedding.isEmpty && embedding.allSatisfy(\.isFinite)
    }

    /// How many numbers a voice print from the MFCC embedder has.
    public static let voicePrintLength = 12

    /// This profile as the current embedder would have made it. Prints
    /// saved by earlier builds had one more number in front, the loudness
    /// of the recording, which made every voice look alike (see
    /// `MFCCSpeakerEmbedder`). The rest of the print is exactly what the
    /// embedder makes now, so dropping it keeps a saved voice working
    /// instead of silently never matching anyone again.
    var withCurrentVoicePrint: SpeakerProfile {
        guard embedding.count == Self.voicePrintLength + 1 else { return self }
        var profile = self
        profile.embedding.removeFirst()
        return profile
    }
}

extension KeyedDecodingContainer {
    /// The value under `key`, or nil when it's missing or can't be read.
    ///
    /// Settings are read leniently one value at a time: a single value a
    /// build doesn't understand (an engine name from a newer version, a
    /// damaged field) falls back to its default instead of failing the
    /// whole file. Failing the whole file meant starting from defaults, and
    /// the next save then overwrote the enrolled voices, vocabulary and
    /// alerts that were still perfectly readable.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// Like `lenient`, but for a list: an entry that can't be read is
    /// dropped and the rest are kept.
    func lenientArray<T: Decodable>(of type: T.Type, forKey key: Key) -> [T]? {
        guard let entries = try? decodeIfPresent([LenientEntry<T>].self, forKey: key) else { return nil }
        return entries.compactMap(\.value)
    }
}

private struct LenientEntry<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
