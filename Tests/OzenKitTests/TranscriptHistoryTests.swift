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

    @Test("a search of several words finds a conversation holding all of them, in any order, on any line or in a name")
    func searchMatchesEveryWord() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        try store.save(record(startedAt: 100, segments: [segment(text: "הרופא אמר"), segment(text: "שני כדורים ביום", speakerName: "דני")]))
        try store.save(record(startedAt: 200, segments: [segment(text: "כדורים של שוקולד")]))

        #expect(store.search("רופא כדורים").count == 1)
        #expect(store.search("כדורים   רופא").count == 1)
        #expect(store.search("דני רופא").count == 1)
        #expect(store.search("כדורים").count == 2)
        #expect(store.search("רופא שוקולד").isEmpty)
    }

    @Test("a search word typed with the article also finds it with another prefix or none, but a short name is not cut down")
    func searchLooksPastTheArticle() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)

        try store.save(record(startedAt: 100, segments: [segment(text: "צריך ללכת לרופא מחר")]))
        try store.save(record(startedAt: 200, segments: [segment(text: "רופא שיניים")]))
        try store.save(record(startedAt: 300, segments: [segment(text: "פרדס גדול")]))

        #expect(store.search("הרופא").count == 2)
        #expect(store.search("הרופא מחר").count == 1)
        #expect(store.search("הדס").isEmpty)

        let loaded = try #require(store.load(id: store.search("מחר")[0].id))
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: loaded, query: "הרופא") == loaded.segments.map(\.id))
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
        #expect(text == "שיחה מתאריך 01.01.1970\n\n[01:01:01] סבתא: שלום\n[01:01:05] מה נשמע")
    }

    @Test("the export heading and numbers block are in English when the app is")
    func exportTextEnglishHeading() {
        Localization.$override.withValue(.english) {
            let untitled = record(startedAt: 3_661, segments: [segment(text: "שלום", startTimestamp: 3_661)])
            #expect(TranscriptHistoryStore.exportText(untitled).hasPrefix("Conversation from 01.01.1970"))

            var segments = (0..<19).map { index in
                segment(text: "line", startTimestamp: 3_600 + TimeInterval(index))
            }
            segments[3] = segment(text: "10:30", speakerName: "doctor", startTimestamp: 3_603)
            segments.append(segment(text: "thanks", startTimestamp: 3_619))
            let long = TranscriptHistoryStore.exportText(record(startedAt: 3_600, segments: segments))
            #expect(long.contains("Numbers mentioned:"))
            #expect(long.contains("The conversation:"))
        }
    }

    @Test("a long conversation shared as text opens with its lines that had numbers; a short one doesn't")
    func exportTextNumbersBlock() {
        var segments = (0..<19).map { index in
            segment(text: "משפט רגיל", speakerName: nil, startTimestamp: 3_600 + TimeInterval(index))
        }
        segments[3] = segment(text: "התור ב-10:30", speakerName: "רופא", startTimestamp: 3_603)
        segments[7] = segment(text: "שלושה כדורים ביום", speakerName: nil, startTimestamp: 3_607)
        segments[9] = segment(text: "רק פעם אחת", speakerName: nil, startTimestamp: 3_609)

        let short = TranscriptHistoryStore.exportText(record(startedAt: 3_600, segments: segments))
        #expect(short.contains("מספרים שנאמרו") == false)

        segments.append(segment(text: "תודה", speakerName: nil, startTimestamp: 3_619))
        let long = TranscriptHistoryStore.exportText(record(startedAt: 3_600, segments: segments))
        #expect(long.hasPrefix("שיחה מתאריך 01.01.1970\n\nמספרים שנאמרו:\n[01:00:03] רופא: התור ב-10:30\n[01:00:07] שלושה כדורים ביום\n\nהשיחה:\n[01:00:00] משפט רגיל\n"))
        #expect(long.hasSuffix("[01:00:19] תודה"))
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
        #expect(TranscriptHistoryStore.exportText(record) == "שיחה מתאריך 01.01.1970\n\n[01:00:00] בוקר")
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: 3 * 3_600) == "שיחה מתאריך 01.01.1970\n\n[04:00:00] בוקר")
        // West of Greenwich, a conversation that started at midnight UTC
        // was still on the previous day.
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: -2 * 3_600) == "שיחה מתאריך 31.12.1969\n\n[23:00:00] בוקר")
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

    @Test("a placeholder saved while the app was in one language is still generic after switching to the other")
    func genericLabelSurvivesALanguageSwitch() {
        // SavedSegment.speakerName is a permanent snapshot: a session
        // recorded in Hebrew keeps "דובר לא ידוע" even after the app's
        // language later changes to English, at which point
        // EmbeddingClusterer.unknownSpeakerName itself evaluates to
        // "Unknown speaker" instead.
        Localization.$override.withValue(.english) {
            #expect(TranscriptSessionSummary.isGenericLabel("דובר לא ידוע"))
        }
        Localization.$override.withValue(.hebrew) {
            #expect(TranscriptSessionSummary.isGenericLabel("Unknown speaker"))
        }
    }

    @Test("top speaker names rank by how many sessions they appeared in, ties broken alphabetically")
    func topSpeakerNamesRanking() {
        func summary(_ names: [String]) -> TranscriptSessionSummary {
            TranscriptSessionSummary(id: UUID(), startedAt: 0, endedAt: nil, segmentCount: 1, preview: "", engine: .whisperKit, speakerNames: names)
        }
        let names = TranscriptSessionSummary.topSpeakerNames(in: [
            summary(["רותי", "אבי"]),
            summary(["רותי"]),
            summary(["רותי", "דנה"]),
            summary(["דנה"]),
        ])
        #expect(names == ["רותי", "דנה", "אבי"])
    }

    @Test("top speaker names counts a name once per session, however many times it repeats in speakerNames")
    func topSpeakerNamesDedupesWithinSession() {
        func summary(_ names: [String]) -> TranscriptSessionSummary {
            TranscriptSessionSummary(id: UUID(), startedAt: 0, endedAt: nil, segmentCount: 1, preview: "", engine: .whisperKit, speakerNames: names)
        }
        // "רותי" repeats within one session but should still only count once
        // against that session, not three times.
        let names = TranscriptSessionSummary.topSpeakerNames(in: [summary(["רותי", "רותי", "אבי"]), summary(["אבי"])])
        #expect(names == ["אבי", "רותי"])
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

        #expect(store.search("לכולם שלום").map(\.id) == [old.id])
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

    @Test("a word split across two caption lines does not count as found; two words on two lines do")
    func noMatchAcrossLines() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        try store.save(record(lines: [("אבא", nil), ("בית", nil)]))

        #expect(store.search("אבית").isEmpty)
        #expect(store.search("אבאבית").isEmpty)
        #expect(store.search("אבא\nבית").count == 1)
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

    @Test("with several words, the lines holding all of them; when no line does, the lines holding any")
    func matchingLinesForSeveralWords() {
        let lines = [
            line("הרופא אמר לקחת את התרופה בבוקר", "דני"),
            line("טוב", "שרה"),
            line("ואת התרופה השנייה בערב", "דני"),
        ]
        let conversation = record(lines)
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "בבוקר תרופה") == [lines[0].id])
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "דני ערב") == [lines[2].id])
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "רופא ערב") == [lines[0].id, lines[2].id])
        #expect(TranscriptHistoryStore.matchingSegmentIDs(in: conversation, query: "רופא ים") == [lines[0].id])
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
        #expect(text == "שיחה מתאריך 01.01.1970\n\n[01:00:00] שלום\n★ [01:00:00] לקחת כדור אחד בבוקר\n[01:00:00] ביי")
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

