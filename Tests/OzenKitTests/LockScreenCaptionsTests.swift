import Testing
import Foundation
@testable import OzenKit

@Suite("Caption lines on the lock screen")
struct LockScreenCaptionsTests {
    private func line(_ text: String, speaker: Int? = nil, final: Bool = true) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), text: text, isCommitted: final, speakerClusterID: speaker, startTimestamp: 0, lastUpdateTimestamp: 0)
    }

    private let names: (TranscriptSegment) -> String? = { segment in
        segment.speakerClusterID.map { "Speaker \($0)" }
    }

    @Test("the newest lines with text, the one still being written included")
    func newestLines() {
        let segments = [line("one"), line("two"), line("  "), line("three", final: false)]
        let lines = LockScreenCaptions.lines(from: segments) { _ in nil }
        #expect(lines == [
            LockScreenCaptionLine(speaker: nil, text: "two", isFinal: true),
            LockScreenCaptionLine(speaker: nil, text: "three", isFinal: false),
        ])
        #expect(LockScreenCaptions.lines(from: []) { _ in nil }.isEmpty)
    }

    @Test("the top line always says who is talking; below it a name shows only where the speaker changes")
    func namesOnTopAndWhereTheSpeakerChanges() {
        let changing = LockScreenCaptions.lines(from: [line("a", speaker: 1), line("b", speaker: 1), line("c", speaker: 2)], name: names)
        #expect(changing.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        let continuing = LockScreenCaptions.lines(from: [line("a", speaker: 2), line("b", speaker: 1), line("c", speaker: 1)], name: names)
        #expect(continuing.map(\.speaker) == ["Speaker 1", nil])
        let unnamed = LockScreenCaptions.lines(from: [line("a", speaker: 1), line("b")], name: names)
        #expect(unnamed.map(\.speaker) == ["Speaker 1", nil])
    }

    @Test("asked for one line, the newest comes with its speaker's name even mid-run")
    func singleLine() {
        let one = LockScreenCaptions.lines(from: [line("a", speaker: 1), line("b", speaker: 1), line("  ")], count: 1, name: names)
        #expect(one == [LockScreenCaptionLine(speaker: "Speaker 1", text: "b", isFinal: true)])
    }

    @Test("long lines are cut to what fits: the newest line gets more room than the one before, and a name takes its share")
    func linesCutToFit() {
        let long = (1...40).map { "word\($0)" }.joined(separator: " ")
        let lines = LockScreenCaptions.lines(from: [line(long), line(long)]) { _ in nil }
        #expect(lines.count == 2)
        #expect(lines[0].text.count <= LockScreenCaptions.earlierLineMaximumCharacters)
        #expect(lines[1].text.count <= LockScreenCaptions.newestLineMaximumCharacters)
        #expect(lines[1].text.count > LockScreenCaptions.earlierLineMaximumCharacters)
        #expect(lines.allSatisfy { $0.text.hasSuffix("word40") })

        let named = LockScreenCaptions.lines(from: [line(long, speaker: 1)], name: names)
        #expect(named[0].speaker == "Speaker 1")
        #expect(named[0].text.count + "Speaker 1: ".count <= LockScreenCaptions.newestLineMaximumCharacters)

        let longName: (TranscriptSegment) -> String? = { _ in String(repeating: "n", count: 90) }
        let crowded = LockScreenCaptions.lines(from: [line(long)], name: longName)
        #expect(crowded[0].text == LockScreenCaptions.tail(of: long, maximumCharacters: LockScreenCaptions.minimumCharacters))
    }

    @Test("a long line keeps its newest words, from a word boundary, marked as cut")
    func longLineTail() {
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        let tail = LockScreenCaptions.tail(of: words, maximumCharacters: 40)
        #expect(tail.hasPrefix("…word"))
        #expect(tail.hasSuffix("word60"))
        #expect(tail.count <= 40)
        #expect(LockScreenCaptions.tail(of: " short ", maximumCharacters: 40) == "short")
    }
}

@Suite("Throttling lock screen updates")
struct LockScreenUpdateThrottleTests {
    private let first = LockScreenCaptionContent(lines: [LockScreenCaptionLine(speaker: nil, text: "hello", isFinal: false)])
    private let second = LockScreenCaptionContent(lines: [LockScreenCaptionLine(speaker: nil, text: "hello there", isFinal: false)])

