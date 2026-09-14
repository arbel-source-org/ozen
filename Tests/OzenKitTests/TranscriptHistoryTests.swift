import Testing
@testable import OzenKit
import Foundation

@Suite("Transcript history persistence")
struct TranscriptHistoryTests {

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ozen-history-\(UUID())")
    }

    private func segment(
        id: UUID = UUID(),
        text: String,
        speakerName: String? = nil,
        speakerClusterID: Int? = nil,
        startTimestamp: TimeInterval = 0,
        isCommitted: Bool = true
    ) -> SavedSegment {
        SavedSegment(
            id: id,
            text: text,
            speakerName: speakerName,
            speakerClusterID: speakerClusterID,
            startTimestamp: startTimestamp,
            isCommitted: isCommitted
        )
    }

    private func record(
        id: UUID = UUID(),
        startedAt: TimeInterval,
        endedAt: TimeInterval? = nil,
        segments: [SavedSegment]
    ) -> TranscriptSessionRecord {
        TranscriptSessionRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            engine: .whisperKit,
            modelVariant: "small",
            inputName: "iPhone Microphone",
            segments: segments
        )
    }

    @Test("saving then loading a session returns exactly what was saved")
    func saveThenLoadRoundTrips() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let original = record(startedAt: 100, endedAt: 200, segments: [segment(text: "שלום")])
        let saved = try store.save(original)
        #expect(saved == true)

        let loaded = store.load(id: original.id)
        #expect(loaded == original)
    }

    @Test("a session with no segments is not written and reports it wasn't saved")
    func emptyRecordIsNotSaved() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let empty = record(startedAt: 100, segments: [])
        let saved = try store.save(empty)
        #expect(saved == false)
        #expect(store.load(id: empty.id) == nil)
        #expect(store.listSummaries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("saving the same session id again overwrites rather than duplicating it")
    func overwriteSameIdKeepsOneEntry() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let id = UUID()
        try store.save(record(id: id, startedAt: 100, segments: [segment(text: "גרסה ראשונה")]))
        try store.save(record(id: id, startedAt: 100, segments: [segment(text: "גרסה שנייה")]))

        let summaries = store.listSummaries()
        #expect(summaries.count == 1)
        #expect(store.load(id: id)?.segments.first?.text == "גרסה שנייה")
    }

    @Test("listing summaries orders sessions newest-started first")
    func listingOrderIsNewestFirst() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let oldest = record(startedAt: 100, segments: [segment(text: "ישן")])
        let middle = record(startedAt: 200, segments: [segment(text: "אמצע")])
        let newest = record(startedAt: 300, segments: [segment(text: "חדש")])
        try store.save(middle)
        try store.save(oldest)
        try store.save(newest)

        let order = store.listSummaries().map(\.startedAt)
        #expect(order == [300, 200, 100])
    }

    @Test("a corrupt file is skipped while other sessions still list correctly")
    func corruptFileIsSkipped() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let good = record(startedAt: 100, segments: [segment(text: "תקין")])
        try store.save(good)
        try Data("not valid json".utf8).write(to: dir.appendingPathComponent("garbage.json"))

        let summaries = store.listSummaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == good.id)
    }

    @Test("a preview longer than 80 characters is truncated with an ellipsis")
    func previewTruncatesOverEightyCharacters() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let longText = String(repeating: "א", count: 120)
        try store.save(record(startedAt: 100, segments: [segment(text: longText)]))

        let preview = store.listSummaries().first?.preview
        #expect(preview?.count == 81)
        #expect(preview?.hasSuffix("…") == true)
        #expect(preview == String(longText.prefix(80)) + "…")
    }

    @Test("a preview of 80 characters or fewer is not truncated")
    func previewUnderLimitIsUnchanged() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let shortText = String(repeating: "ב", count: 80)
        try store.save(record(startedAt: 100, segments: [segment(text: shortText)]))

        let preview = store.listSummaries().first?.preview
        #expect(preview == shortText)
    }

    @Test("search is case-insensitive over segment text")
    func searchIsCaseInsensitive() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        try store.save(record(startedAt: 100, segments: [segment(text: "Hello Grandma")]))

        #expect(store.search("hello").count == 1)
        #expect(store.search("GRANDMA").count == 1)
        #expect(store.search("nonexistent").isEmpty)
    }

    @Test("search matches on speaker name even when the text doesn't contain the query")
    func searchMatchesSpeakerNames() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        try store.save(record(
            startedAt: 100,
            segments: [segment(text: "מה שלומך", speakerName: "סבתא")]
        ))

        #expect(store.search("סבתא").count == 1)
        #expect(store.search("סבא").isEmpty)
    }

    @Test("search ignores Hebrew niqqud on both sides of the comparison")
    func searchIsNiqqudInsensitive() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        try store.save(record(startedAt: 100, segments: [segment(text: "שָׁלוֹם")]))

        #expect(store.search("שלום").count == 1)
    }

    @Test("an empty or whitespace-only search query returns every session")
    func emptySearchQueryReturnsAll() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        try store.save(record(startedAt: 100, segments: [segment(text: "אחד")]))
        try store.save(record(startedAt: 200, segments: [segment(text: "שתיים")]))

        #expect(store.search("").count == 2)
        #expect(store.search("   ").count == 2)
    }

    @Test("delete and deleteAll remove sessions, and deleting a missing id doesn't throw")
    func deleteAndDeleteAllRemoveSessions() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        let first = record(startedAt: 100, segments: [segment(text: "אחד")])
        let second = record(startedAt: 200, segments: [segment(text: "שתיים")])
        try store.save(first)
        try store.save(second)

        try store.delete(id: first.id)
        #expect(store.load(id: first.id) == nil)
        #expect(store.listSummaries().count == 1)

        try store.delete(id: UUID())

        try store.deleteAll()
        #expect(store.listSummaries().isEmpty)
    }

    @Test("exported text matches the exact expected line format")
    func exportTextFormatIsExact() {
        let withName = segment(text: "שלום", speakerName: "סבתא", startTimestamp: 3_661)
        let withoutName = segment(text: "מה נשמע", speakerName: nil, startTimestamp: 3_665)
        let session = record(startedAt: 3_661, segments: [withName, withoutName])

        let text = TranscriptHistoryStore.exportText(session)
        #expect(text == "[01:01:01] סבתא: שלום\n[01:01:05] מה נשמע")
    }

    @Test("make(from:) drops empty-text segments and resolves speaker names")
    func makeFromDropsEmptySegmentsAndResolvesNames() {
        let keptID = UUID()
        let droppedID = UUID()
        let unnamedID = UUID()
        let live: [TranscriptSegment] = [
            TranscriptSegment(
                id: keptID,
                text: "שלום סבתא",
                isCommitted: true,
                speakerClusterID: 0,
                startTimestamp: 10,
                lastUpdateTimestamp: 10
            ),
            TranscriptSegment(
                id: droppedID,
                text: "   ",
                isCommitted: false,
                speakerClusterID: nil,
                startTimestamp: 20,
                lastUpdateTimestamp: 20
            ),
            TranscriptSegment(
                id: unnamedID,
                text: "מי זה",
                isCommitted: false,
                speakerClusterID: 3,
                startTimestamp: 30,
                lastUpdateTimestamp: 30
            ),
        ]

        let record = TranscriptSessionRecord.make(
            from: live,
            speakerName: { segment in
                switch segment.speakerClusterID {
                case 0: return "סבתא"
                default: return nil
                }
            },
            id: UUID(),
            startedAt: 5,
            endedAt: nil,
            engine: .appleSpeech,
            modelVariant: nil,
            inputName: nil
        )

        #expect(record.segments.map(\.id) == [keptID, unnamedID])
        #expect(record.segments.first?.speakerName == "סבתא")
        #expect(record.segments.last?.speakerName == nil)
        #expect(record.segments.last?.speakerClusterID == 3)
    }

    @Test("a record missing segments, modelVariant, inputName, and endedAt still decodes with defaults")
    func tolerantDecodingOfOlderRecord() throws {
        let json = """
        {"id":"1E2B4D2A-6C5F-4F1B-9C3E-000000000001","startedAt":100,"engine":"whisperKit"}
        """
        let decoded = try JSONDecoder().decode(TranscriptSessionRecord.self, from: Data(json.utf8))

        #expect(decoded.startedAt == 100)
        #expect(decoded.engine == .whisperKit)
        #expect(decoded.endedAt == nil)
        #expect(decoded.modelVariant == nil)
        #expect(decoded.inputName == nil)
        #expect(decoded.segments.isEmpty)
    }

    @Test("total size on disk is positive after a save and zero once everything is deleted")
    func totalSizeOnDiskReflectsSavedFiles() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        #expect(store.totalSizeOnDisk() == 0)

        try store.save(record(startedAt: 100, segments: [segment(text: "בדיקה")]))
        #expect(store.totalSizeOnDisk() > 0)

        try store.deleteAll()
        #expect(store.totalSizeOnDisk() == 0)
    }

    @Test("export applies the caller's UTC offset so times read as local clock time")
    func exportUsesUTCOffset() {
        let record = TranscriptSessionRecord(
            startedAt: 0, engine: .whisperKit, modelVariant: nil, inputName: nil,
            segments: [SavedSegment(id: UUID(), text: "בוקר", speakerName: nil, speakerClusterID: nil, startTimestamp: 3_600, isCommitted: true)]
        )
        #expect(TranscriptHistoryStore.exportText(record) == "[01:00:00] בוקר")
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: 3 * 3_600) == "[04:00:00] בוקר")
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: -2 * 3_600) == "[23:00:00] בוקר")
    }

    @Test("the summary lists the real names that took part, once each, without generic labels")
    func summarySpeakerNames() {
        func line(_ name: String?) -> SavedSegment {
            SavedSegment(id: UUID(), text: "שלום", speakerName: name, speakerClusterID: nil, startTimestamp: 0, isCommitted: true)
        }
        let names = TranscriptSessionSummary.realNames(in: [
            line("דובר 2"), line("רותי"), line(nil), line("אבי"), line("רותי"),
            line("דובר לא ידוע"), line("Speaker 3"), line("Unknown speaker"), line("דובר חדש"),
        ])
        #expect(names == ["רותי", "אבי", "דובר חדש"])
    }
}

