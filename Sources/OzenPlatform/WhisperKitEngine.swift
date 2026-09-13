import Foundation
import WhisperKit
import OzenKit

/// Wraps Argmax's WhisperKit (open-source, on-device Whisper via CoreML)
/// for Hebrew-primary live transcription.
///
/// Implementation note: this is built against WhisperKit's simple
/// `transcribe(audioArray:decodeOptions:)` entry point, re-run on a rolling
/// buffer as audio arrives, rather than WhisperKit's internal streaming
/// transcriber class. That's a deliberate, conservative choice: this file
/// cannot be compiled on the development machine (no Mac — CoreML/WhisperKit
/// only build on Apple platforms, verified in CI), so it leans on the
/// smallest, most stable piece of the public API instead of an internal
/// class whose exact current signature can't be checked here. Once this is
/// actually building in CI against a pinned WhisperKit version, switching
/// to its dedicated streaming transcriber (less redundant recompute per
/// pass) is a reasonable, isolated follow-up — nothing above this file
/// would need to change, since callers only see `TranscriptionEngine`.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let kind: TranscriptionEngineKind = .whisperKit

    private var pipe: WhisperKit?
    private let modelVariant: String

    /// Re-run the model at most this often per utterance — often enough to
    /// feel live, not so often that Whisper inference dominates the CPU.
    private let minSecondsBetweenPasses: Double = 0.75
    /// A gap this long with no non-silent audio ends the current utterance.
    private let silenceGapSeconds: Double = 1.2
    private let sampleRate: Double = 16_000

    public init(modelVariant: String = "small") {
        self.modelVariant = modelVariant
    }

    public func checkAvailability(languageCode: String) async -> EngineAvailability {
        do {
            _ = try await loadedPipe()
            return .available
        } catch {
            return .unavailable(reason: "Couldn't load the Whisper model (\(modelVariant)): \(error.localizedDescription)")
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
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreaming(
        languageCode: String,
        audio: AsyncStream<[Float]>,
        continuation: AsyncThrowingStream<TranscriptToken, Error>.Continuation
    ) async throws {
        let pipe = try await loadedPipe()
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode
        )

        var utteranceID = UUID()
        var rollingBuffer: [Float] = []
        var samplesSinceLastPass = 0
        var lastNonSilentSampleIndex = 0
        let minSamplesBetweenPasses = Int(minSecondsBetweenPasses * sampleRate)
        let silenceGapSamples = Int(silenceGapSeconds * sampleRate)

        for await chunk in audio {
            try Task.checkCancellation()
            rollingBuffer.append(contentsOf: chunk)
            samplesSinceLastPass += chunk.count

            if !Self.isSilent(chunk) {
                lastNonSilentSampleIndex = rollingBuffer.count
            }
            let longSilenceSinceLastSpeech = rollingBuffer.count - lastNonSilentSampleIndex > silenceGapSamples

            guard samplesSinceLastPass >= minSamplesBetweenPasses || longSilenceSinceLastSpeech else {
                continue
            }
            samplesSinceLastPass = 0

            let results = try await pipe.transcribe(audioArray: rollingBuffer, decodeOptions: options)
            let text = (results ?? []).map(\.text).joined(separator: " ")

            continuation.yield(TranscriptToken(
                utteranceID: utteranceID,
                text: text,
                isFinal: longSilenceSinceLastSpeech,
                timestamp: Date().timeIntervalSince1970
            ))

            if longSilenceSinceLastSpeech {
                utteranceID = UUID()
                rollingBuffer.removeAll(keepingCapacity: true)
                lastNonSilentSampleIndex = 0
            }
        }
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        let pipe = try await WhisperKit(model: modelVariant)
        self.pipe = pipe
        return pipe
    }

    private static func isSilent(_ chunk: [Float], threshold: Float = 0.01) -> Bool {
        chunk.allSatisfy { abs($0) < threshold }
    }
}