    @Test("the first change goes at once, a quick second one waits out the interval, an unchanged one isn't sent")
    func decisions() {
        var throttle = LockScreenUpdateThrottle(minimumInterval: 1)
        #expect(throttle.decide(first, now: 100) == .send)
        throttle.sent(first, at: 100)
        #expect(throttle.decide(first, now: 100.2) == .nothingNew)
        #expect(throttle.decide(second, now: 100.25) == .wait(0.75))
        #expect(throttle.decide(second, now: 101) == .send)
        throttle.sent(second, at: 101)
        throttle.reset()
        #expect(throttle.decide(second, now: 101.1) == .send)
        throttle.sent(second, at: 101.1)
        // The same lines with a status are news.
        #expect(throttle.decide(LockScreenCaptionContent(lines: second.lines, status: "stopped"), now: 105) == .send)
    }

    @Test("a new status goes at once, even inside the interval")
    func statusChangeSkipsTheWait() {
        var throttle = LockScreenUpdateThrottle(minimumInterval: LockScreenUpdateThrottle.foregroundInterval)
        throttle.sent(first, at: 100)
        #expect(throttle.decide(second, now: 101) == .wait(LockScreenUpdateThrottle.foregroundInterval - 1))
        let paused = LockScreenCaptionContent(lines: first.lines, status: "paused")
        #expect(throttle.decide(paused, now: 101) == .send)
        throttle.sent(paused, at: 101)
        #expect(throttle.decide(LockScreenCaptionContent(lines: second.lines, status: "paused"), now: 102) == .wait(LockScreenUpdateThrottle.foregroundInterval - 1))
        #expect(throttle.decide(first, now: 102) == .send)
    }

    @Test("a clock that went backwards sends rather than waiting for ever")
    func clockBackwards() {
        var throttle = LockScreenUpdateThrottle(minimumInterval: 1)
        throttle.sent(first, at: 500)
        #expect(throttle.decide(second, now: 10) == .send)
    }
}

@Suite("Lock screen captions setting")
struct LockScreenCaptionsSettingTests {
    @Test("on by default, survives older settings files, and can be turned off")
    func settingDefault() throws {
        #expect(DisplayPreferences.default.lockScreenCaptions)
        let old = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"fontSize":30}"#.utf8))
        #expect(old.lockScreenCaptions)
        var off = DisplayPreferences.default
        off.lockScreenCaptions = false
        let roundTripped = try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(off))
        #expect(roundTripped.lockScreenCaptions == false)
    }
}

@Suite("Pipeline tells when captions change")
@MainActor
struct PipelineCaptionsChangedTests {
    @Test("each new or changed line, and clearing, calls the hook")
    func hookCalls() async {
        let engine = FakeEngine()
        let pipeline = CaptionPipeline(audio: FakeAudioCapturer(), engineFactory: { _ in engine }, embedder: FakeEmbedder())
        var calls = 0
        pipeline.onCaptionsChanged = { calls += 1 }
        await pipeline.start(settings: AppSettings.default)
        let id = UUID()
        engine.emit(TranscriptToken(utteranceID: id, text: "hello", isFinal: false, timestamp: 1_000))
        #expect(await eventually { calls == 1 })
        engine.emit(TranscriptToken(utteranceID: id, text: "hello there", isFinal: true, timestamp: 1_001))
        #expect(await eventually { calls == 2 })
        pipeline.clearTranscript()
        #expect(calls == 3)
    }
}

@Suite("When the lock screen keeps its captions")
struct LockScreenPresenceTests {
    @Test("running, starting, failed and on a call keep it with a status; stopped or paused by hand end it")
    func presence() {
        let failure = PipelineFailure(kind: .transcriptionStopped, detail: "")
        #expect(LockScreenCaptions.presence(phase: .listening, interruptedByCall: false, pausedForSpeech: false) == (true, nil))
        #expect(LockScreenCaptions.presence(phase: .startingAudio, interruptedByCall: false, pausedForSpeech: false).keep)
        #expect(LockScreenCaptions.presence(phase: .failed(failure), interruptedByCall: false, pausedForSpeech: false).status != nil)
        #expect(LockScreenCaptions.presence(phase: .failed(failure), interruptedByCall: true, pausedForSpeech: false).keep)
        #expect(LockScreenCaptions.presence(phase: .paused, interruptedByCall: false, pausedForSpeech: true).keep)
        #expect(!LockScreenCaptions.presence(phase: .paused, interruptedByCall: false, pausedForSpeech: false).keep)
        #expect(!LockScreenCaptions.presence(phase: .idle, interruptedByCall: false, pausedForSpeech: false).keep)
    }
}
