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

    @Test("a voice saved with the old loudness number keeps matching: that number is dropped on load")
    func oldVoicePrintMigrates() throws {
        let oldPrint: [Float] = [-180, 12, -3, 4, -5, 6, -7, 8, -9, 10, -11, 1.5, -0.5]
        let other: [Float] = [1, 2, 3]
        let saved = AppSettings(
            engine: .whisperKit,
            languageCode: "he",
            preferredInputUID: nil,
            speakerProfiles: [
                SpeakerProfile(name: "old", embedding: oldPrint),
                SpeakerProfile(name: "current", embedding: Array(oldPrint.dropFirst())),
                SpeakerProfile(name: "other", embedding: other),
            ],
            creditLine: "Made by Arbel"
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        #expect(decoded.speakerProfiles.map(\.embedding) == [Array(oldPrint.dropFirst()), Array(oldPrint.dropFirst()), other])
        #expect(decoded.speakerProfiles.map(\.embedding.count).prefix(2).allSatisfy { $0 == SpeakerProfile.voicePrintLength })
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
        defer { try? FileManager.default.removeItem(at: store.damagedCopyURL) }
        #expect(store.load() == AppSettings.default)
    }

    @Test("a damaged settings file is kept aside, so saving the defaults doesn't destroy it")
    func damagedFileKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-settings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ozen-settings.json")
        try Data("{\"speakerProfiles\": [trunc".utf8).write(to: url)
        let store = SettingsStore(fileURL: url)

        let loaded = store.load()
        try store.save(loaded)
        let keptAfterSave = try String(contentsOf: store.damagedCopyURL, encoding: .utf8)
        try Data("second damage".utf8).write(to: url)
        _ = store.load()

        #expect(loaded == AppSettings.default)
        #expect(store.damagedCopyURL.lastPathComponent == "ozen-settings.damaged.json")
        #expect(keptAfterSave == "{\"speakerProfiles\": [trunc")
        let kept = try String(contentsOf: store.damagedCopyURL, encoding: .utf8)
        #expect(kept == "second damage")
    }

    @Test("a readable file, or no file at all, leaves nothing aside")
    func nothingAsideWhenFine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-settings-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(fileURL: folder.appendingPathComponent("ozen-settings.json"))
        _ = store.load()
        try store.save(.default)
        _ = store.load()
        #expect(!FileManager.default.fileExists(atPath: store.damagedCopyURL.path))
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
        #expect(decoded.speakerSimilarityThreshold == 0.45)
        #expect(decoded.keywordAlerts.isEmpty)
        #expect(decoded.soundAlerts == .default)
        #expect(decoded.saveHistory == true)
        #expect(decoded.quickPhrases == AppSettings.defaultQuickPhrases)
        #expect(decoded.speechRate == 0.45)
        #expect(decoded.vocabulary.isEmpty)
        #expect(decoded.hasCompletedOnboarding == false)
        #expect(decoded.notifyWhenInBackground == true)
        // The credit line is owned by the build, not the file.
        #expect(decoded.creditLine == "Made by Arbel")
    }

    @Test("an empty JSON object decodes to the defaults")
    func emptyObjectIsDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded == AppSettings.default)
    }

    @Test("the model shown for a conversation is the one its engine used")
    func modelDescription() {
        var settings = AppSettings.default
        settings.whisperModelVariant = "small"
        settings.cloudModel = CloudSpeech.accurateModel
        settings.engine = .whisperKit
        let whisper = settings.modelDescription
        settings.engine = .cloud
        let cloud = settings.modelDescription
        settings.engine = .appleSpeech
        let apple = settings.modelDescription
        #expect(whisper == "small")
        #expect(cloud == CloudSpeech.accurateModel)
        #expect(apple == nil)
    }

    @Test("an empty cloud model name falls back to the default model")
    func emptyCloudModel() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"cloudModel":""}"#.utf8))
        #expect(decoded.cloudModel == CloudSpeech.accurateModel)
        #expect(decoded.display.autoHideControls)
        #expect(decoded.appLanguage == .system)
    }

    @Test("a language name from a newer build falls back to following the phone")
    func unknownLanguage() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appLanguage":"klingon"}"#.utf8))
        #expect(decoded.appLanguage == .system)
    }

    @Test("newer settings round-trip through JSON intact")
    func newFieldsRoundTrip() throws {
        var settings = AppSettings.default
        settings.whisperModelVariant = "large-v3_turbo"
        settings.allowServerFallbackForAppleSpeech = true
        settings.cloudModel = CloudSpeech.accurateModel
        settings.appLanguage = .english
        settings.display = DisplayPreferences(fontSize: 44, theme: .highContrast, boldText: true, showSpeakerNames: false, keepScreenAwake: false, autoHideControls: false)
        settings.hapticOnSpeechResume = false
        settings.speakerSimilarityThreshold = 0.6
        settings.keywordAlerts = [KeywordAlert(phrase: "סבתא"), KeywordAlert(phrase: "תרופה", isEnabled: false)]
        settings.soundAlerts = SoundAlertPreferences(isEnabled: true, minimumImportance: .high, mutedIdentifiers: ["music"])
        settings.saveHistory = false
        settings.quickPhrases = ["כן", "לא"]
        settings.speechRate = 0.6
        settings.vocabulary = ["אבי", "רותי"]
        settings.hasCompletedOnboarding = true
        settings.notifyWhenInBackground = false

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

    @Test("a pinch lands on a whole-point size inside the readable range")
    func pinchFontSize() {
        #expect(DisplayPreferences.fontSize(30, scaledBy: 1.2) == 36)
        #expect(DisplayPreferences.fontSize(30, scaledBy: 1.017) == 31)
        #expect(DisplayPreferences.fontSize(30, scaledBy: 10) == DisplayPreferences.maximumFontSize)
        #expect(DisplayPreferences.fontSize(30, scaledBy: 0.1) == DisplayPreferences.minimumFontSize)
        #expect(DisplayPreferences.fontSize(30, scaledBy: 0) == 30)
        #expect(DisplayPreferences.fontSize(30, scaledBy: .nan) == 30)
    }
}

