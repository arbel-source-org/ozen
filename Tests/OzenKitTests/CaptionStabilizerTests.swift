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
