import Foundation
import Testing
@testable import OzenKit

final class FakeCloudHTTP: CloudHTTP, @unchecked Sendable {
    enum Answer {
        case text(String)
        case status(Int, String)
        case offline
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var keyChecks: [Answer]
    private var sent: [CloudHTTPRequest] = []

    init(answers: [Answer] = [], keyChecks: [Answer] = []) {
        self.answers = answers
        self.keyChecks = keyChecks
    }

    var requests: [CloudHTTPRequest] { lock.withLock { sent } }
    var transcriptionRequests: [CloudHTTPRequest] { requests.filter { $0.url == CloudSpeech.completionsURL } }

    func send(_ request: CloudHTTPRequest) async throws -> CloudHTTPResponse {
        let answer: Answer = lock.withLock {
            sent.append(request)
            if request.url == CloudSpeech.keyURL {
                return keyChecks.isEmpty ? .status(200, #"{"data":{"limit_remaining":null}}"#) : keyChecks.removeFirst()
            }
            return answers.count > 1 ? answers.removeFirst() : (answers.first ?? .text(""))
        }
        switch answer {
        case .text(let text):
            let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": text]]]]
            return CloudHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: reply))
        case .status(let status, let body):
            return CloudHTTPResponse(status: status, body: Data(body.utf8))
        case .offline:
            throw URLError(.notConnectedToInternet)
        }
    }
}

@Suite("CloudSpeechEngine")
struct CloudSpeechEngineTests {
    private let chunk = 1_024

    private func speech(seconds: Double) -> [[Float]] {
        (0..<Int(seconds * 16_000) / chunk).map { _ in (0..<chunk).map { 0.05 * sin(Float($0) * 0.3) } }
    }

    private func silence(seconds: Double) -> [[Float]] {
        (0..<Int(seconds * 16_000) / chunk).map { _ in [Float](repeating: 0, count: chunk) }
    }

    private func engine(_ http: FakeCloudHTTP, key: String? = "sk-test") -> CloudSpeechEngine {
        CloudSpeechEngine(http: http, apiKey: { key })
    }

    private func transcribe(_ engine: CloudSpeechEngine, _ chunks: [[Float]]) async throws -> [TranscriptToken] {
        let (audio, input) = AsyncStream<[Float]>.makeStream()
        let tokens = engine.stream(languageCode: "he", audio: audio)
        for chunk in chunks { input.yield(chunk) }
        input.finish()
        var received: [TranscriptToken] = []
        for try await token in tokens { received.append(token) }
        return received
    }

    @Test("a sentence and a pause become one finished line")
    func oneSentence() async throws {
        let http = FakeCloudHTTP(answers: [.text("A: שלום לכולם")])
        let tokens = try await transcribe(engine(http), speech(seconds: 1) + silence(seconds: 1))
        let finals = tokens.filter { $0.isFinal }
        #expect(finals.map(\.text) == ["שלום לכולם"])
        let request = try #require(http.transcriptionRequests.last)
        #expect(request.headers["Authorization"] == "Bearer sk-test")
    }

    @Test("the audio sent is the sentence, not the silence around it")
    func audioSent() async throws {
        let http = FakeCloudHTTP(answers: [.text("שלום")])
        _ = try await transcribe(engine(http), silence(seconds: 2) + speech(seconds: 1) + silence(seconds: 2))
        let request = try #require(http.transcriptionRequests.first)
        let json = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        let content = try #require(((json["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        let audio = try #require(Data(base64Encoded: (content.last?["input_audio"] as? [String: String])?["data"] ?? ""))
        let seconds = Double(audio.count - 44) / 2 / 16_000
        #expect(seconds > 1.0)
        #expect(seconds < 2.0)
    }

