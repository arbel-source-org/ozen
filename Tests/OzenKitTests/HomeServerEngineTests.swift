import Foundation
import Testing
@testable import OzenKit

private struct Closed: Error {}

/// A server that follows a script: what it says to the hello, and what it
/// says once the phone reports the end of its audio.
private actor ScriptedSocket: HomeServerSocket {
    var helloReply: String?
    var afterEnd: [String] = []
    var reportReply: String?
    private(set) var sentTexts: [String] = []
    private(set) var sentBytes = 0
    private(set) var isClosed = false
    var answersPings = true
    var hangsOnHello = false
    private var helloSends: [CheckedContinuation<Void, Error>] = []
    private(set) var pings = 0
    private var pingWaiters: [CheckedContinuation<Void, Error>] = []
    private var queue: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []

    init(helloReply: String?, afterEnd: [String] = []) {
        self.helloReply = helloReply
        self.afterEnd = afterEnd
    }

    func deliver(_ frame: String) {
        if waiters.isEmpty { queue.append(frame) } else { waiters.removeFirst().resume(returning: frame) }
    }

    func drop() {
        isClosed = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: Closed()) }
        let pingsPending = pingWaiters
        pingWaiters = []
        pingsPending.forEach { $0.resume(throwing: Closed()) }
        let sendsPending = helloSends
        helloSends = []
        sendsPending.forEach { $0.resume(throwing: Closed()) }
    }

    func ping() async throws {
        if isClosed { throw Closed() }
        pings += 1
        if answersPings { return }
        try await withCheckedThrowingContinuation { pingWaiters.append($0) }
    }

    func setAnswersPings(_ answers: Bool) { answersPings = answers }

    func setHangsOnHello(_ hangs: Bool) { hangsOnHello = hangs }

    func send(text: String) async throws {
        if isClosed { throw Closed() }
        if hangsOnHello, text.contains(#""type":"hello""#) {
            // Like a connection that never completes: only closing the
            // socket (or cancelling) ends the wait.
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { helloSends.append($0) }
            } onCancel: {
                Task { await self.drop() }
            }
        }
        sentTexts.append(text)
        if text.contains(#""type":"hello""#), let helloReply { deliver(helloReply) }
        if text.contains(#""type":"report""#), let reportReply { deliver(reportReply) }
        if text == HomeServer.end {
            afterEnd.forEach(deliver)
            drop()
        }
    }

    func send(data: Data) async throws {
        if isClosed { throw Closed() }
        sentBytes += data.count
    }

    func receive() async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        if isClosed { throw Closed() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() async { drop() }

    func setReportReply(_ reply: String?) { reportReply = reply }
}

private struct Connector: HomeServerConnecting {
    let socket: ScriptedSocket?
    func open(_ url: URL) async throws -> any HomeServerSocket {
        guard let socket else { throw Closed() }
        return socket
    }
}

private let ready = #"{"type":"ready","model":"ivrit","version":1}"#

private func text(_ utterance: Int, _ words: String, final: Bool) -> String {
    #"{"type":"text","utterance":\#(utterance),"text":"\#(words)","final":\#(final),"confidence":0.9}"#
}

private func engine(_ socket: ScriptedSocket?, address: String = "10.0.0.5", token: String? = "1234", beam: Int? = nil) -> HomeServerEngine {
    HomeServerEngine(address: address, token: { token }, connector: Connector(socket: socket), handshakeSeconds: 1, client: "Ozen 36, iOS 18.2", beam: beam)
}

@Suite("Home server")
struct HomeServerEngineTests {
    @Test("the setup link in the app is a file every release publishes, and that file fetches the server zip the release makes")
    func setupDownloadIsPublished() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let release = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let launcher = try String(contentsOf: root.appendingPathComponent("server").appendingPathComponent(HomeServer.setupFileName), encoding: .utf8)
        #expect(HomeServer.setupDownload.lastPathComponent == HomeServer.setupFileName)
        #expect(HomeServer.setupDownload.absoluteString.contains("/releases/latest/download/"))
        #expect(release.contains("cp server/\(HomeServer.setupFileName) ."))
        #expect(release.contains("gh release create \"$TAG\" Ozen.ipa ozen-home-server.zip \(HomeServer.setupFileName)"))
        #expect(release.contains("zip -q ../ozen-home-server.zip") && release.contains("setup-windows.ps1"))
        #expect(launcher.contains("/releases/latest/download/ozen-home-server.zip"))
        #expect(launcher.contains("setup-windows.ps1"))
        // Windows PowerShell 5.1 reads a script without a BOM as the local
        // code page, and cmd reads .cmd files the same way: any Hebrew in
        // them would be garbled on a Hebrew Windows.
        let setup = try String(contentsOf: root.appendingPathComponent("server/setup-windows.ps1"), encoding: .utf8)
        #expect(launcher.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(setup.unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test("a hello that never finishes sending (a computer gone to sleep mid-connect) gives up within the handshake wait, not the system's minute")
    func helloSendIsTimed() async {
        let socket = ScriptedSocket(helloReply: ready)
        await socket.setHangsOnHello(true)
        let started = ContinuousClock.now
        let answer = await withTaskGroup(of: EngineAvailability?.self) { group in
            group.addTask { await engine(socket).checkAvailability(languageCode: "he") }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(answer?.unavailability?.kind == .homeServerUnreachable)
        #expect(started.duration(to: .now) < .seconds(4))
    }

    @Test("an address without a scheme gets ws and the default port; a given port or wss is kept; nonsense is refused")
    func addresses() {
        #expect(HomeServer.url(from: "10.0.0.5")?.absoluteString == "ws://10.0.0.5:8765")
        #expect(HomeServer.url(from: " grandma-pc:9000 ")?.absoluteString == "ws://grandma-pc:9000")
        #expect(HomeServer.url(from: "wss://captions.example.org/ozen")?.absoluteString == "wss://captions.example.org/ozen")
        #expect(HomeServer.url(from: "http://10.0.0.5") == nil)
        #expect(HomeServer.url(from: "https://desktop.tail0example.ts.net")?.absoluteString == "wss://desktop.tail0example.ts.net")
        #expect(HomeServer.url(from: "HTTPS://captions.example.org/ozen")?.absoluteString == "wss://captions.example.org/ozen")
        #expect(HomeServerPairing(address: "https://captions.example.org", code: "example-code-123") != nil)
        #expect(HomeServer.url(from: "https://wss://desktop.tail0example.ts.net") == nil)
        #expect(HomeServer.url(from: "") == nil)
        #expect(HomeServer.url(from: "two words") == nil)
    }

    @Test("an address pasted into one already there is refused, not saved with the host \"wss\"")
    func doubledScheme() {
        #expect(HomeServer.url(from: "wss://wss://desktop.tail.ts.net") == nil)
        #expect(HomeServer.url(from: "wss://10.0.0.5wss://10.0.0.5") == nil)
        #expect(HomeServer.unsavedAddress(draft: "wss://wss://desktop.tail.ts.net", saved: "") == nil)
        #expect(HomeServer.url(from: "wss://desktop.tail.ts.net") != nil)
    }

    @Test("a pairing link from the QR code gives the address and code; anything else is refused")
    func pairingLinks() throws {
        let link = try #require(URL(string: "ozen://pair?address=wss://desktop.tail.ts.net&code=example-code-123"))
        let pairing = try #require(HomeServerPairing(url: link))
        #expect(pairing.address == "wss://desktop.tail.ts.net")
        #expect(pairing.code == "example-code-123")
        #expect(pairing.computerName == "desktop.tail.ts.net")
        #expect(HomeServerPairing(url: pairing.url) == pairing)

        let encoded = try #require(URL(string: "ozen://pair?address=wss%3A%2F%2Fdesktop.tail.ts.net%3A8765&code=a%2Bb"))
        #expect(HomeServerPairing(url: encoded)?.address == "wss://desktop.tail.ts.net:8765")
        #expect(HomeServerPairing(url: encoded)?.code == "a+b")

        for bad in [
            "https://pair?address=wss://x.net&code=abc",
            "ozen://settings?address=wss://x.net&code=abc",
            "ozen://pair?address=http://x.net&code=abc",
            "ozen://pair?address=wss://x.net",
            "ozen://pair?address=wss://x.net&code=",
            "ozen://pair?code=abc",
        ] {
            #expect(HomeServerPairing(url: try #require(URL(string: bad))) == nil, "\(bad)")
        }
        #expect(HomeServerPairing(address: "10.0.0.5", code: "two words") == nil)

        // Unencrypted audio only to a computer at home or on the tailnet;
        // setup never makes a ws:// link for anything else.
        for home in ["ws://192.168.1.20:8765", "10.0.0.5", "ws://172.20.1.2:8765", "ws://100.64.0.7:8765", "ws://desktop:8765", "ws://grandma-pc.local:8765", "ws://desktop.tail0example.ts.net:8765"] {
            #expect(HomeServerPairing(address: home, code: "abc") != nil, "\(home)")
        }
        for away in ["ws://203.0.113.9:8765", "ws://evil.example.com:8765", "8.8.8.8", "ws://172.32.0.1:8765", "ws://100.128.0.1:8765"] {
            #expect(HomeServerPairing(address: away, code: "abc") == nil, "\(away)")
        }
        #expect(HomeServerPairing(address: "wss://captions.example.com", code: "abc") != nil)

        #expect(HomeServerPairing.isPairingLink(link))
        #expect(HomeServerPairing.isPairingLink(try #require(URL(string: "OZEN://Pair?code="))))
        #expect(!HomeServerPairing.isPairingLink(try #require(URL(string: "ozen://settings?address=wss://x.net&code=abc"))))
        #expect(!HomeServerPairing.isPairingLink(try #require(URL(string: "https://pair?address=wss://x.net&code=abc"))))
    }

    @Test("Test connection says connected with the time it took, a refused code, no answer, or nothing set up yet")
    func connectionCheck() async {
        let ok = await engine(ScriptedSocket(helloReply: ready)).checkAvailability(languageCode: "he")
        #expect(HomeServerCheck(availability: ok, seconds: 0.0424) == .connected(milliseconds: 42))
        let refused = await engine(ScriptedSocket(helloReply: #"{"type":"error","code":"unauthorized","detail":""}"#)).checkAvailability(languageCode: "he")
        #expect(HomeServerCheck(availability: refused, seconds: 0.1) == .codeRefused)
        let silent = await engine(ScriptedSocket(helloReply: nil)).checkAvailability(languageCode: "he")
        #expect(HomeServerCheck(availability: silent, seconds: 0.3) == .unreachable)
        let noCode = await engine(ScriptedSocket(helloReply: ready), token: nil).checkAvailability(languageCode: "he")
        #expect(HomeServerCheck(availability: noCode, seconds: 0) == .notSetUp)
        let noAddress = await engine(ScriptedSocket(helloReply: ready), address: "").checkAvailability(languageCode: "he")
        #expect(HomeServerCheck(availability: noAddress, seconds: 0) == .notSetUp)
    }

    @Test("a connection that stops answering pings is given up on within seconds, even in silence; one that answers is kept")
    func deadPathIsDropped() async throws {
        func run(answering: Bool) async throws -> (Error?, Int) {
            let socket = ScriptedSocket(helloReply: ready)
            await socket.setAnswersPings(answering)
            let server = HomeServerEngine(address: "10.0.0.5", token: { "1234" }, connector: Connector(socket: socket), handshakeSeconds: 1, pingSeconds: 0.05, pongSeconds: 1)
            let (audio, feed) = AsyncStream<[Float]>.makeStream()
            let tokens = server.stream(languageCode: "he", audio: audio)
            let quiet = [Float](repeating: 0.0005, count: 1600)
            let feeding = Task {
                for _ in 0..<120 {
                    feed.yield(quiet)
                    try? await Task.sleep(for: .milliseconds(25))
                }
                feed.finish()
            }
            defer { feeding.cancel() }
            do {
                for try await _ in tokens {}
                return (nil, await socket.pings)
            } catch {
                return (error, await socket.pings)
            }
        }
        let (dead, deadPings) = try await run(answering: false)
        #expect((dead as? EngineUnavailability)?.kind == .homeServerUnreachable)
        #expect(deadPings == 1)
        let (alive, alivePings) = try await run(answering: true)
        #expect(alive == nil)
        #expect(alivePings >= 10)
    }

    @Test("a pairing link that lost its slashes on the way is still recognised as one, so the phone can say it's damaged")
    func damagedPairingLink() throws {
        #expect(HomeServerPairing.isPairingLink(try #require(URL(string: "ozen://pair?address=wss://x.net&code=abc"))))
        #expect(HomeServerPairing.isPairingLink(try #require(URL(string: "ozen:pair?address=wss://x.net&code=abc"))))
        #expect(!HomeServerPairing.isPairingLink(try #require(URL(string: "ozen://settings"))))
        #expect(!HomeServerPairing.isPairingLink(try #require(URL(string: "ozen:settings"))))
        #expect(!HomeServerPairing.isPairingLink(try #require(URL(string: "https://example.com/pair"))))
    }

    @Test("an address typed but never saved is kept as Settings closes, unless it is unchanged, empty or not an address")
    func unsavedAddress() {
        #expect(HomeServer.unsavedAddress(draft: " wss://pc.example.ts.net\n", saved: "10.0.0.5") == "wss://pc.example.ts.net")
        #expect(HomeServer.unsavedAddress(draft: "192.168.1.20", saved: "") == "192.168.1.20")
        #expect(HomeServer.unsavedAddress(draft: "10.0.0.5 ", saved: "10.0.0.5") == nil)
        #expect(HomeServer.unsavedAddress(draft: "", saved: "10.0.0.5") == nil)
        #expect(HomeServer.unsavedAddress(draft: "my computer", saved: "10.0.0.5") == nil)
    }

    @Test("audio goes out as little-endian 16-bit samples, clipped, with a broken sample sent as silence")
    func pcm() {
        let bytes = [UInt8](HomeServer.pcm16([0, 1, -1, 2, .nan]))
        #expect(bytes == [0, 0, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F, 0, 0])
    }

    @Test("a server that stays connected but never answers speech is given up on, so the phone's own model can take over; silence alone never is")
    func stuckServerIsDropped() async throws {
        func run(_ chunk: [Float], replyEvery: Int?, reply: @escaping (Int) -> String = { text($0, "", final: true) }) async throws -> Error? {
            let socket = ScriptedSocket(helloReply: ready)
            let server = HomeServerEngine(address: "10.0.0.5", token: { "1234" }, connector: Connector(socket: socket), handshakeSeconds: 1, stallSeconds: 2)
            let (audio, feed) = AsyncStream<[Float]>.makeStream()
            let tokens = server.stream(languageCode: "he", audio: audio)
            let quiet = [Float](repeating: 0.0005, count: 1600)
            for _ in 0..<10 { feed.yield(quiet) }
            for index in 0..<40 {
                feed.yield(chunk)
                if let every = replyEvery, index % every == 0 {
                    var waited = 0
                    while await socket.sentBytes < (10 + index + 1) * 3200, waited < 500 {
                        try await Task.sleep(for: .milliseconds(2))
                        waited += 1
                    }
                    await socket.deliver(reply(index))
                }
            }
            feed.finish()
            do {
                for try await _ in tokens {}
                return nil
            } catch {
                return error
            }
        }
        let loud = (0..<1600).map { Float(0.3 * sin(Double($0) * 0.3)) }
        let quiet = [Float](repeating: 0.0005, count: 1600)
        let stuck = try await run(loud, replyEvery: nil)
        #expect((stuck as? EngineUnavailability)?.kind == .homeServerUnreachable)
        #expect(try await run(quiet, replyEvery: nil) == nil)
        #expect(try await run(loud, replyEvery: 5) == nil)
        let garbage = try await run(loud, replyEvery: 5) { _ in "<html>502 Bad Gateway</html>" }
        #expect((garbage as? EngineUnavailability)?.kind == .homeServerUnreachable)
    }

    @Test("a diagnostics report goes to the server, which says it kept it; a server that doesn't answer is a failure")
    func sendsReport() async {
        let saving = ScriptedSocket(helloReply: ready)
        await saving.setReportReply(#"{"type":"report_saved","name":"20260926-2100.txt"}"#)
        #expect(await engine(saving).sendReport("levels -40 dB", languageCode: "he"))
        let sent = await saving.sentTexts
        #expect(sent.first?.contains(#""purpose":"report""#) == true)
        #expect(sent.contains(HomeServer.report("levels -40 dB")))

        #expect(await engine(ScriptedSocket(helloReply: ready)).sendReport("x", languageCode: "he") == false)
        #expect(await engine(ScriptedSocket(helloReply: ready), token: nil).sendReport("x", languageCode: "he") == false)
    }

    @Test("the Settings beam goes to the server in the hello; without one the hello leaves it to the server")
    func helloCarriesBeam() async {
        let chosen = ScriptedSocket(helloReply: ready)
        _ = await engine(chosen, beam: 2).checkAvailability(languageCode: "he")
        #expect(await chosen.sentTexts.first?.contains(#""beam":2"#) == true)

        let unset = ScriptedSocket(helloReply: ready)
        _ = await engine(unset).checkAvailability(languageCode: "he")
        let hello = await unset.sentTexts.first ?? ""
        #expect(hello.contains(#""type":"hello""#))
        #expect(!hello.contains("beam"))
    }

    @Test("a name added while captions stream reaches the server at once, as a vocabulary frame")
    func vocabularyMidStream() async throws {
        let socket = ScriptedSocket(helloReply: ready)
        let server = engine(socket)
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        let tokens = server.stream(languageCode: "he", audio: audio)
        feed.yield([0.1])
        var waited = 0
        while await socket.sentBytes == 0, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        await server.setVocabulary(["Ruti"])
        #expect(await socket.sentTexts.last == HomeServer.vocabularyUpdate(["Ruti"]))
        #expect(HomeServer.vocabularyUpdate(["Ruti"]) == #"{"terms":["Ruti"],"type":"vocabulary"}"#)
        feed.finish()
        for try await _ in tokens {}
    }

    @Test("a name added while the connection is still being set up reaches the server once it is ready", .timeLimit(.minutes(1)))
    func vocabularyDuringHandshake() async throws {
        let socket = ScriptedSocket(helloReply: nil)
        let server = engine(socket)
        await server.setVocabulary(["Avi"])
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        let tokens = server.stream(languageCode: "he", audio: audio)
        var waited = 0
        while await socket.sentTexts.isEmpty, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(await socket.sentTexts.first?.contains("Avi") == true)
        await server.setVocabulary(["Avi", "Ruti"])
        await socket.deliver(ready)
        feed.yield([0.1])
        waited = 0
        while await !socket.sentTexts.contains(HomeServer.vocabularyUpdate(["Avi", "Ruti"])), waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(await socket.sentTexts.contains(HomeServer.vocabularyUpdate(["Avi", "Ruti"])))
        feed.finish()
        for try await _ in tokens {}
    }

    @Test("a server that answers ready is available, and the hello carries the code, language and names")
    func pairs() async throws {
        let socket = ScriptedSocket(helloReply: ready)
        let server = engine(socket)
        await server.setVocabulary(["Ruti"])
        #expect(await server.checkAvailability(languageCode: "he") == .available)
        let hello = try #require(await socket.sentTexts.first)
        #expect(hello.contains(#""token":"1234""#))
        #expect(hello.contains(#""language":"he""#))
        #expect(hello.contains("Ruti"))
        #expect(hello.contains(#""purpose":"check""#))
        #expect(hello.contains(#""client":"Ozen 36, iOS 18.2""#))
        #expect(await socket.isClosed)
    }

    @Test("a refused pairing code needs a person; a silent, missing or unparseable server is unreachable")
    func refusals() async {
        let refused = ScriptedSocket(helloReply: #"{"type":"error","code":"unauthorized","detail":""}"#)
        #expect(await engine(refused).checkAvailability(languageCode: "he").unavailability?.kind == .homeServerRejected)
        #expect(await engine(ScriptedSocket(helloReply: ready), token: nil).checkAvailability(languageCode: "he").unavailability?.kind == .homeServerRejected)

        let silent = ScriptedSocket(helloReply: nil)
        #expect(await engine(silent).checkAvailability(languageCode: "he").unavailability?.kind == .homeServerUnreachable)
        #expect(await silent.isClosed)
        #expect(await engine(nil).checkAvailability(languageCode: "he").unavailability?.kind == .homeServerUnreachable)
        #expect(await engine(ScriptedSocket(helloReply: ready), address: "http://x").checkAvailability(languageCode: "he").unavailability?.kind == .homeServerUnreachable)
    }

    @Test("replies become tokens: one id per line, a new id for the next, an empty final keeps the words, the end closes cleanly")
    func streams() async throws {
        let socket = ScriptedSocket(helloReply: ready, afterEnd: [text(1, "", final: true)])
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        let tokens = engine(socket).stream(languageCode: "he", audio: audio)
        var iterator = tokens.makeAsyncIterator()
        var waited = 0
        while await socket.sentTexts.isEmpty, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }

        await socket.deliver(text(0, "shalom", final: false))
        let live = try #require(try await iterator.next())
        await socket.deliver(text(0, "shalom savta", final: true))
        let final = try #require(try await iterator.next())
        #expect(live.utteranceID == final.utteranceID)
        #expect(!live.isFinal && final.isFinal && final.text == "shalom savta")

        await socket.deliver(text(0, "shalom savta", final: false))
        await socket.deliver(text(1, "ma nishma", final: false))
        let next = try #require(try await iterator.next())
        #expect(next.utteranceID != final.utteranceID)
        #expect(next.text == "ma nishma")

        feed.yield([0.1, 0.2, 0.3])
        feed.finish()
        let kept = try #require(try await iterator.next())
        #expect(kept.utteranceID == next.utteranceID && kept.isFinal && kept.text == "ma nishma")
        #expect(try await iterator.next() == nil)
        #expect(await socket.sentBytes == 6)
        #expect(await socket.sentTexts.last == HomeServer.end)
        #expect(await socket.sentTexts.first?.contains(#""purpose":"captions""#) == true)
    }

    @Test("a text frame's per-segment numbers are read; a frame without them still parses")
    func segmentsParse() {
        let frame = #"{"type":"text","utterance":2,"text":"כן","final":true,"confidence":0.8,"segments":[{"text":"כן","no_speech":0.1,"logprob":-0.3,"compression":1.2}]}"#
        guard case .text(_, _, _, _, let segments)? = HomeServerMessage(json: frame) else {
            Issue.record("not a text frame")
            return
        }
        #expect(segments == [WhisperSegmentSummary(text: "כן", noSpeechProb: 0.1, avgLogprob: -0.3, compressionRatio: 1.2)])
        guard case .text(_, _, _, _, let none)? = HomeServerMessage(json: text(0, "כן", final: true)) else {
            Issue.record("not a text frame")
            return
        }
        #expect(none == nil)
    }

    @Test("ready and error messages missing their optional fields fall back to empty strings instead of failing to parse")
    func missingTopLevelFieldsFallBack() {
        #expect(HomeServerMessage(json: #"{"type":"ready"}"#) == .ready(model: ""))
        #expect(HomeServerMessage(json: #"{"type":"error"}"#) == .refused(code: "", detail: ""))
    }

    @Test("a segment missing no_speech, logprob or compression falls back to defaults instead of being dropped")
    func segmentMissingNumbersFallBack() {
        let frame = #"{"type":"text","utterance":0,"text":"כן","final":true,"segments":[{"text":"כן"}]}"#
        guard case .text(_, _, _, _, let segments)? = HomeServerMessage(json: frame) else {
            Issue.record("not a text frame")
            return
        }
        #expect(segments == [WhisperSegmentSummary(text: "כן", noSpeechProb: 0, avgLogprob: 0, compressionRatio: 1)])
    }

    @Test("the server's text gets the phone's own checks: the names list read back, a TV sign-off and a thanks the model barely heard are dropped, real words stay")
    func serverTextIsFiltered() async throws {
        let socket = ScriptedSocket(helloReply: ready)
        let server = engine(socket)
        await server.setVocabulary(["רותי", "אבי", "דני"])
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        var iterator = server.stream(languageCode: "he", audio: audio).makeAsyncIterator()
        var waited = 0
        while await socket.sentTexts.isEmpty, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        await socket.deliver(text(0, "רותי, אבי, דני.", final: true))
        await socket.deliver(text(1, "תודה שצפיתם", final: true))
        await socket.deliver(#"{"type":"text","utterance":2,"text":"תודה","final":true,"segments":[{"text":"תודה","no_speech":0.5,"logprob":-0.95,"compression":1.0}]}"#)
        await socket.deliver(#"{"type":"text","utterance":3,"text":"תודה רבה, אבי","final":true,"segments":[{"text":"תודה רבה, אבי","no_speech":0.02,"logprob":-0.2,"compression":1.1}]}"#)
        let kept = try #require(try await iterator.next())
        #expect(kept.text == "תודה רבה, אבי")
        feed.finish()
        #expect(try await iterator.next() == nil)
    }

    @Test("stopping captions mid-sentence closes the connection, even though the server never hangs up")
    func stoppingCloses() async throws {
        let socket = ScriptedSocket(helloReply: ready)
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        let tokens = engine(socket).stream(languageCode: "he", audio: audio)
        let listening = Task {
            for try await _ in tokens {}
        }
        feed.yield([0.1])
        var waited = 0
        while await socket.sentTexts.isEmpty, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        listening.cancel()
        waited = 0
        while await !socket.isClosed, waited < 200 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(await socket.isClosed)
        feed.finish()
    }

    @Test("after the connection drops, the next availability check asks the server again instead of trusting the last answer")
    func dropForgetsTheServer() async {
        let socket = ScriptedSocket(helloReply: ready)
        let server = engine(socket)
        #expect(await server.checkAvailability(languageCode: "he") == .available)
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        let tokens = server.stream(languageCode: "he", audio: audio)
        feed.yield([0.1])
        await socket.drop()
        do { for try await _ in tokens {} } catch {}
        #expect(await server.checkAvailability(languageCode: "he").unavailability?.kind == .homeServerUnreachable)
        feed.finish()
    }

    @Test("a connection that drops while she is still talking ends the stream as unreachable")
    func drops() async {
        let socket = ScriptedSocket(helloReply: ready)
        let (audio, feed) = AsyncStream<[Float]>.makeStream()
        let tokens = engine(socket).stream(languageCode: "he", audio: audio)
        feed.yield([0.1])
        await socket.drop()
        var thrown: Error?
        do {
            for try await _ in tokens {}
        } catch {
            thrown = error
        }
        #expect((thrown as? EngineUnavailability)?.kind == .homeServerUnreachable)
        feed.finish()
    }
}

@MainActor
@Suite("Home server handing over to the phone's own model")
struct HomeServerCoverTests {
    private var serverSettings: AppSettings {
        var settings = AppSettings.default
        settings.engine = .homeServer
        settings.homeServerAddress = "10.0.0.5"
        return settings
    }

    @Test("an unreachable server or a refused code is covered by the downloaded phone model")
    func coversAtStart() async {
        for kind in [EngineUnavailability.Kind.homeServerUnreachable, .homeServerRejected] {
            let server = FakeEngine(kind: .homeServer, availability: .unavailable(kind, "test"))
            let phone = FakeEngine(kind: .whisperKit)
            let captions = CaptionPipeline(
                audio: FakeAudioCapturer(),
                engineFactory: { $0.engine == .homeServer ? server : phone },
                embedder: FakeEmbedder(),
                recovery: .disabled
            )
            await captions.start(settings: serverSettings)
            #expect(await eventually { captions.phase == .listening }, "\(kind)")
            #expect(captions.isCoveringForCloud)
            #expect(captions.activeEngineKind == .whisperKit)
            #expect(captions.coverReason == kind, "the screen must be able to say which of the two it was")
        }
    }

    @Test("the server going away mid-conversation hands over to the phone instead of stopping")
    func coversMidStream() async {
        let server = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "connection lost"))
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        #expect(captions.isCoveringForCloud)
    }

    @Test("once the unreachable computer answers again, captions go back to it by themselves")
    func switchesBack() async {
        let server = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        captions.homeServerRecheckSeconds = 0.05
        captions.homeServerSwitchBackQuietSeconds = 0
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "connection lost"))
        #expect(await eventually { captions.activeEngineKind == .whisperKit })
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        #expect(!captions.isCoveringForCloud)
        #expect(captions.coverReason == nil)
    }

    @Test("with no backup on the phone, captions start again by themselves once the computer answers, not only after a tap")
    func waitsForTheComputerWithoutABackup() async {
        let server = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerUnreachable, "asleep"))
        let phone = FakeEngine(kind: .whisperKit)
        phone.pendingDownload = 819
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: [])
        )
        captions.homeServerRecheckSeconds = 0.05
        await captions.start(settings: serverSettings)
        #expect(await eventually { server.prepareCount >= 2 && captions.scheduledRetry == nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(captions.phase.failure?.engineUnavailability?.kind == .homeServerUnreachable)
        #expect(phone.prepareCount == 0, "no surprise download of the backup")

        server.availability = .available
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        #expect(!captions.isCoveringForCloud)
    }

    @Test("a computer that answers while a voice sample records starts captions after the recording, without cutting it short")
    func computerAnswersDuringVoiceSample() async {
        let server = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerUnreachable, "asleep"))
        let phone = FakeEngine(kind: .whisperKit)
        phone.pendingDownload = 819
        let audio = FakeAudioCapturer()
        let captions = CaptionPipeline(
            audio: audio,
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: [])
        )
        captions.homeServerRecheckSeconds = 0.05
        await captions.start(settings: serverSettings)
        #expect(await eventually { server.prepareCount >= 2 && captions.scheduledRetry == nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(captions.phase.failure?.engineUnavailability?.kind == .homeServerUnreachable)

        let recording = Task { await captions.captureEnrollmentSamples(seconds: 1) }
        #expect(await eventually { captions.isRecordingVoice })
        server.availability = .available
        try? await Task.sleep(for: .milliseconds(300))
        audio.push([Float](repeating: 0.1, count: 16_000))
        let sample = await recording.value
        #expect(sample.count == 16_000)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
    }

    @Test("an automatic retry that comes due while a voice sample records waits for it, instead of cutting it short and giving up")
    func retryDueDuringVoiceSample() async {
        let server = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerUnreachable, "asleep"))
        let phone = FakeEngine(kind: .whisperKit)
        phone.pendingDownload = 819
        let audio = FakeAudioCapturer()
        let captions = CaptionPipeline(
            audio: audio,
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(glitchDelays: [0.2], downloadDelays: [])
        )
        captions.homeServerRecheckSeconds = 60
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.scheduledRetry != nil })

        let recording = Task { await captions.captureEnrollmentSamples(seconds: 1) }
        #expect(await eventually { captions.isRecordingVoice })
        server.availability = .available
        try? await Task.sleep(for: .milliseconds(400))
        audio.push([Float](repeating: 0.1, count: 16_000))
        let sample = await recording.value
        #expect(sample.count == 16_000)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
    }

    private final class Built: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test("while the phone covers, looking for the computer again keeps the phone's loaded model, so a pause and resume doesn't load it again")
    func recheckKeepsThePhoneModel() async {
        let server = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerUnreachable, "asleep"))
        let phone = FakeEngine(kind: .whisperKit)
        let phonesBuilt = Built()
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                if settings.engine == .homeServer { return server }
                phonesBuilt.add()
                return phone
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        captions.homeServerRecheckSeconds = 0.05
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        #expect(await eventually { server.prepareCount >= 3 })
        captions.pause()
        await captions.resume(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        #expect(phonesBuilt.value == 1)
    }

    private final class Variants: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ variant: String) { lock.withLock { list.append(variant) } }
        var all: [String] { lock.withLock { list } }
    }

    @Test("a phone model chosen while the home computer captions is the one a later cover loads")
    func coverUsesModelChosenMeanwhile() async {
        let server = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let variants = Variants()
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                if settings.engine == .homeServer { return server }
                variants.add(settings.whisperModelVariant)
                return phone
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        captions.setWhisperModelVariant("small")
        server.availability = .unavailable(.homeServerUnreachable, "asleep")
        server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "asleep"))
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        #expect(variants.all == ["small"])
    }

    @Test("a refused code is left for a person to fix, not asked again and again")
    func refusedCodeIsNotPolled() async {
        let server = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerRejected, "wrong code"))
        let phone = FakeEngine(kind: .whisperKit)
        phone.pendingDownload = 819
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(glitchDelays: [0.01], downloadDelays: [])
        )
        captions.homeServerRecheckSeconds = 0.05
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase.failure != nil && captions.scheduledRetry == nil })
        try? await Task.sleep(for: .milliseconds(150))
        let asked = server.prepareCount
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.prepareCount == asked)
    }

    @Test("the switch back waits while someone is mid-sentence")
    func waitsForTheSentenceToEnd() async throws {
        let server = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        captions.homeServerRecheckSeconds = 0.3
        captions.homeServerSwitchBackQuietSeconds = 0
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "connection lost"))
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        let line = UUID()
        phone.emit(TranscriptToken(utteranceID: line, text: "סבתא, את", isFinal: false, timestamp: Date().timeIntervalSince1970))
        #expect(await eventually { captions.segments.last?.text == "סבתא, את" })
        try await Task.sleep(for: .milliseconds(700))
        #expect(captions.activeEngineKind == .whisperKit)
        phone.emit(TranscriptToken(utteranceID: line, text: "סבתא, את באה?", isFinal: true, timestamp: Date().timeIntervalSince1970))
        #expect(await eventually { captions.activeEngineKind == .homeServer })
    }

    @Test("with talk that never goes quiet, captions still go back after a few answered checks, between two lines")
    func switchesBackWithoutSilence() async throws {
        let server = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        captions.homeServerRecheckSeconds = 0.05
        captions.homeServerSwitchBackQuietSeconds = 1000
        captions.switchBackAfterAnsweredChecks = 3
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "connection lost"))
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        let before = server.prepareCount
        var spoken = 0
        while captions.activeEngineKind == .whisperKit, spoken < 60 {
            phone.emit(TranscriptToken(utteranceID: UUID(), text: "הטלוויזיה מדברת \(spoken)", isFinal: true, timestamp: Date().timeIntervalSince1970))
            spoken += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(captions.activeEngineKind == .homeServer)
        #expect(server.prepareCount - before >= 3)
    }

    @Test("pausing and resuming with her home-computer settings keeps the phone's model on while the computer is down")
    func resumeKeepsCover() async {
        let server = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerUnreachable, "test"))
        let built = BuiltEngines()
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                built.add(settings.engine == .homeServer ? server : phone)
                return settings.engine == .homeServer ? server : phone
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.isCoveringForCloud && captions.phase == .listening })
        let tries = server.prepareCount
        let builtBefore = built.count
        captions.pause()
        await captions.resume(settings: serverSettings)
        #expect(captions.phase == .listening)
        #expect(captions.isCoveringForCloud)
        #expect(captions.activeEngineKind == .whisperKit)
        #expect(server.prepareCount == tries)
        #expect(built.count == builtBefore)
        captions.stop()
    }

    @Test("a computer that keeps dropping right after captions go back to it is tried less and less often; a drop after a good stretch starts over")
    func flappingServerBacksOff() async throws {
        let server = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .homeServer ? server : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        // Long enough that the phone's turn outlasts a busy one-core
        // runner's scheduling delay: at 0.02 s the switch back could
        // happen between two polls, and the test missed the phone's turn.
        captions.homeServerRecheckSeconds = 0.1
        captions.homeServerSwitchBackQuietSeconds = 0
        await captions.start(settings: serverSettings)
        // The wait is set just after the switch to the phone; read it once
        // it has settled.
        for wait in [0.1, 0.2, 0.4, 0.8] {
            #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
            server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "no reply for 35 s of speech"))
            #expect(await eventually { captions.activeEngineKind == .whisperKit && captions.currentHomeServerRecheckSeconds == wait })
        }

        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .homeServer })
        captions.homeServerFlapWindowSeconds = 0
        server.endStream(throwing: EngineUnavailability(kind: .homeServerUnreachable, detail: "connection lost"))
        #expect(await eventually { captions.activeEngineKind == .whisperKit && captions.currentHomeServerRecheckSeconds == 0.1 })
        captions.stop()
    }

    @Test("a computer still out of reach is asked again and again; a refused code is left for a person")
    func keepsAskingOnlyWhenUnreachable() async throws {
        for (kind, asksAgain) in [(EngineUnavailability.Kind.homeServerUnreachable, true), (.homeServerRejected, false)] {
            let server = FakeEngine(kind: .homeServer, availability: .unavailable(kind, "test"))
            let phone = FakeEngine(kind: .whisperKit)
            let captions = CaptionPipeline(
                audio: FakeAudioCapturer(),
                engineFactory: { $0.engine == .homeServer ? server : phone },
                embedder: FakeEmbedder(),
                recovery: .disabled
            )
            captions.homeServerRecheckSeconds = 0.05
            captions.homeServerSwitchBackQuietSeconds = 0
            await captions.start(settings: serverSettings)
            #expect(await eventually { captions.phase == .listening && captions.isCoveringForCloud })
            let before = server.prepareCount
            try await Task.sleep(for: .milliseconds(400))
            #expect((server.prepareCount > before) == asksAgain, "\(kind)")
            #expect(captions.activeEngineKind == .whisperKit)
            captions.stop()
        }
    }

    @Test("a new server address builds a new engine instead of reusing the one for the old address")
    func newAddressNewEngine() async {
        var addresses: [String] = []
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                addresses.append(settings.homeServerAddress)
                return FakeEngine(kind: .homeServer)
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: serverSettings)
        #expect(await eventually { captions.phase == .listening })
        var moved = serverSettings
        moved.homeServerAddress = "10.0.0.9"
        await captions.restart(settings: moved)
        #expect(await eventually { captions.phase == .listening })
        #expect(addresses == ["10.0.0.5", "10.0.0.9"])
    }

    @Test("the address survives a save, and settings saved before it existed load with none")
    func settingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.homeServerAddress = "grandma-pc:8765"
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).homeServerAddress == "grandma-pc:8765")
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "homeServerAddress")
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(AppSettings.self, from: oldData).homeServerAddress == "")
    }
}
