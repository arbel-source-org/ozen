import Foundation

public final class SpeechIntake: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var count: Int
        public var firstSpeechStart: Int?
        public var lastSpeechEnd: Int?
        public var finished: Bool
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var speechStarts: [Int] = []
    private var lastSpeechEnd: Int?
    private var finished = false
    private var detector: EnergyVoiceDetector

    public init(detector: EnergyVoiceDetector = EnergyVoiceDetector()) {
        self.detector = detector
    }

    public func append(_ chunk: [Float]) {
        lock.withLock {
            samples.append(contentsOf: chunk)
            if detector.isSpeech(chunk) {
                speechStarts.append(samples.count - chunk.count)
                lastSpeechEnd = samples.count
            }
        }
    }

    public func markFinished() {
        lock.withLock { finished = true }
    }

    public func status() -> Status {
        lock.withLock {
            Status(count: samples.count, firstSpeechStart: speechStarts.first, lastSpeechEnd: lastSpeechEnd, finished: finished)
        }
    }

    public func copySamples(upTo end: Int) -> [Float] {
        lock.withLock {
            Array(samples[0..<min(max(end, 0), samples.count)])
        }
    }

    public func drop(prefix count: Int) {
        lock.withLock {
            let dropped = min(max(count, 0), samples.count)
            samples.removeFirst(dropped)
            speechStarts = speechStarts.compactMap { $0 >= dropped ? $0 - dropped : nil }
            if let end = lastSpeechEnd {
                lastSpeechEnd = end > dropped ? end - dropped : nil
            }
        }
    }
}
