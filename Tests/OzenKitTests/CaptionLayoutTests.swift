import Foundation
import Testing
@testable import OzenKit

@Suite("CaptionLayout")
struct CaptionLayoutTests {
    @Test("a short line is left exactly as it is")
    func shortLine() {
        #expect(CaptionLayout.readableText("מה שלומך? טוב.") == "מה שלומך? טוב.")
    }

    @Test("a long monologue is broken into paragraphs at sentence ends")
    func longMonologue() {
        let text = "אתמול הלכנו לשוק בבוקר מוקדם. היה שם המון אנשים וקנינו ירקות טריים לכל השבוע. אחר כך ישבנו בבית קפה קטן ליד התחנה. ואז חזרנו הביתה באוטובוס."
        let readable = CaptionLayout.readableText(text)
        let paragraphs = readable.split(separator: "\n")
        #expect(paragraphs.count >= 2)
        #expect(paragraphs.allSatisfy { $0.count <= CaptionLayout.paragraphCharacters })
        // Nothing lost or reordered: only spaces became line breaks.
        #expect(readable.replacingOccurrences(of: "\n", with: " ") == text)
    }

    @Test("sentences are gathered while they fit, so short replies don't each get a line")
    func gathersShortSentences() {
        let text = "כן. בטח. למה לא? " + String(repeating: "מילה ", count: 20) + "סוף."
        let readable = CaptionLayout.readableText(text, paragraphCharacters: 40)
        #expect(readable.hasPrefix("כן. בטח. למה לא?\n"))
    }

    @Test("decimals, abbreviations with gershayim, and quotes after the stop don't split wrongly")
    func noFalseSplits() {
        #expect(CaptionLayout.splitSentences("הוא לקח 3.5 כדורים של ד״ר כהן.") == ["הוא לקח 3.5 כדורים של ד״ר כהן."])
        #expect(CaptionLayout.splitSentences("היא אמרה \"די!\" והלכה. באמת?!  כן") == ["היא אמרה \"די!\"", "והלכה.", "באמת?!", "כן"])
    }

    @Test("in Hebrew every paragraph reads right to left, even one opening with a Latin word")
    func rightToLeftParagraphs() {
        let mark = "\u{200F}"
        #expect(CaptionLayout.displayText("OK, אז נתראה מחר") == mark + "OK, אז נתראה מחר")
        #expect(CaptionLayout.displayText("שלום", languageCode: "he-IL") == mark + "שלום")

        let long = "אתמול הלכנו לשוק בבוקר מוקדם. WhatsApp שלחה הודעה וקנינו ירקות טריים לכל השבוע. אחר כך ישבנו בבית קפה קטן ליד התחנה."
        let shown = CaptionLayout.displayText(long)
        let paragraphs = shown.split(separator: "\n")
        #expect(paragraphs.count >= 2)
        #expect(paragraphs.allSatisfy { $0.hasPrefix(mark) })
        // Only the marks were added.
        #expect(shown.replacingOccurrences(of: mark, with: "") == CaptionLayout.readableText(long))
    }

    @Test("a left-to-right language is shown exactly as laid out")
    func leftToRightUntouched() {
        #expect(CaptionLayout.displayText("OK, see you tomorrow.", languageCode: "en") == "OK, see you tomorrow.")
        #expect(CaptionLayout.directed("OK, see you tomorrow.", languageCode: "en") == "OK, see you tomorrow.")
    }

    @Test("which text would lay itself out left to right")
    func opensLeftToRight() {
        #expect(CaptionLayout.opensLeftToRight("OK, אז נתראה מחר"))
        #expect(CaptionLayout.opensLeftToRight("[10:30:00] WhatsApp שלחה"))
        #expect(CaptionLayout.opensLeftToRight("[10:30:00] סבתא: OK") == false)
        #expect(CaptionLayout.opensLeftToRight("3 כדורים ביום") == false)
        #expect(CaptionLayout.opensLeftToRight("12:30, 3.5 ...") == false)
    }

