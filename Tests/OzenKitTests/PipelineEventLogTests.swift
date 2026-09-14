import Foundation
import Testing
@testable import OzenKit

@Suite("Pipeline event log")
struct PipelineEventLogTests {
    @Test("events read back in order, with the clock time and what happened")
    func reportLines() {
        var log = PipelineEventLog()
        let noon: TimeInterval = 12 * 3_600
        log.record(.listening, at: noon)
        log.record(.microphoneStalled, at: noon + 61)
        log.record(.failed(PipelineFailure(kind: .audioSessionFailed, detail: "no audio for 6 s")), at: noon + 61)
        log.record(.retryScheduled(attempt: 1, afterSeconds: 2.4), at: noon + 61)
        log.record(.listening, at: noon + 64)

        #expect(log.reportLines(utcOffsetSeconds: 3 * 3_600) == [
            "15:00:00 listening",
            "15:01:01 microphone stopped delivering audio",
            "15:01:01 failed: audioSessionFailed (no audio for 6 s)",
            "15:01:01 retry 1 in 2s",
            "15:01:04 listening",
        ])
    }

    @Test("an engine failure names why, and a long error is cut short on one line")
    func engineFailureDetail() {
        let long = String(repeating: "x", count: 500) + "\nsecond line"
        let event = PipelineEvent(
            at: 0,
            kind: .failed(PipelineFailure(kind: .engineUnavailable, detail: long, engineUnavailability: EngineUnavailability(kind: .notEnoughStorage, detail: "")))
        )
        let line = event.reportLine(utcOffsetSeconds: 0)
        #expect(line.hasPrefix("00:00:00 failed: engineUnavailable/notEnoughStorage (xxx"))
        #expect(line.hasSuffix("…)"))
        #expect(!line.contains("\n"))
        #expect(line.count < 250)
    }

    @Test("only the most recent events are kept")
    func capacity() {
        var log = PipelineEventLog()
        for index in 0..<(PipelineEventLog.capacity + 10) {
            log.record(.retryScheduled(attempt: index, afterSeconds: 1), at: TimeInterval(index))
        }
        #expect(log.events.count == PipelineEventLog.capacity)
        #expect(log.events.first?.at == 10)
        #expect(log.events.last?.at == TimeInterval(PipelineEventLog.capacity + 9))
    }

    @Test("a memory warning says how much the app was using, when that could be read")
    func memoryWarningLine() {
        #expect(PipelineEvent(at: 0, kind: .memoryWarning(footprintMegabytes: 812)).description == "iOS low on memory (app using 812 MB)")
        #expect(PipelineEvent(at: 0, kind: .memoryWarning(footprintMegabytes: nil)).description == "iOS low on memory")
    }

    @Test("listening twice in a row is recorded once")
    func repeatedListening() {
        var log = PipelineEventLog()
        log.record(.listening, at: 1)
        log.record(.listening, at: 2)
        log.record(.phoneCall(began: true), at: 3)
        log.record(.phoneCall(began: false), at: 4)
        log.record(.listening, at: 5)
        #expect(log.events.map(\.at) == [1, 3, 4, 5])
    }
}
