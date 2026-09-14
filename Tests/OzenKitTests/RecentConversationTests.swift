import Foundation
import Testing
@testable import OzenKit

@Suite("Recent conversation")
struct RecentConversationTests {
    private let now: TimeInterval = 2_000_000_000

    private func summary(
        id: UUID = UUID(),
        startedMinutesAgo: Double,
        endedMinutesAgo: Double? = nil,
        lastLineMinutesAgo: Double? = nil,
        lines: Int = 3
    ) -> TranscriptSessionSummary {
        TranscriptSessionSummary(
            id: id,
            startedAt: now - startedMinutesAgo * 60,
            endedAt: endedMinutesAgo.map { now - $0 * 60 },
            segmentCount: lines,
            preview: "שלום",
            engine: .whisperKit,
            lastLineAt: lastLineMinutesAgo.map { now - $0 * 60 }
        )
    }

    @Test("a conversation cut off a few minutes ago is offered, judged by its last line")
    func cutOffMidConversation() {
        // Began 45 minutes ago, never closed, last line 3 minutes ago.
        let cutOff = summary(startedMinutesAgo: 45, lastLineMinutesAgo: 3)
        #expect(RecentConversation.resumable(in: [cutOff], now: now)?.id == cutOff.id)
        #expect(RecentConversation.minutesAgo(cutOff, now: now) == 3)
    }

    @Test("the newest one wins when several are recent")
    func newestWins() {
        let earlier = summary(startedMinutesAgo: 30, endedMinutesAgo: 15)
        let later = summary(startedMinutesAgo: 14, lastLineMinutesAgo: 2)
        #expect(RecentConversation.resumable(in: [later, earlier], now: now)?.id == later.id)
        #expect(RecentConversation.resumable(in: [earlier, later], now: now)?.id == later.id)
    }

    @Test("nothing is offered for an old conversation, an empty one, or the one already under way")
    func notOffered() {
        let old = summary(startedMinutesAgo: 90, endedMinutesAgo: 60)
        let empty = summary(startedMinutesAgo: 2, lastLineMinutesAgo: 1, lines: 0)
        let current = summary(startedMinutesAgo: 2, lastLineMinutesAgo: 1)
        #expect(RecentConversation.resumable(in: [old, empty], now: now) == nil)
        #expect(RecentConversation.resumable(in: [current], now: now, excluding: current.id) == nil)
        // Exactly at the break is already a new conversation.
        let atBreak = summary(startedMinutesAgo: 40, endedMinutesAgo: ConversationBreak.quietSeconds / 60)
        #expect(RecentConversation.resumable(in: [atBreak], now: now) == nil)
    }

    @Test("a conversation dated well into the future (a wrong clock) is not offered; a slightly early clock is fine")
    func futureDates() {
        let farFuture = summary(startedMinutesAgo: -60, lastLineMinutesAgo: -50)
        let slightlyAhead = summary(startedMinutesAgo: 5, lastLineMinutesAgo: -1)
        #expect(RecentConversation.resumable(in: [farFuture], now: now) == nil)
        #expect(RecentConversation.resumable(in: [slightlyAhead], now: now)?.id == slightlyAhead.id)
        #expect(RecentConversation.minutesAgo(slightlyAhead, now: now) == 1)
    }

    @Test("a saved summary carries when its newest line began, and old cached summaries are rebuilt to include it")
    func summaryKnowsLastLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-recent-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistoryStore(directoryURL: dir)
        let record = TranscriptSessionRecord(
            id: UUID(), startedAt: 100, endedAt: nil, engine: .whisperKit, modelVariant: nil, inputName: nil,
            segments: [
                SavedSegment(id: UUID(), text: "א", speakerName: nil, speakerClusterID: nil, startTimestamp: 100, isCommitted: true),
                SavedSegment(id: UUID(), text: "ב", speakerName: nil, speakerClusterID: nil, startTimestamp: 700, isCommitted: true),
            ]
        )
        try store.save(record)
        #expect(store.listSummaries().first?.lastLineAt == 700)
        #expect(store.listSummaries().first?.lastActiveAt == 700)

        // A summary cached by the previous build, without the field.
        let summaryFile = dir.appendingPathComponent("summaries", isDirectory: true)
            .appendingPathComponent("\(record.id.uuidString).json")
        let previous = #"{"format":3,"summary":{"id":"\#(record.id.uuidString)","startedAt":100,"segmentCount":2,"preview":"א","engine":"whisperKit","speakerNames":[],"starredCount":0}}"#
        try Data(previous.utf8).write(to: summaryFile)
        #expect(store.listSummaries().first?.lastLineAt == 700)
    }
}
