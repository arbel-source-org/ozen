import Foundation
import Testing
@testable import OzenKit

@Suite("Settings survive values they can't read")
struct SettingsResilienceTests {
    private let profileID = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("an engine name from a newer build falls back to the default and keeps the enrolled voices")
    func unknownEngineKeepsProfiles() throws {
        let settings = try decode("""
        {"engine":"someFutureEngine","speakerProfiles":[{"id":"\(profileID)","name":"דנה","embedding":[0.1,0.2,0.3]}],"vocabulary":["אביטל"],"hasCompletedOnboarding":true}
        """)
        #expect(settings.engine == AppSettings.default.engine)
        #expect(settings.speakerProfiles.map(\.name) == ["דנה"])
        #expect(settings.vocabulary == ["אביטל"])
        #expect(settings.hasCompletedOnboarding)
    }

    @Test("one damaged voice profile is dropped and the others are kept")
    func damagedProfileDropped() throws {
        let settings = try decode("""
        {"speakerProfiles":[{"id":"\(profileID)","name":"דנה","embedding":[0.1,0.2]},{"name":"בלי מזהה","embedding":[0.3]},{"id":"not-a-uuid","name":"שבור","embedding":"x"},{"id":"\(UUID().uuidString)","name":"יוסי","embedding":[0.4,0.5]}]}
        """)
        #expect(settings.speakerProfiles.map(\.name) == ["דנה", "יוסי"])
    }

    @Test("an empty voice print is dropped rather than kept to fail later")
    func emptyEmbeddingDropped() throws {
        let settings = try decode("""
        {"speakerProfiles":[{"id":"\(profileID)","name":"ריק","embedding":[]}]}
        """)
        #expect(settings.speakerProfiles.isEmpty)
    }

    @Test("an unreadable display value only resets that value")
    func damagedDisplayValue() throws {
        let settings = try decode("""
        {"display":{"fontSize":48,"theme":"neon","boldText":true},"saveHistory":false}
        """)
        #expect(settings.display.fontSize == 48)
        #expect(settings.display.theme == DisplayPreferences.default.theme)
        #expect(settings.display.boldText)
        #expect(settings.saveHistory == false)
    }

    @Test("a value of the wrong type resets just that setting")
    func wrongType() throws {
        let settings = try decode("""
        {"saveHistory":"yes please","speechRate":0.3,"keywordAlerts":[{"id":"\(profileID)","phrase":"סבתא"},42,{"phrase":"בלי מזהה"}],"soundAlerts":{"isEnabled":false,"minimumImportance":"loud"}}
        """)
        #expect(settings.saveHistory == AppSettings.default.saveHistory)
        #expect(settings.speechRate == 0.3)
        #expect(settings.keywordAlerts.map(\.phrase) == ["סבתא"])
        #expect(settings.soundAlerts.isEnabled == false)
        #expect(settings.soundAlerts.minimumImportance == SoundAlertPreferences.default.minimumImportance)
    }

    @Test("settings read back from damaged files can be saved again")
    func savesAfterRecovery() throws {
        let settings = try decode("""
        {"engine":"someFutureEngine","speakerProfiles":[{"id":"\(profileID)","name":"דנה","embedding":[0.1,0.2]}]}
        """)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-resilience-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SettingsStore(fileURL: file)
        try store.save(settings)
        #expect(store.load().speakerProfiles.map(\.name) == ["דנה"])
    }
}

@Suite("Voice enrollment with an unusable voice print")
@MainActor
struct EnrollmentNonFiniteTests {
    private struct NaNEmbedder: SpeakerEmbedding {
        func embed(samples: [Float], sampleRate: Double) -> [Float]? { [0.1, .nan, 0.3] }
    }

    @Test("a voice print with NaN in it is refused, so it can never break saving settings")
    func nanRefused() {
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in FakeEngine() }, embedder: NaNEmbedder())
        #expect(pipeline.embedding(forEnrollmentSamples: [Float](repeating: 0.2, count: 16_000)) == nil)
    }
}

@Suite("Saved conversations survive lines they can't read")
struct TranscriptRecordResilienceTests {
    @Test("an unknown engine and one damaged line still load the rest of the conversation")
    func damagedLine() throws {
        let id = UUID().uuidString
        let json = """
        {"id":"\(id)","startedAt":100,"engine":"someFutureEngine","segments":[
          {"id":"\(UUID().uuidString)","text":"שלום","startTimestamp":100,"isCommitted":true},
          {"id":"\(UUID().uuidString)","text":42,"startTimestamp":101,"isCommitted":true},
          {"id":"\(UUID().uuidString)","text":"להתראות","startTimestamp":102,"isCommitted":true}
        ],"title":7}
        """
        let record = try JSONDecoder().decode(TranscriptSessionRecord.self, from: Data(json.utf8))
        #expect(record.id.uuidString == id)
        #expect(record.segments.map(\.text) == ["שלום", "להתראות"])
        #expect(record.engine == .whisperKit)
        #expect(record.title == nil)
    }
}
