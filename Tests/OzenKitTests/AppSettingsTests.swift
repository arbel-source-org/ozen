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
}
