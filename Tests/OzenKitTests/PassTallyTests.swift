import Foundation
import Testing
@testable import OzenKit

@Suite("PassTally")
struct PassTallyTests {
    @Test("says how long passes take and how much the filter threw away")
    func summary() {
        var tally = PassTally()
        tally.recordLivePass(seconds: 0.5)
        tally.recordLivePass(seconds: 1.5)
        tally.recordFinalPass(cameBackEmpty: false)
        tally.recordFinalPass(cameBackEmpty: true)
        tally.recordSegments(seen: 5, accepted: 3)
        #expect(tally.summary == "live passes 2 avg 1.00s slowest 1.50s last 1.50s, final passes 2 (1 empty), segments 5 rejected by the filter 2")
    }

    @Test("before anything has run there is still a line, without made-up numbers")
    func empty() {
        #expect(PassTally().summary == "live passes 0 avg -s slowest 0.00s last -s, final passes 0 (0 empty), segments 0 rejected by the filter 0")
    }
}
