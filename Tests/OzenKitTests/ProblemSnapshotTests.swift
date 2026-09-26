import Foundation
import Testing
@testable import OzenKit

@Suite("ProblemSnapshot")
struct ProblemSnapshotTests {
    @Test("says which engine, model and microphone were running, and what the captions last said")
    func lines() {
        var settings = AppSettings.default
        settings.whisperModelVariant = "small"
        var stats = PipelineStats()
        stats.engineRestarts = 2
        let segments = (1...6).map { index in
            TranscriptSegment(id: UUID(), text: "line \(index)", isCommitted: index < 6, speakerClusterID: nil, startTimestamp: 0, lastUpdateTimestamp: 0)
        }
        let lines = ProblemSnapshot.lines(
            settings: settings,
            activeEngine: .whisperKit,
            input: AudioInputDescriptor(uid: "bt", portName: "AirPods", portType: .bluetooth),
            stats: stats,
            segments: segments,
            device: "thermal 1",
            utcOffsetSeconds: 0
        )
        #expect(lines[0] == "PROBLEM MARKED: engine whisperKit model small lang he microphone AirPods [bluetooth]")
        #expect(lines[1].contains("restarts 2"))
        #expect(lines[2] == "  thermal 1")
        #expect(lines.count == 3 + ProblemSnapshot.lineCount)
        #expect(lines.last == "  line (live, sure -, 00:00:00): line 6")
        #expect(lines[3].hasSuffix("line 3"))
    }

    @Test("each line carries its own last-update clock time, at her offset, not the moment the problem was marked")
    func lineTimestamps() {
        let segments = (1...4).map { index in
            TranscriptSegment(id: UUID(), text: "line \(index)", isCommitted: true, speakerClusterID: nil, startTimestamp: 0, lastUpdateTimestamp: TimeInterval(index * 60))
        }
        let lines = ProblemSnapshot.lines(
            settings: .default, activeEngine: nil, input: nil, stats: PipelineStats(), segments: segments, device: "-", utcOffsetSeconds: 3 * 3_600
        )
        #expect(lines[3] == "  line (final, sure -, 03:01:00): line 1")
        #expect(lines.last == "  line (final, sure -, 03:04:00): line 4")
    }

    @Test("with nothing running and nothing said there is still a line to find")
    func empty() {
        let lines = ProblemSnapshot.lines(settings: .default, activeEngine: nil, input: nil, stats: PipelineStats(), segments: [], device: "-", utcOffsetSeconds: 0)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("microphone -"))
    }
}
