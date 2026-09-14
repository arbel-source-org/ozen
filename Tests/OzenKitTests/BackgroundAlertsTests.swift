import Foundation
import Testing
@testable import OzenKit

@Suite("BackgroundAlertPolicy")
struct BackgroundAlertPolicyTests {
    private func sound(_ identifier: String) -> SoundAlert {
        let event = SoundEventCatalog.event(for: identifier)!
        return SoundAlert(event: event, confidence: 0.9, timestamp: 0)
    }

    private func hit(_ phrase: String, alertID: UUID = UUID()) -> KeywordHit {
        KeywordHit(segmentID: UUID(), match: KeywordMatch(alertID: alertID, phrase: phrase, matchedText: phrase, wordIndex: 0), timestamp: 0)
    }

    @Test("nothing is posted while the app is on screen: the banner is already there")
    func foregroundSilent() {
        var policy = BackgroundAlertPolicy()
        #expect(policy.notification(for: sound("door_bell"), appIsActive: true, now: 0) == nil)
        #expect(policy.notification(for: hit("סבתא"), lineText: "סבתא בואי", appIsActive: true, now: 0) == nil)
    }

    @Test("in the background a sound becomes a notification, and a siren is marked urgent")
    func backgroundSound() {
        var policy = BackgroundAlertPolicy()
        let bell = policy.notification(for: sound("door_bell"), appIsActive: false, now: 0)
        #expect(bell?.title == SoundEventCatalog.event(for: "door_bell")?.name)
        #expect(bell?.isUrgent == false)
        let siren = policy.notification(for: sound("civil_defense_siren"), appIsActive: false, now: 0)
        #expect(siren?.isUrgent == true)
        #expect(siren?.threadIdentifier == "sounds")
    }

    @Test("the same sound or word notifies once per cooldown, different ones independently")
    func cooldown() {
        var policy = BackgroundAlertPolicy(cooldownSeconds: 30)
        let alertID = UUID()
        #expect(policy.notification(for: hit("סבתא", alertID: alertID), lineText: "סבתא", appIsActive: false, now: 100) != nil)
        #expect(policy.notification(for: hit("סבתא", alertID: alertID), lineText: "סבתא שוב", appIsActive: false, now: 110) == nil)
        #expect(policy.notification(for: hit("אקמול"), lineText: "אקמול", appIsActive: false, now: 111) != nil)
        #expect(policy.notification(for: hit("סבתא", alertID: alertID), lineText: "סבתא", appIsActive: false, now: 131) != nil)
    }

    @Test("turned off, nothing is ever posted")
    func disabled() {
        var policy = BackgroundAlertPolicy(isEnabled: false)
        #expect(policy.notification(for: sound("door_bell"), appIsActive: false, now: 0) == nil)
    }

    @Test("a keyword notification quotes the line, cut at a whole word")
    func excerpt() {
        var policy = BackgroundAlertPolicy()
        let content = policy.notification(for: hit("סבתא"), lineText: "  סבתא, בואי לאכול ", appIsActive: false, now: 0)
        #expect(content?.title == "נאמר: סבתא")
        #expect(content?.body == "סבתא, בואי לאכול")
        // One opening with an English word is marked to read right to left.
        let english = policy.notification(for: hit("סבתא"), lineText: "OK סבתא, בואי", appIsActive: false, now: 100)
        #expect(english?.body == "\u{200F}OK סבתא, בואי")

        let long = String(repeating: "מילה ", count: 60)
        let cut = BackgroundAlertPolicy.excerpt(long)
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= 121)
        #expect(cut.dropLast().hasSuffix("מילה"))
    }
}
