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

/// Everything Ozen remembers between launches. Small enough that plain
/// `Codable` + a JSON file (see `SettingsStore`) is the right amount of
/// persistence machinery — no database needed for a single-user app.
public struct AppSettings: Codable, Sendable, Equatable {
    public var engine: TranscriptionEngineKind
    public var languageCode: String
    public var preferredInputUID: String?
    public var speakerProfiles: [SpeakerProfile]
    public var creditLine: String

    public init(
        engine: TranscriptionEngineKind,
        languageCode: String,
        preferredInputUID: String?,
        speakerProfiles: [SpeakerProfile],
        creditLine: String
    ) {
        self.engine = engine
        self.languageCode = languageCode
        self.preferredInputUID = preferredInputUID
        self.speakerProfiles = speakerProfiles
        self.creditLine = creditLine
    }

    public static let `default` = AppSettings(
        engine: .whisperKit,
        languageCode: "he",
        preferredInputUID: nil,
        speakerProfiles: [],
        creditLine: "Made by Arbel"
    )
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