@Suite("Transcript history starred lines across conversations")
struct TranscriptHistoryAllStarredTests {
    private func line(_ text: String, starred: Bool) -> SavedSegment {
        SavedSegment(id: UUID(), text: text, speakerName: nil, speakerClusterID: nil, startTimestamp: 0, isCommitted: true, isStarred: starred)
    }

    @Test("starred lines come newest conversation first, in spoken order, and unstarred conversations are left out")
    func allStarred() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-all-stars-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let morning = TranscriptSessionRecord(startedAt: 100, engine: .whisperKit, modelVariant: nil, inputName: nil,
                                              segments: [line("כדור בבוקר", starred: true), line("טוב", starred: false), line("ובערב שניים", starred: true)])
        let evening = TranscriptSessionRecord(startedAt: 900, engine: .whisperKit, modelVariant: nil, inputName: nil,
                                              segments: [line("התור ביום שלישי", starred: true)])
        let chat = TranscriptSessionRecord(startedAt: 500, engine: .whisperKit, modelVariant: nil, inputName: nil,
                                           segments: [line("מה נשמע", starred: false)])
        for record in [morning, evening, chat] { try store.save(record) }

        let starred = store.starredLines()
        #expect(starred.map(\.segment.text) == ["התור ביום שלישי", "כדור בבוקר", "ובערב שניים"])
        #expect(starred.map(\.sessionID) == [evening.id, morning.id, morning.id])
        #expect(starred.first?.sessionStartedAt == 900)
    }

    @Test("no stars anywhere gives an empty list")
    func none() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-no-stars-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        try store.save(TranscriptSessionRecord(startedAt: 1, engine: .whisperKit, modelVariant: nil, inputName: nil, segments: [line("שלום", starred: false)]))
        #expect(store.starredLines().isEmpty)
    }
}

