import Foundation
import Testing
@testable import OzenKit

@Suite("Caption announcer")
struct CaptionAnnouncerTests {
    private func line(_ text: String, committed: Bool = true, speaker: Int? = nil) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), text: text, isCommitted: committed, speakerClusterID: speaker, startTimestamp: 0, lastUpdateTimestamp: 0)
    }

    private let names: (TranscriptSegment) -> String? = { segment in
        switch segment.speakerClusterID {
        case 1: return "דנה"
        case 2: return "יוסי"
        default: return nil
        }
    }

    @Test("a finished line is announced once; a line still changing is not announced yet")
    func onlyFinishedLinesOnce() {
        var announcer = CaptionAnnouncer()
        var open = line("שלום מה", committed: false)
        let finished = line("בוקר טוב")
        #expect(announcer.announcement(for: [finished, open], speakerName: { _ in nil }) == "בוקר טוב")
        #expect(announcer.announcement(for: [finished, open], speakerName: { _ in nil }) == nil)

        open.text = "שלום מה שלומך"
        open.isCommitted = true
        #expect(announcer.announcement(for: [finished, open], speakerName: { _ in nil }) == "שלום מה שלומך")
    }

    @Test("lines finished together go out as one announcement, in order")
    func batched() {
        var announcer = CaptionAnnouncer()
        let lines = [line("אחת"), line("שתיים"), line("שלוש")]
        #expect(announcer.announcement(for: lines, speakerName: { _ in nil }) == "אחת\nשתיים\nשלוש")
    }

    @Test("the speaker's name leads a line only when the speaker changes")
    func speakerNames() {
        var announcer = CaptionAnnouncer()
        let first = line("איך את מרגישה?", speaker: 1)
        let second = line("והכדורים?", speaker: 1)
        let third = line("טוב, תודה", speaker: 2)
        #expect(announcer.announcement(for: [first, second], speakerName: names) == "דנה: איך את מרגישה?\nוהכדורים?")
        #expect(announcer.announcement(for: [first, second, third], speakerName: names) == "יוסי: טוב, תודה")
        let fourth = line("יופי", speaker: 2)
        #expect(announcer.announcement(for: [first, second, third, fourth], speakerName: names) == "יופי")
    }

    @Test("after five quiet minutes the same speaker is named again")
    func nameAgainAfterQuiet() {
        var announcer = CaptionAnnouncer()
        let before = TranscriptSegment(id: UUID(), text: "לילה טוב", isCommitted: true, speakerClusterID: 1, startTimestamp: 1000, lastUpdateTimestamp: 1002)
        let soon = TranscriptSegment(id: UUID(), text: "ונשיקות", isCommitted: true, speakerClusterID: 1, startTimestamp: 1010, lastUpdateTimestamp: 1011)
        let later = TranscriptSegment(id: UUID(), text: "בוקר טוב", isCommitted: true, speakerClusterID: 1, startTimestamp: 1400, lastUpdateTimestamp: 1402)
        #expect(announcer.announcement(for: [before], speakerName: names) == "דנה: לילה טוב")
        #expect(announcer.announcement(for: [before, soon], speakerName: names) == "ונשיקות")
        #expect(announcer.announcement(for: [before, soon, later], speakerName: names) == "דנה: בוקר טוב")
    }

    @Test("blank finished lines are skipped and never announced later")
    func blankLines() {
        var announcer = CaptionAnnouncer()
        let blank = line("   ")
        #expect(announcer.announcement(for: [blank], speakerName: { _ in nil }) == nil)
        #expect(announcer.announcement(for: [blank, line("כן")], speakerName: { _ in nil }) == "כן")
    }

    @Test("turning on mid-conversation skips the backlog but not a line still being said")
    func skipBacklog() {
        var announcer = CaptionAnnouncer()
        let old = [line("מזמן"), line("גם מזמן")]
        var open = line("עכשיו", committed: false)
        announcer.skipLinesSoFar(old + [open])
        #expect(announcer.announcement(for: old + [open], speakerName: { _ in nil }) == nil)
        open.isCommitted = true
        #expect(announcer.announcement(for: old + [open], speakerName: { _ in nil }) == "עכשיו")
    }

    @Test("after the screen is cleared the next speaker is named again")
    func clearedTranscript() {
        var announcer = CaptionAnnouncer()
        let before = line("לפני", speaker: 1)
        #expect(announcer.announcement(for: [before], speakerName: names) == "דנה: לפני")
        #expect(announcer.announcement(for: [], speakerName: names) == nil)
        let after = line("אחרי", speaker: 1)
        #expect(announcer.announcement(for: [after], speakerName: names) == "דנה: אחרי")
    }

    @Test("announcing is on by default and survives settings files from before it existed")
    func settingDecoding() throws {
        #expect(DisplayPreferences.default.announceNewLines)
        let old = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"fontSize":40}"#.utf8))
        #expect(old.announceNewLines)
        var off = DisplayPreferences.default
        off.announceNewLines = false
        let roundTripped = try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(off))
        #expect(roundTripped.announceNewLines == false)
    }

    @Test("a line left open while many others finish is still announced when it finishes")
    func longOpenLine() {
        var announcer = CaptionAnnouncer()
        var open = TranscriptSegment(id: UUID(), text: "והרופא", isCommitted: false, speakerClusterID: nil, startTimestamp: 0, lastUpdateTimestamp: 0)
        var lines = [open]
        #expect(announcer.announcement(for: lines, speakerName: { _ in nil }) == nil)
        for n in 1...(CaptionAnnouncer.recheckedLines * 3) {
            lines.append(line("שורה \(n)"))
            _ = announcer.announcement(for: lines, speakerName: { _ in nil })
        }
        open.text = "והרופא אמר"
        open.isCommitted = true
        lines[0] = open
        lines.append(line("עוד"))
        #expect(announcer.announcement(for: lines, speakerName: { _ in nil }) == "והרופא אמר\nעוד")
    }

    @Test("a line provisionally committed by the stale-commit safety net is still caught when it reopens and changes, however far back it's scrolled")
    func provisionalCommitReopensAfterScrollingOut() {
        var announcer = CaptionAnnouncer()
        var provisional = TranscriptSegment(
            id: UUID(), text: "הרופא אמר", isCommitted: true, speakerClusterID: nil,
            startTimestamp: 0, lastUpdateTimestamp: 0, isProvisionalCommit: true
        )
        var lines = [provisional]
        #expect(announcer.announcement(for: lines, speakerName: { _ in nil }) == "הרופא אמר")
        for n in 1...(CaptionAnnouncer.recheckedLines * 3) {
            lines.append(line("שורה \(n)"))
            _ = announcer.announcement(for: lines, speakerName: { _ in nil })
        }
        // Reopens with more text, then really finalizes — as CaptionStabilizer.ingest
        // does within one call when a straggler both reopens and finalizes a line.
        provisional.text = "הרופא אמר כדור אחד"
        provisional.isProvisionalCommit = false
        lines[0] = provisional
        #expect(announcer.announcement(for: lines, speakerName: { _ in nil }) == "הרופא אמר כדור אחד")
    }

    @Test("once enough unrelated lines have replaced it, a rolled-off line's entry is forgotten, so reusing its id later announces it fresh instead of assuming it was already read")
    func forgetsLinesThatRolledOff() {
        var announcer = CaptionAnnouncer()
        let staleID = UUID()
        let stale = TranscriptSegment(id: staleID, text: "ישן מאוד", isCommitted: true, speakerClusterID: nil, startTimestamp: 0, lastUpdateTimestamp: 0)
        #expect(announcer.announcement(for: [stale], speakerName: { _ in nil }) == "ישן מאוד")

        // Two rounds of a small, entirely unrelated segments array (as a
        // fresh conversation after a restart would look): `announced`
        // keeps what it saw before while the array handed in shrinks back
        // down each time, which is exactly what should sweep it out.
        for _ in 0..<2 {
            _ = announcer.announcement(for: [line("א"), line("ב")], speakerName: { _ in nil })
        }

        let reused = TranscriptSegment(id: staleID, text: "ישן מאוד", isCommitted: true, speakerClusterID: nil, startTimestamp: 100, lastUpdateTimestamp: 100)
        #expect(announcer.announcement(for: [reused], speakerName: { _ in nil }) == "ישן מאוד")
    }

    @Test("a line corrected after it was read out is read again; unchanged lines are not")
    func correctedLineReadAgain() {
        var announcer = CaptionAnnouncer()
        var segment = line("הרופא אמר")
        #expect(announcer.announcement(for: [segment], speakerName: { _ in nil }) == "הרופא אמר")
        #expect(announcer.announcement(for: [segment], speakerName: { _ in nil }) == nil)

        segment.isCommitted = false
        segment.text = "הרופא אמר כדור אחד"
        #expect(announcer.announcement(for: [segment], speakerName: { _ in nil }) == nil)
        segment.isCommitted = true
        #expect(announcer.announcement(for: [segment], speakerName: { _ in nil }) == "הרופא אמר כדור אחד")
    }
}
