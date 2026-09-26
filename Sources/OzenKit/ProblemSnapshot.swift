import Foundation

public enum ProblemSnapshot {
    public static let lineCount = 4

    public static func lines(
        settings: AppSettings,
        activeEngine: TranscriptionEngineKind?,
        input: AudioInputDescriptor?,
        stats: PipelineStats,
        segments: [TranscriptSegment],
        device: String,
        utcOffsetSeconds: Int
    ) -> [String] {
        let engine = activeEngine ?? settings.engine
        var lines = [
            "PROBLEM MARKED: engine \(engine.rawValue) model \(settings.modelDescription ?? "-") lang \(settings.languageCode) microphone \(input.map { "\($0.portName) [\($0.portType.rawValue)]" } ?? "-")",
            "  lag \(number(stats.captionLagSeconds, "%.2f"))s levels \(stats.inputLevels.summary ?? "-") speech \(number(stats.speechShare.map { $0 * 100 }, "%.0f"))% floor \(number(stats.noiseFloorDecibels, "%.1f")) margin \(number(stats.noiseMarginDecibels, "%.1f"))dB restarts \(stats.engineRestarts) stalls \(stats.audioStalls) updates \(stats.tokensReceived) lines \(stats.segmentsCommitted)",
            "  \(device)",
        ]
        for segment in segments.suffix(lineCount) {
            let sureness = segment.confidence.map { String(format: "%.2f", $0) } ?? "-"
            // The problem-marked line above and the journal entry this all
            // becomes both carry the moment the problem was marked, not
            // when each line last changed: without its own clock time here
            // there's no telling a line stuck for ten minutes from one
            // that just went wrong.
            let time = TranscriptHistoryStore.formattedClockTime(segment.lastUpdateTimestamp, utcOffsetSeconds: utcOffsetSeconds)
            lines.append("  line (\(segment.isCommitted ? "final" : "live"), sure \(sureness), \(time)): \(segment.text)")
        }
        return lines
    }

    private static func number(_ value: Double?, _ format: String) -> String {
        value.map { String(format: format, $0) } ?? "-"
    }
}
