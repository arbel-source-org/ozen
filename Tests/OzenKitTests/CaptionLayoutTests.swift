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

    @Test("trailing punctuation after a Latin word or a digit gets a mark of its own, anchoring it at the line's end")
    func trailingPunctuationAnchored() {
        let mark = "\u{200F}"
        #expect(CaptionLayout.displayText("תתקשר ב-WhatsApp.").hasSuffix(mark))
        #expect(CaptionLayout.displayText("התרופה היא Acamol!").hasSuffix(mark))
        #expect(CaptionLayout.displayText("בדקו ב-WhatsApp)").hasSuffix(mark))
        // Punctuation after a Hebrew word needs no trailing mark: it's
        // already anchored by the paragraph's own right-to-left context.
        #expect(!CaptionLayout.displayText("מה שלומך?").hasSuffix(mark))
        #expect(!CaptionLayout.displayText("שלום").hasSuffix(mark))
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

@Suite("CaptionLayout numbers in right-to-left lines")
struct CaptionLayoutNumberDirectionTests {
    let open = "\u{2066}", close = "\u{2069}", mark = "\u{200F}"

    @Test("a star code, a number in spaced groups and an international number are each kept left to right in a Hebrew line")
    func numbersIsolated() {
        #expect(CaptionLayout.displayText("תתקשרי לקופה *2700") == mark + "תתקשרי לקופה " + open + "*2700" + close)
        #expect(CaptionLayout.displayText("תתקשרי 050 123 4567 מחר") == mark + "תתקשרי " + open + "050 123 4567" + close + " מחר")
        #expect(CaptionLayout.directed("אליו +972-3-1234567.") == mark + "אליו " + open + "+972-3-1234567" + close + ".")
        #expect(CaptionLayout.directed("המוקד 1-700-50-50-50 פתוח") == mark + "המוקד " + open + "1-700-50-50-50" + close + " פתוח")
    }

    @Test("times, doses and English lines are left as they were, and the numbers still dial from the shown line")
    func otherTextUntouched() {
        #expect(CaptionLayout.displayText("בשעה 10:30, 3 כדורים") == mark + "בשעה 10:30, 3 כדורים")
        #expect(CaptionLayout.displayText("call 050 123 4567", languageCode: "en") == "call 050 123 4567")
        let shown = CaptionLayout.displayText("תתקשרי 050 123 4567 או +972-3-1234567 מחר")
        #expect(PhoneNumbers.matches(in: shown).map(\.dialable) == ["0501234567", "+97231234567"])
    }

    @Test("a copied line keeps its phone number left to right when pasted into a Hebrew chat, and plain words are copied as said")
    func copiedLineKeepsNumbers() {
        #expect(CaptionLayout.copiedText("תתקשרי 050 123 4567 מחר") == "תתקשרי " + open + "050 123 4567" + close + " מחר")
        #expect(CaptionLayout.copiedText("לקופה *2700") == "לקופה " + open + "*2700" + close)
        #expect(CaptionLayout.copiedText("בשעה 10:30, 3 כדורים") == "בשעה 10:30, 3 כדורים")
        #expect(PhoneNumbers.matches(in: CaptionLayout.copiedText("תתקשרי 050 123 4567")).map(\.dialable) == ["0501234567"])
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

    @Test("five quiet minutes between lines puts a time between them, and the name heads the run again")
    func quietGap() {
        func at(_ start: TimeInterval, _ end: TimeInterval, speaker: Int? = 1) -> TranscriptSegment {
            TranscriptSegment(id: UUID(), text: "line", isCommitted: true, speakerClusterID: speaker, startTimestamp: start, lastUpdateTimestamp: end)
        }
        let first = at(1000, 1010)
        #expect(!CaptionLayout.startsAfterQuiet(first, previous: nil))
        #expect(!CaptionLayout.startsAfterQuiet(at(1309, 1320), previous: first))
        #expect(CaptionLayout.startsAfterQuiet(at(1310, 1320), previous: first))
        #expect(!CaptionLayout.showsSpeakerLabel(for: at(1020, 1030), after: first))
        #expect(CaptionLayout.showsSpeakerLabel(for: at(1400, 1410), after: first))
        #expect(!CaptionLayout.showsSpeakerLabel(for: at(1400, 1410, speaker: nil), after: first))
    }

    @Test("two voices with one name are one speaker: her name doesn't head every line")
    func oneNameSeveralVoices() {
        let names = [0: "Savta", 1: "Savta", 2: "Dana"]
        let lines = [line(0), line(1), line(0), line(2), line(1)]
        let shown = lines.indices.map {
            CaptionLayout.showsSpeakerLabel(for: lines[$0], after: $0 > 0 ? lines[$0 - 1] : nil) { names[$0.speakerClusterID ?? -1] ?? "" }
        }
        #expect(shown == [true, false, false, true, true])
        #expect(!CaptionLayout.showsSpeakerLabel(for: line(nil), after: line(0)) { _ in "Savta" })
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

    @Test("six quiet minutes between two saved lines repeats the same speaker's name, like the live view does")
    func quietGapRepeatsName() {
        func at(_ start: TimeInterval, name: String? = "שרה") -> SavedSegment {
            SavedSegment(id: UUID(), text: "שלום", speakerName: name, speakerClusterID: nil, startTimestamp: start, isCommitted: true)
        }
        let first = at(0)
        #expect(!CaptionLayout.startsAfterQuiet(for: at(299), previous: first))
        #expect(CaptionLayout.startsAfterQuiet(for: at(300), previous: first))
        #expect(!CaptionLayout.showsSpeakerLabel(for: at(120), after: first))
        #expect(CaptionLayout.showsSpeakerLabel(for: at(360), after: first))
        #expect(!CaptionLayout.showsSpeakerLabel(for: at(360, name: nil), after: first))
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

@Suite("CaptionLayout lines drawn on the caption screen")
struct CaptionLayoutOnScreenTests {
    @Test("only the newest lines are drawn once there are more than the limit")
    func window() {
        #expect(CaptionLayout.firstOnScreenIndex(lineCount: 0) == 0)
        #expect(CaptionLayout.firstOnScreenIndex(lineCount: CaptionLayout.onScreenLineLimit) == 0)
        #expect(CaptionLayout.firstOnScreenIndex(lineCount: CaptionLayout.onScreenLineLimit + 1) == 1)
        #expect(CaptionLayout.firstOnScreenIndex(lineCount: 20_000) == 20_000 - CaptionLayout.onScreenLineLimit)
    }
}

@Suite("CaptionPipeline with days of lines")
@MainActor
struct CaptionPipelineLongRunTests {
    @Test("an update to the newest line lands on it, however many lines came before")
    func manyLines() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder(), recovery: .disabled)
        await pipeline.start(settings: .default)
        for index in 0..<2_000 {
            engine.emit(TranscriptToken(utteranceID: UUID(), text: "שורה \(index)", isFinal: true, timestamp: 1_000 + Double(index)))
        }
        let open = UUID()
        engine.emit(TranscriptToken(utteranceID: open, text: "עוד", isFinal: false, timestamp: 3_000))
        engine.emit(TranscriptToken(utteranceID: open, text: "עוד מעט", isFinal: true, timestamp: 3_001))
        #expect(await eventually { pipeline.segments.count == 2_001 && pipeline.segments.last?.text == "עוד מעט" })
        #expect(pipeline.segments.last?.isCommitted == true)
        #expect(pipeline.segments.first?.text == "שורה 0")
    }
}

