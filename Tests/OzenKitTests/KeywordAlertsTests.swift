import Foundation
import Testing
@testable import OzenKit

@Suite("KeywordAlertMatcher")
struct KeywordAlertMatcherTests {
    private func alert(_ phrase: String, isEnabled: Bool = true) -> KeywordAlert {
        KeywordAlert(phrase: phrase, isEnabled: isEnabled)
    }

    @Test("an exact word match is found")
    func exactMatch() {
        let grandma = alert("סבתא")
        let matcher = KeywordAlertMatcher(alerts: [grandma])
        let matches = matcher.matches(in: "היום סבתא באה לבקר")
        #expect(matches.count == 1)
        #expect(matches[0].alertID == grandma.id)
        #expect(matches[0].phrase == "סבתא")
        #expect(matches[0].matchedText == "סבתא")
        #expect(matches[0].wordIndex == 1)
    }

    @Test("every single-letter attached prefix matches the stem")
    func everySingleLetterPrefixMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סבתא")])
        for letter in ["ו", "ה", "ב", "ל", "מ", "ש", "כ"] {
            let word = letter + "סבתא"
            let matches = matcher.matches(in: "שלום \(word) שלום")
            #expect(matches.count == 1, "prefix \(letter) should match")
            #expect(matches.first?.matchedText == word)
        }
    }

    @Test("stacked attached prefixes match the stem")
    func stackedPrefixesMatch() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סבתא")])
        for stacked in ["וה", "כש", "וכש"] {
            let word = stacked + "סבתא"
            let matches = matcher.matches(in: "אתמול \(word) ישנה")
            #expect(matches.count == 1, "stacked prefix \(stacked) should match")
        }
    }

    @Test("a prefix that stacks on the article matches the stem")
    func prefixStackedOnArticleMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("רופא")])
        for stacked in ["כשה", "וכשה", "ומה", "שמה"] {
            let word = stacked + "רופא"
            let matches = matcher.matches(in: "אתמול \(word) אמר לחכות")
            #expect(matches.count == 1, "stacked prefix \(stacked) should match")
            #expect(matches.first?.matchedText == word)
        }
    }

    @Test("a name starting with the letter he does not fire on an everyday word that only looks like it with a preposition swapped in")
    func nameStartingWithHeDoesNotMatchSwappedLetter() {
        let matcher = KeywordAlertMatcher(alerts: [alert("הילה"), alert("הלל")])
        #expect(matcher.matches(in: "לילה טוב, זה בכלל לא חשוב").isEmpty)
        #expect(matcher.matches(in: "להילה ולהלל").count == 2)
    }

    @Test("a suffix change is not treated as a match")
    func suffixChangeDoesNotMatch() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סבתא")])
        #expect(matcher.matches(in: "כל הסבתאות באו").isEmpty)
    }

    @Test("a shorter name inside a longer one is not a match")
    func shortNameInsideLongerNameDoesNotMatch() {
        let matcher = KeywordAlertMatcher(alerts: [alert("דן")])
        #expect(matcher.matches(in: "דנה הגיעה הביתה").isEmpty)
    }

    @Test("niqqud on the caption does not block a match against a plain phrase")
    func niqqudOnCaptionMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סבתא")])
        let matches = matcher.matches(in: "היום סָבְתָא הגיעה")
        #expect(matches.count == 1)
    }

    @Test("niqqud on the phrase itself does not block a match")
    func niqqudOnPhraseMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סָבְתָא")])
        let matches = matcher.matches(in: "היום סבתא הגיעה")
        #expect(matches.count == 1)
    }

    @Test("punctuation and quotes around the word do not block a match")
    func surroundingPunctuationDoesNotBlockMatch() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סבתא")])
        #expect(matcher.matches(in: "היום סבתא, הגיעה").count == 1)
        #expect(matcher.matches(in: "היום \"סבתא\" הגיעה").count == 1)
        #expect(matcher.matches(in: "היום סבתא! הגיעה").count == 1)
    }

    @Test("a Latin phrase matches regardless of case")
    func latinPhraseIsCaseInsensitive() {
        let matcher = KeywordAlertMatcher(alerts: [alert("dana")])
        let matches = matcher.matches(in: "I saw Dana today")
        #expect(matches.count == 1)
        #expect(matches[0].matchedText == "Dana")
    }

    @Test("a multi-word phrase matches only when its words are consecutive")
    func multiWordPhraseRequiresConsecutiveWords() {
        let matcher = KeywordAlertMatcher(alerts: [alert("בית חולים")])
        #expect(matcher.matches(in: "נסענו לבית חולים דחוף").isEmpty == false)
        #expect(matcher.matches(in: "נסענו לבית גדול וגם חולים").isEmpty)
    }

    @Test("an attached prefix on the first word of a multi-word phrase still matches")
    func prefixOnFirstWordOfMultiWordPhraseMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("בית חולים")])
        let matches = matcher.matches(in: "נסענו לבית חולים דחוף")
        #expect(matches.count == 1)
        #expect(matches[0].matchedText == "לבית חולים")
        #expect(matches[0].wordIndex == 1)
    }

    @Test("two occurrences of the same keyword yield two matches in caption order")
    func twoOccurrencesYieldTwoMatches() {
        let grandma = alert("סבתא")
        let matcher = KeywordAlertMatcher(alerts: [grandma])
        let matches = matcher.matches(in: "סבתא אמרה לסבתא שלום")
        #expect(matches.count == 2)
        #expect(matches[0].wordIndex == 0)
        #expect(matches[0].matchedText == "סבתא")
        #expect(matches[1].wordIndex == 2)
        #expect(matches[1].matchedText == "לסבתא")
    }

    @Test("a disabled alert never matches")
    func disabledAlertNeverMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("סבתא", isEnabled: false)])
        #expect(matcher.matches(in: "היום סבתא הגיעה").isEmpty)
    }

    @Test("a blank phrase never matches")
    func blankPhraseNeverMatches() {
        let matcher = KeywordAlertMatcher(alerts: [alert("   ")])
        #expect(matcher.matches(in: "היום סבתא הגיעה").isEmpty)
    }

    @Test("matches from two different alerts in one caption are both reported in caption order")
    func twoDifferentAlertsBothMatch() {
        let grandma = alert("סבתא")
        let ambulance = alert("אמבולנס")
        let matcher = KeywordAlertMatcher(alerts: [ambulance, grandma])
        let matches = matcher.matches(in: "סבתא קראה לאמבולנס")
        #expect(matches.count == 2)
        #expect(matches[0].alertID == grandma.id)
        #expect(matches[0].wordIndex == 0)
        #expect(matches[1].alertID == ambulance.id)
        #expect(matches[1].wordIndex == 2)
    }
}

