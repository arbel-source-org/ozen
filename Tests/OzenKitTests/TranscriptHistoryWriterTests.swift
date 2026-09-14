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
}
