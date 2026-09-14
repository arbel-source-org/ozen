import Foundation

public struct SilencePhraseGuard: Sendable {
    public static let quietSeconds: TimeInterval = 60

    private let phrases: [[Substring]]
    private var lastPhraseAt: TimeInterval?
    private var shownPhraseLine: UUID?

    public init(phrases: Set<String> = WhisperResultFilter.defaultAmbiguousHallucinations) {
        self.phrases = phrases
            .map { WhisperResultFilter.normalize($0).split(separator: " ") }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public mutating func admits(_ token: TranscriptToken, at time: TimeInterval) -> Bool {
        let words = WhisperResultFilter.normalize(token.text).split(separator: " ")
        guard !words.isEmpty else { return true }
        guard let count = phraseCount(in: words) else {
            lastPhraseAt = nil
            shownPhraseLine = nil
            return true
        }
        if token.utteranceID == shownPhraseLine, count == 1 {
            lastPhraseAt = time
            return true
        }
        let cameBack = lastPhraseAt.map { time - $0 < Self.quietSeconds } ?? false
        lastPhraseAt = time
        guard count == 1, !cameBack else { return false }
        shownPhraseLine = token.utteranceID
        return true
    }

    private func phraseCount(in words: [Substring]) -> Int? {
        var index = 0
        var count = 0
        while index < words.count {
            guard let phrase = phrases.first(where: { words[index...].starts(with: $0) }) else { return nil }
            index += phrase.count
            count += 1
        }
        return count
    }
}