@Suite("Transcript history sharing starred lines")
struct TranscriptHistoryStarredExportTests {
    @Test("starred lines share as dated blocks with times and real names only")
    func exportFormat() {
        let first = UUID()
        let second = UUID()
        // 2026-09-14 09:05:00 UTC and 2025-02-28 23:30:00 UTC.
        let september: TimeInterval = 1_789_376_700
        let february: TimeInterval = 1_740_785_400
        let lines = [
            StarredLine(sessionID: first, sessionStartedAt: september, segment: SavedSegment(id: UUID(), text: "כדור בבוקר", speakerName: "ד״ר כהן", speakerClusterID: 0, startTimestamp: september, isCommitted: true, isStarred: true)),
            StarredLine(sessionID: first, sessionStartedAt: september, segment: SavedSegment(id: UUID(), text: "ושניים בערב", speakerName: "דובר 2", speakerClusterID: 1, startTimestamp: september + 65, isCommitted: true, isStarred: true)),
            StarredLine(sessionID: second, sessionStartedAt: february, segment: SavedSegment(id: UUID(), text: "התור ביום שלישי", speakerName: nil, speakerClusterID: nil, startTimestamp: february, isCommitted: true, isStarred: true)),
        ]
        let text = TranscriptHistoryStore.exportStarredText(lines)
        #expect(text == "14.09.2026\n[09:05:00] ד״ר כהן: כדור בבוקר\n[09:06:05] ושניים בערב\n\n28.02.2025\n[23:30:00] התור ביום שלישי")
    }

    @Test("the date follows the phone's time zone across midnight")
    func dateUsesOffset() {
        let lateUTC: TimeInterval = 1_740_785_400 // 2025-02-28 23:30 UTC
        let line = StarredLine(sessionID: UUID(), sessionStartedAt: lateUTC, segment: SavedSegment(id: UUID(), text: "א", speakerName: nil, speakerClusterID: nil, startTimestamp: lateUTC, isCommitted: true, isStarred: true))
        #expect(TranscriptHistoryStore.exportStarredText([line], utcOffsetSeconds: 2 * 3_600) == "01.03.2025\n[01:30:00] א")
        #expect(TranscriptHistoryStore.exportStarredText([]) == "")
        let leapDay: TimeInterval = 1_709_208_000 // 2024-02-29 12:00 UTC
        let leap = StarredLine(sessionID: UUID(), sessionStartedAt: leapDay, segment: SavedSegment(id: UUID(), text: "ב", speakerName: nil, speakerClusterID: nil, startTimestamp: leapDay, isCommitted: true, isStarred: true))
        #expect(TranscriptHistoryStore.exportStarredText([leap]) == "29.02.2024\n[12:00:00] ב")
    }

    @Test("a starred line opening with an English word gets a right-to-left mark when shared")
    func starredRightToLeft() {
        let line = StarredLine(sessionID: UUID(), sessionStartedAt: 0, segment: SavedSegment(id: UUID(), text: "OK, מחר", speakerName: nil, speakerClusterID: nil, startTimestamp: 0, isCommitted: true, isStarred: true))
        #expect(TranscriptHistoryStore.exportStarredText([line]) == "01.01.1970\n\u{200F}[00:00:00] OK, מחר")
    }
}

@Suite("Transcript history conversation names")
struct TranscriptHistoryTitleTests {
    private func makeStore() -> (TranscriptHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-titles-\(UUID())")
        return (TranscriptHistoryStore(directoryURL: dir), dir)
    }

    private func record(id: UUID, lines: [String]) -> TranscriptSessionRecord {
        TranscriptSessionRecord(
            id: id, startedAt: 10, engine: .whisperKit, modelVariant: nil, inputName: nil,
            segments: lines.map { SavedSegment(id: UUID(), text: $0, speakerName: nil, speakerClusterID: nil, startTimestamp: 10, isCommitted: true) }
        )
    }

    @Test("a named conversation shows its name in the list and is found by it")
    func renameAndSearch() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try store.save(record(id: id, lines: ["שלום"]))