    @Test("two voices in one reply become two lines")
    func twoSpeakers() async throws {
        let http = FakeCloudHTTP(answers: [.text("A: מה שלומך?\nB: טוב, תודה")])
        let finals = try await transcribe(engine(http), speech(seconds: 1.5) + silence(seconds: 1)).filter { $0.isFinal }
        #expect(finals.map(\.text) == ["מה שלומך?", "טוב, תודה"])
        #expect(Set(finals.map(\.utteranceID)).count == 2)
        #expect(finals.map(\.startsNewSpeakerTurn) == [false, true])
    }

    @Test("a quiet room sends nothing and shows nothing")
    func silenceOnly() async throws {
        let http = FakeCloudHTTP(answers: [.text("תודה")])
        let tokens = try await transcribe(engine(http), silence(seconds: 3))
        #expect(tokens.isEmpty)
        #expect(http.transcriptionRequests.isEmpty)
    }

    @Test("words appear while someone is still talking, then the line is finished")
    func livePreview() async throws {
        let http = FakeCloudHTTP(answers: [.text("שלום"), .text("שלום לכולם")])
        let engine = engine(http)
        let (audio, input) = AsyncStream<[Float]>.makeStream()
        let tokens = engine.stream(languageCode: "he", audio: audio)
        let collected = Task {
            var received: [TranscriptToken] = []
            for try await token in tokens { received.append(token) }
            return received
        }
        for chunk in speech(seconds: 3) { input.yield(chunk) }
        #expect(await eventually { http.transcriptionRequests.count == 1 })
        for chunk in silence(seconds: 1) { input.yield(chunk) }
        input.finish()
        let received = try await collected.value
        #expect(received.map(\.text) == ["שלום", "שלום לכולם"])
        #expect(received.map(\.isFinal) == [false, true])
        #expect(Set(received.map(\.utteranceID)).count == 1)
    }

    @Test("a final request that fails once is tried again")
    func retriesFinal() async throws {
        let http = FakeCloudHTTP(answers: [.offline, .text("שלום")])
        let finals = try await transcribe(engine(http), speech(seconds: 1) + silence(seconds: 1)).filter { $0.isFinal }
        #expect(finals.map(\.text) == ["שלום"])
        #expect(http.transcriptionRequests.count == 2)
    }

    @Test("when the final request never gets through, the words already shown stay")
    func keepsShownWords() async throws {
        let http = FakeCloudHTTP(answers: [.text("שלום"), .status(503, "{}"), .status(503, "{}"), .text("")])
        let engine = engine(http)
        let (audio, input) = AsyncStream<[Float]>.makeStream()
        let tokens = engine.stream(languageCode: "he", audio: audio)
        let collected = Task {
            var received: [TranscriptToken] = []
            for try await token in tokens { received.append(token) }
            return received
        }
        for chunk in speech(seconds: 3) { input.yield(chunk) }
        #expect(await eventually { http.transcriptionRequests.count == 1 })
        for chunk in silence(seconds: 1) { input.yield(chunk) }
        input.finish()
        let received = try await collected.value
        #expect(received.map(\.text) == ["שלום", "שלום"])
        #expect(received.map(\.isFinal) == [false, true])
    }