@Suite("Transcript history summary files")
struct TranscriptHistorySummaryCacheTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ozen-history-cache-\(UUID())")
    }

    private func record(id: UUID = UUID(), startedAt: TimeInterval, texts: [String]) -> TranscriptSessionRecord {
        TranscriptSessionRecord(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            engine: .whisperKit,
            modelVariant: "small",
            inputName: nil,
            segments: texts.map {
                SavedSegment(id: UUID(), text: $0, speakerName: nil, speakerClusterID: nil, startTimestamp: startedAt, isCommitted: true)
            }
        )
    }

    private func recordFile(_ dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    private func summaryFile(_ dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent(TranscriptHistoryStore.summariesFolderName).appendingPathComponent("\(id.uuidString).json")
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test("the list comes from the summary file, without reading the full conversation")
    func listUsesSummary() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let saved = record(startedAt: 100, texts: ["שלום סבתא", "מה שלומך"])
        try store.save(saved)
        #expect(FileManager.default.fileExists(atPath: summaryFile(dir, saved.id).path))

        // Unreadable conversation, older than its summary: only a list that
        // trusts the summary can still show it.
        try Data("not json".utf8).write(to: recordFile(dir, saved.id))
        try setModified(recordFile(dir, saved.id), Date(timeIntervalSince1970: 1_000))

        let listed = store.listSummaries()
        #expect(listed.count == 1)
        #expect(listed.first?.preview == "שלום סבתא")
        #expect(listed.first?.segmentCount == 2)
    }

    @Test("a conversation saved by an older build, with no summary, is listed and gets one")
    func missingSummaryIsRebuilt() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let old = record(startedAt: 50, texts: ["ישן"])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: recordFile(dir, old.id))

        #expect(store.listSummaries().map(\.id) == [old.id])
        #expect(FileManager.default.fileExists(atPath: summaryFile(dir, old.id).path))
    }

    @Test("a summary older than its conversation is rebuilt, not trusted")
    func staleSummaryIsRebuilt() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let id = UUID()
        try store.save(record(id: id, startedAt: 10, texts: ["אחת"]))

        // The conversation changed after its summary was written.
        try JSONEncoder().encode(record(id: id, startedAt: 10, texts: ["אחת", "שתיים", "שלוש"])).write(to: recordFile(dir, id))
        try setModified(summaryFile(dir, id), Date(timeIntervalSince1970: 1_000))
        try setModified(recordFile(dir, id), Date(timeIntervalSince1970: 2_000))

        #expect(store.listSummaries().first?.segmentCount == 3)
    }

    @Test("an unreadable summary is rebuilt from the conversation")
    func corruptSummaryIsRebuilt() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let saved = record(startedAt: 10, texts: ["טקסט"])
        try store.save(saved)
        try Data("{".utf8).write(to: summaryFile(dir, saved.id))

        #expect(store.listSummaries().first?.preview == "טקסט")
    }

    @Test("deleting a conversation removes its summary, so it can't reappear in the list")
    func deleteRemovesSummary() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let first = record(startedAt: 10, texts: ["א"])
        let second = record(startedAt: 20, texts: ["ב"])
        try store.save(first)
        try store.save(second)

        try store.delete(id: first.id)
        #expect(!FileManager.default.fileExists(atPath: summaryFile(dir, first.id).path))
        #expect(store.listSummaries().map(\.id) == [second.id])

        try store.deleteAll()
        #expect(store.listSummaries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptHistoryStore.summariesFolderName).path))
        #expect(store.totalSizeOnDisk() == 0)
    }
}

