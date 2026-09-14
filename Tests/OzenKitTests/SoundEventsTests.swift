import Testing
@testable import OzenKit
import Foundation

@Suite("SoundEventCatalog and SoundEventPolicy")
struct SoundEventsTests {
    @Test("what a buzzing phone can be taken for is never a safety sound or the doorbell, and every name is a real sound")
    func vibrationLookalikesAreSafeToIgnore() {
        for identifier in SoundEventCatalog.vibrationLookalikes {
            let event = SoundEventCatalog.event(for: identifier)
            #expect(event != nil, "\(identifier) is not in the catalog")
            #expect(event?.importance != .critical)
            #expect(identifier != "door_bell")
        }
    }

    @Test("catalog identifiers are unique, snake_case, and speech is deliberately absent")
    func catalogSanity() {
        let identifiers = SoundEventCatalog.events.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
        for identifier in identifiers {
            #expect(identifier == identifier.lowercased(), Comment(rawValue: identifier))
            #expect(!identifier.contains(" "), Comment(rawValue: identifier))
        }
        #expect(SoundEventCatalog.event(for: "speech") == nil)
        #expect(SoundEventCatalog.event(for: "whispering") == nil)
        #expect(SoundEventCatalog.event(for: "civil_defense_siren")?.importance == .critical)
        #expect(SoundEventCatalog.event(for: "door_bell")?.name == "פעמון דלת")
    }

    @Test("importance orders critical above high above medium above low")
    func importanceOrdering() {
        #expect(SoundEvent.Importance.critical > .high)
        #expect(SoundEvent.Importance.high > .medium)
        #expect(SoundEvent.Importance.medium > .low)
        #expect(SoundEvent.Importance.allCases.sorted().first == .low)
    }

    private func reading(_ id: String, confidence: Double = 0.9, at time: TimeInterval = 100) -> SoundObservation {
        SoundObservation(identifier: id, confidence: confidence, timestamp: time)
    }

    @Test("a confident, listed, important sound becomes an alert")
    func basicAlert() {
        var policy = SoundEventPolicy()
        let alert = policy.evaluate(reading("door_bell"))
        #expect(alert?.event.identifier == "door_bell")
        #expect(alert?.confidence == 0.9)
        #expect(alert?.timestamp == 100)
    }

    @Test("low confidence, unknown labels and disabled preferences produce nothing")
    func filters() {
        var policy = SoundEventPolicy()
        let lowConfidence = policy.evaluate(reading("door_bell", confidence: 0.3))
        let unknown = policy.evaluate(reading("speech"))
        #expect(lowConfidence == nil)
        #expect(unknown == nil)

        var disabled = SoundEventPolicy(preferences: SoundAlertPreferences(isEnabled: false))
        let none = disabled.evaluate(reading("smoke_detector"))
        #expect(none == nil)
    }

    @Test("the importance floor and the mute list are respected")
    func importanceAndMute() {
        var policy = SoundEventPolicy(preferences: SoundAlertPreferences(minimumImportance: .high, mutedIdentifiers: ["door_bell"]))
        let lowImportance = policy.evaluate(reading("cough"))
        let muted = policy.evaluate(reading("door_bell"))
        let knock = policy.evaluate(reading("knock"))
        #expect(lowImportance == nil)
        #expect(muted == nil)
        #expect(knock?.event.identifier == "knock")
    }

    @Test("the same sound is not re-alerted within the cooldown, but a different sound is")
    func cooldown() {
        var policy = SoundEventPolicy(cooldownSeconds: 20)
        let first = policy.evaluate(reading("dog_bark", at: 100))
        let repeatSoon = policy.evaluate(reading("dog_bark", at: 110))
        let other = policy.evaluate(reading("door_bell", at: 111))
        let afterCooldown = policy.evaluate(reading("dog_bark", at: 121))
        #expect(first != nil)
        #expect(repeatSoon == nil)
        #expect(other != nil)
        #expect(afterCooldown != nil)

        policy.resetCooldowns()
        let afterReset = policy.evaluate(reading("dog_bark", at: 122))
        #expect(afterReset != nil)
    }

    @Test("a banner gives way only to an alert at least as important")
    func bannerTakeOver() throws {
        func alert(_ identifier: String) throws -> SoundAlert {
            SoundAlert(event: try #require(SoundEventCatalog.event(for: identifier)), confidence: 0.9, timestamp: 1)
        }
        let smoke = try alert("smoke_detector")
        let horn = try alert("car_horn")
        #expect(smoke.takesBanner(from: nil))
        #expect(!horn.takesBanner(from: smoke))
        #expect(smoke.takesBanner(from: horn))
        #expect(try alert("siren").takesBanner(from: smoke))
    }

    @Test("preferences decode tolerantly and round-trip")
    func preferencesCodable() throws {
        let decoded = try JSONDecoder().decode(SoundAlertPreferences.self, from: Data("{}".utf8))
        #expect(decoded == .default)

        let custom = SoundAlertPreferences(isEnabled: false, minimumImportance: .critical, mutedIdentifiers: ["cat", "music"])
        let data = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(SoundAlertPreferences.self, from: data) == custom)
    }
}