@Suite("AppSettings on a fresh install")
struct AppSettingsFreshInstallTests {
    @Test("saving works even when the folder doesn't exist yet, and the walkthrough stays done")
    func savesIntoMissingFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-fresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("Application Support").appendingPathComponent("ozen-settings.json")
        let store = SettingsStore(fileURL: url)

        var settings = store.load()
        settings.hasCompletedOnboarding = true
        try store.save(settings)

        #expect(SettingsStore(fileURL: url).load().hasCompletedOnboarding)
    }
}

@Suite("AppSettings offer of the recommended model")
struct BetterModelOfferTests {
    @Test("offered to a phone still on Small from before it stopped being the default, until taken")
    func offer() throws {
        let onSmall = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hasCompletedOnboarding":true,"whisperModelVariant":"small"}"#.utf8))
        #expect(onSmall.offersBetterModel())
        #expect(onSmall.runsWeakerModel)

        var switched = onSmall
        switched.whisperModelVariant = WhisperModelCatalog.recommendedVariant
        #expect(switched.offersBetterModel() == false)
        #expect(switched.runsWeakerModel == false)
    }

    @Test("\"Not now\" puts the offer away for three days, then two weeks, then two months, never for good")
    func snooze() throws {
        let day = 86_400.0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hasCompletedOnboarding":true,"whisperModelVariant":"small"}"#.utf8))

        settings.snoozeBetterModelOffer(from: start)
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.offersBetterModel(at: start.addingTimeInterval(2.9 * day)) == false)
        #expect(saved.offersBetterModel(at: start.addingTimeInterval(3.1 * day)))

        settings.snoozeBetterModelOffer(from: start)
        #expect(settings.offersBetterModel(at: start.addingTimeInterval(13 * day)) == false)
        #expect(settings.offersBetterModel(at: start.addingTimeInterval(15 * day)))

