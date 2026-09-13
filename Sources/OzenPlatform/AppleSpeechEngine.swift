import Foundation
import Speech
import AVFoundation
import OzenKit

/// Wraps `SFSpeechRecognizer`, locked to on-device recognition unless the
/// user explicitly opted into Apple's server-based fallback in Settings.
/// Refuses to make that choice silently: doing so would break the
/// on-device-only requirement (privacy, works with no signal, lowest
/// latency) without anyone noticing.
///
/// Apple's recognizer works in *requests*, each of which ends with exactly
/// one final result — the first build's stream simply ended there, so it
/// captioned one sentence and went quiet. `RecognitionSession` below rolls
/// requests over continuously: it ends the current request at a natural
/// pause (or after 45 s), which produces the final result for that
/// utterance, and immediately opens the next request for whatever comes
/// after, so the stream lives as long as the audio does.
public final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public let kind: TranscriptionEngineKind = .appleSpeech

    private let allowServerFallback: Bool

    public init(allowServerFallback: Bool = false) {
        self.allowServerFallback = allowServerFallback
    }

    public func prepare(
        languageCode: String,
        progress: @escaping @Sendable (EnginePreparationProgress) -> Void
    ) async -> EngineAvailability {
        progress(EnginePreparationProgress(stage: .checkingSupport, detail: "SFSpeechRecognizer"))
        let locale = Locale(identifier: Self.localeIdentifier(for: languageCode))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailable(.languageNotSupportedOnDevice, "No speech recognizer exists for \(locale.identifier) on this iOS version")
        }
        if !recognizer.supportsOnDeviceRecognition && !allowServerFallback {
            return .unavailable(
                .languageNotSupportedOnDevice,
                "On-device recognition isn't available for \(locale.identifier) on this device/OS version; server fallback is off"
            )
        }

        progress(EnginePreparationProgress(stage: .requestingPermission, detail: "speech recognition"))
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            return .unavailable(.permissionDenied, "Speech recognition authorization status: \(status.rawValue)")
        }
        guard recognizer.isAvailable else {
            return .unavailable(.temporarilyUnavailable, "SFSpeechRecognizer.isAvailable is false")
        }
        return .available
    }

    public func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error> {
        AsyncThrowingStream { continuation in
            let locale = Locale(identifier: Self.localeIdentifier(for: languageCode))
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                continuation.finish(throwing: EngineError.recognizerUnavailable)
                return
            }
            recognizer.defaultTaskHint = .dictation
            // On-device whenever the device can; the server is only ever
            // used when the user allowed it AND the device can't.
            let requiresOnDevice = recognizer.supportsOnDeviceRecognition || !allowServerFallback
            let session = RecognitionSession(
                recognizer: recognizer,
                requiresOnDevice: requiresOnDevice,
                continuation: continuation
            )
            session.start(feeding: audio)
            continuation.onTermination = { _ in session.stop() }
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func localeIdentifier(for languageCode: String) -> String {
        languageCode == "he" ? "he-IL" : languageCode
    }

    enum EngineError: Error {
        case recognizerUnavailable
        case recognizerKeepsFailing(String)
    }
}

