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

    @Test("a single sentence longer than a paragraph stays whole")
    func oneLongSentence() {
        let text = String(repeating: "מילה ", count: 40).trimmingCharacters(in: .whitespaces)
        #expect(CaptionLayout.readableText(text) == text)
    }
}