        settings.snoozeBetterModelOffer(from: start)
        settings.snoozeBetterModelOffer(from: start)
        #expect(settings.offersBetterModel(at: start.addingTimeInterval(59 * day)) == false)
        #expect(settings.offersBetterModel(at: start.addingTimeInterval(61 * day)))
    }

    @Test("a phone that turned the offer down for good in an older build is asked once more")
    func oldDismissal() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hasCompletedOnboarding":true,"whisperModelVariant":"small","betterModelOfferDismissed":true}"#.utf8))
        #expect(old.offersBetterModel())
    }

    @Test("not offered to a fresh install, to a phone still in the walkthrough, or to one on another engine")
    func notOffered() throws {
        #expect(AppSettings.default.offersBetterModel() == false)

        let inWalkthrough = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"whisperModelVariant":"small"}"#.utf8))
        #expect(inWalkthrough.offersBetterModel() == false)

        var onApple = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hasCompletedOnboarding":true,"whisperModelVariant":"small"}"#.utf8))
        onApple.engine = .appleSpeech
        #expect(onApple.offersBetterModel() == false)

        var onCloud = onApple
        onCloud.engine = .cloud
        #expect(onCloud.offersBetterModel() == false)
    }
}

@Suite("AppSettings offer to set up the name alert")
struct NameAlertOfferTests {
    @Test("offered to a phone set up before the walkthrough asked, until a word is added or it's turned down")
    func offer() throws {
        let fromOlderBuild = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hasCompletedOnboarding":true}"#.utf8))
        #expect(fromOlderBuild.nameAlertOfferDismissed == false)
        #expect(fromOlderBuild.offersNameAlert)

        var withName = fromOlderBuild
        withName.keywordAlerts = [KeywordAlert(phrase: "רותי")]
        #expect(withName.offersNameAlert == false)

        var turnedDown = fromOlderBuild
        turnedDown.nameAlertOfferDismissed = true
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(turnedDown))
        #expect(roundTripped.offersNameAlert == false)

        // During the walkthrough its own page asks instead.
        #expect(AppSettings.default.offersNameAlert == false)
    }
}

@Suite("Saved speakers list")
struct SavedSpeakerTests {
    @Test("a name saved for several voices is one person, listed where it was first saved")
    func groupsByName() {
        let first = SpeakerProfile(name: "Dana", embedding: [1])
        let other = SpeakerProfile(name: "Avi", embedding: [2])
        let second = SpeakerProfile(name: "Dana", embedding: [3])
        let speakers = SavedSpeaker.grouping([first, other, second])
        #expect(speakers.map(\.name) == ["Dana", "Avi"])
        #expect(speakers.first?.profileIDs == [first.id, second.id])
        #expect(speakers.last?.profileIDs == [other.id])
        #expect(SavedSpeaker.grouping([]).isEmpty)
    }

    @Test("the untouched ready-made phrases follow the app's language, an edited list does not")
    func quickPhrasesFollowLanguage() {
        let hebrew = AppSettings.defaultQuickPhrases
        let english = AppSettings.defaultQuickPhrasesEnglish
        #expect(hebrew.count == english.count)
        // Stored as Hebrew until anyone chooses: English shows the English list.
        #expect(AppSettings.displayedQuickPhrases(stored: hebrew, language: .english) == english)
        #expect(AppSettings.displayedQuickPhrases(stored: hebrew, language: .hebrew) == hebrew)
        // And back again.
        #expect(AppSettings.displayedQuickPhrases(stored: english, language: .hebrew) == hebrew)
        // A list she has changed is hers, in either language.
        let edited = hebrew + ["תודה רבה"]
        #expect(AppSettings.displayedQuickPhrases(stored: edited, language: .english) == edited)
        #expect(AppSettings.displayedQuickPhrases(stored: [], language: .english).isEmpty)
    }
}
