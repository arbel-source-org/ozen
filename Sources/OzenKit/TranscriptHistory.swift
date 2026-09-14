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
    /// Marked as important while it was said ("what the doctor said about
    /// the pills"), so it can be found again.
    public var isStarred: Bool
    /// The engine's confidence in the line when it was saved.
    public var confidence: Float?

    public init(
        id: UUID,
        text: String,
        speakerName: String?,
        speakerClusterID: Int?,
        startTimestamp: TimeInterval,
        isCommitted: Bool,
        isStarred: Bool = false,
        confidence: Float? = nil
    ) {
        self.id = id
        self.text = text
        self.speakerName = speakerName
        self.speakerClusterID = speakerClusterID
        self.startTimestamp = startTimestamp
        self.isCommitted = isCommitted
        self.isStarred = isStarred
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, speakerName, speakerClusterID, startTimestamp, isCommitted, isStarred, confidence
    }

    /// Lines saved before stars existed load as not starred.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        speakerName = try container.decodeIfPresent(String.self, forKey: .speakerName)
        speakerClusterID = try container.decodeIfPresent(Int.self, forKey: .speakerClusterID)
        startTimestamp = try container.decode(TimeInterval.self, forKey: .startTimestamp)
        isCommitted = try container.decode(Bool.self, forKey: .isCommitted)
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
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
    /// A name the reader gave the conversation ("ביקור אצל הרופא").
    public var title: String?

    public init(
        id: UUID = UUID(),
        startedAt: TimeInterval,
        endedAt: TimeInterval? = nil,
        engine: TranscriptionEngineKind,
        modelVariant: String?,
        inputName: String?,
        segments: [SavedSegment],
        title: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.engine = engine
        self.modelVariant = modelVariant
        self.inputName = inputName
        self.segments = segments
        self.title = title
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
        inputName: String?,
        starred: Set<UUID> = []
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
                isCommitted: segment.isCommitted,
                isStarred: starred.contains(segment.id),
                confidence: segment.confidence
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
        case id, startedAt, endedAt, engine, modelVariant, inputName, segments, title
    }

    // Decoding is tolerant of missing keys on the fields a later build
    // could plausibly add or a caller could plausibly omit — the same
    // reasoning as `AppSettings`: an old record on disk must still load
    // rather than losing a whole session to a decode error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(TimeInterval.self, forKey: .startedAt)
        endedAt = container.lenient(TimeInterval.self, forKey: .endedAt)
        // Which engine wrote it only labels the conversation; one this
        // build doesn't know mustn't hide everything that was said.
        engine = container.lenient(TranscriptionEngineKind.self, forKey: .engine) ?? .whisperKit
        modelVariant = container.lenient(String.self, forKey: .modelVariant)
        inputName = container.lenient(String.self, forKey: .inputName)
        // A damaged line is left out; the rest of the conversation loads.
        segments = container.lenientArray(of: SavedSegment.self, forKey: .segments) ?? []
        title = container.lenient(String.self, forKey: .title)
    }
}

/// One line marked as important, with the conversation it came from.
public struct StarredLine: Sendable, Equatable, Identifiable {
    public let sessionID: UUID
    public let sessionStartedAt: TimeInterval
    public let segment: SavedSegment
    public var id: UUID { segment.id }

    public init(sessionID: UUID, sessionStartedAt: TimeInterval, segment: SavedSegment) {
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.segment = segment
    }
}

