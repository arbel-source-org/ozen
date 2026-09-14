import Foundation
import Testing
@testable import OzenKit

@Suite("CloudSpeech")
struct CloudSpeechTests {
    private func reply(_ status: Int, _ json: String) -> CloudHTTPResponse {
        CloudHTTPResponse(status: status, body: Data(json.utf8))
    }

    private func body(of request: CloudHTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("each change of speaker is its own line, labels removed")
    func speakerTurns() {
        let turns = CloudSpeech.turns(in: "A: שלום לכולם\nB: מה נשמע?\nA: הכול טוב")
        #expect(turns == ["שלום לכולם", "מה נשמע?", "הכול טוב"])
    }

    @Test("lines from the same speaker, or with no label, stay one line")
    func sameSpeakerJoined() {
        #expect(CloudSpeech.turns(in: "A: שלום\nA: מה נשמע") == ["שלום מה נשמע"])
        #expect(CloudSpeech.turns(in: "שלום\nמה נשמע") == ["שלום מה נשמע"])
        #expect(CloudSpeech.turns(in: "A: שלום\nמה נשמע\nB: טוב") == ["שלום מה נשמע", "טוב"])
    }

    @Test("labels as models write them: numbers, 'Speaker', Hebrew letters")
    func labelSpellings() {
        #expect(CloudSpeech.turns(in: "Speaker 1: כן\nspeaker 2: לא") == ["כן", "לא"])
        #expect(CloudSpeech.turns(in: "דובר א: כן\nדוברת ב: לא") == ["כן", "לא"])
        #expect(CloudSpeech.turns(in: "א: כן\nב: לא") == ["כן", "לא"])
    }

    @Test("a sentence that opens with a short word and a colon keeps the word")
    func shortWordWithColon() {
        #expect(CloudSpeech.turns(in: "אז: הלכנו הביתה") == ["אז: הלכנו הביתה"])
    }

    @Test("notes about sounds are taken out, and a reply of only notes is no line")
    func annotations() {
        #expect(CloudSpeech.turns(in: "[inaudible] שלום (music) לכולם") == ["שלום לכולם"])
        #expect(CloudSpeech.turns(in: "[silence]").isEmpty)
        #expect(CloudSpeech.turns(in: "<noise>\n").isEmpty)
        #expect(CloudSpeech.turns(in: "").isEmpty)
    }

    @Test("lines speech models are known to invent are dropped")
    func inventedLines() {
        #expect(CloudSpeech.turns(in: "A: תודה שצפיתם").isEmpty)
        #expect(CloudSpeech.turns(in: "A: מוזיקה\nB: בואו נאכל") == ["בואו נאכל"])
    }

    @Test("a phrase said over and over is shortened")
    func repeats() {
        let turns = CloudSpeech.turns(in: "כן כן כן כן כן כן כן")
        #expect(turns.count == 1)
        #expect((turns.first?.split(separator: " ").count ?? 0) <= 3)
    }

    @Test("the reply's text is the transcript")
    func transcriptFromReply() throws {
        let text = try CloudSpeech.transcript(from: reply(200, #"{"choices":[{"message":{"role":"assistant","content":"A: שלום"}}]}"#))
        #expect(text == "A: שלום")
        let empty = try CloudSpeech.transcript(from: reply(200, #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#))
        #expect(empty == "")
    }

    @Test("an error inside a successful reply, or an unreadable reply, is a failure")
    func brokenReplies() {
        #expect(throws: CloudSpeechError.serverTrouble(status: 200)) {
            try CloudSpeech.transcript(from: reply(200, #"{"error":{"message":"provider failed"}}"#))
        }
        #expect(throws: CloudSpeechError.badReply) {
            try CloudSpeech.transcript(from: reply(200, "<html>"))
        }
    }

    @Test("what each refusal means")
    func failures() {
        #expect(CloudSpeech.failure(from: reply(401, "{}")) == .keyRejected)
        #expect(CloudSpeech.failure(from: reply(402, "{}")) == .outOfCredit)
        #expect(CloudSpeech.failure(from: reply(403, #"{"error":{"message":"Key limit exceeded"}}"#)) == .outOfCredit)
        #expect(CloudSpeech.failure(from: reply(403, #"{"error":{"message":"flagged"}}"#)) == .keyRejected)
        #expect(CloudSpeech.failure(from: reply(429, "{}")) == .rateLimited)
        #expect(CloudSpeech.failure(from: reply(503, "{}")) == .serverTrouble(status: 503))
        #expect(throws: CloudSpeechError.keyRejected) {
            try CloudSpeech.transcript(from: reply(401, "{}"))
        }
    }

    @Test("only problems the person has to fix stop retrying, and each says what to fix")
    func errorKinds() {
        let needsPerson = [CloudSpeechError.keyMissing, .keyRejected, .outOfCredit, .rateLimited, .offline, .serverTrouble(status: 500), .badReply].map(\.needsPerson)
        #expect(needsPerson == [true, true, true, false, false, false, false])
        #expect(CloudSpeechError.keyMissing.unavailability.kind == .cloudKeyNeeded)
        #expect(CloudSpeechError.keyRejected.unavailability.kind == .cloudKeyNeeded)
        #expect(CloudSpeechError.outOfCredit.unavailability.kind == .cloudOutOfCredit)
        #expect(CloudSpeechError.offline.unavailability.kind == .noInternet)
        #expect(CloudSpeechError.rateLimited.unavailability.kind == .temporarilyUnavailable)
    }

    @Test("a key check with no credit left, a key with no limit, an unreadable answer")
    func creditLeft() {
        #expect(!CloudSpeech.hasCreditLeft(keyCheck: reply(200, #"{"data":{"limit":3,"limit_remaining":0}}"#)))
        #expect(!CloudSpeech.hasCreditLeft(keyCheck: reply(200, #"{"data":{"limit":3,"limit_remaining":-0.01}}"#)))
        #expect(CloudSpeech.hasCreditLeft(keyCheck: reply(200, #"{"data":{"limit":3,"limit_remaining":2.5}}"#)))
        #expect(CloudSpeech.hasCreditLeft(keyCheck: reply(200, #"{"data":{"limit":null,"limit_remaining":null}}"#)))
        #expect(CloudSpeech.hasCreditLeft(keyCheck: reply(200, "nope")))
    }

    @Test("the request carries the key, the model, the audio and the names list")
    func request() throws {
        let wav = WAVFile.pcm16([0.1, -0.1], sampleRate: 16_000)
        let request = CloudSpeech.completionRequest(model: CloudSpeech.fastModel, apiKey: "sk-test", wav: wav, languageCode: "he", vocabulary: ["דנה", "ד\"ר כהן"])
        #expect(request.url == CloudSpeech.completionsURL)
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        let json = try body(of: request)
        #expect(json["model"] as? String == CloudSpeech.fastModel)
        #expect((json["reasoning"] as? [String: String])?["effort"] == "minimal")
        let content = try #require(((json["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        let prompt = try #require(content.first?["text"] as? String)
        #expect(prompt.contains("Hebrew"))
        #expect(prompt.contains("דנה"))
        #expect(prompt.contains("ד\"ר כהן"))
        let audio = try #require(content.last?["input_audio"] as? [String: String])
        #expect(audio["format"] == "wav")
        #expect(Data(base64Encoded: audio["data"] ?? "") == wav)
    }

    @Test("no names list, no names sentence; a model that isn't Google's gets no thinking setting")
    func plainRequest() throws {
        #expect(!CloudSpeech.prompt(languageCode: "he", vocabulary: []).contains("Names"))
        let request = CloudSpeech.completionRequest(model: "openai/gpt-audio-mini", apiKey: "k", wav: Data(), languageCode: "he", vocabulary: [])
        #expect(try body(of: request)["reasoning"] == nil)
        #expect(CloudSpeech.keyCheckRequest(apiKey: "k").url == CloudSpeech.keyURL)
    }
}
