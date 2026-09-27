import Foundation
import Testing
@testable import OzenKit

@Suite("Localization")
struct LocalizationTests {
    @Test("the phone's language picks Hebrew or English; a fixed choice ignores it")
    func resolution() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["he-IL", "en-US"]) == .hebrew)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["iw"]) == .hebrew)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ru-RU", "he-IL"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .hebrew)
        #expect(AppLanguage.hebrew.resolved(preferredLanguages: ["en-US"]) == .hebrew)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["he-IL"]) == .english)
    }

    @Test("tr gives the version for the language in use")
    func pick() {
        #expect(tr("שלום", "Hello", in: .hebrew) == "שלום")
        #expect(tr("שלום", "Hello", in: .english) == "Hello")
        let english = Localization.$override.withValue(.english) { tr("שלום", "Hello") }
        #expect(english == "Hello")
    }

    @Test("a test's own language doesn't leak to others")
    func overrideIsScoped() async {
        await Localization.$override.withValue(.english) {
            await Task.yield()
            #expect(Localization.language == .english)
        }
        #expect(Localization.override == nil)
    }

    @Test("only Hebrew reads right to left")
    func direction() {
        #expect(UILanguage.hebrew.isRightToLeft)
        #expect(!UILanguage.english.isRightToLeft)
    }

    @Test("the voice follows the letters, and the app's language when there are none")
    func speakingVoice() {
        #expect(UILanguage.forSpeaking("שלום, thanks", otherwise: .english) == .hebrew)
        #expect(UILanguage.forSpeaking("Thank you", otherwise: .hebrew) == .english)
        #expect(UILanguage.forSpeaking("10:30", otherwise: .hebrew) == .hebrew)
        #expect(UILanguage.forSpeaking("10:30", otherwise: .english) == .english)
        #expect(UILanguage.forSpeaking("Привет", otherwise: .hebrew) == .hebrew)
    }

    @Test("dates are written in the app's language, not the phone's, keeping the phone's region")
    func dateLanguage() {
        let hebrew = UILanguage.hebrew.locale(keepingRegionOf: Locale(identifier: "en_GB"))
        #expect(hebrew.language.languageCode?.identifier == "he")
        #expect(hebrew.region?.identifier == "GB")
        let english = UILanguage.english.locale(keepingRegionOf: Locale(identifier: "he_IL"))
        #expect(english.language.languageCode?.identifier == "en")
        #expect(english.region?.identifier == "IL")

        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)
        let inHebrew = date.formatted(style.locale(hebrew))
        let inEnglish = date.formatted(style.locale(english))
        #expect(inHebrew.unicodeScalars.contains { (0x05D0...0x05EA).contains($0.value) })
        #expect(!inEnglish.unicodeScalars.contains { (0x05D0...0x05EA).contains($0.value) })
        #expect(inEnglish.contains("Oct") || inEnglish.contains("Sep"))
    }
}