    @Test("a rejected key ends the stream at once")
    func rejectedKey() async {
        let http = FakeCloudHTTP(answers: [.status(401, #"{"error":{"message":"No auth credentials found"}}"#)])
        await #expect(throws: CloudSpeechError.keyRejected) {
            _ = try await transcribe(engine(http), speech(seconds: 1) + silence(seconds: 1))
        }
        #expect(http.transcriptionRequests.count == 1)
    }

    @Test("several failures in a row end the stream")
    func tooManyFailures() async {
        // Nothing ever gets shown for this utterance, so every failed
        // final segment is retried (see shortUtteranceFinalFailureRetried)
        // rather than silently moved past -- eventually the retries
        // themselves are the "several failures in a row" that give up.
        let http = FakeCloudHTTP(answers: [.offline])
        await #expect(throws: CloudSpeechError.offline) {
            _ = try await transcribe(engine(http), speech(seconds: 1) + silence(seconds: 1))
        }
        // Two attempts per retried final segment, until failuresInARow
        // reaches the limit.
        #expect(http.transcriptionRequests.count == CloudSpeechEngine.failuresBeforeStopping * 2)
    }

    @Test("a short utterance's final request failing outright, with nothing shown yet, is retried rather than lost")
    func shortUtteranceFinalFailureRetried() async {
        let http = FakeCloudHTTP(answers: [.offline, .offline, .text("שלום")])
        let engine = engine(http)
        let tokens = try? await transcribe(engine, speech(seconds: 1) + silence(seconds: 1))
        // Too short for a live pass (under livePassSeconds); the first
        // final attempt-pair fails outright with nothing shown, so it must
        // retry rather than move on with the words lost.
        #expect(tokens?.map(\.text) == ["שלום"])
        #expect(http.transcriptionRequests.count == 3)
    }

    @Test("the names list read back on its own is not a line")
    func namesEcho() async throws {
        let http = FakeCloudHTTP(answers: [.text("דנה, יוסי, מרים")])
        let engine = engine(http)
        await engine.setVocabulary(["דנה", "יוסי", "מרים"])
        let tokens = try await transcribe(engine, speech(seconds: 1) + silence(seconds: 1))
        #expect(tokens.isEmpty)
    }

    @Test("no key: nothing is sent and the screen asks for one")
    func noKey() async {
        let http = FakeCloudHTTP()
        let availability = await engine(http, key: "  ").checkAvailability(languageCode: "he")
        #expect(availability.unavailability?.kind == .cloudKeyNeeded)
        #expect(http.requests.isEmpty)
    }

    @Test("the key is checked once, and again only when it changes")
    func keyCheckedOnce() async {
        let http = FakeCloudHTTP()
        let key = KeyBox("sk-one")
        let engine = CloudSpeechEngine(http: http, apiKey: { key.value })
        #expect(await engine.checkAvailability(languageCode: "he") == .available)
        #expect(await engine.checkAvailability(languageCode: "he") == .available)
        #expect(http.requests.count == 1)
        key.value = "sk-two"
        #expect(await engine.checkAvailability(languageCode: "he") == .available)
        #expect(http.requests.count == 2)
        #expect(http.requests.last?.headers["Authorization"] == "Bearer sk-two")
    }

    @Test("a key check that fails says why")
    func keyCheckFailures() async {
        let rejected = await engine(FakeCloudHTTP(keyChecks: [.status(401, "{}")])).checkAvailability(languageCode: "he")
        let spent = await engine(FakeCloudHTTP(keyChecks: [.status(200, #"{"data":{"limit_remaining":0}}"#)])).checkAvailability(languageCode: "he")
        let offline = await engine(FakeCloudHTTP(keyChecks: [.offline])).checkAvailability(languageCode: "he")
        let busy = await engine(FakeCloudHTTP(keyChecks: [.status(502, "{}")])).checkAvailability(languageCode: "he")
        #expect(rejected.unavailability?.kind == .cloudKeyNeeded)
        #expect(spent.unavailability?.kind == .cloudOutOfCredit)
        #expect(offline.unavailability?.kind == .noInternet)
        #expect(busy.unavailability?.kind == .temporarilyUnavailable)
    }

    @Test("a key turned down mid-conversation is checked again before the next start")
    func rejectedKeyForgotten() async {
        let http = FakeCloudHTTP(answers: [.status(401, "{}")], keyChecks: [.status(200, "{}"), .status(401, "{}")])
        let engine = engine(http)
        #expect(await engine.checkAvailability(languageCode: "he") == .available)
        await #expect(throws: CloudSpeechError.keyRejected) {
            _ = try await transcribe(engine, speech(seconds: 1) + silence(seconds: 1))
        }
        #expect(await engine.checkAvailability(languageCode: "he").unavailability?.kind == .cloudKeyNeeded)
    }
}

final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) {
        stored = value
    }

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
