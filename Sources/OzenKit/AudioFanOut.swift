import Foundation

/// Splits one audio stream into several independent consumers — the
/// transcription engine, the speaker embedder, and later the sound-event
/// classifier all need every sample — without any of them blocking or
/// starving the others. Each output gets its own unbounded buffer, so a
/// consumer that's briefly slow (Whisper mid-inference) just falls a little
/// behind rather than dropping audio; consumers are expected to catch up
/// (the engines are written to accumulate quickly and infer separately).
public struct AudioFanOut: Sendable {
    public let outputs: [AsyncStream<[Float]>]
    private let pump: Task<Void, Never>

    public init(source: AsyncStream<[Float]>, count: Int) {
        var streams: [AsyncStream<[Float]>] = []
        var continuations: [AsyncStream<[Float]>.Continuation] = []
        for _ in 0..<max(count, 1) {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
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