    @Test("a preview gets the marks without being broken into paragraphs")
    func previewNotParagraphed() {
        let long = "אתמול הלכנו לשוק בבוקר מוקדם. WhatsApp שלחה הודעה וקנינו ירקות טריים לכל השבוע. אחר כך ישבנו בבית קפה קטן ליד התחנה."
        #expect(CaptionLayout.directed(long) == "\u{200F}" + long)
    }

    @Test("a single sentence longer than a paragraph stays whole")
    func oneLongSentence() {
        let text = String(repeating: "מילה ", count: 40).trimmingCharacters(in: .whitespaces)
        #expect(CaptionLayout.readableText(text) == text)
    }
}

@Suite("CaptionLayout speaker labels")
struct CaptionLayoutSpeakerLabelTests {
    private func line(_ cluster: Int?) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), text: "שלום", isCommitted: true, speakerClusterID: cluster, startTimestamp: 0, lastUpdateTimestamp: 0)
    }

    @Test("the name appears when the speaker changes, not on every line")
    func onChangeOnly() {
        let lines = [line(0), line(0), line(1), line(1), line(0)]
        let shown = lines.indices.map { CaptionLayout.showsSpeakerLabel(for: lines[$0], after: $0 > 0 ? lines[$0 - 1] : nil) }
        #expect(shown == [true, false, true, false, true])
    }

    @Test("a line with no identified speaker has no label, and the next identified line gets one")
    func unknownSpeaker() {
        #expect(CaptionLayout.showsSpeakerLabel(for: line(nil), after: nil) == false)
        #expect(CaptionLayout.showsSpeakerLabel(for: line(nil), after: line(2)) == false)
        #expect(CaptionLayout.showsSpeakerLabel(for: line(2), after: line(nil)))
    }
}

@Suite("CaptionLayout speaker labels in saved conversations")
struct CaptionLayoutSavedSpeakerLabelTests {
    private func line(_ name: String?) -> SavedSegment {
        SavedSegment(id: UUID(), text: "שלום", speakerName: name, speakerClusterID: nil, startTimestamp: 0, isCommitted: true)
    }

    @Test("a saved conversation shows each name when the speaker changes")
    func onChangeOnly() {
        let lines = [line("שרה"), line("שרה"), line("דובר 2"), line("שרה")]
        let shown = lines.indices.map { CaptionLayout.showsSpeakerLabel(for: lines[$0], after: $0 > 0 ? lines[$0 - 1] : nil) }
        #expect(shown == [true, false, true, true])
    }

    @Test("unknown-speaker lines have no label and don't break a run")
    func unknownSpeaker() {
        #expect(CaptionLayout.showsSpeakerLabel(for: line(EmbeddingClusterer.unknownSpeakerName), after: nil) == false)
        #expect(CaptionLayout.showsSpeakerLabel(for: line("Unknown speaker"), after: nil) == false)
        #expect(CaptionLayout.showsSpeakerLabel(for: line(nil), after: line("שרה")) == false)
        #expect(CaptionLayout.showsSpeakerLabel(for: line("שרה"), after: line(EmbeddingClusterer.unknownSpeakerName)))
    }
}

@Suite("CaptionLayout time marks in saved conversations")
struct CaptionLayoutTimeMarkTests {
    private func line(at seconds: TimeInterval) -> SavedSegment {
        SavedSegment(id: UUID(), text: "x", speakerName: nil, speakerClusterID: nil, startTimestamp: seconds, isCommitted: true)
    }

    @Test("the first line, then the first line five minutes after the last time shown")
    func marks() {
        let lines = [line(at: 0), line(at: 60), line(at: 299), line(at: 300), line(at: 400), line(at: 700), line(at: 2_000)]
        let marked = CaptionLayout.timeMarkedLineIDs(in: lines)
        #expect(lines.map { marked.contains($0.id) } == [true, false, false, true, false, true, true])
    }

    @Test("no lines, no marks")
    func empty() {
        #expect(CaptionLayout.timeMarkedLineIDs(in: []).isEmpty)
    }
}
