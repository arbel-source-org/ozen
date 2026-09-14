import Dispatch
import Foundation
import Testing
@testable import OzenKit

@Suite("History retention")
struct HistoryRetentionTests {
    private let day: TimeInterval = 86_400
    private let now: TimeInterval = 2_000_000_000

    private func makeStore() -> (TranscriptHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-retention-\(UUID())", isDirectory: true)
        return (TranscriptHistoryStore(directoryURL: dir), dir)
    }

    private func conversation(
        startedDaysAgo: Double,
        endedDaysAgo: Double?,
        starred: Bool = false,
        title: String? = nil,
        lastLineDaysAgo: Double? = nil,
        id: UUID = UUID()
    ) -> TranscriptSessionRecord {
        TranscriptSessionRecord(
            id: id,
            startedAt: now - startedDaysAgo * day,
            endedAt: endedDaysAgo.map { now - $0 * day },
            engine: .whisperKit,
            modelVariant: nil,
            inputName: nil,
            segments: [
                SavedSegment(id: UUID(), text: "שלום", speakerName: nil, speakerClusterID: nil, startTimestamp: now - startedDaysAgo * day, isCommitted: true, isStarred: starred),
            ] + (lastLineDaysAgo.map { [SavedSegment(id: UUID(), text: "להתראות", speakerName: nil, speakerClusterID: nil, startTimestamp: now - $0 * day, isCommitted: true)] } ?? []),
            title: title
        )
    }

    @Test("forever keeps everything; the others count back whole days")
    func cutoffs() {
        #expect(HistoryRetention.forever.cutoff(now: now) == nil)
        #expect(HistoryRetention.week.cutoff(now: now) == now - 7 * day)
        #expect(HistoryRetention.month.cutoff(now: now) == now - 30 * day)
        #expect(HistoryRetention.threeMonths.cutoff(now: now) == now - 90 * day)
        #expect(HistoryRetention.year.cutoff(now: now) == now - 365 * day)
    }

    @Test("old conversations go; recent ones, starred ones and named ones stay")
    func deletesOnlyExpired() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = conversation(startedDaysAgo: 40, endedDaysAgo: 40)
        let recent = conversation(startedDaysAgo: 3, endedDaysAgo: 3)
        let oldStarred = conversation(startedDaysAgo: 40, endedDaysAgo: 40, starred: true)
        let oldNamed = conversation(startedDaysAgo: 40, endedDaysAgo: 40, title: "יום הולדת")
        // Began long ago but went on until yesterday: judged by its end.
        let longRunning = conversation(startedDaysAgo: 40, endedDaysAgo: 1)
        // Never closed (the app was killed): judged by its newest line.
        let neverClosed = conversation(startedDaysAgo: 40, endedDaysAgo: nil)
        let neverClosedButTalkedYesterday = conversation(startedDaysAgo: 40, endedDaysAgo: nil, lastLineDaysAgo: 1)
        for record in [old, recent, oldStarred, oldNamed, longRunning, neverClosed, neverClosedButTalkedYesterday] {
            try store.save(record)
        }

        let deleted = store.deleteConversations(inactiveBefore: now - 30 * day)

        #expect(deleted == 2)
        let left = Set(store.listSummaries().map(\.id))
        #expect(left == [recent.id, oldStarred.id, oldNamed.id, longRunning.id, neverClosedButTalkedYesterday.id])
        #expect(store.load(id: old.id) == nil)
        #expect(store.search("שלום").count == 5)
    }

    @Test("the conversation still on screen is never deleted")
    func protectsLiveConversation() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = conversation(startedDaysAgo: 40, endedDaysAgo: nil)
        try store.save(live)

        #expect(store.deleteConversations(inactiveBefore: now - 30 * day, protecting: [live.id]) == 0)
        #expect(store.load(id: live.id) != nil)
    }

    @Test("the writer does nothing when set to keep forever, and prunes behind queued saves otherwise")
    func writerPrunes() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.retention")
        let writer = TranscriptHistoryWriter(store: store, queue: queue)
        let old = conversation(startedDaysAgo: 400, endedDaysAgo: 400)
        writer.saveNow(old)

        #expect(writer.deleteExpiredNow(retention: .forever, now: now, protecting: []) == 0)
        #expect(store.load(id: old.id) != nil)

        // An autosave of the same old conversation is still waiting to be
        // written; pruning must run after it, not before.
        queue.suspend()
        writer.saveInBackground(old)
        let pruned = DispatchSemaphore(value: 0)
        let count = LockedCount()
        DispatchQueue.global().async {
            count.set(writer.deleteExpiredNow(retention: .year, now: self.now, protecting: []))
            pruned.signal()
        }
        let returnedEarly = pruned.wait(timeout: .now() + .milliseconds(200)) == .success
        queue.resume()
        if !returnedEarly { pruned.wait() }
        writer.waitUntilIdle()

        #expect(returnedEarly == false)
        #expect(count.value == 1)
        #expect(store.listSummaries().isEmpty)
    }

    @Test("settings default to keeping forever, and an unknown choice from a newer build reads as forever")
    func settingDecoding() throws {
        #expect(AppSettings.default.historyRetention == .forever)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.historyRetention == .forever)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"historyRetention":"fortnight"}"#.utf8))
        #expect(unknown.historyRetention == .forever)

        var settings = AppSettings.default
        settings.historyRetention = .month
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTripped.historyRetention == .month)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = -1
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func set(_ newValue: Int) {
        lock.lock(); defer { lock.unlock() }
        stored = newValue
    }
}
