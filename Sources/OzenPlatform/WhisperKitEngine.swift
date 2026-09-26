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
/// works on the *latest* audio — if a pass takes longer than 0.6 s the
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
    ///
    /// It was 1.0 s. People answering each other leave shorter gaps than
    /// that, so a whole exchange ran into one line: 764 turns of Hebrew
    /// broadcast conversation became 139 lines, several voices in each,
    /// and 10.0% of the words came out wrong against 8.4% with every turn
    /// on its own. At 0.7 s it was 365 lines and 8.9%, and 51.6 min of
    /// lectures stayed where they were (13.6% -> 13.3%, 326 lines for 368
    /// sentences). Shorter still started cutting sentences in half: at
    /// 0.5 s the lectures got worse (14.2%, 494 lines).
    private let pauseSeconds = 0.7
    /// Audio kept after the last detected speech when finalizing, so a
    /// trailing soft consonant isn't clipped.
    private let trailingPadSeconds = 0.3
    /// Audio kept while waiting in silence, so the first syllable of the
    /// next sentence is already in the buffer when speech is detected.
    private let leadingKeepSeconds = 0.5
    /// Whisper's window is 30 s; finalize before that so the model never
    /// sees a truncated utterance.
    private let maxUtteranceSeconds = 28.0
    /// How far back from the end a line that ran too long looks for a
    /// quiet moment to be cut at (`UtteranceCut`), and the stretch it
    /// measures at a time.
    private let longCutLookBackSeconds = 2.0
    private let longCutFrameSeconds = 0.05
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

    /// What is left to download when the model isn't fully on the phone
    /// yet. The hub keeps every file a cut-off download finished and skips
    /// those next time, so what's already on disk is subtracted (never
    /// below 1, which would read as "size unknown"). 0 means a model the
    /// catalog doesn't know the size of.
    public func pendingDownloadMegabytes() async -> Int? {
        if pipe != nil { return nil }
        guard store.installedFolder(for: modelVariant) == nil else { return nil }
        guard let total = WhisperModelCatalog.option(for: modelVariant)?.sizeMB else { return 0 }
        let onDiskMegabytes = Int(store.sizeOnDisk(of: modelVariant) / 1_048_576)
        return max(total - onDiskMegabytes, 1)
    }

    public func pendingInstallMegabytes() async -> Int? {
        guard let download = await pendingDownloadMegabytes() else { return nil }
        guard let option = WhisperModelCatalog.option(for: modelVariant) else { return download }
        return download + (option.installMegabytes - option.sizeMB)
    }

    /// A full disk, with how much room to free when that can be worked out.
    private static func outOfSpace(variant: String, error: any Error) -> EngineAvailability {
        let option = WhisperModelCatalog.option(for: variant)
        let size = option?.sizeMB
        let missing = option.flatMap { StorageSpaceGate.shortfallMegabytes(downloadMegabytes: $0.installMegabytes, availableBytes: DeviceStorage.availableBytes()) }
        return .unavailable(EngineUnavailability(
            kind: .notEnoughStorage,
            detail: "\(variant): disk full: \(error)",
            downloadMegabytes: size,
            missingMegabytes: missing
        ))
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
                if StorageSpaceGate.isOutOfSpace(error) {
                    return Self.outOfSpace(variant: modelVariant, error: error)
                }
                return .unavailable(.modelDownloadFailed, "\(modelVariant): \(error)")
            }
        }

        let firstTime = !store.hasLoadedBefore(variant: variant)
        progress(EnginePreparationProgress(stage: .loadingModel, detail: modelVariant, isFirstTime: firstTime))
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
                    if StorageSpaceGate.isOutOfSpace(downloadError) {
                        return Self.outOfSpace(variant: variant, error: downloadError)
                    }
                    return .unavailable(.modelDownloadFailed, "\(variant): load failed (\(error)); repair download failed: \(downloadError)")
                }
                progress(EnginePreparationProgress(stage: .loadingModel, detail: variant, isFirstTime: firstTime))
                loaded = try await load(folder: folder)
            }
            store.markComplete(variant: variant)
            store.markLoaded(variant: variant)

            // One throwaway pass over a second of silence: CoreML pays its
            // first-run specialization cost here rather than on the first
            // real sentence somebody says.
            progress(EnginePreparationProgress(stage: .warmingUp, detail: modelVariant, isFirstTime: firstTime))
            let warmup: [TranscriptionResult]? = try? await loaded.transcribe(
                audioArray: [Float](repeating: 0, count: Int(sampleRate)),
                decodeOptions: liveOptions(languageCode: languageCode)
            )
            _ = warmup

            pipe = loaded
            return .available
        } catch {
            // Compiling the model for this phone's chip on first load
            // writes a cache; a full disk there is not a broken model.
            if StorageSpaceGate.isOutOfSpace(error) {
                return Self.outOfSpace(variant: modelVariant, error: error)
            }
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
                await self.beginStreaming()
                do {
                    try await self.runStreaming(languageCode: languageCode, audio: audio, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self.endStreaming()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether a stream is using `pipe`, and the streams waiting for it.
    ///
    /// WhisperKit keeps decoder state on the instance, so two passes must
    /// never run on it at once. Without this they could: the pipeline
    /// cancels a stream on pause, restart or recovery without waiting for it
    /// to end, a cancelled stream can still be inside `transcribe` (a pass
    /// doesn't stop part way), and an actor lets the next stream in while
    /// that call is suspended. The next stream now waits, at most one pass.
    /// How the passes have gone since the engine was made, for the journal.
    private var tally = PassTally()

    public func diagnosticsSummary() async -> String? {
        "\(modelVariant): \(tally.summary)"
    }

    private var isStreaming = false
    private var streamWaiters: [CheckedContinuation<Void, Never>] = []

    private func beginStreaming() async {
        guard isStreaming else {
            isStreaming = true
            return
        }
        await withCheckedContinuation { streamWaiters.append($0) }
    }

    /// Hands `pipe` straight to the next waiting stream, if there is one.
    private func endStreaming() {
        if streamWaiters.isEmpty {
            isStreaming = false
        } else {
            streamWaiters.removeFirst().resume()
        }
    }

    // MARK: - Streaming

    private func runStreaming(
        languageCode: String,
        audio: AsyncStream<[Float]>,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) async throws {
        guard let pipe else { throw EngineError.notPrepared }

        let intake = AudioIntake(voiceScorer: SileroVoiceScorer())
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
        let longCutLookBack = Int(longCutLookBackSeconds * sampleRate)
        let longCutFrame = Int(longCutFrameSeconds * sampleRate)
        var lastLivePassSeconds: Double?

        var utteranceID = UUID()
        var samplesAtLastPass = 0
        var lastShownText = ""
        var lastShownConfidence: Float?

        while true {
            try Task.checkCancellation()
            // The counts only: most turns just wait for more audio, and
            // copying up to 28 seconds of it twenty times a second to find
            // that out cost battery all through a conversation.
            let status = intake.status()
            let total = status.count

            guard let speechEnd = status.lastSpeechEnd else {
                // Nothing but silence so far: don't run the model at all
                // (that's where hallucinations come from), just keep a
                // little lead-in audio and wait.
                if total > keepSamples {
                    intake.drop(prefix: total - keepSamples)
                }
                if status.finished { break }
                try await Task.sleep(for: .milliseconds(80))
                continue
            }

            let pauseReached = total - speechEnd >= pauseSamples
            let tooLong = total >= maxSamples
            let isFinal = pauseReached || tooLong || status.finished
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

            // Only this loop drops audio from the front, so the first
            // `total` samples are still the ones the counts described.
            let window: [Float]
            if !isFinal {
                window = intake.copySamples(upTo: total)
            } else if tooLong && !pauseReached && !status.finished {
                // Still talking at the cap: end the line in the quietest
                // moment of the last two seconds rather than mid-word. What
                // comes after it is kept and starts the next line.
                let heard = intake.copySamples(upTo: min(total, speechEnd + padSamples))
                let cut = UtteranceCut.quietestPoint(
                    in: heard,
                    before: heard.count,
                    lookBack: longCutLookBack,
                    frame: longCutFrame
                )
                window = Array(heard[0..<cut])
            } else {
                window = intake.copySamples(upTo: min(total, speechEnd + padSamples))
            }
            let end = window.count
            samplesAtLastPass = total

            // Kitchen clatter and a running tap pass the energy detector
            // and come back from Whisper as confident Hebrew. A stretch in
            // which the voice model heard no voice at all never reaches
            // Whisper; a line already on screen is always finished. So is
            // the last one when captions stop: its final quarter-second
            // may not have been scored yet.
            if !status.finished && intake.hasVoice(upTo: end) == false && lastShownText.isEmpty {
                tally.recordSkippedWithoutVoice()
                if isFinal {
                    intake.drop(prefix: end)
                    utteranceID = UUID()
                    samplesAtLastPass = 0
                    lastLivePassSeconds = nil
                }
                continue
            }

            var options = isFinal ? finalPass : livePass
            options.promptTokens = promptTokens(using: pipe)
            let passStarted = ContinuousClock.now
            let results: [TranscriptionResult]
            do {
                results = try await pipe.transcribe(audioArray: window, decodeOptions: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One pass failing (the Neural Engine busy, memory tight for
                // a moment) used to end the stream: the pipeline restarted
                // the engine and the sentence being spoken was lost with the
                // buffer. The same window gets one more try first.
                try await Task.sleep(for: .milliseconds(250))
                results = try await pipe.transcribe(audioArray: window, decodeOptions: options)
            }
            if !isFinal {
                // Only live passes: a final pass may retry at higher
                // temperatures and would overstate how slow the phone is.
                let elapsed = ContinuousClock.now - passStarted
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                lastLivePassSeconds = seconds
                tally.recordLivePass(seconds: seconds)
            }
            // Only on the pass that stays: a line still being written
            // changes its mind about words as well as about itself.
            let wordTokenizer = isFinal ? pipe.tokenizer : nil
            let summaries = results.flatMap(\.segments).map {
                WhisperSegmentSummary(
                    text: $0.text,
                    noSpeechProb: $0.noSpeechProb,
                    avgLogprob: $0.avgLogprob,
                    compressionRatio: $0.compressionRatio,
                    uncertainWords: Self.uncertainWords(in: $0, tokenizer: wordTokenizer)
                )
            }
            // Confidence has to describe exactly the text being shown, not
            // the whole pass -- a rejected hallucination segment can have a
            // confident logprob of its own and skew the mean either way for
            // content that never reaches the screen.
            let acceptedSegments = filter.accepted(from: summaries, echo: echoDetector)
            let text = filter.acceptedText(from: summaries, echo: echoDetector)
            let confidence = Self.confidence(from: acceptedSegments.map(\.avgLogprob))
            tally.recordSegments(seen: summaries.count, accepted: acceptedSegments.count)
            if isFinal { tally.recordFinalPass(cameBackEmpty: text.isEmpty) }

            // A final pass that comes back empty (the pad was silence and
            // the model changed its mind) must not erase what was shown --
            // and its confidence describes that unrelated, rejected pass,
            // not the text now being shown again, so it falls back too.
            let shown = text.isEmpty ? lastShownText : text
            let shownConfidence = text.isEmpty ? lastShownConfidence : confidence
            if !shown.isEmpty {
                continuation.yield(TranscriptToken(
                    utteranceID: utteranceID,
                    text: shown,
                    isFinal: isFinal,
                    timestamp: Date().timeIntervalSince1970,
                    confidence: shownConfidence,
                    uncertainWords: text.isEmpty ? [] : acceptedSegments.flatMap(\.uncertainWords)
                ))
                lastShownText = shown
                lastShownConfidence = shownConfidence
            }

            if isFinal {
                intake.drop(prefix: end)
                utteranceID = UUID()
                samplesAtLastPass = 0
                lastShownText = ""
                lastShownConfidence = nil
                // How long a pass over the finished line took says little
                // about the next, shorter one; its first preview shouldn't
                // wait on it.
                lastLivePassSeconds = nil
                if status.finished && total - end == 0 { break }
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

    /// The words of `segment` the model was least sure of. Special tokens
    /// (timestamps, the language tag) aren't words and are left out, with
    /// their scores, before the tokenizer puts pieces back into words.
    private static func uncertainWords(in segment: TranscriptionSegment, tokenizer: (any WhisperTokenizer)?) -> [String] {
        guard let tokenizer else { return [] }
        let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
        var tokens: [Int] = []
        var logprobs: [Float] = []
        for (token, scores) in zip(segment.tokens, segment.tokenLogProbs) where token < specialTokenBegin {
            guard let logprob = scores[token] else { continue }
            tokens.append(token)
            logprobs.append(logprob)
        }
        guard !tokens.isEmpty else { return [] }
        let split = tokenizer.splitToWordTokens(tokenIds: tokens)
        var next = 0
        var perWord: [[Float]] = []
        for wordTokens in split.wordTokens {
            let end = min(next + wordTokens.count, logprobs.count)
            perWord.append(next < end ? Array(logprobs[next..<end]) : [])
            next = end
        }
        return UncertainWords.pick(words: split.words, logprobs: perWord)
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
    struct Status {
        var count: Int
        /// Index just past the last chunk classified as speech, if any.
        var lastSpeechEnd: Int?
        var finished: Bool
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastSpeechEnd: Int?
    private var finished = false
    private var detector = EnergyVoiceDetector()
    /// Nil when the voice model isn't there or didn't load: then every
    /// line goes to Whisper, as before (see `VoiceEvidence`).
    private var evidence: VoiceEvidence?

    init(voiceScorer: SileroVoiceScorer?) {
        evidence = voiceScorer.map { scorer in VoiceEvidence(score: scorer.score) }
    }

    func append(_ chunk: [Float]) {
        lock.withLock {
            samples.append(contentsOf: chunk)
            if detector.isSpeech(chunk) {
                lastSpeechEnd = samples.count
            }
            evidence?.append(chunk)
        }
    }

    /// Whether the first `end` samples had a voice in them; nil when
    /// that isn't known.
    func hasVoice(upTo end: Int) -> Bool? {
        lock.withLock { evidence?.hasVoice(inFirst: end) }
    }

    func markFinished() {
        lock.withLock { finished = true }
    }

    func status() -> Status {
        lock.withLock {
            Status(count: samples.count, lastSpeechEnd: lastSpeechEnd, finished: finished)
        }
    }

    /// A copy of the first `end` samples.
    func copySamples(upTo end: Int) -> [Float] {
        lock.withLock {
            Array(samples[0..<min(max(end, 0), samples.count)])
        }
    }

    func drop(prefix count: Int) {
        lock.withLock {
            let dropped = min(count, samples.count)
            samples.removeFirst(dropped)
            evidence?.drop(prefix: dropped)
            if let end = lastSpeechEnd {
                lastSpeechEnd = end > dropped ? end - dropped : nil
            }
        }
    }
}