@Suite("Transcript history search files")
struct TranscriptHistorySearchCacheTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ozen-history-search-\(UUID())")
    }

    private func record(id: UUID = UUID(), startedAt: TimeInterval = 10, lines: [(String, String?)]) -> TranscriptSessionRecord {
        TranscriptSessionRecord(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            engine: .whisperKit,
            modelVariant: nil,
            inputName: nil,
            segments: lines.map {
                SavedSegment(id: UUID(), text: $0.0, speakerName: $0.1, speakerClusterID: nil, startTimestamp: startedAt, isCommitted: true)
            }
        )
    }

    private func recordFile(_ dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    private func searchFile(_ dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent(TranscriptHistoryStore.summariesFolderName).appendingPathComponent("\(id.uuidString).search-v1.txt")
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test("search answers from the prepared text, without reading the conversation")
    func searchUsesPreparedText() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let saved = record(lines: [("הלכנו לשוק", "שרה")])
        try store.save(saved)
        #expect(FileManager.default.fileExists(atPath: searchFile(dir, saved.id).path))

        try Data("not json".utf8).write(to: recordFile(dir, saved.id))
        try setModified(recordFile(dir, saved.id), Date(timeIntervalSince1970: 1_000))

        #expect(store.search("שוק").map(\.id) == [saved.id])
        #expect(store.search("שרה").map(\.id) == [saved.id])
        #expect(store.search("ים").isEmpty)
    }

    @Test("a conversation saved by an older build is searched in full and gets its text file")
    func olderConversationIsSearched() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let old = record(lines: [("שָׁלוֹם לכולם", nil)])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: recordFile(dir, old.id))

        #expect(store.search("שלום").map(\.id) == [old.id])
        #expect(FileManager.default.fileExists(atPath: searchFile(dir, old.id).path))
        // And the file it wrote answers the next search the same way.
        #expect(store.search("שלום").map(\.id) == [old.id])
        #expect(store.search("להתראות").isEmpty)
    }

    @Test("a text file older than its conversation is not trusted")
    func staleTextIsRebuilt() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let id = UUID()
        try store.save(record(id: id, lines: [("בוקר", nil)]))

        try JSONEncoder().encode(record(id: id, lines: [("בוקר", nil), ("ערב", nil)])).write(to: recordFile(dir, id))
        try setModified(searchFile(dir, id), Date(timeIntervalSince1970: 1_000))
        try setModified(recordFile(dir, id), Date(timeIntervalSince1970: 2_000))

        #expect(store.search("ערב").map(\.id) == [id])
    }

    @Test("a word split across two caption lines does not count as found")
    func noMatchAcrossLines() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        try store.save(record(lines: [("אבא", nil), ("בית", nil)]))

        #expect(store.search("אבא\nבית").isEmpty)
        #expect(store.search("אבית").isEmpty)
    }

    @Test("deleting a conversation removes its text file")
    func deleteRemovesText() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let saved = record(lines: [("משהו", nil)])
        try store.save(saved)
        try store.delete(id: saved.id)
        #expect(!FileManager.default.fileExists(atPath: searchFile(dir, saved.id).path))
    }
}