@Suite("KeywordAlertDeduplicator")
struct KeywordAlertDeduplicatorTests {
    @Test("repeated partial updates for the same utterance fire a match only once")
    func repeatedPartialUpdatesFireOnce() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()
        let utteranceID = UUID()

        let firstMatches = matcher.matches(in: "היום")
        let firstReported = deduplicator.newMatches(utteranceID: utteranceID, matches: firstMatches)
        #expect(firstReported.isEmpty)

        let secondMatches = matcher.matches(in: "היום סבתא")
        let secondReported = deduplicator.newMatches(utteranceID: utteranceID, matches: secondMatches)
        #expect(secondReported.count == 1)

        let thirdMatches = matcher.matches(in: "היום סבתא אכלה")
        let thirdReported = deduplicator.newMatches(utteranceID: utteranceID, matches: thirdMatches)
        #expect(thirdReported.isEmpty)
    }

    @Test("a genuinely new occurrence later in the same utterance still fires")
    func newOccurrenceLaterInSameUtteranceFires() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()
        let utteranceID = UUID()

        let firstMatches = matcher.matches(in: "סבתא הגיעה")
        let firstReported = deduplicator.newMatches(utteranceID: utteranceID, matches: firstMatches)
        #expect(firstReported.count == 1)

        let secondMatches = matcher.matches(in: "סבתא הגיעה וגם סבתא התקשרה")
        let secondReported = deduplicator.newMatches(utteranceID: utteranceID, matches: secondMatches)
        #expect(secondReported.count == 1)
        #expect(secondReported[0].wordIndex == 3)
    }

    @Test("a later pass that drops an earlier word moves the name, and it is still the same mention")
    func revisionThatShiftsTheWordIsNotANewMention() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()
        let utteranceID = UUID()

        let first = deduplicator.newMatches(utteranceID: utteranceID, matches: matcher.matches(in: "אה בקיצור סבתא התקשרה"))
        #expect(first.count == 1)
        let revised = deduplicator.newMatches(utteranceID: utteranceID, matches: matcher.matches(in: "אה סבתא התקשרה"))
        #expect(revised.isEmpty)
        let longer = deduplicator.newMatches(utteranceID: utteranceID, matches: matcher.matches(in: "בקיצור אה סבתא התקשרה אתמול"))
        #expect(longer.isEmpty)
    }

    @Test("a different utterance fires again for the same keyword")
    func differentUtteranceFiresAgain() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()

        let matches = matcher.matches(in: "סבתא הגיעה")
        let firstReported = deduplicator.newMatches(utteranceID: UUID(), matches: matches)
        let secondReported = deduplicator.newMatches(utteranceID: UUID(), matches: matches)
        #expect(firstReported.count == 1)
        #expect(secondReported.count == 1)
    }

    @Test("forget resets an utterance so its matches can fire again")
    func forgetResetsUtterance() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()
        let utteranceID = UUID()

        let matches = matcher.matches(in: "סבתא הגיעה")
        let firstReported = deduplicator.newMatches(utteranceID: utteranceID, matches: matches)
        #expect(firstReported.count == 1)

        deduplicator.forget(utteranceID: utteranceID)

        let secondReported = deduplicator.newMatches(utteranceID: utteranceID, matches: matches)
        #expect(secondReported.count == 1)
    }

    @Test("forgetAll resets every utterance")
    func forgetAllResetsEveryUtterance() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()
        let firstUtterance = UUID()
        let secondUtterance = UUID()
        let matches = matcher.matches(in: "סבתא הגיעה")

        _ = deduplicator.newMatches(utteranceID: firstUtterance, matches: matches)
        _ = deduplicator.newMatches(utteranceID: secondUtterance, matches: matches)
        deduplicator.forgetAll()

        #expect(deduplicator.newMatches(utteranceID: firstUtterance, matches: matches).count == 1)
        #expect(deduplicator.newMatches(utteranceID: secondUtterance, matches: matches).count == 1)
    }

    @Test("tracking is bounded to the 64 most recent utterances, evicting the oldest")
    func trackingIsBoundedAndEvictsOldest() {
        let alert = KeywordAlert(phrase: "סבתא")
        let matcher = KeywordAlertMatcher(alerts: [alert])
        var deduplicator = KeywordAlertDeduplicator()
        let matches = matcher.matches(in: "סבתא הגיעה")

        let firstUtterance = UUID()
        let firstReported = deduplicator.newMatches(utteranceID: firstUtterance, matches: matches)
        #expect(firstReported.count == 1)

        // 64 more distinct utterances push the tracker to 65 tracked ids,
        // one over the cap, which must evict `firstUtterance`.
        for _ in 0..<64 {
            _ = deduplicator.newMatches(utteranceID: UUID(), matches: matches)
        }

        let reportedAgain = deduplicator.newMatches(utteranceID: firstUtterance, matches: matches)
        #expect(reportedAgain.count == 1)
    }
}

