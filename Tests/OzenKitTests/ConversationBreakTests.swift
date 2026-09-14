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
}
