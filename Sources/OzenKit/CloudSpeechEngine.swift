import Foundation

/// Live captions from a model on the internet (see `CloudSpeech`), in the
/// same rhythm as the Whisper engine: a short silence ends a line, and a
/// line never runs past 28 seconds.
///
/// While someone is still talking, the sentence so far goes out again
/// every couple of seconds so words appear as they are said; the request
/// after the pause is the one that stays. A live request that fails on a
/// weak connection is simply skipped, a final one gets a second try, and
/// what was already on screen is kept rather than lost. A key problem, or
/// several failures in a row, end the stream so the screen can say why.
public actor CloudSpeechEngine: TranscriptionEngine {
    public nonisolated let kind: TranscriptionEngineKind = .cloud

    public static let sampleRate = 16_000
    public static let pauseSeconds = 0.8
    public static let livePassSeconds = 2.0
    public static let maxUtteranceSeconds = 28.0
    public static let failuresBeforeStopping = 4
    static let trailingPadSeconds = 0.3
    static let leadingKeepSeconds = 0.5
    static let longCutLookBackSeconds = 2.0
    static let longCutFrameSeconds = 0.05

    public nonisolated let model: String
    private let http: any CloudHTTP
    private let apiKey: @Sendable () -> String?
    private let filter: WhisperResultFilter
    private var vocabulary: [String] = []
    private var echo: PromptEchoDetector?
    /// The key the last check approved, so a restart doesn't ask again.
    private var approvedKey: String?

    public init(
        model: String = CloudSpeech.accurateModel,
        http: any CloudHTTP = URLSessionCloudHTTP(),
        filter: WhisperResultFilter = WhisperResultFilter(),
        apiKey: @escaping @Sendable () -> String?
    ) {
        self.model = model
        self.http = http
        self.filter = filter
        self.apiKey = apiKey
    }

    public func setVocabulary(_ terms: [String]) async {
        vocabulary = terms
        let detector = PromptEchoDetector(terms: terms)
        echo = detector.isEmpty ? nil : detector
    }

    public func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability {
        progress(EnginePreparationProgress(stage: .checkingSupport))
        guard let key = currentKey() else {
            return .unavailable(CloudSpeechError.keyMissing.unavailability)
        }
        if approvedKey == key { return .available }
        let response: CloudHTTPResponse
        do {
            response = try await http.send(CloudSpeech.keyCheckRequest(apiKey: key))
        } catch {
            return .unavailable(CloudSpeechError.offline.unavailability)
        }
        guard (200..<300).contains(response.status) else {
            return .unavailable(CloudSpeech.failure(from: response).unavailability)
        }
        guard CloudSpeech.hasCreditLeft(keyCheck: response) else {
            return .unavailable(CloudSpeechError.outOfCredit.unavailability)
        }
        approvedKey = key
        return .available
    }

    public nonisolated func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(languageCode: languageCode, audio: audio, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func currentKey() -> String? {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    private func run(
        languageCode: String,
        audio: AsyncStream<[Float]>,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) async throws {
        guard let key = currentKey() else { throw CloudSpeechError.keyMissing }
        let intake = SpeechIntake()
        let intakeTask = Task {
            for await chunk in audio {
                if Task.isCancelled { break }
                intake.append(chunk)
            }
            intake.markFinished()
        }
        defer { intakeTask.cancel() }

        let rate = Double(Self.sampleRate)
        let pauseSamples = Int(Self.pauseSeconds * rate)
        let padSamples = Int(Self.trailingPadSeconds * rate)
        let keepSamples = Int(Self.leadingKeepSeconds * rate)
        let maxSamples = Int(Self.maxUtteranceSeconds * rate)
        var utteranceID = UUID()
        var samplesAtLastPass = 0
        var lastShownText = ""
        var lastLivePassSeconds = 0.0
        var failuresInARow = 0

        while true {
            try Task.checkCancellation()
            let status = intake.status()
            let total = status.count
            guard let speechEnd = status.lastSpeechEnd else {
                // Nothing said yet: no request at all, since silence is
                // where models invent words, and silence costs money too.
                if total > keepSamples {
                    intake.drop(prefix: total - keepSamples)
                }
                if status.finished { break }
                try await Task.sleep(for: .milliseconds(80))
                continue
            }

            // Silence ahead of the first word is never sent. It piles up
            // while a request is out, and would be paid for and risk
            // invented words.
            if let start = status.firstSpeechStart, start > keepSamples {
                intake.drop(prefix: start - keepSamples)
                continue
            }

            let pauseReached = total - speechEnd >= pauseSamples
            let tooLong = total >= maxSamples
            let isFinal = pauseReached || tooLong || status.finished
            // Never more often than a request takes, or they would pile up
            // behind each other on a slow connection.
            let liveSamples = Int(max(Self.livePassSeconds, lastLivePassSeconds) * rate)
            if !isFinal && total - samplesAtLastPass < liveSamples {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }

            let window: [Float]
            if !isFinal {
                window = intake.copySamples(upTo: total)
            } else if tooLong && !pauseReached && !status.finished {
                let heard = intake.copySamples(upTo: min(total, speechEnd + padSamples))
                let cut = UtteranceCut.quietestPoint(
                    in: heard,
                    before: heard.count,
                    lookBack: Int(Self.longCutLookBackSeconds * rate),
                    frame: Int(Self.longCutFrameSeconds * rate)
                )
                window = Array(heard[0..<cut])
            } else {
                window = intake.copySamples(upTo: min(total, speechEnd + padSamples))
            }
            let end = window.count
            samplesAtLastPass = total

            var turns: [String]?
            var lastFailure: CloudSpeechError?
            let started = ContinuousClock.now
            for attempt in 1...(isFinal ? 2 : 1) {
                do {
                    turns = try await transcribe(window, key: key, languageCode: languageCode)
                    lastFailure = nil
                    break
                } catch let error as CloudSpeechError {
                    if error.needsPerson {
                        approvedKey = nil
                        throw error
                    }
                    lastFailure = error
                    if attempt == 1 && isFinal {
                        try await Task.sleep(for: .milliseconds(400))
                    }
                }
            }
            // One failed segment is one failure regardless of how many
            // attempts it took to give up on it -- a final segment's own
            // second try isn't a second, unrelated failure.
            if let lastFailure {
                failuresInARow += 1
                if failuresInARow >= Self.failuresBeforeStopping { throw lastFailure }
            } else {
                failuresInARow = 0
            }
            if !isFinal {
                let elapsed = ContinuousClock.now - started
                lastLivePassSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }

            let timestamp = Date().timeIntervalSince1970
            if !isFinal {
                let text = (turns ?? []).joined(separator: " ")
                if !text.isEmpty {
                    continuation.yield(TranscriptToken(utteranceID: utteranceID, text: text, isFinal: false, timestamp: timestamp))
                    lastShownText = text
                }
            } else {
                // A final request that failed, or came back empty, must not
                // take away what was already on screen.
                let finalTurns = turns.flatMap { $0.isEmpty ? nil : $0 } ?? (lastShownText.isEmpty ? [] : [lastShownText])
                if turns == nil, lastShownText.isEmpty {
                    // The request itself failed (as opposed to succeeding
                    // with nothing to say) and there's no earlier live
                    // preview to fall back to. Dropping the intake here
                    // would lose these words outright with no trace of a
                    // failure; retrying with the same audio, bounded by the
                    // failuresInARow check above, is the only way not to.
                    continue
                }
                for (index, turn) in finalTurns.enumerated() {
                    continuation.yield(TranscriptToken(
                        utteranceID: index == 0 ? utteranceID : UUID(),
                        text: turn,
                        isFinal: true,
                        timestamp: timestamp,
                        startsNewSpeakerTurn: index > 0
                    ))
                }
                intake.drop(prefix: end)
                utteranceID = UUID()
                samplesAtLastPass = 0
                lastShownText = ""
                lastLivePassSeconds = 0
                if status.finished && total - end == 0 { break }
            }
        }
    }

    private func transcribe(_ window: [Float], key: String, languageCode: String) async throws -> [String] {
        let request = CloudSpeech.completionRequest(
            model: model,
            apiKey: key,
            // Measurement mode hands speech from across a room over at
            // -45 to -60 dBFS, where a 16-bit file keeps only a few bits
            // of it.
            wav: WAVFile.pcm16(SpeechGain.normalized(window), sampleRate: Self.sampleRate),
            languageCode: languageCode,
            vocabulary: vocabulary
        )
        let response: CloudHTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CloudSpeechError.offline
        }
        let echo = self.echo
        return CloudSpeech.turns(in: try CloudSpeech.transcript(from: response), filter: filter)
            .filter { !(echo?.isEcho($0) ?? false) }
    }
}
