import Foundation

/// Captions written by a speech model on the internet, reached through
/// OpenRouter (openrouter.ai) with a key the person pastes into Settings.
///
/// The phone's own models are slow on older phones and lose the thread
/// when several people talk. Measured on twelve Hebrew FLEURS recordings
/// (September 2026, about 250 words), share of words wrong:
///
/// | engine                          | words wrong | seconds per request |
/// |---------------------------------|-------------|---------------------|
/// | Whisper small, on the phone     | 60%         | -                   |
/// | Whisper large-v3 turbo          | 39%         | -                   |
/// | Whisper large-v3                | 37%         | -                   |
/// | google/gemini-3.1-flash-lite    | 29%         | 1.6                 |
/// | google/gemini-3.8-flash         | 24%         | 4                   |
///
/// gemini-3.1-flash-lite also put four alternating speakers on four lines,
/// labelled A B A B, and costs about six cents per hour of speech sent once
/// (the live re-sends make it two to three times that).
///
/// Who is talking is still the phone's job. Given a short recording of each
/// of four people and asked whose voice a new recording was, these models
/// got 8 and 7 of 22 right (LibriSpeech voices): barely better than a guess.
public enum CloudSpeech {
    public static let completionsURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    /// Fast and cheap; the default.
    public static let fastModel = "google/gemini-3.1-flash-lite"
    /// Fewer mistakes, but each line takes a few seconds longer to arrive.
    public static let accurateModel = "google/gemini-3.8-flash"
    public static let models = [fastModel, accurateModel]

    public static func prompt(languageCode: String, vocabulary: [String]) -> String {
        let language = languageNames[languageCode] ?? languageCode
        var prompt = """
        You are writing live captions for a hard of hearing person. Transcribe the speech in this audio exactly as spoken, \
        in \(language). Do not translate, summarise, correct or add anything. \
        When more than one person speaks, start a new line at every change of speaker and begin each line with a label \
        such as "A:" or "B:". If people talk over each other, give each person their own line. \
        If there is no clear speech, reply with nothing at all.
        """
        let names = VocabularyHints.normalized(vocabulary)
        if !names.isEmpty {
            prompt += " Names and words that may come up: \(names.joined(separator: ", "))."
        }
        return prompt
    }

