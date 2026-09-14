import Foundation

/// What VoiceOver reads out, or sends to a braille display, as captions
/// come in.
///
/// Someone whose eyesight is failing as well as their hearing can follow a
/// conversation through VoiceOver: speech into hearing aids, or a braille
/// display under the fingers. The lines on screen can be read by moving to
/// them, but a live conversation needs new words to arrive by themselves.
///
/// Only finished lines are announced, since a line that is still changing
/// would be read five times over. Each is announced once, several finished
/// together go out as one announcement, and the speaker's name leads a
/// line when the speaker changes, the way the screen shows it.
public struct CaptionAnnouncer: Sendable, Equatable {
    /// What each line said when it was last announced (or skipped).
    private var announced: [UUID: String] = [:]
    private var lastSpeaker: String?
    /// The line announced (or skipped) last, for the quiet before the next.
    private var lastLine: TranscriptSegment?
    /// Where the next look starts (`scanStart`): lines before it were
    /// finished and handled, and nothing corrects a line that far back.
    private var scannedCount = 0
    private var firstOpenIndex: Int?
    /// Finished lines this close to the end are looked at again, for a
    /// correction that comes after a line was read out.
    static let recheckedLines = 8

    public init() {}

    /// The text to announce for lines finished since the last call, or nil
    /// when there is nothing new. `speakerName` returns nil for lines whose
    /// speaker shouldn't be named.
    public mutating func announcement(
        for segments: [TranscriptSegment],
        speakerName: (TranscriptSegment) -> String?
    ) -> String? {
        forgetLinesNoLongerShown(segments)
        var parts: [String] = []
        let start = scanStart(in: segments)
        noteScanned(segments, from: start)
        for segment in segments[start...] where segment.isCommitted {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A line read out once is read again only if its words changed
            // afterwards (a slow engine correcting one of the last lines).
            guard announced[segment.id] != text else { continue }
            announced[segment.id] = text
            guard !text.isEmpty else { continue }
            let name = speakerName(segment)
            // After a quiet stretch the name comes again, as on screen.
            if let name, name != lastSpeaker || CaptionLayout.startsAfterQuiet(segment, previous: lastLine) {
                parts.append("\(name): \(text)")
            } else {
                parts.append(text)
            }
            lastSpeaker = name
            lastLine = segment
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Treats every line already there as read, so turning VoiceOver (or
    /// the setting) on mid-conversation doesn't read out the whole backlog.
    public mutating func skipLinesSoFar(_ segments: [TranscriptSegment]) {
        forgetLinesNoLongerShown(segments)
        let start = scanStart(in: segments)
        noteScanned(segments, from: start)
        for segment in segments[start...] where segment.isCommitted {
            announced[segment.id] = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Only the lines that can have changed are looked at: those since the
    /// last look, the few before them, and any line that was still being
    /// written then. Called for every finished line of an evening's
    /// captions, a pass over the whole transcript each time grew with it.
    private func scanStart(in segments: [TranscriptSegment]) -> Int {
        var start = max(0, min(scannedCount, segments.count) - Self.recheckedLines)
        if let firstOpenIndex { start = min(start, firstOpenIndex) }
        return min(start, segments.count)
    }

    private mutating func noteScanned(_ segments: [TranscriptSegment], from start: Int) {
        scannedCount = segments.count
        firstOpenIndex = segments[start...].firstIndex { !$0.isCommitted }
    }

    private mutating func forgetLinesNoLongerShown(_ segments: [TranscriptSegment]) {
        if segments.isEmpty || segments.count < scannedCount {
            scannedCount = 0
            firstOpenIndex = nil
        }
        if segments.isEmpty {
            announced = [:]
            lastSpeaker = nil
            lastLine = nil
        } else if announced.count > segments.count {
            let shown = Set(segments.map(\.id))
            announced = announced.filter { shown.contains($0.key) }
        }
    }
}
