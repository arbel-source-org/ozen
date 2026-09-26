import SwiftUI
import Testing
@testable import Ozen
@testable import OzenKit

/// A named speaker's color must stay put across app launches (a fresh
/// `EmbeddingClusterer` assigns ids in whatever order voices are heard), so
/// grandma can still spot her own lines by color from one day to the next.
@Suite("Speaker color")
struct SpeakerColorTests {
    @Test("a named speaker's color depends on the name, not the session-only cluster id")
    func namedSpeakerIsStableAcrossIDs() {
        let first = SpeakerColor.color(forClusterID: 0, speakerName: "סבתא", on: .dark)
        let second = SpeakerColor.color(forClusterID: 7, speakerName: "סבתא", on: .dark)
        #expect(first == second)
    }

    @Test("two different names don't reliably collide on the same cluster id")
    func differentNamesCanDiffer() {
        let names = ["סבתא", "אבא", "אמא", "דנה", "יוסי"]
        let colors = Set(names.map { SpeakerColor.color(forClusterID: 3, speakerName: $0, on: .dark) })
        #expect(colors.count > 1)
    }

    @Test("an unnamed stranger still falls back to coloring by cluster id")
    func strangerUsesID() {
        let a = SpeakerColor.color(forClusterID: 0, speakerName: nil, on: .dark)
        let b = SpeakerColor.color(forClusterID: 1, speakerName: nil, on: .dark)
        #expect(a != b)
    }

    @Test("a generic 'Speaker N' label colors by id, like an unnamed stranger")
    func genericLabelUsesID() {
        let generic = SpeakerColor.color(forClusterID: 4, speakerName: EmbeddingClusterer.genericName(number: 4), on: .dark)
        let byID = SpeakerColor.color(forClusterID: 4, speakerName: nil, on: .dark)
        #expect(generic == byID)
    }
}