    public static func completionRequest(model: String, apiKey: String, wav: Data, languageCode: String, vocabulary: [String]) -> CloudHTTPRequest {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt(languageCode: languageCode, vocabulary: vocabulary)],
                    ["type": "input_audio", "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]],
                ],
            ]],
        ]
        // Thinking first would make every line seconds later.
        if model.hasPrefix("google/") {
            body["reasoning"] = ["effort": "minimal"]
        }
        return CloudHTTPRequest(
            url: completionsURL,
            method: "POST",
            headers: headers(apiKey: apiKey),
            body: try? JSONSerialization.data(withJSONObject: body),
            timeoutSeconds: 20
        )
    }

    public static func keyCheckRequest(apiKey: String) -> CloudHTTPRequest {
        CloudHTTPRequest(url: keyURL, headers: headers(apiKey: apiKey), timeoutSeconds: 10)
    }

    /// Whether the key described by a successful key check can still pay
    /// for a request. A key with no spending limit reports none left as
    /// null, and an unreadable answer is not held against the key.
    public static func hasCreditLeft(keyCheck response: CloudHTTPResponse) -> Bool {
        guard
            let reply = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let data = reply["data"] as? [String: Any],
            let remaining = data["limit_remaining"] as? NSNumber
        else { return true }
        return remaining.doubleValue > 0
    }

    /// The transcript in a successful reply, or why the request failed.
    public static func transcript(from response: CloudHTTPResponse) throws(CloudSpeechError) -> String {
        guard (200..<300).contains(response.status) else {
            throw failure(from: response)
        }
        guard
            let reply = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let choices = reply["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            // OpenRouter can answer 200 with an error object when the model
            // provider failed part way.
            if let reply = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], reply["error"] != nil {
                throw .serverTrouble(status: response.status)
            }
            throw .badReply
        }
        return (message["content"] as? String) ?? ""
    }

    public static func failure(from response: CloudHTTPResponse) -> CloudSpeechError {
        let message = String(decoding: response.body, as: UTF8.self).lowercased()
        switch response.status {
        case 401:
            return .keyRejected
        case 402:
            return .outOfCredit
        case 403 where message.contains("limit") || message.contains("credit"):
            return .outOfCredit
        case 403:
            return .keyRejected
        case 429:
            return .rateLimited
        default:
            return .serverTrouble(status: response.status)
        }
    }

    /// One entry per speaker turn, labels removed, with what the model
    /// adds that nobody said ("[inaudible]", "(music)") and invented
    /// filler lines taken out.
    public static func turns(in transcript: String, filter: WhisperResultFilter = WhisperResultFilter()) -> [String] {
        var turns: [String] = []
        var lastLabel: Substring?
        for rawLine in transcript.split(whereSeparator: \.isNewline) {
            var line = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var label: Substring?
            if let match = line.firstMatch(of: speakerLabel) {
                label = match.output.1
                line = line[match.range.upperBound...]
            }
            let text = WhisperResultFilter.collapsingRepeats(withoutAnnotations(String(line)))
            guard !text.isEmpty, !filter.isKnownHallucination(text) else { continue }
            if let previous = turns.last, label == nil || label == lastLabel {
                turns[turns.count - 1] = previous + " " + text
            } else {
                turns.append(text)
            }
            lastLabel = label ?? lastLabel
        }
        return turns
    }

    /// "A:", "Speaker 2:", "דובר ב:". Hebrew only as a single letter, so a
    /// sentence that opens with a short word and a colon keeps its word.
    private nonisolated(unsafe) static let speakerLabel = /^(?:(?:speaker|דוברת|דובר)\s*)?([A-Za-z0-9]{1,2}|[א-ת])\s*[:：]\s*/.ignoresCase()

    private static func withoutAnnotations(_ text: String) -> String {
        text.replacing(/[\[(<][A-Za-z _-]*[\])>]/, with: "")
            .replacing(/\s{2,}/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headers(apiKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "X-Title": "Ozen",
        ]
    }

    private static let languageNames = [
        "he": "Hebrew", "en": "English", "ar": "Arabic", "ru": "Russian", "fr": "French",
        "es": "Spanish", "am": "Amharic", "de": "German", "it": "Italian", "pt": "Portuguese",
    ]
}

public enum CloudSpeechError: Error, Sendable, Equatable {
    case keyMissing
    case keyRejected
    case outOfCredit
    case rateLimited
    case offline
    case serverTrouble(status: Int)
    case badReply

    /// Nothing gets better by trying again: the person has to fix the key
    /// or add credit.
    public var needsPerson: Bool {
        switch self {
        case .keyMissing, .keyRejected, .outOfCredit: return true
        case .rateLimited, .offline, .serverTrouble, .badReply: return false
        }
    }

    public var unavailability: EngineUnavailability {
        switch self {
        case .keyMissing: return EngineUnavailability(kind: .cloudKeyNeeded, detail: "no OpenRouter key")
        case .keyRejected: return EngineUnavailability(kind: .cloudKeyNeeded, detail: "OpenRouter rejected the key")
        case .outOfCredit: return EngineUnavailability(kind: .cloudOutOfCredit, detail: "OpenRouter key is out of credit")
        case .offline: return EngineUnavailability(kind: .noInternet, detail: "no connection to OpenRouter")
        case .rateLimited: return EngineUnavailability(kind: .temporarilyUnavailable, detail: "OpenRouter rate limit")
        case .serverTrouble(let status): return EngineUnavailability(kind: .temporarilyUnavailable, detail: "OpenRouter answered \(status)")
        case .badReply: return EngineUnavailability(kind: .temporarilyUnavailable, detail: "unreadable reply from OpenRouter")
        }
    }
}
