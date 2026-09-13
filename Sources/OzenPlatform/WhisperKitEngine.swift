import Foundation
import CoreML
// WhisperKit itself isn't audited/marked Sendable upstream, so under Swift
// 6's strict concurrency checking, constructing and storing it inside this
// actor is flagged even though it's actually used safely (never shared
// outside this actor). `@preconcurrency` is the standard, documented way
// to consume a dependency that hasn't done its own Sendable audit yet,
// rather than turning off strict concurrency for this file entirely.
@preconcurrency import WhisperKit
import OzenKit

/// Wraps Argmax's WhisperKit (open-source, on-device Whisper via CoreML)
/// for Hebrew-primary live transcription.
///
/// Shape of the streaming loop, and why: Whisper isn't a streaming model —
/// every pass re-decodes a whole (padded-to-30 s) window. So "live" here
/// means re-running the model on the current utterance's audio every
/// ~0.6 s of new speech and showing the latest hypothesis, then running
/// one last, more careful pass when a pause ends the utterance. Audio
/// intake and inference are separate loops on purpose: intake just
/// appends to a buffer and can never fall behind, while inference always
/// works on the *latest* snapshot — if a pass takes longer than 0.6 s the
/// next one simply covers more audio, instead of a queue of stale passes
/// building up and the captions drifting further and further behind.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let kind: TranscriptionEngineKind = .whisperKit

    private let modelVariant: String
    private let filter: WhisperResultFilter
    private let store: WhisperModelStore
    private var pipe: WhisperKit?
    private var vocabulary: [String] = []
    /// Token ids for the current vocabulary prompt, recomputed only when
    /// the list changes (encoding is cheap but runs every pass otherwise).
    private var promptCache: (terms: [String], tokens: [Int])?
    /// Rebuilt with the vocabulary; catches the prompt coming back as a
    /// caption on a quiet window.
    private var echoDetector: PromptEchoDetector?
    /// Whisper's prompt budget is half its 448-token context; stay well
    /// under so the audio's own tokens never get squeezed.
    private let maxPromptTokens = 120

    // How often the live preview re-runs is decided per pass by
    // `InferenceCadence` (0.6 s on a cool phone, slower when hot, in Low
    // Power Mode, or when the last pass was itself slow).
    /// A gap this long with no speech ends the current utterance.
    private let pauseSeconds = 1.0
    /// Audio kept after the last detected speech when finalizing, so a
    /// trailing soft consonant isn't clipped.
    private let trailingPadSeconds = 0.3
    /// Audio kept while waiting in silence, so the first syllable of the
    /// next sentence is already in the buffer when speech is detected.
    private let leadingKeepSeconds = 0.5
    /// Whisper's window is 30 s; finalize before that so the model never
    /// sees a truncated utterance.
    private let maxUtteranceSeconds = 28.0
    private let sampleRate = 16_000.0

    public init(
        modelVariant: String = WhisperModelCatalog.defaultVariant,
        filter: WhisperResultFilter = WhisperResultFilter(),
        store: WhisperModelStore = WhisperModelStore()
    ) {
        self.modelVariant = modelVariant
        self.filter = filter
        self.store = store
    }

    // MARK: - TranscriptionEngine

    public func setVocabulary(_ terms: [String]) async {
        vocabulary = terms
        let detector = PromptEchoDetector(terms: terms)
        echoDetector = detector.isEmpty ? nil : detector
    }

    public func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability {
        if pipe != nil { return .available }

        let variant = modelVariant
        let downloadAndReport: @Sendable () async throws -> URL = { [store] in
            progress(EnginePreparationProgress(stage: .downloadingModel, fraction: 0, detail: variant))
            return try await store.download(variant: variant) { fraction in
                progress(EnginePreparationProgress(stage: .downloadingModel, fraction: fraction, detail: variant))
            }
        }

        var folder: URL
        var fetchedThisTime = false
        if let installed = store.installedFolder(for: modelVariant) {
            folder = installed
        } else {
            do {
                folder = try await downloadAndReport()
                fetchedThisTime = true
            } catch {
                return .unavailable(.modelDownloadFailed, "\(modelVariant): \(error)")
            }
        }

        progress(EnginePreparationProgress(stage: .loadingModel, detail: modelVariant))
        do {
            let loaded: WhisperKit
            do {
                loaded = try await load(folder: folder)
            } catch {
                // A folder no download ever vouched for may be a cut-off
                // download that happened to pass the file checks. Ask the
                // hub for whatever is missing (it skips what's there) and
                // try once more before calling the model broken.
                guard !fetchedThisTime, store.state(of: variant) == .unverified else { throw error }
                do {
                    folder = try await downloadAndReport()
                } catch let downloadError {
                    return .unavailable(.modelDownloadFailed, "\(variant): load failed (\(error)); repair download failed: \(downloadError)")
                }
                progress(EnginePreparationProgress(stage: .loadingModel, detail: variant))
                loaded = try await load(folder: folder)
            }
            store.markComplete(variant: variant)

            // One throwaway pass over a second of silence: CoreML pays its
            // first-run specialization cost here rather than on the first
            // real sentence somebody says.
            progress(EnginePreparationProgress(stage: .warmingUp, detail: modelVariant))
            let warmup: [TranscriptionResult]? = try? await loaded.transcribe(
                audioArray: [Float](repeating: 0, count: Int(sampleRate)),
                decodeOptions: liveOptions(languageCode: languageCode)
            )
            _ = warmup

            pipe = loaded
            return .available
        } catch {
            // The tokenizer is fetched from the internet on the very first
            // load. Offline at that moment is a connection problem, and
            // saying "model broken" would send the user the wrong way.
            if !store.hasCachedTokenizer() {
                return .unavailable(.modelDownloadFailed, "\(modelVariant): first load needs the internet once to fetch the tokenizer: \(error)")
            }
            return .unavailable(.modelLoadFailed, "\(modelVariant): \(error)")
        }
    }

    private func load(folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: store.tokenizerBase,
            // Captions keep running with the phone locked or in a pocket
            // (that's when the doorbell notification matters), and iOS
            // doesn't let a background app submit GPU work. WhisperKit
            // puts the mel spectrogram on the GPU by default; it's a small
            // calculation, so it runs on the CPU and nothing in a pass
            // needs the GPU. The encoder and decoder stay on the Neural
            // Engine.
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly),
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    public nonisolated func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStreaming(languageCode: languageCode, audio: audio, continuation: continuation)
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

    // MARK: - Streaming

    private func runStreaming(
        languageCode: String,
        audio: AsyncStream<[Float]>,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) async throws {
        guard let pipe else { throw EngineError.notPrepared }

        let intake = AudioIntake()
        let intakeTask = Task {
            for await chunk in audio {
                if Task.isCancelled { break }
                intake.append(chunk)
            }
            intake.markFinished()
        }
        defer { intakeTask.cancel() }

        let livePass = liveOptions(languageCode: languageCode)
        let finalPass = finalOptions(languageCode: languageCode)
        let pauseSamples = Int(pauseSeconds * sampleRate)
        let padSamples = Int(trailingPadSeconds * sampleRate)
        let keepSamples = Int(leadingKeepSeconds * sampleRate)
        let maxSamples = Int(maxUtteranceSeconds * sampleRate)
        var lastLivePassSeconds: Double?

        var utteranceID = UUID()
        var samplesAtLastPass = 0
        var lastShownText = ""

        while true {
            try Task.checkCancellation()
            let snapshot = intake.snapshot()
            let total = snapshot.samples.count

            guard let speechEnd = snapshot.lastSpeechEnd else {
                // Nothing but silence so far: don't run the model at all
                // (that's where hallucinations come from), just keep a
                // little lead-in audio and wait.
                if total > keepSamples {
                    intake.drop(prefix: total - keepSamples)
                }
                if snapshot.finished { break }
                try await Task.sleep(for: .milliseconds(80))
                continue
            }

            let pauseReached = total - speechEnd >= pauseSamples
            let tooLong = total >= maxSamples
            let isFinal = pauseReached || tooLong || snapshot.finished
            let interval = InferenceCadence.secondsBetweenLivePasses(
                heat: Self.currentHeat(),
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                lastPassSeconds: lastLivePassSeconds
            )
            let enoughNewAudio = total - samplesAtLastPass >= Int(interval * sampleRate)
            if !isFinal && !enoughNewAudio {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }

            let end = isFinal ? min(total, speechEnd + padSamples) : total
            let window = Array(snapshot.samples[0..<end])
            samplesAtLastPass = total

            var options = isFinal ? finalPass : livePass
            options.promptTokens = promptTokens(using: pipe)
            let passStarted = ContinuousClock.now
            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: window,
                decodeOptions: options
            )
            if !isFinal {
                // Only live passes: a final pass may retry at higher
                // temperatures and would overstate how slow the phone is.
                let elapsed = ContinuousClock.now - passStarted
                lastLivePassSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }
            let segments = results.flatMap(\.segments)
            let text = filter.acceptedText(from: segments.map {
                WhisperSegmentSummary(
                    text: $0.text,
                    noSpeechProb: $0.noSpeechProb,
                    avgLogprob: $0.avgLogprob,
                    compressionRatio: $0.compressionRatio
                )
            }, echo: echoDetector)
            let confidence = Self.confidence(from: segments.map(\.avgLogprob))

            // A final pass that comes back empty (the pad was silence and
            // the model changed its mind) must not erase what was shown.
            let shown = text.isEmpty ? lastShownText : text
            if !shown.isEmpty {
                continuation.yield(TranscriptToken(
                    utteranceID: utteranceID,
                    text: shown,
                    isFinal: isFinal,
                    timestamp: Date().timeIntervalSince1970,
                    confidence: confidence
                ))
                lastShownText = shown
            }

            if isFinal {
                intake.drop(prefix: end)
                utteranceID = UUID()
                samplesAtLastPass = 0
                lastShownText = ""
                if snapshot.finished && total - end == 0 { break }
            }
        }
    }

    private static func currentHeat() -> DeviceHeat {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    // MARK: - Vocabulary prompt

    /// Encodes the names list the way WhisperKit's own CLI does for
    /// `--prompt`: a leading space, special tokens stripped, trimmed to
    /// the budget from the end (the list is ordered most-important-first).
    private func promptTokens(using pipe: WhisperKit) -> [Int]? {
        guard !vocabulary.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        if let cached = promptCache, cached.terms == vocabulary {
            return cached.tokens
        }
        let text = VocabularyHints.whisperPrompt(vocabulary)
        guard !text.isEmpty else { return nil }
        let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
        let tokens = Array(
            tokenizer.encode(text: " " + text)
                .filter { $0 < specialTokenBegin }
                .prefix(maxPromptTokens)
        )
        promptCache = (vocabulary, tokens)
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Decoding options

    /// Fast settings for the in-progress hypothesis: greedy, no
    /// temperature fallbacks (each fallback is a whole extra decode).
    private nonisolated func liveOptions(languageCode: String) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.none
        )
    }

    /// The once-per-utterance pass can afford a couple of retries at
    /// higher temperature when the greedy decode looks degenerate.
    private nonisolated func finalOptions(languageCode: String) -> DecodingOptions {
        var options = liveOptions(languageCode: languageCode)
        options.temperatureFallbackCount = 2
        return options
    }

    /// Whisper reports mean token log-probability; e^x of that is a
    /// reasonable 0…1 confidence for the UI.
    private static func confidence(from logprobs: [Float]) -> Float? {
        guard !logprobs.isEmpty else { return nil }
        let mean = logprobs.reduce(0, +) / Float(logprobs.count)
        return min(max(exp(mean), 0), 1)
    }

    enum EngineError: Error {
        case notPrepared
    }
}

/// The intake buffer shared between the audio loop and the inference loop.
/// Locked rather than actor-isolated so the audio loop never has to wait
/// for the actor while a long inference pass is in flight.
private final class AudioIntake: @unchecked Sendable {
    struct Snapshot {
        var samples: [Float]
        /// Index just past the last chunk classified as speech, if any.
        var lastSpeechEnd: Int?
        var finished: Bool
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastSpeechEnd: Int?
    private var finished = false
    private var detector = EnergyVoiceDetector()

    func append(_ chunk: [Float]) {
        lock.withLock {
            samples.append(contentsOf: chunk)
            if detector.isSpeech(chunk) {
                lastSpeechEnd = samples.count
            }
        }
    }

    func markFinished() {
        lock.withLock { finished = true }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(samples: samples, lastSpeechEnd: lastSpeechEnd, finished: finished)
        }
    }

    func drop(prefix count: Int) {
        lock.withLock {
            let dropped = min(count, samples.count)
            samples.removeFirst(dropped)
            if let end = lastSpeechEnd {
                lastSpeechEnd = end > dropped ? end - dropped : nil
            }
        }
    }
}
