import Dispatch
import Foundation
import Testing
@testable import OzenKit

@Suite("Transcript history writer")
struct TranscriptHistoryWriterTests {
    private func record(id: UUID, lines: Int, ended: Bool) -> TranscriptSessionRecord {
        TranscriptSessionRecord(
            id: id,
            startedAt: 100,
            endedAt: ended ? 200 : nil,
            engine: .whisperKit,
            modelVariant: nil,
            inputName: nil,
            segments: (0..<lines).map {
                SavedSegment(id: UUID(), text: "שורה \($0)", speakerName: nil, speakerClusterID: nil, startTimestamp: 100, isCommitted: true)
            }
        )
    }

    /// Runs `work` on another thread, so a call that wrongly blocks shows
    /// up as a failed expectation instead of hanging the whole test run.
    private func offThread(_ work: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            work()
            done.signal()
        }
        return done
    }

    private func makeStore() -> (TranscriptHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-writer-\(UUID())", isDirectory: true)
        return (TranscriptHistoryStore(directoryURL: dir), dir)
    }

    @Test("an autosave returns without waiting for the disk")
    func autosaveDoesNotBlock() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.writer")
        let writer = TranscriptHistoryWriter(store: store, queue: queue)

        queue.suspend()
        let returned = offThread { writer.saveInBackground(self.record(id: UUID(), lines: 1, ended: false)) }
        let returnedWhilePaused = returned.wait(timeout: .now() + .seconds(1)) == .success
        #expect(returnedWhilePaused)
        #expect(store.listSummaries().isEmpty)

        queue.resume()
        if !returnedWhilePaused { returned.wait() }
        writer.waitUntilIdle()
        #expect(store.listSummaries().count == 1)
    }

    @Test("an autosave says when it is done, by which time a failure is already known")
    func autosaveReportsWhenDone() async throws {
        // A plain file where the history folder should be: the save fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-writer-blocked-\(UUID())")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let writer = TranscriptHistoryWriter(store: TranscriptHistoryStore(directoryURL: blocker.appendingPathComponent("history", isDirectory: true)))

        let failureWhenDone: String? = await withCheckedContinuation { continuation in
            writer.saveInBackground(record(id: UUID(), lines: 1, ended: false)) {
                continuation.resume(returning: writer.lastFailure)
            }
        }
        #expect(failureWhenDone != nil)
    }

    @Test("a rename waits for autosaves already queued, so the name ends up on the newest copy")
    func renameQueuesBehindAutosave() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.writer")
        let writer = TranscriptHistoryWriter(store: store, queue: queue)
        let id = UUID()
        writer.saveNow(record(id: id, lines: 1, ended: false))

        queue.suspend()
        let autosaved = offThread { writer.saveInBackground(self.record(id: id, lines: 4, ended: false)) }
        let autosaveReturned = autosaved.wait(timeout: .now() + .seconds(1)) == .success
        let renamed = offThread { writer.renameNow(id: id, title: "ארוחת ערב") }
        let renameReturnedEarly = renamed.wait(timeout: .now() + .milliseconds(200)) == .success
        queue.resume()
        if !autosaveReturned { autosaved.wait() }
        if !renameReturnedEarly { renamed.wait() }
        writer.waitUntilIdle()

        #expect(renameReturnedEarly == false)
        #expect(store.load(id: id)?.title == "ארוחת ערב")
        #expect(store.load(id: id)?.segments.count == 4)
    }

    @Test("a save made now lands after an autosave that was still waiting, never under it")
    func saveNowWinsOverPendingAutosave() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.writer")
        let writer = TranscriptHistoryWriter(store: store, queue: queue)
        let id = UUID()

        queue.suspend()
        let autosaved = offThread { writer.saveInBackground(self.record(id: id, lines: 1, ended: false)) }
        let autosaveReturned = autosaved.wait(timeout: .now() + .seconds(1)) == .success
        let saved = offThread { writer.saveNow(self.record(id: id, lines: 3, ended: true)) }
        // A correct writer is stuck behind the paused autosave here; one
        // that skips the queue has already written and returned.
        let saveReturnedEarly = saved.wait(timeout: .now() + .milliseconds(200)) == .success
        queue.resume()
        if !autosaveReturned { autosaved.wait() }
        if !saveReturnedEarly { saved.wait() }
        writer.waitUntilIdle()

        let summary = store.listSummaries().first
        #expect(summary?.segmentCount == 3)
        #expect(summary?.endedAt == 200)
    }

    private func summaryFile(_ dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent(TranscriptHistoryStore.summariesFolderName).appendingPathComponent("\(id.uuidString).json")
    }

    @Test("a save made now skips the summary and search-text files an autosave would have written")
    func saveNowSkipsSearchCaches() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TranscriptHistoryWriter(store: store)

        let now = record(id: UUID(), lines: 1, ended: true)
        writer.saveNow(now)
        #expect(!FileManager.default.fileExists(atPath: summaryFile(dir, now.id).path))
        // The conversation itself is still there and lists correctly --
        // only the cache files are skipped.
        #expect(store.listSummaries().map(\.id) == [now.id])

        let autosaved = record(id: UUID(), lines: 1, ended: false)
        writer.saveInBackground(autosaved)
        writer.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: summaryFile(dir, autosaved.id).path))
    }

    @Test("a delete waits for an autosave of the same conversation, so the autosave can't bring it back")
    func deleteQueuesBehindAutosave() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.writer")
        let writer = TranscriptHistoryWriter(store: store, queue: queue)
        let id = UUID()
        writer.saveNow(record(id: id, lines: 1, ended: false))

        queue.suspend()
        let autosaved = offThread { writer.saveInBackground(self.record(id: id, lines: 2, ended: false)) }
        let autosaveReturned = autosaved.wait(timeout: .now() + .seconds(1)) == .success
        let deleted = offThread { try? writer.deleteNow(id: id) }
        let deleteReturnedEarly = deleted.wait(timeout: .now() + .milliseconds(200)) == .success
        queue.resume()
        if !autosaveReturned { autosaved.wait() }
        if !deleteReturnedEarly { deleted.wait() }
        writer.waitUntilIdle()

        #expect(deleteReturnedEarly == false)
        #expect(store.load(id: id) == nil)
        #expect(store.listSummaries().isEmpty)
    }

    @Test("delete all waits for queued autosaves too")
    func deleteAllQueuesBehindAutosave() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.writer")
        let writer = TranscriptHistoryWriter(store: store, queue: queue)
        writer.saveNow(record(id: UUID(), lines: 1, ended: true))

        queue.suspend()
        let autosaved = offThread { writer.saveInBackground(self.record(id: UUID(), lines: 2, ended: false)) }
        let autosaveReturned = autosaved.wait(timeout: .now() + .seconds(1)) == .success
        let deleted = offThread { try? writer.deleteAllNow() }
        let deleteReturnedEarly = deleted.wait(timeout: .now() + .milliseconds(200)) == .success
        queue.resume()
        if !autosaveReturned { autosaved.wait() }
        if !deleteReturnedEarly { deleted.wait() }
        writer.waitUntilIdle()

        #expect(deleteReturnedEarly == false)
        #expect(store.listSummaries().isEmpty)
    }

    private func removeRecordFiles(in dir: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    @Test("an autosave with nothing new since the last write leaves the disk alone; a new line is written")
    func unchangedAutosaveIsSkipped() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TranscriptHistoryWriter(store: store)
        let id = UUID()
        let quiet = record(id: id, lines: 2, ended: false)
        writer.saveInBackground(quiet)
        writer.waitUntilIdle()
        #expect(store.load(id: id) == quiet)

        // Removed behind the writer's back: only a write brings it back.
        try removeRecordFiles(in: dir)
        writer.saveInBackground(quiet)
        writer.waitUntilIdle()
        #expect(store.load(id: id) == nil)

        var grown = quiet
        grown.segments.append(SavedSegment(id: UUID(), text: "עוד שורה", speakerName: nil, speakerClusterID: nil, startTimestamp: 150, isCommitted: true))
        writer.saveInBackground(grown)
        writer.waitUntilIdle()
        #expect(store.load(id: id) == grown)
    }

    @Test("after a failed write, a delete or a rename, the same conversation is written again")
    func unchangedAutosaveWrittenAfterTrouble() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TranscriptHistoryWriter(store: store)
        let conversation = record(id: UUID(), lines: 1, ended: false)

        writer.saveNow(conversation)
        try FileManager.default.removeItem(at: dir)
        try Data("not a folder".utf8).write(to: dir)
        writer.saveNow(conversation)
        #expect(writer.lastFailure != nil)
        try FileManager.default.removeItem(at: dir)
        writer.saveInBackground(conversation)
        writer.waitUntilIdle()
        #expect(store.load(id: conversation.id) == conversation)
        #expect(writer.lastFailure == nil)

        try writer.deleteNow(id: conversation.id)
        writer.saveInBackground(conversation)
        writer.waitUntilIdle()
        #expect(store.load(id: conversation.id) == conversation)

        writer.renameNow(id: conversation.id, title: "ביקור")
        try removeRecordFiles(in: dir)
        writer.saveInBackground(conversation)
        writer.waitUntilIdle()
        #expect(store.load(id: conversation.id) != nil)
    }

    @Test("a line starred after the conversation ended is saved, counted, and keeps the conversation from being cleared out")
    func starAfterwards() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TranscriptHistoryWriter(store: store, queue: DispatchQueue(label: "test.star"))
        let conversation = record(id: UUID(), lines: 3, ended: true)
        writer.saveInBackground(conversation)
        writer.waitUntilIdle()
        let line = conversation.segments[1].id

        #expect(writer.toggleStarNow(sessionID: conversation.id, segmentID: line) == true)
        #expect(store.load(id: conversation.id)?.segments.map(\.isStarred) == [false, true, false])
        let summary = try #require(store.listSummaries().first { $0.id == conversation.id })
        #expect(summary.starredCount == 1)
        #expect(summary.isKeptByChoice)

        writer.saveInBackground(conversation)
        writer.waitUntilIdle()
        #expect(store.load(id: conversation.id)?.segments.map(\.isStarred) == [false, false, false])
        #expect(writer.toggleStarNow(sessionID: conversation.id, segmentID: line) == true)
        #expect(writer.toggleStarNow(sessionID: conversation.id, segmentID: line) == false)
        #expect(try #require(store.listSummaries().first { $0.id == conversation.id }).starredCount == 0)
        #expect(writer.toggleStarNow(sessionID: conversation.id, segmentID: UUID()) == nil)
        #expect(writer.toggleStarNow(sessionID: UUID(), segmentID: line) == nil)
    }

    @Test("a save that can't reach the disk is reported, and the next one that does clears it")
    func saveFailureIsReported() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-writer-fail-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // A file where the history folder should be: every save fails, the
        // way it would on a phone with no room left.
        let blocked = base.appendingPathComponent("history")
        try Data("not a folder".utf8).write(to: blocked)
        let failing = TranscriptHistoryWriter(store: TranscriptHistoryStore(directoryURL: blocked), queue: DispatchQueue(label: "test.fail"))

        #expect(failing.lastFailure == nil)
        failing.saveInBackground(record(id: UUID(), lines: 1, ended: false))
        failing.waitUntilIdle()
        #expect(failing.lastFailure != nil)

        // The folder becomes usable again (room was freed): the next save
        // works and the problem is no longer reported.
        try FileManager.default.removeItem(at: blocked)
        failing.saveNow(record(id: UUID(), lines: 1, ended: false))
        #expect(failing.lastFailure == nil)
    }
}
