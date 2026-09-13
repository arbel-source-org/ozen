import Foundation
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

    /// Re-run the model at most this often per utterance — often enough to
    /// feel live, not so often that inference dominates the CPU.
    private let minSecondsBetweenPasses = 0.6
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

    public func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability {
        if pipe != nil { return .available }

        let folder: URL
        if let installed = store.installedFolder(for: modelVariant) {
            folder = installed
        } else {
            progress(EnginePreparationProgress(stage: .downloadingModel, fraction: 0, detail: modelVariant))
            do {
                let variant = modelVariant
                folder = try await store.download(variant: variant) { fraction in
                    progress(EnginePreparationProgress(stage: .downloadingModel, fraction: fraction, detail: variant))
                }
            } catch {
                return .unavailable(.modelDownloadFailed, "\(modelVariant): \(error)")
            }
        }

        progress(EnginePreparationProgress(stage: .loadingModel, detail: modelVariant))
        do {
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            )
            let loaded = try await WhisperKit(config)

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
            return .unavailable(.modelLoadFailed, "\(modelVariant): \(error)")
        }
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
        let minNewSamples = Int(minSecondsBetweenPasses * sampleRate)

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
            let enoughNewAudio = total - samplesAtLastPass >= minNewSamples
            if !isFinal && !enoughNewAudio {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }

            let end = isFinal ? min(total, speechEnd + padSamples) : total
            let window = Array(snapshot.samples[0..<end])
            samplesAtLastPass = total

            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: window,
                decodeOptions: isFinal ? finalPass : livePass
            )
            let segments = results.flatMap(\.segments)
            let text = filter.acceptedText(from: segments.map {
                WhisperSegmentSummary(
                    text: $0.text,
                    noSpeechProb: $0.noSpeechProb,
                    avgLogprob: $0.avgLogprob,
                    compressionRatio: $0.compressionRatio
                )
            })
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
