import Foundation
import Testing
@testable import OzenKit

private struct Closed: Error {}

/// A server that follows a script: what it says to the hello, and what it
/// says once the phone reports the end of its audio.
private actor ScriptedSocket: HomeServerSocket {
    var helloReply: String?
    var afterEnd: [String] = []
    private(set) var sentTexts: [String] = []
    private(set) var sentBytes = 0
    private(set) var isClosed = false
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
    }

    func send(text: String) async throws {
        if isClosed { throw Closed() }
        sentTexts.append(text)
        if text.contains(#""type":"hello""#), let helloReply { deliver(helloReply) }
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

private func engine(_ socket: ScriptedSocket?, address: String = "10.0.0.5", token: String? = "1234") -> HomeServerEngine {
    HomeServerEngine(address: address, token: { token }, connector: Connector(socket: socket), handshakeSeconds: 0.3)
}

@Suite("Home server")
struct HomeServerEngineTests {
    @Test("an address without a scheme gets ws and the default port; a given port or wss is kept; nonsense is refused")
    func addresses() {
        #expect(HomeServer.url(from: "10.0.0.5")?.absoluteString == "ws://10.0.0.5:8765")
        #expect(HomeServer.url(from: " grandma-pc:9000 ")?.absoluteString == "ws://grandma-pc:9000")
        #expect(HomeServer.url(from: "wss://captions.example.org/ozen")?.absoluteString == "wss://captions.example.org/ozen")
        #expect(HomeServer.url(from: "http://10.0.0.5") == nil)
        #expect(HomeServer.url(from: "") == nil)
        #expect(HomeServer.url(from: "two words") == nil)
    }

    @Test("audio goes out as little-endian 16-bit samples, clipped, with a broken sample sent as silence")
    func pcm() {
        let bytes = [UInt8](HomeServer.pcm16([0, 1, -1, 2, .nan]))
        #expect(bytes == [0, 0, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F, 0, 0])
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

        await socket.deliver(text(1, "ma nishma", final: false))
        let next = try #require(try await iterator.next())
        #expect(next.utteranceID != final.utteranceID)

        feed.yield([0.1, 0.2, 0.3])
        feed.finish()
        let kept = try #require(try await iterator.next())
        #expect(kept.utteranceID == next.utteranceID && kept.isFinal && kept.text == "ma nishma")
        #expect(try await iterator.next() == nil)
        #expect(await socket.sentBytes == 6)
        #expect(await socket.sentTexts.last == HomeServer.end)
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
