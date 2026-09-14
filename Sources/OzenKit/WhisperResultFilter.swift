import Foundation

/// The per-segment numbers Whisper reports alongside its text, reduced to
/// what the filter below needs. Kept as a plain struct so the filtering
/// rules are testable here without WhisperKit's own result types.
public struct WhisperSegmentSummary: Sendable, Equatable {
    public var text: String
    /// Probability the model assigns to "this window contains no speech".
    public var noSpeechProb: Float
    /// Mean log-probability of the emitted tokens; very negative means the
    /// model was guessing.
    public var avgLogprob: Float
    /// gzip compression ratio of the text — high values mean repetitive
    /// output, the signature of a decoding loop ("תודה תודה תודה ...").
    public var compressionRatio: Float

    public init(text: String, noSpeechProb: Float, avgLogprob: Float, compressionRatio: Float) {
        self.text = text
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
    }
}

/// Whisper is famous for hallucinating on silence and background noise:
/// given a quiet room it will happily emit "תודה רבה", "כתוביות על ידי ...",
/// or "Subtitles by the Amara.org community". For a captioning app that's
/// worse than showing nothing — the reader can't tell an invented sentence
/// from a real one. This applies the same three statistical checks the
/// reference Whisper implementation uses to decide a window is junk, plus a
/// short list of phrases the model is known to invent on silence in Hebrew
/// and English.
public struct WhisperResultFilter: Sendable, Equatable {
    public var noSpeechThreshold: Float
    public var logprobThreshold: Float
    public var compressionRatioThreshold: Float
    public var knownHallucinations: Set<String>
    /// Phrases Whisper invents on noise that people also genuinely say in
    /// conversation ("תודה", "תודה רבה"). Dropped only when the segment's
    /// own statistics look like noise, never when the model heard them
    /// clearly: missing a real "thank you" is its own kind of wrong.
    public var ambiguousHallucinations: Set<String>
    /// Above this no-speech probability an ambiguous phrase is treated as
    /// invented. Real short speech sits far below it.
    public var ambiguousNoSpeechThreshold: Float
    /// Below this mean log-probability an ambiguous phrase is treated as
    /// a guess.
    public var ambiguousLogprobThreshold: Float
    /// Openings of the credit lines Whisper invents on silence, which come
    /// with an arbitrary name attached ("כתוביות על ידי <name>"), so an
    /// exact-phrase list can't catch them.
    public var hallucinatedCreditPrefixes: [String]
    /// A credit prefix only condemns a short segment; a long one that
    /// happens to start the same way is someone actually talking.
    public var maximumCreditLineWords: Int

    /// Bare labels ("כתוביות", "תרגום") are ordinary words too, so they
    /// only count as a credit when a colon follows, as in "תרגום: מיכל".
    public var hallucinatedCreditLabels: [String]

    public static let defaultCreditPrefixes: [String] = [
        "כתוביות על ידי", "תורגם על ידי", "תרגום על ידי", "תמלול על ידי", "תוכתב על ידי",
        "subtitles by", "subtitled by", "translated by", "transcribed by", "captions by",
    ]

    public static let defaultCreditLabels: [String] = [
        "כתוביות", "תרגום", "תמלול", "הפקה", "עריכה", "subtitles", "translation", "captions",
    ]

    /// Nobody says these to someone across a dinner table: they are
    /// broadcast credits and sound tags, always dropped.
    public static let defaultKnownHallucinations: Set<String> = [
        "תודה שצפיתם", "תודה על הצפייה", "תודה על הצפיה", "תודה שהאזנתם",
        "כתוביות", "תרגום", "תרגום וכתוביות", "כתוביות על ידי", "תרגום על ידי",
        "מוזיקה", "שירה", "צחוק", "מחיאות כפיים",
        // English leaks through even with the language forced to Hebrew.
        "thanks for watching", "thank you for watching",
        "subtitles by the amara.org community", "subtitles by", "you",
        "music", "applause", "laughter",
    ]

    public static let defaultAmbiguousHallucinations: Set<String> = [
        "תודה", "תודה רבה", "תודה לכם", "thank you",
    ]

    public init(
        noSpeechThreshold: Float = 0.6,
        logprobThreshold: Float = -1.0,
        compressionRatioThreshold: Float = 2.4,
        knownHallucinations: Set<String> = WhisperResultFilter.defaultKnownHallucinations,
        ambiguousHallucinations: Set<String> = WhisperResultFilter.defaultAmbiguousHallucinations,
        ambiguousNoSpeechThreshold: Float = 0.25,
        ambiguousLogprobThreshold: Float = -0.9,
        hallucinatedCreditPrefixes: [String] = WhisperResultFilter.defaultCreditPrefixes,
        hallucinatedCreditLabels: [String] = WhisperResultFilter.defaultCreditLabels,
        maximumCreditLineWords: Int = 7
    ) {
        self.hallucinatedCreditLabels = hallucinatedCreditLabels.map { $0.lowercased() }
        self.ambiguousHallucinations = Set(ambiguousHallucinations.map(Self.normalize))
        self.ambiguousNoSpeechThreshold = ambiguousNoSpeechThreshold
        self.ambiguousLogprobThreshold = ambiguousLogprobThreshold
        self.hallucinatedCreditPrefixes = hallucinatedCreditPrefixes.map(Self.normalize)
        self.maximumCreditLineWords = maximumCreditLineWords
        self.noSpeechThreshold = noSpeechThreshold
        self.logprobThreshold = logprobThreshold
        self.compressionRatioThreshold = compressionRatioThreshold
        // Stored pre-normalized so lookups compare like with like — an
        // entry written as "amara.org" would otherwise never match input
        // whose dot the normalizer already stripped.
        self.knownHallucinations = Set(knownHallucinations.map(Self.normalize))
    }

