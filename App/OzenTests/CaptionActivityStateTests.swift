import Foundation
import Testing
@testable import Ozen

@Suite("Lock screen activity state")
struct CaptionActivityStateTests {
    @Test("a state from an older build still decodes, and the app's direction goes both ways")
    func directionSurvivesTheTrip() throws {
        let old = #"{"lines":[{"text":"שלום","isFinal":true}],"large":false,"english":true}"#
        let decoded = try JSONDecoder().decode(CaptionActivityAttributes.ContentState.self, from: Data(old.utf8))
        #expect(decoded.appRightToLeft == nil)
        #expect(decoded.english)

        var state = decoded
        state.appRightToLeft = false
        let again = try JSONDecoder().decode(CaptionActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        #expect(again.appRightToLeft == false)
    }
}
