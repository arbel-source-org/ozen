import Testing
@testable import OzenKit

@Suite("ConversationBreak")
struct ConversationBreakTests {
    @Test("a conversation with nothing saved yet is never split")
    func empty() {
        #expect(ConversationBreak.shouldStartNew(lastCaptionAt: nil, now: 1_000_000) == false)
    }

    @Test("a pause in talking is still the same conversation")
    func shortPause() {
        #expect(ConversationBreak.shouldStartNew(lastCaptionAt: 1_000, now: 1_000 + 19 * 60) == false)
    }

    @Test("twenty quiet minutes start a new one")
    func longQuiet() {
        #expect(ConversationBreak.shouldStartNew(lastCaptionAt: 1_000, now: 1_000 + 20 * 60))
    }

    @Test("a conversation starts when listening began, unless its first line came a break's worth of quiet later")
    func conversationStart() {
        let night = 1_000_000.0
        #expect(ConversationBreak.start(listeningSince: night, firstLineAt: night + 5 * 60) == night)
        #expect(ConversationBreak.start(listeningSince: night, firstLineAt: night + 9.5 * 3_600) == night + 9.5 * 3_600)
        #expect(ConversationBreak.start(listeningSince: night, firstLineAt: 1) == night)
        #expect(ConversationBreak.start(listeningSince: night, firstLineAt: nil) == night)
        #expect(ConversationBreak.start(listeningSince: nil, firstLineAt: night) == night)
        #expect(ConversationBreak.start(listeningSince: nil, firstLineAt: nil) == nil)
    }
}