    /// The text worth showing from one decoding pass, with junk segments
    /// dropped. Empty when nothing survives — the caller should then emit
    /// nothing rather than a blank token.
    ///
    /// `echo` drops segments that are just the vocabulary prompt read back
    /// (see `PromptEchoDetector`).
    public func acceptedText(from segments: [WhisperSegmentSummary], echo: PromptEchoDetector? = nil) -> String {
        let joined = segments
            .filter { accepts($0) && !(echo?.isEcho(Self.stripSpecialTokens($0.text)) ?? false) }
            .map { Self.stripSpecialTokens($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Self.collapsingRepeats(joined)
    }

    /// A decoding loop that stays short enough to pass the compression
    /// check still puts "לבוא לבוא לבוא לבוא לבוא לבוא" on screen. Any word
    /// or short phrase repeated back to back more than `maxRepeats` times
    /// is cut down to that many: people do say "לא, לא, לא", but nobody
    /// says it six times. The kept copies are the first ones and the last,
    /// so the sentence keeps its closing punctuation. Text with nothing to
    /// collapse comes back exactly as it was.
    public static func collapsingRepeats(_ text: String, maxRepeats: Int = 3, maxPhraseWords: Int = 4) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard maxRepeats >= 1, words.count > maxRepeats else { return text }
        var changed = false
        for phraseLength in 1...maxPhraseWords {
            let keys = words.map(normalize)
            var result: [String] = []
            var index = 0
            while index < words.count {
                let phraseEnd = index + phraseLength
                guard phraseEnd <= words.count, !keys[index..<phraseEnd].allSatisfy(\.isEmpty) else {
                    result.append(words[index])
                    index += 1
                    continue
                }
                let phrase = keys[index..<phraseEnd]
                var repeats = 1
                while index + (repeats + 1) * phraseLength <= words.count,
                      keys[(index + repeats * phraseLength)..<(index + (repeats + 1) * phraseLength)].elementsEqual(phrase) {
                    repeats += 1
                }
                if repeats > maxRepeats {
                    result.append(contentsOf: words[index..<(index + (maxRepeats - 1) * phraseLength)])
                    let lastStart = index + (repeats - 1) * phraseLength
                    result.append(contentsOf: words[lastStart..<(lastStart + phraseLength)])
                    index += repeats * phraseLength
                    changed = true
                } else {
                    result.append(words[index])
                    index += 1
                }
            }
            words = result
        }
        return changed ? words.joined(separator: " ") : text
    }

    public func accepts(_ segment: WhisperSegmentSummary) -> Bool {
        let text = Self.stripSpecialTokens(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if isKnownHallucination(text) { return false }
        if ambiguousHallucinations.contains(Self.normalize(text)),
           segment.noSpeechProb > ambiguousNoSpeechThreshold || segment.avgLogprob < ambiguousLogprobThreshold {
            return false
        }
        // The reference implementation only treats "no speech" as decisive
        // when the model was *also* unsure of its tokens; a confident
        // transcript in a window the VAD thought was quiet is kept.
        if segment.noSpeechProb > noSpeechThreshold && segment.avgLogprob < logprobThreshold {
            return false
        }
        if segment.compressionRatio > compressionRatioThreshold { return false }
        return true
    }

    /// Case-, punctuation- and bracket-insensitive lookup, so "[תודה רבה]",
    /// "תודה רבה." and "תודה רבה!" all match one entry.
    public func isKnownHallucination(_ text: String) -> Bool {
        let normalized = Self.normalize(text)
        if knownHallucinations.contains(normalized) { return true }
        return isCreditLine(raw: text, normalized: normalized)
    }

    /// "כתוביות: ישראל ישראלי", "Subtitles by XYZ": a short segment that
    /// opens with a credit phrase, followed by a separator (the
    /// normalizer already turned ":" into nothing) or a name. Whole words
    /// only, so "כתוביותיים" or "תרגומים" never match.
    func isCreditLine(raw: String, normalized: String) -> Bool {
        let words = normalized.split(separator: " ")
        guard !words.isEmpty, words.count <= maximumCreditLineWords else { return false }
        let byPhrase = hallucinatedCreditPrefixes.contains { prefix in
            let prefixWords = prefix.split(separator: " ")
            return words.count >= prefixWords.count && Array(words.prefix(prefixWords.count)) == prefixWords
        }
        if byPhrase { return true }

        let opening = raw
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "[](){}<>\"'״-–—")))
            .lowercased()
        return hallucinatedCreditLabels.contains { label in
            guard opening.hasPrefix(label) else { return false }
            return opening.dropFirst(label.count).drop(while: \.isWhitespace).first == ":"
        }
    }

    /// Removes Whisper's control tokens (`<|startoftranscript|>`,
    /// `<|he|>`, `<|0.00|>` timestamps, ...) that leak into segment text
    /// depending on decoding options. Belt and braces: the engine asks
    /// for them to be skipped, and this makes sure none reach the screen.
    public static func stripSpecialTokens(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("<|"), let close = text[index...].range(of: "|>") {
                index = close.upperBound
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    static func normalize(_ text: String) -> String {
        let stripped = text.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