/// A lightweight stand-in for a `TranscriptSessionRecord` used for listing
/// and searching, so browsing years of history never has to decode every
/// segment of every session just to show a list of dates and previews.
public struct TranscriptSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startedAt: TimeInterval
    public var endedAt: TimeInterval?
    public var segmentCount: Int
    public var preview: String
    public var engine: TranscriptionEngineKind
    /// The real names that took part, in order of first appearance.
    /// Generic labels ("דובר 2") say nothing about who was there and are
    /// left out.
    public var speakerNames: [String]
    /// Lines marked as important.
    public var starredCount: Int
    public var title: String?
    /// When the newest line began. A conversation the app never got to
    /// close (iOS ended the app in the background) has no end time, and
    /// this is the closest thing to one.
    public var lastLineAt: TimeInterval?

    public init(
        id: UUID,
        startedAt: TimeInterval,
        endedAt: TimeInterval?,
        segmentCount: Int,
        preview: String,
        engine: TranscriptionEngineKind,
        speakerNames: [String] = [],
        starredCount: Int = 0,
        title: String? = nil,
        lastLineAt: TimeInterval? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segmentCount = segmentCount
        self.preview = preview
        self.engine = engine
        self.speakerNames = speakerNames
        self.starredCount = starredCount
        self.title = title
        self.lastLineAt = lastLineAt
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
            engine: record.engine,
            speakerNames: Self.realNames(in: record.segments),
            starredCount: record.segments.filter(\.isStarred).count,
            title: record.title,
            lastLineAt: record.segments.map(\.startTimestamp).max()
        )
    }

    static func realNames(in segments: [SavedSegment]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for segment in segments {
            guard let name = segment.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !isGenericLabel(name), !seen.contains(name)
            else { continue }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    /// "דובר 3", "דובר לא ידוע", and the English labels older builds saved.
    public static func isGenericLabel(_ name: String) -> Bool {
        if name == EmbeddingClusterer.unknownSpeakerName || name == "Unknown speaker" { return true }
        for prefix in ["דובר ", "Speaker "] where name.hasPrefix(prefix) {
            if Int(name.dropFirst(prefix.count)) != nil { return true }
        }
        return false
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
///
/// Next to each conversation sits a tiny summary file in `summaries/`.
/// The history list reads only those, so opening it after a year of daily
/// conversations doesn't decode every line ever captioned. A summary is a
/// cache: if it is missing (a session saved by an older build), older than
/// its conversation, or unreadable, the list rebuilds it from the full
/// record and writes it back.
public struct TranscriptHistoryStore: Sendable {
    private let directoryURL: URL

    /// Bumped whenever `TranscriptSessionSummary` changes meaning, so
    /// summaries written by an older build are rebuilt instead of trusted.
    static let summaryFormat = 4
    static let summariesFolderName = "summaries"

    private struct CachedSummary: Codable {
        var format: Int
        var summary: TranscriptSessionSummary
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    private var summariesURL: URL {
        directoryURL.appendingPathComponent(Self.summariesFolderName, isDirectory: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func summaryURL(forRecordFile url: URL) -> URL {
        summariesURL.appendingPathComponent(url.lastPathComponent)
    }

    /// The searchable words of one conversation, already lowercased and
    /// stripped of niqqud, one caption line or speaker name per line. The
    /// format is in the file name, so a future change simply stops
    /// finding the old files and rebuilds them.
    private func searchTextURL(forRecordFile url: URL) -> URL {
        summariesURL.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".search-v1.txt")
    }

    /// Saves a session, overwriting any earlier save with the same id —
    /// that's what lets a caller autosave periodically during a live
    /// session and again when it ends, without creating duplicates. A
    /// session with no segments is noise rather than history (the user
    /// opened the app and closed it again) so it's deliberately not
    /// written at all.
    ///
    /// A conversation still being captioned is autosaved from the live
    /// transcript, which knows nothing of a name given to it meanwhile on
    /// the history screen. A save without a title therefore keeps the one
    /// already on disk (read from the small summary file, not the whole
    /// conversation); `rename` is how a title is changed or removed.
    @discardableResult
    public func save(_ record: TranscriptSessionRecord) throws -> Bool {
        guard !record.segments.isEmpty else { return false }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = fileURL(for: record.id)
        var record = record
        if record.title == nil {
            record.title = cachedSummary(forRecordFile: url)?.title
        }
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        // Written after the record, so a fresh summary is never older than
        // its conversation. If this write fails the conversation is still
        // saved; the list just rebuilds the summary next time.
        writeSummary(TranscriptSessionSummary(summarizing: record), forRecordFile: url)
        writeSearchText(Self.searchableText(of: record), forRecordFile: url)
        return true
    }

    public func load(id: UUID) -> TranscriptSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(TranscriptSessionRecord.self, from: data)
    }

    /// The conversation files in the directory, without reading them.
    private func recordFiles() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" }
    }

    /// A file that fails to decode (truncated write, a future format the
    /// current build doesn't understand) comes back nil and is skipped by
    /// the list and search — one bad session must never hide every other.
    private static func decodeRecord(at url: URL) -> TranscriptSessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptSessionRecord.self, from: data)
    }

    private static func modificationDate(of url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// A cache file is trusted only if it was written after its conversation.
    private static func isFresh(_ cacheURL: URL, forRecordFile url: URL) -> Bool {
        guard let cacheDate = modificationDate(of: cacheURL),
              let recordDate = modificationDate(of: url)
        else { return false }
        return cacheDate >= recordDate
    }

    private func cachedSummary(forRecordFile url: URL) -> TranscriptSessionSummary? {
        let cacheURL = summaryURL(forRecordFile: url)
        guard Self.isFresh(cacheURL, forRecordFile: url),
              let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedSummary.self, from: data),
              cached.format == Self.summaryFormat
        else { return nil }
        return cached.summary
    }

    private func writeSummary(_ summary: TranscriptSessionSummary, forRecordFile url: URL) {
        guard let data = try? JSONEncoder().encode(CachedSummary(format: Self.summaryFormat, summary: summary)) else { return }
        try? FileManager.default.createDirectory(at: summariesURL, withIntermediateDirectories: true)
        try? data.write(to: summaryURL(forRecordFile: url), options: .atomic)
    }

    private func cachedSearchText(forRecordFile url: URL) -> String? {
        let cacheURL = searchTextURL(forRecordFile: url)
        guard Self.isFresh(cacheURL, forRecordFile: url),
              let data = try? Data(contentsOf: cacheURL)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeSearchText(_ text: String, forRecordFile url: URL) {
        try? FileManager.default.createDirectory(at: summariesURL, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: searchTextURL(forRecordFile: url), options: .atomic)
    }

    static func searchableText(of record: TranscriptSessionRecord) -> String {
        var lines: [String] = record.title.map { [normalizedForSearch($0)] } ?? []
        for segment in record.segments {
            lines.append(normalizedForSearch(segment.text))
            if let name = segment.speakerName {
                lines.append(normalizedForSearch(name))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func normalizedForSearch(_ text: String) -> String {
        strippingNiqqud(text.replacingOccurrences(of: "\n", with: " ")).lowercased()
    }

    private static func record(_ record: TranscriptSessionRecord, matches needle: String) -> Bool {
        if let title = record.title, strippingNiqqud(title).lowercased().contains(needle) {
            return true
        }
        return record.segments.contains { segment($0, matches: needle) }
    }

    private static func segment(_ segment: SavedSegment, matches needle: String) -> Bool {
        if strippingNiqqud(segment.text).lowercased().contains(needle) {
            return true
        }
        guard let name = segment.speakerName else { return false }
        return strippingNiqqud(name).lowercased().contains(needle)
    }

    /// The lines of a conversation that a search for `query` found, in
    /// order, by the same rules as `search`: the words of the line or the
    /// name of who said it. Opening a search result jumps to these.
    public static func matchingSegmentIDs(in record: TranscriptSessionRecord, query: String) -> [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = strippingNiqqud(trimmed).lowercased()
        return record.segments.filter { segment($0, matches: needle) }.map(\.id)
    }

    public func listSummaries() -> [TranscriptSessionSummary] {
        summaries(of: recordFiles())
    }

    /// Summaries of the conversations whose file was written at or after
    /// `cutoff`. Checking a file's date is far cheaper than opening it, so
    /// "what was being saved in the last half hour" doesn't read a year of
    /// history at launch.
    public func summaries(modifiedSince cutoff: TimeInterval) -> [TranscriptSessionSummary] {
        let recent = recordFiles().filter { url in
            guard let modified = Self.modificationDate(of: url) else { return true }
            return modified.timeIntervalSince1970 >= cutoff
        }
        return summaries(of: recent)
    }

    private func summaries(of files: [URL]) -> [TranscriptSessionSummary] {
        files
            .compactMap { url -> TranscriptSessionSummary? in
                if let cached = cachedSummary(forRecordFile: url) { return cached }
                guard let record = Self.decodeRecord(at: url) else { return nil }
                let summary = TranscriptSessionSummary(summarizing: record)
                writeSummary(summary, forRecordFile: url)
                return summary
            }
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

        return recordFiles()
            .compactMap { url -> TranscriptSessionSummary? in
                // Fast path: the conversation's prepared search text says
                // no, or says yes and its summary is ready.
                if let text = cachedSearchText(forRecordFile: url) {
                    let found = text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.contains(needle) }
                    guard found else { return nil }
                    if let summary = cachedSummary(forRecordFile: url) { return summary }
                }
                // Slow path, once per conversation: read it whole and write
                // the files that make the next search fast.
                guard let record = Self.decodeRecord(at: url) else { return nil }
                let summary = TranscriptSessionSummary(summarizing: record)
                writeSummary(summary, forRecordFile: url)
                writeSearchText(Self.searchableText(of: record), forRecordFile: url)
                return Self.record(record, matches: needle) ? summary : nil
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Every starred line in saved history, newest conversation first and
    /// in spoken order within one. Only conversations whose summary counts
    /// a star are opened.
    public func starredLines() -> [StarredLine] {
        listSummaries()
            .filter { $0.starredCount > 0 }
            .compactMap { load(id: $0.id) }
            .flatMap { record in
                record.segments
                    .filter(\.isStarred)
                    .map { StarredLine(sessionID: record.id, sessionStartedAt: record.startedAt, segment: $0) }
            }
    }

    /// Names a saved conversation, or removes its name with an empty one.
    public func rename(id: UUID, title: String) throws {
        guard var record = load(id: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.title = trimmed.isEmpty ? nil : trimmed
        let url = fileURL(for: id)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        writeSummary(TranscriptSessionSummary(summarizing: record), forRecordFile: url)
        writeSearchText(Self.searchableText(of: record), forRecordFile: url)
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: summaryURL(forRecordFile: url))
        try? FileManager.default.removeItem(at: searchTextURL(forRecordFile: url))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func deleteAll() throws {
        for url in recordFiles() {
            try FileManager.default.removeItem(at: url)
        }
        if FileManager.default.fileExists(atPath: summariesURL.path) {
            try FileManager.default.removeItem(at: summariesURL)
        }
    }

    /// Bytes used by conversations and their summaries.
    public func totalSizeOnDisk() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// A plain-text rendering for sharing or reviewing a session outside
    /// the app (e.g. AirDrop'd as a .txt file). The clock time is computed
    /// by hand from the raw seconds plus a caller-supplied UTC offset
    /// rather than through `DateFormatter`, which is locale-sensitive and
    /// would otherwise make this render differently on a test machine than
    /// on the phone. The app passes `TimeZone.current.secondsFromGMT()`;
    /// tests pass 0.
    public static func exportText(_ record: TranscriptSessionRecord, utcOffsetSeconds: Int = 0) -> String {
        let lines = record.segments
            .map { segment in
                let time = formattedClockTime(segment.startTimestamp, utcOffsetSeconds: utcOffsetSeconds)
                let star = segment.isStarred ? "★ " : ""
                if let name = segment.speakerName, !name.isEmpty {
                    return "\(star)[\(time)] \(name): \(segment.text)"
                }
                return "\(star)[\(time)] \(segment.text)"
            }
            .joined(separator: "\n")
        // A named conversation says what it was before the first line.
        guard let title = record.title else { return lines }
        return "\(title)\n\n\(lines)"
    }

    /// Starred lines as plain text for sharing: one block per
    /// conversation, headed by its date, then each line with its time and
    /// who said it. Dates are computed by hand for the same reason as the
    /// clock times: identical output on the phone and in tests.
    public static func exportStarredText(_ lines: [StarredLine], utcOffsetSeconds: Int = 0) -> String {
        var blocks: [String] = []
        var currentSession: UUID?
        var block: [String] = []
        for line in lines {
            if line.sessionID != currentSession {
                if !block.isEmpty { blocks.append(block.joined(separator: "\n")) }
                block = [formattedDate(line.sessionStartedAt, utcOffsetSeconds: utcOffsetSeconds)]
                currentSession = line.sessionID
            }
            let time = formattedClockTime(line.segment.startTimestamp, utcOffsetSeconds: utcOffsetSeconds)
            if let name = line.segment.speakerName, !name.isEmpty, !TranscriptSessionSummary.isGenericLabel(name) {
                block.append("[\(time)] \(name): \(line.segment.text)")
            } else {
                block.append("[\(time)] \(line.segment.text)")
            }
        }
        if !block.isEmpty { blocks.append(block.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n")
    }

    /// Day.month.year of a timestamp in the given UTC offset.
    private static func formattedDate(_ timestamp: TimeInterval, utcOffsetSeconds: Int) -> String {
        let days = Int((Double(Int(timestamp.rounded(.down)) + utcOffsetSeconds) / 86_400).rounded(.down))
        // Civil-from-days (Howard Hinnant's algorithm), valid for any day count.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return "\(twoDigits(day)).\(twoDigits(month)).\(year)"
    }

    static func formattedClockTime(_ timestamp: TimeInterval, utcOffsetSeconds: Int) -> String {
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
