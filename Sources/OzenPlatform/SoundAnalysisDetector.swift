import Foundation
import AVFoundation
import SoundAnalysis
import OzenKit

/// Apple's built-in sound classifier (SoundAnalysis, on-device, ~300
/// labels) fed from the same 16 kHz stream the transcription engines get.
/// Produces raw `SoundObservation`s; `SoundEventPolicy` in OzenKit decides
/// which become alerts, so the only job here is to run the classifier and
/// forward what it says.
///
/// Apple publishes no static list of the classifier's labels, so the
/// catalog in OzenKit was assembled from runtime dumps; `knownIdentifiers`
/// lets Settings show which of those this device's classifier actually
/// has, instead of promising a "doorbell" alert that can never fire.
public struct SoundAnalysisDetector: SoundEventDetecting {
    /// Readings below this never leave the detector; the policy applies
    /// its own, higher floor on top.
    private let forwardingConfidence: Double
    private let windowSeconds: Double

    public init(forwardingConfidence: Double = 0.3, windowSeconds: Double = 1.5) {
        self.forwardingConfidence = forwardingConfidence
        self.windowSeconds = windowSeconds
    }

    /// The labels this device's classifier reports, or nil if the
    /// classifier can't be created at all (very old OS, missing model).
    public static func knownIdentifiers() -> Set<String>? {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        return Set(request.knownClassifications)
    }

    /// How many times a failed classifier is set up again in one session
    /// before sound alerts are left off (Diagnostics then says so).
    static let maximumRestarts = 5

    public func observations(audio: AsyncStream<[Float]>) -> AsyncStream<SoundObservation> {
        let forwardingConfidence = forwardingConfidence
        let windowSeconds = windowSeconds
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
                    continuation.finish()
                    return
                }
                // The analyzer's request can fail partway through a
                // conversation; a new analyzer picks up from the next chunk,
                // so a doorbell later in the evening still gets through.
                var session = Self.makeSession(format: format, continuation: continuation, forwardingConfidence: forwardingConfidence, windowSeconds: windowSeconds)
                var restarts = 0
                var framePosition: AVAudioFramePosition = 0
                for await chunk in audio {
                    if Task.isCancelled { break }
                    if session == nil || session?.observer.hasFailed == true {
                        guard restarts < Self.maximumRestarts else { break }
                        restarts += 1
                        session = Self.makeSession(format: format, continuation: continuation, forwardingConfidence: forwardingConfidence, windowSeconds: windowSeconds)
                        framePosition = 0
                        guard session != nil else { continue }
                    }
                    guard let current = session, let buffer = Self.pcmBuffer(from: chunk, format: format) else { continue }
                    // Synchronous and CPU-bound: this is exactly why the
                    // whole loop runs on a detached utility-priority task
                    // rather than anywhere near the main actor.
                    current.analyzer.analyze(buffer, atAudioFramePosition: framePosition)
                    framePosition += AVAudioFramePosition(chunk.count)
                }
                session?.analyzer.completeAnalysis()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Session {
        let analyzer: SNAudioStreamAnalyzer
        let observer: ClassificationObserver
    }

    private static func makeSession(
        format: AVAudioFormat,
        continuation: AsyncStream<SoundObservation>.Continuation,
        forwardingConfidence: Double,
        windowSeconds: Double
    ) -> Session? {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = ClassificationObserver(continuation: continuation, minimumConfidence: forwardingConfidence)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let window = CMTime(seconds: windowSeconds, preferredTimescale: 16_000)
            if case .durationRange(let range) = request.windowDurationConstraint, range.containsTime(window) {
                request.windowDuration = window
            }
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: observer)
        } catch {
            return nil
        }
        return Session(analyzer: analyzer, observer: observer)
    }

    private static func pcmBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
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

/// Receives classifier results on the analyzer's own queue and forwards
/// the top few confident labels of each window. A failure is only noted:
/// the detector's loop sets up a new analyzer rather than ending the
/// stream of observations.
private final class ClassificationObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let continuation: AsyncStream<SoundObservation>.Continuation
    private let minimumConfidence: Double
    private let lock = NSLock()
    private var failed = false

    var hasFailed: Bool {
        lock.withLock { failed }
    }

    init(continuation: AsyncStream<SoundObservation>.Continuation, minimumConfidence: Double) {
        self.continuation = continuation
        self.minimumConfidence = minimumConfidence
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let timestamp = Date().timeIntervalSince1970
        for candidate in classification.classifications.prefix(3) where candidate.confidence >= minimumConfidence {
            continuation.yield(SoundObservation(
                identifier: candidate.identifier,
                confidence: candidate.confidence,
                timestamp: timestamp
            ))
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.withLock { failed = true }
    }

    func requestDidComplete(_ request: SNRequest) {
        // Only after `completeAnalysis`, when the audio has ended; the
        // detector's loop finishes the stream itself.
    }
}
