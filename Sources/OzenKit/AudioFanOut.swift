import Foundation

/// Splits one audio stream into several independent consumers — the
/// transcription engine, the speaker embedder, and later the sound-event
/// classifier all need every sample — without any of them blocking or
/// starving the others. Each output gets its own buffer, so a consumer
/// that's briefly slow (Whisper mid-inference) just falls a little behind
/// rather than dropping audio; consumers are expected to catch up (the
/// engines are written to accumulate quickly and infer separately).
///
/// The buffers are large but not endless. A consumer that stops reading
/// for good while captions run (the sound classifier's request failing
/// mid-conversation, say) would otherwise pile up every sample for the
/// rest of the evening: about 230 MB an hour. Past the limit an output
/// keeps the newest audio and lets the oldest go.
public struct AudioFanOut: Sendable {
    public let outputs: [AsyncStream<[Float]>]
    private let pump: Task<Void, Never>

    /// Chunks each output holds for a consumer that isn't reading: two
    /// minutes or more of audio at the chunk sizes microphones deliver,
    /// far more than any live consumer falls behind by.
    public static let defaultBufferLimit = 3_000

    public init(source: AsyncStream<[Float]>, count: Int, bufferLimit: Int = AudioFanOut.defaultBufferLimit) {
        var streams: [AsyncStream<[Float]>] = []
        var continuations: [AsyncStream<[Float]>.Continuation] = []
        for _ in 0..<max(count, 1) {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(max(bufferLimit, 1)))
            streams.append(stream)
            continuations.append(continuation)
        }
        outputs = streams

        let sinks = continuations
        pump = Task {
            for await chunk in source {
                if Task.isCancelled { break }
                for sink in sinks {
                    sink.yield(chunk)
                }
            }
            for sink in sinks {
                sink.finish()
            }
        }
    }

    /// Stops forwarding and finishes every output. The source stream is
    /// left to its owner (the audio capturer) to end.
    public func cancel() {
        pump.cancel()
    }
}
