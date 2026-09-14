import Foundation

/// One person's part in a saved conversation.
public struct SpeakerShare: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// The cluster the name was first seen with, for the speaker's colour.
    public let clusterID: Int?
    public let words: Int
    /// Stretches of consecutive lines by this speaker.
    public let turns: Int
}

/// The longest uninterrupted stretch by one speaker.
public struct LongestTurn: Sendable, Equatable {
    public let speakerName: String
    public let words: Int
}

/// A short, exact summary of a saved conversation: how long, how many
/// words, who said how much. Saved lines carry only their start time, so
/// nothing here pretends to know how long anyone actually spoke; every
/// number is a count or a span between real timestamps.
public struct ConversationStats: Sendable, Equatable {
    public static let unknownSpeakerName = "דובר לא ידוע"

    public let totalWords: Int
    public let totalTurns: Int
    public let durationSeconds: Double
    /// Sorted by words, most first; ties by name.
    public let speakers: [SpeakerShare]
    public let longestTurn: LongestTurn?

    public var wordsPerMinute: Double {
        durationSeconds >= 1 ? Double(totalWords) / (durationSeconds / 60) : 0
    }

    public func wordFraction(of speaker: SpeakerShare) -> Double {
        totalWords > 0 ? Double(speaker.words) / Double(totalWords) : 0
    }

    public static func compute(from record: TranscriptSessionRecord) -> ConversationStats {
        compute(segments: record.segments, startedAt: record.startedAt, endedAt: record.endedAt)
    }

    /// Duration is the recorded session span when the session ended
    /// cleanly, otherwise first line to last line.
    public static func compute(
        segments: [SavedSegment],
        startedAt: TimeInterval? = nil,
        endedAt: TimeInterval? = nil
    ) -> ConversationStats {
        var wordsBySpeaker: [String: Int] = [:]
        var turnsBySpeaker: [String: Int] = [:]
        var clusterBySpeaker: [String: Int] = [:]
        var order: [String] = []
        var totalWords = 0
        var totalTurns = 0
        var longest: LongestTurn?

        var currentSpeaker: String?
        var currentTurnWords = 0

        func closeTurn() {
            guard let speaker = currentSpeaker else { return }
            if currentTurnWords > (longest?.words ?? 0) {
                longest = LongestTurn(speakerName: speaker, words: currentTurnWords)
            }
        }

        for segment in segments {
            let name = speakerName(of: segment)
            let words = HebrewText.words(segment.text).count
            if wordsBySpeaker[name] == nil {
                order.append(name)
                wordsBySpeaker[name] = 0
                turnsBySpeaker[name] = 0
            }
            if clusterBySpeaker[name] == nil, let cluster = segment.speakerClusterID {
                clusterBySpeaker[name] = cluster
            }
            wordsBySpeaker[name, default: 0] += words
            totalWords += words

            if name != currentSpeaker {
                closeTurn()
                currentSpeaker = name
                currentTurnWords = 0
                turnsBySpeaker[name, default: 0] += 1
                totalTurns += 1
            }
            currentTurnWords += words
        }
        closeTurn()

        let speakers = order
            .map { name in
                SpeakerShare(
                    name: name,
                    clusterID: clusterBySpeaker[name],
                    words: wordsBySpeaker[name] ?? 0,
                    turns: turnsBySpeaker[name] ?? 0
                )
            }
            .sorted { lhs, rhs in
                lhs.words != rhs.words ? lhs.words > rhs.words : lhs.name < rhs.name
            }

        let duration: Double
        if let startedAt, let endedAt, endedAt > startedAt {
            duration = endedAt - startedAt
        } else if let first = segments.first, let last = segments.last {
            duration = max(0, last.startTimestamp - first.startTimestamp)
        } else {
            duration = 0
        }

        return ConversationStats(
            totalWords: totalWords,
            totalTurns: totalTurns,
            durationSeconds: duration,
            speakers: speakers,
            longestTurn: longest
        )
    }

    private static func speakerName(of segment: SavedSegment) -> String {
        guard let name = segment.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return unknownSpeakerName
        }
        return name
    }

    // MARK: - Wording

    /// "12 dakot · 3 dovrim · 840 milim" ("12 minutes · 3 speakers ·
    /// 840 words"), with Hebrew's special forms for one and two.
    public var hebrewSummary: String {
        var parts = [Self.minutesText(durationSeconds)]
        if !speakers.isEmpty {
            parts.append(Self.speakersText(speakers.count))
        }
        parts.append(Self.wordsText(totalWords))
        return parts.joined(separator: " · ")
    }

    public static func minutesText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case ..<1: return "פחות מדקה"
        case 1: return "דקה אחת"
        case 2: return "שתי דקות"
        default: return "\(minutes) דקות"
        }
    }

    public static func speakersText(_ count: Int) -> String {
        switch count {
        case 1: return "דובר אחד"
        case 2: return "שני דוברים"
        default: return "\(count) דוברים"
        }
    }

    public static func wordsText(_ count: Int) -> String {
        switch count {
        case 0: return "אין מילים"
        case 1: return "מילה אחת"
        case 2: return "שתי מילים"
        default: return "\(count) מילים"
        }
    }
}
