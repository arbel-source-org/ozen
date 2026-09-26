import Foundation

/// Live captions from the family's own GPU computer (see `HomeServer`).
/// The server decides where lines start and end, exactly as the phone's
/// Whisper engine would; this side only streams the microphone and turns
/// each reply into a token for the line it belongs to.
///
/// Anything that stops the server being reachable (no answer to the
/// hello, the connection dropping mid-sentence) ends the stream with
/// `homeServerUnreachable`, which `CloudCover` answers by carrying on with
/// the phone's own model; a pairing code the server turns down ends it
/// with `homeServerRejected`, which only a person can fix.
public actor HomeServerEngine: TranscriptionEngine {
    public nonisolated let kind: TranscriptionEngineKind = .homeServer

    public nonisolated let address: String
    private let token: @Sendable () -> String?
    private let connector: any HomeServerConnecting
    private let handshakeSeconds: Double
    private var vocabulary: [String] = []
    private var echo: PromptEchoDetector?
    private let filter = WhisperResultFilter()
    private var liveSocket: (any HomeServerSocket)?
    private var verified: (url: URL, token: String)?
    private var endSent = false

    public init(
        address: String,
        token: @escaping @Sendable () -> String?,
        connector: any HomeServerConnecting,
        handshakeSeconds: Double = 5
    ) {
        self.address = address
        self.token = token
        self.connector = connector
        self.handshakeSeconds = handshakeSeconds
    }

    public func setVocabulary(_ terms: [String]) async {
        vocabulary = terms
        let detector = PromptEchoDetector(terms: terms)
        echo = detector.isEmpty ? nil : detector
        if let liveSocket {
            try? await liveSocket.send(text: HomeServer.vocabularyUpdate(terms))
        }
    }

    public func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability {
        progress(EnginePreparationProgress(stage: .checkingSupport))
        let target: (url: URL, token: String)
        switch destination() {
        case .success(let found): target = found
        case .failure(let why): return .unavailable(why)
        }
        if let verified, verified.url == target.url, verified.token == target.token { return .available }
        do {
            let socket = try await handshake(target, languageCode: languageCode)
            await socket.close()
            verified = target
            return .available
        } catch let why as EngineUnavailability {
            return .unavailable(why)
        } catch {
            return .unavailable(.homeServerUnreachable("\(error)"))
        }
    }

    public nonisolated func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(languageCode: languageCode, audio: audio, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func diagnosticsSummary() async -> String? {
        "home server \(address)"
    }

    // MARK: - Streaming

    private func run(
        languageCode: String,
        audio: AsyncStream<[Float]>,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) async {
        let target: (url: URL, token: String)
        switch destination() {
        case .success(let found): target = found
        case .failure(let why):
            continuation.finish(throwing: why)
            return
        }
        let socket: any HomeServerSocket
        do {
            socket = try await handshake(target, languageCode: languageCode)
        } catch {
            continuation.finish(throwing: error as? EngineUnavailability ?? .homeServerUnreachable("\(error)"))
            return
        }
        liveSocket = socket
        endSent = false
        let sender = Task {
            for await chunk in audio {
                if Task.isCancelled { return }
                try? await socket.send(data: HomeServer.pcm16(chunk))
            }
            try? await socket.send(text: HomeServer.end)
            self.markEndSent()
        }
        defer { sender.cancel() }

        // Stopping captions cancels this task, but a socket's receive
        // doesn't notice cancellation: without the close the connection
        // (and this loop) would stay open for as long as the server did.
        await withTaskCancellationHandler {
            await receive(from: socket, continuation: continuation)
        } onCancel: {
            Task { await socket.close() }
        }
    }

    private func receive(
        from socket: any HomeServerSocket,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) async {
        var ids: [Int: UUID] = [:]
        var shown: [Int: String] = [:]
        while true {
            let frame: String
            do {
                frame = try await socket.receive()
            } catch {
                liveSocket = nil
                await socket.close()
                if Task.isCancelled || endSent {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: EngineUnavailability.homeServerUnreachable("connection lost: \(error)"))
                }
                return
            }
            guard case .text(let number, let received, let isFinal, let confidence, let segments)? = HomeServerMessage(json: frame) else { continue }
            let id = ids[number] ?? UUID()
            ids[number] = id
            // The same checks the phone's own model gets: the names list
            // read back in a quiet moment, a TV sign-off, a "thanks" the
            // model barely heard. A server that sends no segments gets its
            // whole text checked as one, without Whisper's numbers.
            let text = filter.acceptedText(
                from: segments ?? [WhisperSegmentSummary(text: received, noSpeechProb: 0, avgLogprob: 0, compressionRatio: 1)],
                echo: echo
            )
            // A final pass that comes back empty (the model changed its
            // mind about a quiet tail) keeps what was already on screen.
            let words = text.isEmpty ? (shown[number] ?? "") : text
            if isFinal {
                ids[number] = nil
                shown[number] = nil
            } else {
                shown[number] = words
            }
            guard !words.isEmpty else { continue }
            continuation.yield(TranscriptToken(
                utteranceID: id,
                text: words,
                isFinal: isFinal,
                timestamp: Date().timeIntervalSince1970,
                confidence: confidence
            ))
        }
    }

    private func markEndSent() {
        endSent = true
    }

    // MARK: - Connecting

    private func destination() -> Result<(url: URL, token: String), EngineUnavailability> {
        guard let url = HomeServer.url(from: address) else {
            return .failure(.homeServerUnreachable("no valid server address"))
        }
        guard let token = token(), !token.isEmpty else {
            return .failure(.homeServerRejected("no pairing code"))
        }
        return .success((url, token))
    }

    /// Opens a connection, says hello and waits for the server's answer.
    /// A server that never answers is closed after `handshakeSeconds`, so
    /// a dead address doesn't leave captions waiting.
    private func handshake(_ target: (url: URL, token: String), languageCode: String) async throws -> any HomeServerSocket {
        let socket: any HomeServerSocket
        do {
            socket = try await connector.open(target.url)
        } catch {
            throw EngineUnavailability.homeServerUnreachable("could not connect: \(error)")
        }
        do {
            try await socket.send(text: HomeServer.hello(token: target.token, languageCode: languageCode, vocabulary: vocabulary))
            let reply = try await Self.firstReply(from: socket, within: handshakeSeconds)
            switch HomeServerMessage(json: reply) {
            case .ready?:
                return socket
            case .refused(let code, let detail)? where code == "unauthorized":
                throw EngineUnavailability.homeServerRejected("pairing code refused \(detail)")
            case .refused(let code, let detail)?:
                throw EngineUnavailability.homeServerUnreachable("server said \(code) \(detail)")
            default:
                throw EngineUnavailability.homeServerUnreachable("unexpected reply")
            }
        } catch {
            await socket.close()
            throw error as? EngineUnavailability ?? .homeServerUnreachable("\(error)")
        }
    }

    private static func firstReply(from socket: any HomeServerSocket, within seconds: Double) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                // Closing is what makes a receive that ignores
                // cancellation give up.
                await socket.close()
                throw EngineUnavailability.homeServerUnreachable("no answer within \(seconds) s")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw EngineUnavailability.homeServerUnreachable("no answer")
            }
            return first
        }
    }
}