        try store.rename(id: id, title: "  ביקור אצל הרופא ")
        #expect(store.load(id: id)?.title == "ביקור אצל הרופא")
        #expect(store.listSummaries().first?.title == "ביקור אצל הרופא")
        #expect(store.search("רופא").map(\.id) == [id])
    }

    @Test("without the prepared search files (a copy restored from a backup) a conversation is still found by its name, and they are made again")
    func nameFoundWithoutSearchFiles() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try store.save(record(id: id, lines: ["שלום"]))
        try store.rename(id: id, title: "ביקור אצל הרופא")
        let prepared = dir.appendingPathComponent(TranscriptHistoryStore.summariesFolderName, isDirectory: true)
        try FileManager.default.removeItem(at: prepared)

        #expect(store.search("רופא").map(\.id) == [id])
        #expect(store.search("סבתא").isEmpty)
        let remade = try FileManager.default.contentsOfDirectory(atPath: prepared.path)
        #expect(remade.contains { $0.hasSuffix(".search-v1.txt") })
        #expect(store.search("רופא").map(\.id) == [id])
    }

    @Test("autosaving a live conversation keeps the name given to it meanwhile")
    func autosaveKeepsName() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try store.save(record(id: id, lines: ["שלום"]))
        try store.rename(id: id, title: "ארוחת שישי")

        // The live transcript has grown and knows nothing about the name.
        try store.save(record(id: id, lines: ["שלום", "מה נשמע"]))

        #expect(store.load(id: id)?.title == "ארוחת שישי")
        #expect(store.load(id: id)?.segments.count == 2)
        #expect(store.listSummaries().first?.title == "ארוחת שישי")
        #expect(store.search("שישי").map(\.id) == [id])
    }

    @Test("an empty name removes it, and a later autosave doesn't bring it back")
    func clearName() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try store.save(record(id: id, lines: ["שלום"]))
        try store.rename(id: id, title: "זמני")
        try store.rename(id: id, title: "   ")
        try store.save(record(id: id, lines: ["שלום", "עוד"]))

        #expect(store.load(id: id)?.title == nil)
        #expect(store.listSummaries().first?.title == nil)
        #expect(store.search("זמני").isEmpty)
    }

    @Test("a conversation saved before names existed loads without one")
    func olderRecord() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startedAt":1,"engine":"whisperKit","segments":[]}"#
        #expect(try JSONDecoder().decode(TranscriptSessionRecord.self, from: Data(json.utf8)).title == nil)
    }
}

@Suite("Transcript history sharing a named conversation")
struct TranscriptHistoryTitledExportTests {
    @Test("shared text starts with the conversation's name, if any, and its date")
    func titled() {
        // 14 September 2026, 07:30 in Israel (UTC+3).
        let startedAt: TimeInterval = 1_789_360_200
        let line = SavedSegment(id: UUID(), text: "כדור בבוקר", speakerName: nil, speakerClusterID: nil, startTimestamp: startedAt, isCommitted: true)
        var record = TranscriptSessionRecord(startedAt: startedAt, engine: .whisperKit, modelVariant: nil, inputName: nil, segments: [line])
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: 3 * 3_600) == "שיחה מתאריך 14.09.2026\n\n[07:30:00] כדור בבוקר")
        record.title = "ביקור אצל הרופא"
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: 3 * 3_600) == "ביקור אצל הרופא, 14.09.2026\n\n[07:30:00] כדור בבוקר")
        record.title = ""
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: 3 * 3_600) == "שיחה מתאריך 14.09.2026\n\n[07:30:00] כדור בבוקר")
        record.segments = []
        #expect(TranscriptHistoryStore.exportText(record, utcOffsetSeconds: 3 * 3_600) == "שיחה מתאריך 14.09.2026")
    }

    @Test("a shared line opening with an English word gets a right-to-left mark, Hebrew lines don't")
    func rightToLeftLines() {
        let english = SavedSegment(id: UUID(), text: "OK, נתראה מחר", speakerName: nil, speakerClusterID: nil, startTimestamp: 0, isCommitted: true)
        let named = SavedSegment(id: UUID(), text: "OK, נתראה מחר", speakerName: "דנה", speakerClusterID: nil, startTimestamp: 0, isCommitted: true)
        let record = TranscriptSessionRecord(startedAt: 0, engine: .whisperKit, modelVariant: nil, inputName: nil, segments: [english, named])
        #expect(TranscriptHistoryStore.exportText(record) == "שיחה מתאריך 01.01.1970\n\n\u{200F}[00:00:00] OK, נתראה מחר\n[00:00:00] דנה: OK, נתראה מחר")
    }
}

@Suite("A conversation's length in the history list")
struct ConversationLengthTests {
    @Test("a conversation cut off when the app closed is as long as its last line, not unknown")
    func cutOffConversation() {
        let summary = TranscriptSessionSummary(id: UUID(), startedAt: 1_000, endedAt: nil, segmentCount: 3, preview: "", engine: .whisperKit, lastLineAt: 1_600)
        #expect(summary.durationSeconds == 600)
    }

    @Test("a closed conversation still ends where it was closed")
    func closedConversation() {
        let summary = TranscriptSessionSummary(id: UUID(), startedAt: 1_000, endedAt: 1_900, segmentCount: 3, preview: "", engine: .whisperKit, lastLineAt: 1_600)
        #expect(summary.durationSeconds == 900)
    }

    @Test("with no lines and no end there is still nothing to show")
    func nothingToMeasure() {
        let summary = TranscriptSessionSummary(id: UUID(), startedAt: 1_000, endedAt: nil, segmentCount: 0, preview: "", engine: .whisperKit)
        #expect(summary.durationSeconds == nil)
    }
}