@Suite("KeywordAlert decoding")
struct KeywordAlertDecodingTests {
    @Test("a saved alert with no isEnabled key decodes as enabled")
    func missingIsEnabledDecodesAsEnabled() throws {
        let json = """
        {"id":"\(UUID().uuidString)","phrase":"סבתא"}
        """.data(using: .utf8)!
        let alert = try JSONDecoder().decode(KeywordAlert.self, from: json)
        #expect(alert.isEnabled)
        #expect(alert.phrase == "סבתא")
    }

    @Test("hyphenated, maqaf-joined and spaced forms of a name match each other")
    func joinedForms() {
        let matcher = KeywordAlertMatcher(alerts: [KeywordAlert(phrase: "תל אביב")])
        #expect(matcher.matches(in: "נסענו לתל-אביב אתמול").count == 1)
        #expect(matcher.matches(in: "נסענו לתל\u{05BE}אביב אתמול").count == 1)
        let hyphenated = KeywordAlertMatcher(alerts: [KeywordAlert(phrase: "בן-דוד")])
        #expect(hyphenated.matches(in: "הגיע בן דוד שלי").count == 1)
        #expect(HebrewText.normalize("תל-אביב") == HebrewText.normalize("תל אביב"))
    }
}

@Suite("KeywordAttentionPolicy")
struct KeywordAttentionPolicyTests {
    private func hit(_ alertID: UUID, at timestamp: TimeInterval) -> KeywordHit {
        KeywordHit(segmentID: UUID(), match: KeywordMatch(alertID: alertID, phrase: "סבתא", matchedText: "סבתא", wordIndex: 0), timestamp: timestamp)
    }

