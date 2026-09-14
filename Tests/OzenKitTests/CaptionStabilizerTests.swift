import Testing
@testable import OzenKit
import Foundation

@Suite("CaptionStabilizer")
struct CaptionStabilizerTests {

    @Test("a single final token becomes one committed segment")
    func singleFinalToken() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        let segment = stabilizer.ingest(
            TranscriptToken(utteranceID: id, text: "שלום", isFinal: true, timestamp: 0)
        )
        #expect(segment.text == "שלום")
        #expect(segment.isCommitted)
        #expect(stabilizer.segments.count == 1)
    }

    @Test("repeated partial tokens for the same utterance update in place, not append")
    func partialTokensUpdateInPlace() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "אני", isFinal: false, timestamp: 0))
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "אני רוצה", isFinal: false, timestamp: 0.3))
        let final = stabilizer.ingest(TranscriptToken(utteranceID: id, text: "אני רוצה לשתות", isFinal: true, timestamp: 0.9))

        #expect(stabilizer.segments.count == 1)
        #expect(final.text == "אני רוצה לשתות")
        #expect(final.isCommitted)
    }

    @Test("text is never shortened as an utterance updates — nothing gets cut off mid-flight")
    func textNeverTruncatedWhilePending() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        let first = stabilizer.ingest(TranscriptToken(utteranceID: id, text: "מה שלומך", isFinal: false, timestamp: 0))
        let second = stabilizer.ingest(TranscriptToken(utteranceID: id, text: "מה שלומך היום", isFinal: false, timestamp: 0.4))

        #expect(second.text.count >= first.text.count)
        #expect(!first.isCommitted)
        #expect(!second.isCommitted)
    }

    @Test("a pending segment commits on its own after a long enough silence")
    func silenceCommitsAStaleSegment() {
        var stabilizer = CaptionStabilizer(silenceCommitThreshold: 1.0)
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "רגע...", isFinal: false, timestamp: 0))

        let notYet = stabilizer.commitStale(now: 0.5)
        #expect(notYet.isEmpty)
        #expect(!stabilizer.segments[0].isCommitted)

        let nowCommitted = stabilizer.commitStale(now: 1.2)
        #expect(nowCommitted.count == 1)
        #expect(stabilizer.segments[0].isCommitted)
    }

    @Test("once committed, a later token for the same id does not un-commit it, but can still correct the text")
    func committedSegmentCanStillBeCorrectedButStaysCommittedFlagWise() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "בסדר", isFinal: true, timestamp: 0))
        let corrected = stabilizer.ingest(TranscriptToken(utteranceID: id, text: "בסדר גמור", isFinal: true, timestamp: 0.1))

        #expect(corrected.isCommitted)
        #expect(corrected.text == "בסדר גמור")
    }

    @Test("two different utterances are tracked as two independent segments")
    func independentUtterancesStayIndependent() {
        var stabilizer = CaptionStabilizer()
        let first = UUID()
        let second = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: first, text: "היי", isFinal: true, timestamp: 0, speakerClusterID: 0))
        stabilizer.ingest(TranscriptToken(utteranceID: second, text: "מה קורה", isFinal: true, timestamp: 1, speakerClusterID: 1))

        #expect(stabilizer.segments.count == 2)
        #expect(stabilizer.segments[0].speakerClusterID == 0)
        #expect(stabilizer.segments[1].speakerClusterID == 1)
    }

    @Test("commitStale never touches segments that already committed")
    func commitStaleIgnoresAlreadyCommitted() {
        var stabilizer = CaptionStabilizer(silenceCommitThreshold: 1.0)
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "כבר גמרתי", isFinal: true, timestamp: 0))

        let result = stabilizer.commitStale(now: 100)
        #expect(result.isEmpty)
    }

    @Test("an empty update never erases text already shown; an empty final still commits it")
    func emptyUpdateKeepsText() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: id, text: "שלום", isFinal: false, timestamp: 1))
        let afterEmpty = stabilizer.ingest(TranscriptToken(utteranceID: id, text: "", isFinal: false, timestamp: 2))
        #expect(afterEmpty.text == "שלום")
        #expect(afterEmpty.lastUpdateTimestamp == 2)

        let final = stabilizer.ingest(TranscriptToken(utteranceID: id, text: "  ", isFinal: true, timestamp: 3))
        #expect(final.text == "שלום")
        #expect(final.isCommitted)
    }
}

