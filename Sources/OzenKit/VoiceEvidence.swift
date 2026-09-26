import Foundation

public struct VoiceEvidence {
    public static let chunkSamples = 4096
    public static let contextSamples = 64
    public static let voiceThreshold: Float = 0.5

    public typealias Scorer = ([Float]) -> Float?

    private let score: Scorer
    private var pending: [Float] = []
    private var context = [Float](repeating: 0, count: VoiceEvidence.contextSamples)
    private var chunks: [(end: Int, voiced: Bool?)] = []
    private var start = 0
    private var received = 0

    public init(score: @escaping Scorer) {
        self.score = score
    }

    public mutating func append(_ samples: [Float]) {
        received += samples.count
        pending.append(contentsOf: samples)
        while pending.count >= Self.chunkSamples {
            let chunk = Array(pending.prefix(Self.chunkSamples))
            pending.removeFirst(Self.chunkSamples)
            let probability = score(context + chunk)
            context = Array(chunk.suffix(Self.contextSamples))
            chunks.append((end: received - pending.count, voiced: probability.map { $0 >= Self.voiceThreshold }))
        }
    }

    public func hasVoice(inFirst count: Int) -> Bool? {
        let end = start + count
        let overlapping = chunks.filter { $0.end > start && $0.end - Self.chunkSamples < end }
        guard !overlapping.isEmpty else { return nil }
        if overlapping.contains(where: { $0.voiced == true }) { return true }
        return overlapping.contains { $0.voiced == nil } ? nil : false
    }

    public mutating func drop(prefix count: Int) {
        start += count
        chunks.removeAll { $0.end <= start }
    }
}
