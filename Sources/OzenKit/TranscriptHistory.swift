import Foundation

/// One committed or pending caption line as saved to disk. `speakerName` is
/// a snapshot of whatever was actually shown onscreen at save time (a
/// profile's name, or a generic "דובר 2") rather than a live reference to a
/// `SpeakerProfile` — a profile can be renamed or deleted later, and
/// history should keep reading the way the conversation actually looked.
public struct SavedSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var speakerName: String?
    public var speakerClusterID: Int?
    public var startTimestamp: TimeInterval
    public var isCommitted: Bool

    public init(
        id: UUID,
        text: String,
        speakerName: String?,
        speakerClusterID: Int?,
        startTimestamp: TimeInterval,
        isCommitted: Bool
    ) {
        self.id = id
        self.text = text
        self.speakerName = speakerName
        self.speakerClusterID = speakerClusterID
        self.startTimestamp = startTimestamp
        self.isCommitted = isCommitted
    }
}

/// One captioning session as persisted to disk. `CaptionStabilizer` and
/// `CaptionPipeline` only ever hold the current session in memory, so this
/// is the whole answer to "can I look back at what was said yesterday" —
/// anything meant to survive past the current run has to become one of
/// these first.
public struct TranscriptSessionRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startedAt: TimeInterval
    public var endedAt: TimeInterval?
    public var engine: TranscriptionEngineKind
    public var modelVariant: String?
    public var inputName: String?
    public var segments: [SavedSegment]

    public init(
        id: UUID = UUID(),
        startedAt: TimeInterval,
        endedAt: TimeInterval? = nil,
        engine: TranscriptionEngineKind,
        modelVariant: String?,
        inputName: String?,
        segments: [SavedSegment]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.engine = engine
        self.modelVariant = modelVariant
        self.inputName = inputName
        self.segments = segments
    }

    /// Converts a live in-memory transcript into a saveable record. A
    /// segment whose text is empty (an utterance the engine opened but
    /// never filled in, e.g. right as the app was stopped) carries no
    /// information and is dropped rather than becoming a blank line in
    /// exported text.
    public static func make(
        from segments: [TranscriptSegment],
        speakerName: (TranscriptSegment) -> String?,
        id: UUID,
        startedAt: TimeInterval,
        endedAt: TimeInterval?,
        engine: TranscriptionEngineKind,
        modelVariant: String?,
        inputName: String?
    ) -> TranscriptSessionRecord {
        let saved = segments.compactMap { segment -> SavedSegment? in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return SavedSegment(
                id: segment.id,
                text: segment.text,
                speakerName: speakerName(segment),
                speakerClusterID: segment.speakerClusterID,
                startTimestamp: segment.startTimestamp,
                isCommitted: segment.isCommitted
            )
        }
        return TranscriptSessionRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            engine: engine,
            modelVariant: modelVariant,
            inputName: inputName,
            segments: saved
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, engine, modelVariant, inputName, segments
    }

    // Decoding is tolerant of missing keys on the fields a later build
    // could plausibly add or a caller could plausibly omit — the same
    // reasoning as `AppSettings`: an old record on disk must still load
    // rather than losing a whole session to a decode error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(TimeInterval.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .endedAt)
        engine = try container.decode(TranscriptionEngineKind.self, forKey: .engine)
        modelVariant = try container.decodeIfPresent(String.self, forKey: .modelVariant)
        inputName = try container.decodeIfPresent(String.self, forKey: .inputName)
        segments = try container.decodeIfPresent([SavedSegment].self, forKey: .segments) ?? []
    }
}

/// A lightweight stand-in for a `TranscriptSessionRecord` used for listing
/// and searching, so browsing years of history never has to decode every
/// segment of every session just to show a list of dates and previews.
public struct TranscriptSessionSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startedAt: TimeInterval
    public var endedAt: TimeInterval?
    public var segmentCount: Int
    public var preview: String
    public var engine: TranscriptionEngineKind

    public init(
        id: UUID,
        startedAt: TimeInterval,
        endedAt: TimeInterval?,
        segmentCount: Int,
        preview: String,
        engine: TranscriptionEngineKind
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segmentCount = segmentCount
        self.preview = preview
        self.engine = engine
    }

    public var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt - startedAt
    }
}

extension TranscriptSessionSummary {
    /// The preview is capped well short of a full segment so a list of
    /// sessions stays scannable at a glance instead of each row wrapping
    /// to several lines.
    static let previewCharacterLimit = 80