@Suite("Caption confidence")
struct CaptionConfidenceTests {
    private func token(_ id: UUID, _ text: String, final: Bool, confidence: Float?) -> TranscriptToken {
        TranscriptToken(utteranceID: id, text: text, isFinal: final, timestamp: 1, confidence: confidence)
    }

    @Test("a line keeps the engine's latest confidence, and an update without one doesn't erase it")
    func carriedThrough() {
        var stabilizer = CaptionStabilizer()
        let id = UUID()
        stabilizer.ingest(token(id, "שלו", final: false, confidence: 0.2))
        stabilizer.ingest(token(id, "שלום", final: false, confidence: nil))
        #expect(stabilizer.segments.first?.confidence == 0.2)
        stabilizer.ingest(token(id, "שלום לכם", final: true, confidence: 0.9))
        #expect(stabilizer.segments.first?.confidence == 0.9)
    }

    @Test("only finished lines with a real low score are marked unsure")
    func uncertaintyRule() {
        #expect(CaptionConfidence.isUncertain(confidence: 0.3, isCommitted: true))
        #expect(CaptionConfidence.isUncertain(confidence: 0.3, isCommitted: false) == false)
        #expect(CaptionConfidence.isUncertain(confidence: 0.8, isCommitted: true) == false)
        #expect(CaptionConfidence.isUncertain(confidence: 0.4, isCommitted: true) == false)
        #expect(CaptionConfidence.isUncertain(confidence: 0, isCommitted: true) == false)
        #expect(CaptionConfidence.isUncertain(confidence: nil, isCommitted: true) == false)
    }

    @Test("confidence is saved with the line, and older saved lines have none")
    func savedWithHistory() throws {
        let live = TranscriptSegment(id: UUID(), text: "אולי", isCommitted: true, speakerClusterID: nil, startTimestamp: 0, lastUpdateTimestamp: 0, confidence: 0.25)
        let record = TranscriptSessionRecord.make(from: [live], speakerName: { _ in nil }, id: UUID(), startedAt: 0, endedAt: nil, engine: .whisperKit, modelVariant: nil, inputName: nil)
        let decoded = try JSONDecoder().decode(TranscriptSessionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.segments.first?.confidence == 0.25)

        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"ישן","startTimestamp":1,"isCommitted":true}"#
        #expect(try JSONDecoder().decode(SavedSegment.self, from: Data(old.utf8)).confidence == nil)
    }

    @Test("marking unsure lines is on by default and survives older settings files")
    func settingDefault() throws {
        #expect(DisplayPreferences.default.markUncertainLines)
        let old = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"fontSize":30}"#.utf8))
        #expect(old.markUncertainLines)
    }
}

@Suite("CaptionStabilizer finishing every open line")
struct CaptionStabilizerCommitAllTests {
    @Test("commitAll finishes open lines only, and returns just those")
    func commitAll() {
        var stabilizer = CaptionStabilizer()
        let open = UUID()
        let done = UUID()
        stabilizer.ingest(TranscriptToken(utteranceID: done, text: "שלום", isFinal: true, timestamp: 1))
        stabilizer.ingest(TranscriptToken(utteranceID: open, text: "מה נש", isFinal: false, timestamp: 2))

        let finished = stabilizer.commitAll()
        #expect(finished.map(\.id) == [open])
        let allFinished = stabilizer.segments.allSatisfy { $0.isCommitted }
        #expect(allFinished)
        #expect(stabilizer.commitAll().isEmpty)
    }
}
