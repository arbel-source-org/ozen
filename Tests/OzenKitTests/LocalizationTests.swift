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
}
