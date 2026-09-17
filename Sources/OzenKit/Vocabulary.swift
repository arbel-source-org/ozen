import Foundation

/// Names and words the recognizers should expect. Family members' names
/// are the single biggest source of wrong captions in a home — "Avi"
/// becomes "aval" ("but"), "Ruti" becomes "Rotem" — and both engines
/// accept hints: Apple's recognizer via `contextualStrings`, Whisper via
/// a text prompt the decoder is conditioned on before it hears any audio.
public enum VocabularyHints {
    public static let maximumTerms = 200
    public static let maximumTermLength = 40

    /// Trims, drops empties and duplicates (ignoring case and niqqud),
    /// clips over-long entries and caps the list, keeping first-seen order
    /// so the user's most important names stay at the front — the Whisper
    /// prompt has a token budget and is cut from the end.
    public static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in terms {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = String(trimmed.prefix(maximumTermLength))
            let key = HebrewText.normalize(clipped).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(clipped)
            if result.count == maximumTerms { break }
        }
        return result
    }

    /// The text Whisper is primed with. A plain comma-separated list is
    /// what the model was trained to treat as "previous context": it
    /// biases spelling towards these forms without the model trying to
    /// transcribe the prompt itself.
    public static func whisperPrompt(_ terms: [String]) -> String {
        let cleaned = normalized(terms)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.joined(separator: ", ") + "."
    }
}

/// Whisper conditioned on a prompt sometimes "hears" the prompt itself in
/// a quiet window: the names list comes back as a caption ("Avi, Ruti,
/// Dani."). Real speech almost never lists several of those names in
/// exactly the order they were typed in, so a caption made only of a run
/// of consecutive list entries is treated as an echo.
///
/// One name on its own is never an echo. Someone calling "Avi!" across
/// the room is exactly the caption the list exists to get right.
public struct PromptEchoDetector: Sendable, Equatable {
    /// Each term as normalized words, in list order.
    private let terms: [[String]]
    private let vocabularyWords: Set<String>

    public init(terms: [String]) {
        self.terms = VocabularyHints.normalized(terms)
            .map { HebrewText.words($0) }
            .filter { !$0.isEmpty }
        vocabularyWords = Set(self.terms.flatMap { $0 })
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// How many consecutive list entries a caption must consist of to count
    /// as an echo: three, or the whole list when it's shorter than that.
    var minimumRun: Int { min(3, terms.count) }

    public func isEcho(_ text: String) -> Bool {
        guard terms.count >= 2 else { return false }
        let words = HebrewText.words(text)
        guard !words.isEmpty, words.allSatisfy(vocabularyWords.contains) else { return false }

        for start in terms.indices {
            var position = 0
            var index = start
            // Two entries sharing a word ("רותי" / "ד״ר רותי") is exactly
            // what naming or disambiguating two people sounds like, not a
            // list read back — a word already claimed by an earlier entry
            // in this run can't count toward a later one.
            var claimedWords = Set<String>()
            while index < terms.count, position < words.count {
                let term = terms[index]
                guard position + term.count <= words.count,
                      Array(words[position..<(position + term.count)]) == term,
                      term.allSatisfy({ !claimedWords.contains($0) })
                else { break }
                claimedWords.formUnion(term)
                position += term.count
                index += 1
            }
            let run = index - start
            if position == words.count, run >= minimumRun {
                return true
            }
        }
        return false
    }
}