    @Test("her name gets her attention, then not again for every mention right after")
    func repeatsInsideCooldownAreQuiet() {
        var policy = KeywordAttentionPolicy(cooldownSeconds: 15)
        let name = UUID()
        let atFirst = policy.claimAttention(for: hit(name, at: 100))
        #expect(atFirst)
        let fourSecondsLater = policy.claimAttention(for: hit(name, at: 104))
        #expect(!fourSecondsLater)
        let fourteenSecondsLater = policy.claimAttention(for: hit(name, at: 114))
        #expect(!fourteenSecondsLater)
    }

    @Test("said again once the cooldown has passed, it gets her attention again, counted from the last time it did")
    func afterCooldownAttentionAgain() {
        var policy = KeywordAttentionPolicy(cooldownSeconds: 15)
        let name = UUID()
        let atFirst = policy.claimAttention(for: hit(name, at: 100))
        #expect(atFirst)
        let tenSecondsLater = policy.claimAttention(for: hit(name, at: 110))
        #expect(!tenSecondsLater)
        // 15 s after the buzz, not after the quiet mention at 110.
        let fifteenSecondsAfterTheBuzz = policy.claimAttention(for: hit(name, at: 115))
        #expect(fifteenSecondsAfterTheBuzz)
    }

    @Test("a clock set back an hour doesn't hold back the next time her name is said")
    func clockSetBack() {
        var policy = KeywordAttentionPolicy(cooldownSeconds: 15)
        let name = UUID()
        let before = policy.claimAttention(for: hit(name, at: 10_000))
        #expect(before)
        let afterTheClockWentBack = policy.claimAttention(for: hit(name, at: 10_000 - 3_600 + 30))
        #expect(afterTheClockWentBack)
    }

    @Test("a different word is not held back by the first one")
    func wordsAreIndependent() {
        var policy = KeywordAttentionPolicy(cooldownSeconds: 15)
        let firstWord = policy.claimAttention(for: hit(UUID(), at: 100))
        #expect(firstWord)
        let otherWordASecondLater = policy.claimAttention(for: hit(UUID(), at: 101))
        #expect(otherWordASecondLater)
    }
}
