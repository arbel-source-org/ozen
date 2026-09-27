import Foundation
import Testing
@testable import OzenKit

@Suite("Localization")
struct LocalizationTests {
    @Test("the phone's preferred languages resolve to the first one that's supported; Hebrew is the fallback")
    func resolution() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["he-IL", "en-US"]) == .hebrew)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["iw"]) == .hebrew)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ru-RU", "he-IL"]) == .russian)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ar-EG"]) == .arabic)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-CA", "en-US"]) == .french)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-US", "en-US"]) == .chineseSimplified)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]) == .chineseSimplified)
        // A preference nobody supports is skipped in favor of the next one...
        #expect(AppLanguage.system.resolved(preferredLanguages: ["da-DK", "de-DE"]) == .german)
        // ...and falls back to Hebrew when none of them are supported at all.
        #expect(AppLanguage.system.resolved(preferredLanguages: ["da-DK"]) == .hebrew)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .hebrew)
        #expect(AppLanguage.hebrew.resolved(preferredLanguages: ["en-US"]) == .hebrew)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["he-IL"]) == .english)
        #expect(AppLanguage.arabic.resolved(preferredLanguages: ["en-US"]) == .arabic)
        #expect(AppLanguage.hindi.resolved(preferredLanguages: []) == .hindi)
    }

    @Test("tr gives the version for the language in use")
    func pick() {
        #expect(tr("שלום", "Hello", in: .hebrew) == "שלום")
        #expect(tr("שלום", "Hello", in: .english) == "Hello")
        let english = Localization.$override.withValue(.english) { tr("שלום", "Hello") }
        #expect(english == "Hello")
    }

    @Test("every language beyond Hebrew and English is looked up in the translation table")
    func translatedLanguages() {
        #expect(tr("ביטול", "Cancel", in: .arabic) == "إلغاء")
        #expect(tr("ביטול", "Cancel", in: .russian) == "Отмена")
        #expect(tr("ביטול", "Cancel", in: .french) == "Annuler")
        #expect(tr("ביטול", "Cancel", in: .german) == "Abbrechen")
        #expect(tr("ביטול", "Cancel", in: .spanish) == "Cancelar")
    }

    @Test("a key missing from a language's table falls back to English, never to an empty string")
    func fallbackToEnglish() {
        let notInAnyTable = "There is definitely no translation for this exact sentence anywhere"
        #expect(tr("אין תרגום כזה", notInAnyTable, in: .french) == notInAnyTable)
        #expect(tr("אין תרגום כזה", notInAnyTable, in: .hindi) == notInAnyTable)
        #expect(!tr("אין תרגום כזה", notInAnyTable, in: .amharic).isEmpty)
    }

    @Test("an interpolated string is translated as a template, with the values still substituted in")
    func templatedTranslation() {
        let french = tr("הסוללה ב-%1%", "Battery at %1%", args: ["42"], in: .french)
        #expect(french.contains("42"))
        #expect(french != "Battery at 42%")
        let english = tr("הסוללה ב-%1%", "Battery at %1%", args: ["42"], in: .english)
        #expect(english == "Battery at 42%")
        let hebrew = tr("הסוללה ב-%1%", "Battery at %1%", args: ["42"], in: .hebrew)
        #expect(hebrew == "הסוללה ב-42%")
    }

    @Test("a template used twice repeats the same value both times")
    func templatedTranslationRepeatsPlaceholder() {
        let result = tr("%1 מתוך %1, הכי איטי", "%1 of %1, slowest", args: ["7"], in: .english)
        #expect(result == "7 of 7, slowest")
    }

    @Test("a test's own language doesn't leak to others")
    func overrideIsScoped() async {
        await Localization.$override.withValue(.english) {
            await Task.yield()
            #expect(Localization.language == .english)
        }
        #expect(Localization.override == nil)
    }

    @Test("Hebrew and Arabic read right to left; every other language reads left to right")
    func direction() {
        #expect(UILanguage.hebrew.isRightToLeft)
        #expect(UILanguage.arabic.isRightToLeft)
        #expect(!UILanguage.english.isRightToLeft)
        for language in UILanguage.allCases where language != .hebrew && language != .arabic {
            #expect(!language.isRightToLeft, "\(language) should read left to right")
        }
    }

    @Test("the voice follows the letters, and the app's language when there are none")
    func speakingVoice() {
        #expect(UILanguage.forSpeaking("שלום, thanks", otherwise: .english) == .hebrew)
        #expect(UILanguage.forSpeaking("Thank you", otherwise: .hebrew) == .english)
        #expect(UILanguage.forSpeaking("10:30", otherwise: .hebrew) == .hebrew)
        #expect(UILanguage.forSpeaking("10:30", otherwise: .english) == .english)
        #expect(UILanguage.forSpeaking("Привет", otherwise: .hebrew) == .russian)
        #expect(UILanguage.forSpeaking("Дякую", otherwise: .ukrainian) == .ukrainian)
        #expect(UILanguage.forSpeaking("Я не зрозуміла", otherwise: .hebrew) == .ukrainian)
        #expect(UILanguage.forSpeaking("شكرًا", otherwise: .english) == .arabic)
        #expect(UILanguage.forSpeaking("አመሰግናለሁ", otherwise: .english) == .amharic)
        #expect(UILanguage.forSpeaking("धन्यवाद", otherwise: .english) == .hindi)
        #expect(UILanguage.forSpeaking("谢谢", otherwise: .english) == .chineseSimplified)
        #expect(UILanguage.forSpeaking("Merci", otherwise: .french) == .french)
        #expect(UILanguage.forSpeaking("Não", otherwise: .portuguese) == .portuguese)
        #expect(UILanguage.forSpeaking("Merci", otherwise: .arabic) == .english)
        #expect(UILanguage.forSpeaking("10:30", otherwise: .german) == .german)
    }

    @Test("every language's ready-made phrases are read by that language's voice")
    func quickPhrasesSpeakInTheirOwnLanguage() {
        for language in UILanguage.allCases {
            for phrase in AppSettings.defaultQuickPhrases(for: language) {
                #expect(UILanguage.forSpeaking(phrase, otherwise: language) == language, "\(language): \(phrase)")
            }
        }
    }

    @Test("text in a language the phone has no voice for is held back; Hebrew still follows the Hebrew voice")
    @MainActor
    func heldBackWithoutAVoice() {
        let synthesizer = FakeSynthesizer()
        #expect(synthesizer.canSay("שלום"))
        synthesizer.hasHebrewVoice = false
        #expect(!synthesizer.canSay("שלום"))
        #expect(synthesizer.canSay("Thank you"))
        #expect(synthesizer.canSay("شكرًا"))

        synthesizer.missingVoices = [.amharic]
        #expect(!synthesizer.canSay("አመሰግናለሁ"))
        #expect(synthesizer.canSay("شكرًا"))
        #expect(!synthesizer.hasVoiceOrOwnHint(for: .amharic))
        #expect(synthesizer.hasVoiceOrOwnHint(for: .arabic))
        #expect(synthesizer.hasVoiceOrOwnHint(for: .hebrew))
        #expect(synthesizer.hasVoiceOrOwnHint(for: .english))
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

    @Test("every supported language formats a date in its own script or wording, keeping the phone's region")
    func dateLanguageForNewLanguages() {
        let base = Locale(identifier: "en_US")
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)
        for language in UILanguage.allCases {
            let locale = language.locale(keepingRegionOf: base)
            #expect(locale.region?.identifier == "US")
            let formatted = date.formatted(style.locale(locale))
            #expect(!formatted.isEmpty)
        }
        let chinese = UILanguage.chineseSimplified.locale(keepingRegionOf: base)
        #expect(chinese.language.languageCode?.identifier == "zh")
        #expect(chinese.language.script?.identifier == "Hans")
    }

    @Test("the Settings picker shows every language by its own name")
    func nativeNames() {
        #expect(UILanguage.hebrew.nativeName == "עברית")
        #expect(UILanguage.english.nativeName == "English")
        #expect(UILanguage.arabic.nativeName == "العربية")
        #expect(UILanguage.russian.nativeName == "Русский")
        #expect(UILanguage.amharic.nativeName == "አማርኛ")
        #expect(UILanguage.french.nativeName == "Français")
        #expect(UILanguage.spanish.nativeName == "Español")
        #expect(UILanguage.ukrainian.nativeName == "Українська")
        #expect(UILanguage.german.nativeName == "Deutsch")
        #expect(UILanguage.portuguese.nativeName == "Português")
        #expect(UILanguage.chineseSimplified.nativeName == "简体中文")
        #expect(UILanguage.hindi.nativeName == "हिन्दी")
    }
}