    init(summarizing record: TranscriptSessionRecord) {
        let firstNonEmpty = record.segments.first {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.init(
            id: record.id,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            segmentCount: record.segments.count,
            preview: Self.truncated(firstNonEmpty?.text ?? ""),
            engine: record.engine
        )
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > previewCharacterLimit else { return text }
        return String(text.prefix(previewCharacterLimit)) + "…"
    }
}

/// Reads and writes `TranscriptSessionRecord`s as one JSON file per session
/// in a caller-supplied directory. Kept file-based and pointed at an
/// injected URL, like `SettingsStore`, purely so tests can use a temp
/// directory instead of touching real app storage — there's no database
/// here, just a folder of small JSON files.
public struct TranscriptHistoryStore: Sendable {
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// Saves a session, overwriting any earlier save with the same id —
    /// that's what lets a caller autosave periodically during a live
    /// session and again when it ends, without creating duplicates. A
    /// session with no segments is noise rather than history (the user
    /// opened the app and closed it again) so it's deliberately not
    /// written at all.
    @discardableResult
    public func save(_ record: TranscriptSessionRecord) throws -> Bool {
        guard !record.segments.isEmpty else { return false }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: record.id), options: .atomic)
        return true
    }

    public func load(id: UUID) -> TranscriptSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(TranscriptSessionRecord.self, from: data)
    }

    /// Every readable, decodable record in the directory. A file that
    /// fails to decode (truncated write, a future format the current
    /// build doesn't understand) is silently skipped rather than failing
    /// the whole listing — one bad session must never hide every other
    /// one.
    private func allRecords() -> [TranscriptSessionRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(TranscriptSessionRecord.self, from: data)
        }
    }

    public func listSummaries() -> [TranscriptSessionSummary] {
        allRecords()
            .map { TranscriptSessionSummary(summarizing: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Case-insensitive substring search over segment text and speaker
    /// names, with Hebrew niqqud stripped from both the query and the
    /// stored text first. Niqqud is how vowels are written in Hebrew, but
    /// almost nobody types it when searching, and speech engines rarely
    /// emit it either — without stripping it, a search for a plain-typed
    /// word would fail to find a session where the transcript happened to
    /// include the pointed form.
    public func search(_ query: String) -> [TranscriptSessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return listSummaries() }
        let needle = Self.strippingNiqqud(trimmed).lowercased()

        return allRecords()
            .filter { record in
                record.segments.contains { segment in
                    if Self.strippingNiqqud(segment.text).lowercased().contains(needle) {
                        return true
                    }
                    guard let name = segment.speakerName else { return false }
                    return Self.strippingNiqqud(name).lowercased().contains(needle)
                }
            }
            .map { TranscriptSessionSummary(summarizing: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func deleteAll() throws {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls where url.pathExtension == "json" {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func totalSizeOnDisk() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    /// A plain-text rendering for sharing or reviewing a session outside
    /// the app (e.g. AirDrop'd as a .txt file). The clock time is computed
    /// by hand from the raw seconds plus a caller-supplied UTC offset
    /// rather than through `DateFormatter`, which is locale-sensitive and
    /// would otherwise make this render differently on a test machine than
    /// on the phone. The app passes `TimeZone.current.secondsFromGMT()`;
    /// tests pass 0.
    public static func exportText(_ record: TranscriptSessionRecord, utcOffsetSeconds: Int = 0) -> String {
        record.segments
            .map { segment in
                let time = formattedClockTime(segment.startTimestamp, utcOffsetSeconds: utcOffsetSeconds)
                if let name = segment.speakerName, !name.isEmpty {
                    return "[\(time)] \(name): \(segment.text)"
                }
                return "[\(time)] \(segment.text)"
            }
            .joined(separator: "\n")
    }

    private static func formattedClockTime(_ timestamp: TimeInterval, utcOffsetSeconds: Int) -> String {
        let totalSeconds = Int(timestamp.rounded(.down)) + utcOffsetSeconds
        // Wrap into a single day of seconds so a session that (in theory)
        // started with a huge or negative timestamp still prints a valid
        // 24-hour clock reading instead of garbage.
        let secondsOfDay = ((totalSeconds % 86_400) + 86_400) % 86_400
        let hours = secondsOfDay / 3_600
        let minutes = (secondsOfDay % 3_600) / 60
        let seconds = secondsOfDay % 60
        return "\(twoDigits(hours)):\(twoDigits(minutes)):\(twoDigits(seconds))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func strippingNiqqud(_ text: String) -> String {
        HebrewText.stripNiqqud(text)
    }
}
