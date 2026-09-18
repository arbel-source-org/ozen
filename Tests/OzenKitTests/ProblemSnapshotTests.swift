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
            device: "thermal 1"
        )
        #expect(lines[0] == "PROBLEM MARKED: engine whisperKit model small lang he microphone AirPods [bluetooth]")
        #expect(lines[1].contains("restarts 2"))
        #expect(lines[2] == "  thermal 1")
        #expect(lines.count == 3 + ProblemSnapshot.lineCount)
        #expect(lines.last == "  line (live, sure -): line 6")
        #expect(lines[3].hasSuffix("line 3"))
    }

    @Test("with nothing running and nothing said there is still a line to find")
    func empty() {
        let lines = ProblemSnapshot.lines(settings: .default, activeEngine: nil, input: nil, stats: PipelineStats(), segments: [], device: "-")
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("microphone -"))
    }
}