@Suite("Transcript history search matches inside a conversation")
struct TranscriptHistoryMatchingLinesTests {
    private func line(_ text: String, _ name: String? = nil) -> SavedSegment {
        SavedSegment(id: UUID(), text: text, speakerName: name, speakerClusterID: nil, startTimestamp: 0, isCommitted: true)
    }

    private func record(_ segments: [SavedSegment]) -> TranscriptSessionRecord {
        TranscriptSessionRecord(id: UUID(), startedAt: 0, endedAt: nil, engine: .whisperKit, modelVariant: nil, inputName: nil, segments: segments)
    }

    @Test("the lines a search found, in order, by words or by who said them")
    func matchingLines() {
        let lines = [
            line("הרופא אמר לקחת את התְּרוּפָה בבוקר", "דני"),
            line("טוב", "שרה"),
            line("ואת התרופה השנייה בערב", "דני"),
            line("Aspirin?", "רותי"),
        ]
        let conversation = record(lines)
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: " תרופה ") == [lines[0].id, lines[2].id])
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "שרה") == [lines[1].id])
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "ASPIRIN") == [lines[3].id])
    }

    @Test("an empty search, or one that matches nothing, finds no lines")
    func noLines() {
        let conversation = record([line("שלום")])
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "  ").isEmpty)
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "להתראות").isEmpty)
    }
}

