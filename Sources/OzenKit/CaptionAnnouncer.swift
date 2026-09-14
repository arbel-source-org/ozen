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
    private var announced: Set<UUID> = []
    private var lastSpeaker: String?

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
        for segment in segments where segment.isCommitted && !announced.contains(segment.id) {
            announced.insert(segment.id)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name = speakerName(segment)
            if let name, name != lastSpeaker {
                parts.append("\(name): \(text)")
            } else {
                parts.append(text)
            }
            lastSpeaker = name
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Treats every line already there as read, so turning VoiceOver (or
    /// the setting) on mid-conversation doesn't read out the whole backlog.
    public mutating func skipLinesSoFar(_ segments: [TranscriptSegment]) {
        forgetLinesNoLongerShown(segments)
        for segment in segments where segment.isCommitted {
            announced.insert(segment.id)
        }
    }

    private mutating func forgetLinesNoLongerShown(_ segments: [TranscriptSegment]) {
        if segments.isEmpty {
            announced = []
            lastSpeaker = nil
        } else if announced.count > segments.count {
            announced.formIntersection(segments.map(\.id))
        }
    }
}
