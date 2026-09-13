import Foundation
import Testing
@testable import OzenKit

@Suite("ConversationStats")
struct ConversationStatsTests {
    private func line(_ text: String, _ speaker: String?, at time: TimeInterval, cluster: Int? = nil) -> SavedSegment {
        SavedSegment(id: UUID(), text: text, speakerName: speaker, speakerClusterID: cluster, startTimestamp: time, isCommitted: true)
    }

    @Test("words are counted per speaker, Hebrew punctuation and niqqud don't make extra words")
    func wordCounts() {
        let stats = ConversationStats.compute(segments: [
            line("שָׁלוֹם, מה שלומך?", "רותי", at: 0),
            line("טוב, תודה!", "אבי", at: 5),
            line("ד״ר כהן התקשר", "רותי", at: 10),
        ])
        #expect(stats.totalWords == 8)
        #expect(stats.speakers.map(\.name) == ["רותי", "אבי"])
        #expect(stats.speakers.map(\.words) == [6, 2])
    }

    @Test("consecutive lines by one speaker are one turn")
    func turns() {
        let stats = ConversationStats.compute(segments: [
            line("אחת", "רותי", at: 0),
            line("שתיים", "רותי", at: 1),
            line("שלוש", "אבי", at: 2),
            line("ארבע", "רותי", at: 3),
            line("חמש", "רותי", at: 4),
        ])
        #expect(stats.totalTurns == 3)
        let ruti = stats.speakers.first { $0.name == "רותי" }
        #expect(ruti?.turns == 2)
        #expect(ruti?.words == 4)
    }

    @Test("the longest turn sums the words of its consecutive lines")
    func longestTurn() {
        let stats = ConversationStats.compute(segments: [
            line("שלום לכולם", "רותי", at: 0),
            line("אני רוצה לספר לכם משהו", "אבי", at: 1),
            line("זה קרה אתמול", "אבי", at: 2),
            line("באמת?", "רותי", at: 3),
        ])
        #expect(stats.longestTurn == LongestTurn(speakerName: "אבי", words: 8))
    }

    @Test("fractions add up to one and a missing name becomes the unknown speaker")
    func fractionsAndUnknown() {
        let stats = ConversationStats.compute(segments: [
            line("אחת שתיים שלוש", nil, at: 0),
            line("ארבע", "  ", at: 1),
            line("חמש שש שבע שמונה", "אבי", at: 2, cluster: 4),
        ])
        #expect(stats.speakers.map(\.name) == ["אבי", ConversationStats.unknownSpeakerName])
        let total = stats.speakers.map { stats.wordFraction(of: $0) }.reduce(0, +)
        #expect(abs(total - 1) < 0.0001)
        #expect(stats.speakers.first?.clusterID == 4)
    }

    @Test("ties in word count are ordered by name so the list doesn't jump around")
    func tieOrder() {
        let stats = ConversationStats.compute(segments: [
            line("אחת", "רותי", at: 0),
            line("אחת", "אבי", at: 1),
        ])
        #expect(stats.speakers.map(\.name) == ["אבי", "רותי"])
    }

    @Test("duration uses the recorded session span when there is one, else first to last line")
    func duration() {
        let segments = [line("א ב", "רותי", at: 100), line("ג ד", "אבי", at: 160)]
        let spanned = ConversationStats.compute(segments: segments, startedAt: 90, endedAt: 210)
        #expect(spanned.durationSeconds == 120)
        #expect(spanned.wordsPerMinute == 2)
        let fallback = ConversationStats.compute(segments: segments)
        #expect(fallback.durationSeconds == 60)
        #expect(fallback.wordsPerMinute == 4)
    }

    @Test("an empty conversation is all zeros, never a division by zero")
    func empty() {
        let stats = ConversationStats.compute(segments: [])
        #expect(stats.totalWords == 0)
        #expect(stats.totalTurns == 0)
        #expect(stats.durationSeconds == 0)
        #expect(stats.wordsPerMinute == 0)
        #expect(stats.speakers.isEmpty)
        #expect(stats.longestTurn == nil)
        #expect(stats.hebrewSummary == "פחות מדקה · אין מילים")
    }

    @Test("the Hebrew summary uses the special forms for one and two")
    func wording() {
        #expect(ConversationStats.minutesText(20) == "פחות מדקה")
        #expect(ConversationStats.minutesText(60) == "דקה אחת")
        #expect(ConversationStats.minutesText(125) == "שתי דקות")
        #expect(ConversationStats.minutesText(12 * 60) == "12 דקות")
        #expect(ConversationStats.speakersText(1) == "דובר אחד")
        #expect(ConversationStats.speakersText(2) == "שני דוברים")
        #expect(ConversationStats.speakersText(5) == "5 דוברים")
        #expect(ConversationStats.wordsText(1) == "מילה אחת")
        #expect(ConversationStats.wordsText(2) == "שתי מילים")
        #expect(ConversationStats.wordsText(840) == "840 מילים")

        let record = TranscriptSessionRecord(
            startedAt: 0, endedAt: 720, engine: .whisperKit, modelVariant: nil, inputName: nil,
            segments: [line("שלום לך", "רותי", at: 1), line("שלום", "אבי", at: 2)]
        )
        #expect(ConversationStats.compute(from: record).hebrewSummary == "12 דקות · שני דוברים · 3 מילים")
    }
}
