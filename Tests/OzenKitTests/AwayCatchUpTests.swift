import Testing
import Foundation
@testable import OzenKit

@Suite("Marking the lines said while the screen was away")
struct AwayCatchUpTests {
    private func lines(startingAt times: [TimeInterval]) -> [TranscriptSegment] {
        times.map { TranscriptSegment(id: UUID(), text: "line", isCommitted: true, speakerClusterID: nil, startTimestamp: $0, lastUpdateTimestamp: $0) }
    }

    @Test("lines that began while she was away are marked from the first of them")
    func marksTheFirstMissedLine() {
        var catchUp = AwayCatchUp()
        catchUp.screenLeft(at: 100)
        catchUp.screenReturned(at: 400)
        // The line she was reading when she left carried on; it isn't new.
        let segments = lines(startingAt: [50, 90, 150, 200, 390, 410])
        #expect(catchUp.firstMissedIndex(in: segments) == 2)
        #expect(catchUp.missedLineCount(in: segments) == 3)
        #expect(catchUp.offersJump(in: segments))
    }

    @Test("a glance away doesn't count, and doesn't move an earlier mark")
    func shortAbsenceKeepsTheEarlierMark() {
        var catchUp = AwayCatchUp()
        catchUp.screenLeft(at: 100)
        catchUp.screenReturned(at: 400)
        catchUp.acknowledge()
        catchUp.screenLeft(at: 500)
        catchUp.screenReturned(at: 505)
        let segments = lines(startingAt: [150, 200, 502, 503])
        #expect(catchUp.away == 100...400)
        #expect(catchUp.firstMissedIndex(in: segments) == 0)
        // Seen already, so it isn't offered again after the glance.
        #expect(!catchUp.offersJump(in: segments))
    }

    @Test("a new long absence replaces the mark and offers the jump again")
    func newAbsenceReplacesTheMark() {
        var catchUp = AwayCatchUp()
        catchUp.screenLeft(at: 100)
        catchUp.screenReturned(at: 400)
        catchUp.acknowledge()
        catchUp.screenLeft(at: 1_000)
        catchUp.screenReturned(at: 2_000)
        let segments = lines(startingAt: [150, 200, 1_100, 1_200, 1_300])
        #expect(catchUp.firstMissedIndex(in: segments) == 2)
        #expect(catchUp.offersJump(in: segments))
    }

    @Test("repeated leave calls keep the moment she first left")
    func firstLeaveWins() {
        var catchUp = AwayCatchUp()
        catchUp.screenLeft(at: 100)
        catchUp.screenLeft(at: 300)
        catchUp.screenReturned(at: 320)
        #expect(catchUp.away == 100...320)
    }

    @Test("a single missed line, or none, draws no mark")
    func tooFewLines() {
        var catchUp = AwayCatchUp()
        catchUp.screenLeft(at: 100)
        catchUp.screenReturned(at: 400)
        #expect(catchUp.firstMissedIndex(in: lines(startingAt: [50, 150, 450])) == nil)
        #expect(catchUp.firstMissedIndex(in: []) == nil)
        #expect(!catchUp.offersJump(in: lines(startingAt: [50])))
    }

    @Test("coming back without having left, and clearing, leave no mark")
    func noMark() {
        var catchUp = AwayCatchUp()
        catchUp.screenReturned(at: 400)
        #expect(catchUp.away == nil)
        catchUp.screenLeft(at: 100)
        catchUp.screenReturned(at: 400)
        catchUp.clear()
        #expect(catchUp.away == nil)
        #expect(catchUp.firstMissedIndex(in: lines(startingAt: [150, 200])) == nil)
    }
}
