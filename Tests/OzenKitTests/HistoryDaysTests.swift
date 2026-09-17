import Foundation
import Testing
@testable import OzenKit

@Suite("History grouped by day")
struct HistoryDaysTests {
    private let israel = 3 * 3_600
    private let mondayNoonUTC: TimeInterval = 1_789_387_200

    private func summary(_ startedAt: TimeInterval, preview: String = "שלום") -> TranscriptSessionSummary {
        TranscriptSessionSummary(id: UUID(), startedAt: startedAt, endedAt: nil, segmentCount: 1, preview: preview, engine: .whisperKit)
    }

    @Test("today, yesterday, a weekday within the week, then the weekday with the date, and the year only when it isn't this one")
    func titles() {
        let today = CivilDate.localDay(of: mondayNoonUTC, utcOffsetSeconds: israel)
        #expect(CivilDate(daysSinceEpoch: today) == CivilDate(year: 2026, month: 9, day: 14))
        #expect(HistoryDays.title(day: today, today: today) == "היום")
        #expect(HistoryDays.title(day: today - 1, today: today) == "אתמול")
        #expect(HistoryDays.title(day: today - 2, today: today) == "יום שבת")
        #expect(HistoryDays.title(day: today - 6, today: today) == "יום שלישי")
        #expect(HistoryDays.title(day: today - 7, today: today) == "יום שני, 7 בספטמבר")
        #expect(HistoryDays.title(day: today - 258, today: today) == "יום שלישי, 30 בדצמבר 2025")
        #expect(HistoryDays.title(day: today + 1, today: today) == "יום שלישי, 15 בספטמבר")
        let lateSundayUTC = mondayNoonUTC - 13.5 * 3_600
        #expect(HistoryDays.title(of: lateSundayUTC, now: mondayNoonUTC, utcOffsetSeconds: { _ in israel }) == "היום")
        #expect(HistoryDays.title(of: lateSundayUTC, now: mondayNoonUTC, utcOffsetSeconds: { _ in 0 }) == "אתמול")
    }

    @Test("conversations keep their order under their local day, even when a day comes round again out of order")
    func grouping() {
        let hour: TimeInterval = 3_600
        let late = summary(mondayNoonUTC - 2 * hour, preview: "late")
        let early = summary(mondayNoonUTC - 8 * hour, preview: "early")
        let lastNight = summary(mondayNoonUTC - 12 * hour, preview: "last night")
        let beforeMidnightUTC = summary(mondayNoonUTC - 13.5 * hour, preview: "after local midnight")
        let yesterday = summary(mondayNoonUTC - 20 * hour, preview: "yesterday")
        let days = HistoryDays.grouped(
            [late, early, lastNight, yesterday, beforeMidnightUTC],
            now: mondayNoonUTC,
            utcOffsetSeconds: { _ in israel }
        )
        #expect(days.map(\.title) == ["היום", "אתמול"])
        #expect(days.first?.sessions.map(\.preview) == ["late", "early", "last night", "after local midnight"])
        #expect(days.last?.sessions.map(\.preview) == ["yesterday"])
        #expect(Set(days.map(\.id)).count == 2)
    }

    @Test("each conversation's day is taken at its own offset from UTC, so a clock change doesn't move it")
    func offsetPerConversation() {
        let yesterdayLate = summary(mondayNoonUTC - 14 * 3_600 - 1_800)
        let days = HistoryDays.grouped([yesterdayLate], now: mondayNoonUTC) { time in
            time < mondayNoonUTC - 6 * 3_600 ? 2 * 3_600 : 3 * 3_600
        }
        #expect(days.map(\.title) == ["אתמול"])
    }

    @Test("nothing saved means no days")
    func empty() {
        #expect(HistoryDays.grouped([], now: mondayNoonUTC, utcOffsetSeconds: { _ in 0 }).isEmpty)
    }

    @Test("English titles: today, yesterday, a weekday, then the weekday with the date")
    func englishTitles() {
        Localization.$override.withValue(.english) {
            let today = CivilDate.localDay(of: mondayNoonUTC, utcOffsetSeconds: israel)
            #expect(HistoryDays.title(day: today, today: today) == "Today")
            #expect(HistoryDays.title(day: today - 1, today: today) == "Yesterday")
            #expect(HistoryDays.title(day: today - 2, today: today) == "Saturday")
            #expect(HistoryDays.title(day: today - 6, today: today) == "Tuesday")
            #expect(HistoryDays.title(day: today - 7, today: today) == "Monday, 7 September")
            #expect(HistoryDays.title(day: today - 258, today: today) == "Tuesday, 30 December 2025")
        }
    }

    @Test("on this day: conversations on today's month and day in an earlier year, newest first; this year and other days are excluded")
    func onThisDayMatches() {
        let oneYear: TimeInterval = 365 * 86_400
        let now = mondayNoonUTC
        let yearAgo = now - oneYear
        let twoYearsAgo = yearAgo - oneYear

        let matches = OnThisDay.matches(
            in: [
                summary(now, preview: "היום"),
                summary(now - 86_400, preview: "אתמול"),
                summary(twoYearsAgo, preview: "לפני שנתיים"),
                summary(yearAgo, preview: "לפני שנה"),
            ],
            now: now,
            utcOffsetSeconds: { _ in israel }
        )
        #expect(matches.map(\.preview) == ["לפני שנה", "לפני שנתיים"])
    }

    @Test("on this day: each session's own offset decides its local day, not today's -- reusing today's offset would manufacture a false match")
    func onThisDayUsesEachSessionsOwnOffset() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func timestamp(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> TimeInterval {
            utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
        }

        // 23:40 local time under a +2h offset (standard time) on Oct 26 last year.
        let session = timestamp(2025, 10, 26, 21, 40)
        // A year later, local time under a +3h offset (daylight time) is Oct 27.
        let now = timestamp(2026, 10, 27, 9, 0)
        let transition = timestamp(2026, 1, 1, 0, 0)
        func offset(at time: TimeInterval) -> Int {
            time < transition ? 2 * 3_600 : 3 * 3_600
        }

        let matches = OnThisDay.matches(in: [summary(session, preview: "אשתקד")], now: now, utcOffsetSeconds: offset)
        // Converted with its own (pre-transition, +2h) offset the session
        // lands on Oct 26, one day short of today's Oct 27 -- no match.
        // Reusing today's +3h offset for the session too would instead
        // push it to Oct 27, a false anniversary hit a year early.
        #expect(matches.isEmpty)
    }
}