@Suite("Transcript history starred lines")
struct TranscriptHistoryStarredTests {
    private func live(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), text: text, isCommitted: true, speakerClusterID: nil, startTimestamp: 3_600, lastUpdateTimestamp: 3_600)
    }

    @Test("starred lines are saved as starred, counted in the summary, and marked in shared text")
    func starredRoundTrip() throws {
        let lines = [live("שלום"), live("לקחת כדור אחד בבוקר"), live("ביי")]
        let record = TranscriptSessionRecord.make(
            from: lines,
            speakerName: { _ in nil },
            id: UUID(),
            startedAt: 3_600,
            endedAt: nil,
            engine: .whisperKit,
            modelVariant: nil,
            inputName: nil,
            starred: [lines[1].id]
        )
        #expect(record.segments.map(\.isStarred) == [false, true, false])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-stars-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        try store.save(record)
        #expect(store.load(id: record.id)?.segments.map(\.isStarred) == [false, true, false])
        #expect(store.listSummaries().first?.starredCount == 1)

        let text = TranscriptHistoryStore.exportText(record)
        #expect(text == "[01:00:00] שלום\n★ [01:00:00] לקחת כדור אחד בבוקר\n[01:00:00] ביי")
    }

    @Test("a line saved before stars existed loads as not starred")
    func olderLineDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"ישן","startTimestamp":1,"isCommitted":true}"#
        let line = try JSONDecoder().decode(SavedSegment.self, from: Data(json.utf8))
        #expect(line.isStarred == false)
        #expect(line.speakerName == nil)
    }

    @Test("a summary file from before stars were counted is rebuilt")
    func oldSummaryRebuilt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-stars-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let record = TranscriptSessionRecord(
            startedAt: 1, engine: .whisperKit, modelVariant: nil, inputName: nil,
            segments: [SavedSegment(id: UUID(), text: "חשוב", speakerName: nil, speakerClusterID: nil, startTimestamp: 1, isCommitted: true, isStarred: true)]
        )
        try store.save(record)
        // What a build with format 1 wrote: no starredCount at all.
        let summaryURL = dir.appendingPathComponent(TranscriptHistoryStore.summariesFolderName).appendingPathComponent("\(record.id.uuidString).json")
        let old = #"{"format":1,"summary":{"id":"\#(record.id.uuidString)","startedAt":1,"segmentCount":1,"preview":"חשוב","engine":"whisperKit","speakerNames":[]}}"#
        try Data(old.utf8).write(to: summaryURL)

        #expect(store.listSummaries().first?.starredCount == 1)
    }
}
