import Testing
import Foundation
@testable import OzenKit

@Suite("Plural rules for the other ten languages")
struct PluralizationTests {
    private let hebrewLetters = ClosedRange<UInt32>(uncheckedBounds: (0x0590, 0x05FF))

    private func hasHebrewLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { hebrewLetters.contains($0.value) }
    }

    @Test("Russian one/few/many at the numbers where they actually differ")
    func russianEdgeNumbers() {
        Localization.$override.withValue(.russian) {
            #expect(ConversationStats.wordsText(1) == "1 слово")
            #expect(ConversationStats.wordsText(2) == "2 слова")
            #expect(ConversationStats.wordsText(5) == "5 слов")
            #expect(ConversationStats.wordsText(11) == "11 слов")
            #expect(ConversationStats.wordsText(21) == "21 слово")
            #expect(ConversationStats.wordsText(22) == "22 слова")
            #expect(ConversationStats.wordsText(25) == "25 слов")

            let starred = (singular: "מסומנת", plural: "מסומנות")
            #expect(ConversationStats.linesText(1, adjective: starred, englishAdjective: "new") == "1 новая строка")
            #expect(ConversationStats.linesText(3, adjective: starred, englishAdjective: "new") == "3 новые строки")
            #expect(ConversationStats.linesText(11, adjective: starred, englishAdjective: "new") == "11 новых строк")
        }
    }

    @Test("Arabic's zero/one/two/few/many/other, with its dual")
    func arabicEdgeNumbers() {
        Localization.$override.withValue(.arabic) {
            #expect(ConversationStats.linesText(0) == "0 سطر")
            #expect(ConversationStats.linesText(1) == "سطر")
            #expect(ConversationStats.linesText(2) == "سطران")
            #expect(ConversationStats.linesText(3) == "3 أسطر")
            #expect(ConversationStats.linesText(11) == "11 سطر")
            #expect(ConversationStats.linesText(100) == "100 سطر")

            #expect(ConversationStats.wordsText(0) == "لا كلمات")
            #expect(ConversationStats.wordsText(1) == "كلمة")
            #expect(ConversationStats.wordsText(2) == "كلمتان")
            #expect(ConversationStats.wordsText(3) == "3 كلمات")
            #expect(ConversationStats.wordsText(11) == "11 كلمة")
            #expect(ConversationStats.wordsText(100) == "100 كلمة")
        }
    }

    @Test("Speaking pace takes the word's form from the number")
    func speakingPace() {
        let expected: [(UILanguage, Double, String)] = [
            (.hebrew, 120, "120 מילים לדקה"),
            (.english, 120, "120 words per minute"),
            (.russian, 101, "101 слово в минуту"),
            (.russian, 102, "102 слова в минуту"),
            (.russian, 105, "105 слов в минуту"),
            (.ukrainian, 122, "122 слова за хвилину"),
            (.ukrainian, 125, "125 слів за хвилину"),
            (.arabic, 104, "104 كلمات في الدقيقة"),
            (.arabic, 120, "120 كلمة في الدقيقة"),
            (.german, 120, "120 Wörter pro Minute"),
            (.chineseSimplified, 120, "每分钟 120 字"),
        ]
        for (language, pace, text) in expected {
            Localization.$override.withValue(language) {
                #expect(ConversationStats.paceText(pace) == text, "\(language) \(pace)")
            }
        }
    }

    @Test("a voice sample's recording progress is read out with the right word form")
    func secondsSpoken() {
        let expected: [(UILanguage, Int, String)] = [
            (.hebrew, 1, "שנייה אחת"), (.hebrew, 2, "שתי שניות"), (.hebrew, 7, "7 שניות"),
            (.english, 1, "1 second"), (.english, 7, "7 seconds"),
            (.russian, 1, "1 секунда"), (.russian, 3, "3 секунды"), (.russian, 7, "7 секунд"),
            (.arabic, 1, "ثانية"), (.arabic, 5, "5 ثوانٍ"),
            (.german, 1, "1 Sekunde"), (.german, 7, "7 Sekunden"),
        ]
        for (language, count, text) in expected {
            Localization.$override.withValue(language) {
                #expect(ConversationStats.secondsText(count) == text, "\(language) \(count)")
            }
        }
    }

    @Test("a download's minutes left take the form 'about' needs: Russian and Ukrainian 21, 31, 41, 51; Arabic 3 to 10")
    func aboutMinutesLeft() {
        let expected: [(UILanguage, Int, String)] = [
            (.hebrew, 5, "עוד כ-5 דקות"),
            (.english, 21, "About 21 minutes left"),
            (.russian, 5, "Осталось около 5 минут"),
            (.russian, 21, "Осталось около 21 минуты"),
            (.russian, 11, "Осталось около 11 минут"),
            (.ukrainian, 31, "Залишилося близько 31 хвилини"),
            (.ukrainian, 12, "Залишилося близько 12 хвилин"),
            (.arabic, 5, "تبقّى نحو 5 دقائق"),
            (.arabic, 12, "تبقّى نحو 12 دقيقة"),
            (.german, 21, "Noch etwa 21 Minuten"),
        ]
        for (language, minutes, text) in expected {
            Localization.$override.withValue(language) {
                #expect(ConversationStats.aboutMinutesLeftText(minutes) == text, "\(language) \(minutes)")
            }
        }
    }

    @Test("'N old conversations will be deleted now' agrees with the number in Russian, Ukrainian and Arabic")
    func oldConversationsDeleted() {
        let expected: [(UILanguage, Int, String)] = [
            (.hebrew, 12, "12 שיחות ישנות יימחקו עכשיו"),
            (.english, 21, "21 old conversations will be deleted now"),
            (.russian, 3, "3 старых разговора будут удалены сейчас"),
            (.russian, 5, "5 старых разговоров будут удалены сейчас"),
            (.russian, 21, "21 старый разговор будет удалён сейчас"),
            (.russian, 13, "13 старых разговоров будут удалены сейчас"),
            (.ukrainian, 3, "3 старі розмови буде видалено зараз"),
            (.ukrainian, 21, "21 стару розмову буде видалено зараз"),
            (.ukrainian, 11, "11 старих розмов буде видалено зараз"),
            (.arabic, 5, "سيتم الآن حذف 5 محادثات قديمة"),
            (.arabic, 12, "سيتم الآن حذف 12 محادثة قديمة"),
        ]
        for (language, count, text) in expected {
            Localization.$override.withValue(language) {
                #expect(ConversationStats.oldConversationsDeletedText(count) == text, "\(language) \(count)")
            }
        }
    }

    @Test("French treats zero the same as one, unlike everything else")
    func frenchEdgeNumbers() {
        Localization.$override.withValue(.french) {
            #expect(ConversationStats.linesText(0) == "0 ligne")
            #expect(ConversationStats.linesText(1) == "1 ligne")
            #expect(ConversationStats.linesText(2) == "2 lignes")
            #expect(ConversationStats.linesText(3, englishAdjective: "new") == "3 nouvelles lignes")
            #expect(ConversationStats.linesText(1, englishAdjective: "new") == "1 nouvelle ligne")
        }
    }

    @Test("Chinese has no plural at all")
    func chineseEdgeNumbers() {
        Localization.$override.withValue(.chineseSimplified) {
            #expect(ConversationStats.wordsText(1) == "1 字")
            #expect(ConversationStats.wordsText(2) == "2 字")
            #expect(ConversationStats.linesText(1) == "1 行")
            #expect(ConversationStats.linesText(2) == "2 行")
        }
    }

    @Test("\"5 minutes ago\" in every one of the other ten languages")
    func fiveMinutesAgoEverywhere() {
        let expected: [UILanguage: String] = [
            .russian: "5 минут назад",
            .french: "il y a 5 minutes",
            .german: "vor 5 Minuten",
            .spanish: "hace 5 minutos",
            .portuguese: "há 5 minutos",
            .chineseSimplified: "5 分钟前",
            .hindi: "5 मिनट पहले",
            .arabic: "قبل 5 دقائق",
            .ukrainian: "5 хвилин тому",
            .amharic: "ከ5 ደቂቃ በፊት",
        ]
        for (language, text) in expected {
            Localization.$override.withValue(language) {
                #expect(HebrewTime.minutesAgo(5) == text, "\(language)")
            }
        }
    }

    @Test("Russian and Ukrainian \"a minute ago\" and \"an hour ago\" take the form that follows \"ago\"")
    func slavicAgoCase() {
        let expected: [(UILanguage, Int, String)] = [
            (.russian, 1, "1 минуту назад"),
            (.russian, 21, "21 минуту назад"),
            (.russian, 3, "3 минуты назад"),
            (.russian, 11, "11 минут назад"),
            (.russian, 60, "1 час назад"),
            (.ukrainian, 1, "1 хвилину тому"),
            (.ukrainian, 31, "31 хвилину тому"),
            (.ukrainian, 4, "4 хвилини тому"),
            (.ukrainian, 60, "1 годину тому"),
            (.ukrainian, 120, "2 години тому"),
            (.ukrainian, 300, "5 годин тому"),
        ]
        for (language, minutes, text) in expected {
            Localization.$override.withValue(language) {
                #expect(HebrewTime.minutesAgo(minutes) == text, "\(language) \(minutes)")
            }
        }
    }

    @Test("no function leaks a Hebrew word into another language's text")
    func noHebrewLeak() {
        for language in UILanguage.allCases where language != .hebrew {
            Localization.$override.withValue(language) {
                let counts = [0, 1, 2, 3, 5, 10, 11, 20, 21, 22, 25, 50, 60, 99, 100, 101]
                for count in counts {
                    #expect(!hasHebrewLetters(ConversationStats.wordsText(count)), "\(language) wordsText(\(count))")
                    #expect(!hasHebrewLetters(ConversationStats.speakersText(count)), "\(language) speakersText(\(count))")
                    #expect(!hasHebrewLetters(ConversationStats.linesText(count)), "\(language) linesText(\(count))")
                    let starred = (singular: "מסומנת", plural: "מסומנות")
                    #expect(!hasHebrewLetters(ConversationStats.linesText(count, adjective: starred, englishAdjective: "starred")), "\(language) linesText(\(count), starred)")
                    #expect(!hasHebrewLetters(ConversationStats.linesText(count, adjective: starred, englishAdjective: "new")), "\(language) linesText(\(count), new)")
                    #expect(!hasHebrewLetters(ConversationStats.linesText(count, englishAdjective: "unheardof")), "\(language) linesText(\(count), unheardof)")
                    #expect(!hasHebrewLetters(HebrewTime.minutesAgo(count)), "\(language) minutesAgo(\(count))")
                }
                let seconds: [Double] = [0, 20, 60, 90, 3600, 3660, 4500, 7200, 12000]
                for value in seconds {
                    #expect(!hasHebrewLetters(ConversationStats.minutesText(value)), "\(language) minutesText(\(value))")
                }
            }
        }
    }

    @Test("an adjective this file doesn't know falls back to English, never Hebrew")
    func unknownAdjectiveFallsBackToEnglish() {
        Localization.$override.withValue(.russian) {
            #expect(ConversationStats.linesText(3, englishAdjective: "unheardof") == "3 unheardof lines")
        }
    }
}
