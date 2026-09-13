import Testing
@testable import OzenKit
import Foundation

@Suite("AppSettings persistence")
struct AppSettingsTests {

    @Test("default settings use Whisper, Hebrew, and the requested credit line")
    func defaults() {
        let settings = AppSettings.default
        #expect(settings.engine == .whisperKit)
        #expect(settings.languageCode == "he")
        #expect(settings.creditLine == "Made by Arbel")
        #expect(settings.speakerProfiles.isEmpty)
    }

    @Test("settings round-trip through JSON without losing data")
    func codableRoundTrip() throws {
        let original = AppSettings(
            engine: .appleSpeech,
            languageCode: "he",
            preferredInputUID: "airpods-123",
            speakerProfiles: [SpeakerProfile(name: "סבתא", embedding: [0.1, 0.2, 0.3])],
            creditLine: "Made by Arbel"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test("loading with no file on disk yet returns defaults instead of throwing")
    func loadWithMissingFileReturnsDefault() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-settings-missing-\(UUID()).json")
        let store = SettingsStore(fileURL: missingURL)
        #expect(store.load() == AppSettings.default)
    }

    @Test("save then load returns exactly what was saved")
    func saveThenLoadRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(fileURL: url)
        var settings = AppSettings.default
        settings.preferredInputUID = "usb-lav-1"
        settings.speakerProfiles = [SpeakerProfile(name: "Chen", embedding: [1, 2, 3])]

        try store.save(settings)
        let loaded = store.load()
        #expect(loaded == settings)
    }

    @Test("a corrupted settings file falls back to defaults instead of crashing the app")
    func corruptedFileFallsBackToDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-settings-corrupt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("not valid json".utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        #expect(store.load() == AppSettings.default)
    }

    @Test("a settings file from an older build (missing every newer key) still loads, keeping its speaker profiles")
    func olderFileDecodesWithDefaults() throws {
        let legacy = """
        {"engine":"appleSpeech","languageCode":"he","preferredInputUID":"airpods-1",
         "speakerProfiles":[{"id":"1E2B4D2A-6C5F-4F1B-9C3E-000000000001","name":"סבתא","embedding":[0.5,0.25]}],
         "creditLine":"whatever an old build wrote"}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        #expect(decoded.engine == .appleSpeech)
        #expect(decoded.preferredInputUID == "airpods-1")
        #expect(decoded.speakerProfiles.map(\.name) == ["סבתא"])
        #expect(decoded.whisperModelVariant == AppSettings.default.whisperModelVariant)
        #expect(decoded.allowServerFallbackForAppleSpeech == false)
        #expect(decoded.display == .default)
        #expect(decoded.hapticOnSpeechResume == true)
        #expect(decoded.speakerSimilarityThreshold == 0.75)
        #expect(decoded.keywordAlerts.isEmpty)
        #expect(decoded.soundAlerts == .default)
        #expect(decoded.saveHistory == true)
        #expect(decoded.quickPhrases == AppSettings.defaultQuickPhrases)
        #expect(decoded.speechRate == 0.45)
        // The credit line is owned by the build, not the file.
        #expect(decoded.creditLine == "Made by Arbel")
    }

    @Test("an empty JSON object decodes to the defaults")
    func emptyObjectIsDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded == AppSettings.default)
    }

    @Test("newer settings round-trip through JSON intact")
    func newFieldsRoundTrip() throws {
        var settings = AppSettings.default
        settings.whisperModelVariant = "large-v3_turbo"
        settings.allowServerFallbackForAppleSpeech = true
        settings.display = DisplayPreferences(fontSize: 44, theme: .highContrast, boldText: true, showSpeakerNames: false, keepScreenAwake: false)
        settings.hapticOnSpeechResume = false
        settings.speakerSimilarityThreshold = 0.6
        settings.keywordAlerts = [KeywordAlert(phrase: "סבתא"), KeywordAlert(phrase: "תרופה", isEnabled: false)]
        settings.soundAlerts = SoundAlertPreferences(isEnabled: true, minimumImportance: .high, mutedIdentifiers: ["music"])
        settings.saveHistory = false
        settings.quickPhrases = ["כן", "לא"]
        settings.speechRate = 0.6

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("an out-of-range speech rate is clamped so the voice stays intelligible")
    func speechRateClamped() throws {
        let fast = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speechRate":5}"#.utf8))
        #expect(fast.speechRate == 0.7)
        let slow = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speechRate":0}"#.utf8))
        #expect(slow.speechRate == 0.2)
    }

    @Test("an out-of-range saved font size is clamped on load rather than rendering unreadable text")
    func fontSizeClamped() throws {
        let tiny = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"fontSize":4}"#.utf8))
        #expect(tiny.fontSize == DisplayPreferences.minimumFontSize)
        let huge = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"fontSize":400}"#.utf8))
        #expect(huge.fontSize == DisplayPreferences.maximumFontSize)
    }
}
