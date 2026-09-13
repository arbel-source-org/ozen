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

    public static let defaultKnownHallucinations: Set<String> = [
        // Hebrew — what Whisper emits on silence when told the language is Hebrew.
        "תודה", "תודה רבה", "תודה לכם", "תודה שצפיתם", "תודה על הצפייה", "תודה על הצפיה",
        "כתוביות", "תרגום", "תרגום וכתוביות", "כתוביות על ידי", "תרגום על ידי",
        "מוזיקה", "שירה", "צחוק", "מחיאות כפיים",
        // English — leaks through even with language forced, on pure silence.
        "thank you", "thanks for watching", "thank you for watching",
        "subtitles by the amara.org community", "subtitles by", "you",
        "music", "applause", "laughter",
    ]

    public init(
        noSpeechThreshold: Float = 0.6,
        logprobThreshold: Float = -1.0,
        compressionRatioThreshold: Float = 2.4,
        knownHallucinations: Set<String> = WhisperResultFilter.defaultKnownHallucinations
    ) {
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
        segments
            .filter { accepts($0) && !(echo?.isEcho(Self.stripSpecialTokens($0.text)) ?? false) }
            .map { Self.stripSpecialTokens($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func accepts(_ segment: WhisperSegmentSummary) -> Bool {
        let text = Self.stripSpecialTokens(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if isKnownHallucination(text) { return false }
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
        knownHallucinations.contains(Self.normalize(text))
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