/// One live recognition session made of many consecutive requests. All
/// state is behind a lock because `SFSpeechRecognizer` delivers results
/// on its own queue while audio arrives from the pipeline's task.
private final class RecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private let requiresOnDevice: Bool
    private let continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var utteranceID = UUID()
    private var feedTask: Task<Void, Never>?
    private var stopped = false

    private var voiceDetector = EnergyVoiceDetector()
    private var samplesInRequest = 0
    private var samplesSinceSpeech = 0
    private var requestHasSpeech = false
    private var lastTextByUtterance: [UUID: String] = [:]
    private var consecutiveFailures = 0

    private static let sampleRate = 16_000
    /// A pause this long after speech ends the utterance.
    private static let pauseSamples = Int(1.2 * Double(sampleRate))
    /// Requests are rolled over before Apple's own limits bite and so a
    /// single runaway utterance can't grow without bound.
    private static let maxRequestSamples = 45 * sampleRate
    /// Pure silence for this long restarts the request quietly, so the
    /// recognizer never times out with "no speech detected".
    private static let idleRestartSamples = 8 * sampleRate

    init(
        recognizer: SFSpeechRecognizer,
        requiresOnDevice: Bool,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) {
        self.recognizer = recognizer
        self.requiresOnDevice = requiresOnDevice
        self.continuation = continuation
    }

    func start(feeding audio: AsyncStream<[Float]>) {
        lock.withLock { beginRequestLocked() }
        feedTask = Task { [self] in
            for await chunk in audio {
                if Task.isCancelled { break }
                self.ingest(chunk)
            }
            // Audio ended (pipeline stopped): let the last utterance
            // finalize rather than cutting it off.
            self.lock.withLock { self.request?.endAudio() }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
        }
        feedTask?.cancel()
    }

    private func ingest(_ chunk: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let request else { return }

        if voiceDetector.isSpeech(chunk) {
            requestHasSpeech = true
            samplesSinceSpeech = 0
        } else {
            samplesSinceSpeech += chunk.count
        }
        samplesInRequest += chunk.count

        if let buffer = Self.pcmBuffer(from: chunk) {
            request.append(buffer)
        }

        let pausedAfterSpeech = requestHasSpeech && samplesSinceSpeech >= Self.pauseSamples
        let tooLong = samplesInRequest >= Self.maxRequestSamples
        let idleTooLong = !requestHasSpeech && samplesInRequest >= Self.idleRestartSamples
        if pausedAfterSpeech || tooLong || idleTooLong {
            rollOverLocked()
        }
    }

    /// Ends the current request (its final result arrives asynchronously,
    /// tagged with its own utterance id) and opens the next one.
    private func rollOverLocked() {
        request?.endAudio()
        beginRequestLocked()
    }

    private func beginRequestLocked() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDevice
        request.taskHint = .dictation
        request.addsPunctuation = true

        let id = UUID()
        utteranceID = id
        samplesInRequest = 0
        samplesSinceSpeech = 0
        requestHasSpeech = false
        self.request = request
        // `SFSpeechRecognitionTask` isn't Sendable; it's only ever touched
        // under this session's lock, which is the real invariant here.
        nonisolated(unsafe) let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, utteranceID: id)
        }
        self.task = task
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, utteranceID id: UUID) {
        lock.lock()
        let stopped = self.stopped
        let isCurrent = id == utteranceID
        lock.unlock()
        guard !stopped else { return }

        if let error {
            // A request that was ended on purpose reports the end as an
            // error (cancelled / no speech detected); those are expected.
            // Only the *current* request dying is worth reacting to, and
            // even then one restart usually clears it.
            guard isCurrent else { return }
            lock.lock()
            consecutiveFailures += 1
            let failures = consecutiveFailures
            if failures < 3 {
                rollOverLocked()
                lock.unlock()
            } else {
                lock.unlock()
                continuation.finish(throwing: AppleSpeechEngine.EngineError.recognizerKeepsFailing(String(describing: error)))
            }
            return
        }

        guard let result else { return }
        lock.withLock { consecutiveFailures = 0 }

        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = result.bestTranscription.segments
        let confidence: Float? = segments.isEmpty
            ? nil
            : segments.map(\.confidence).reduce(0, +) / Float(segments.count)

        // An empty final (the recognizer heard nothing after we ended the
        // request) must not wipe text that was already shown for this
        // utterance, and an utterance that never had text is not worth a
        // segment at all.
        let displayText: String = lock.withLock {
            if text.isEmpty {
                return lastTextByUtterance[id] ?? ""
            }
            lastTextByUtterance[id] = text
            return text
        }
        if displayText.isEmpty { return }

        continuation.yield(TranscriptToken(
            utteranceID: id,
            text: displayText,
            isFinal: result.isFinal,
            timestamp: Date().timeIntervalSince1970,
            confidence: confidence
        ))
        if result.isFinal {
            lock.withLock { lastTextByUtterance[id] = nil }
        }
    }

    private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }
}
