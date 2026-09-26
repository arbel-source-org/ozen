import Foundation

public struct VoiceEvidence {
    public static let chunkSamples = 4096
    public static let contextSamples = 64
    public static let voiceThreshold: Float = 0.5

    public typealias Scorer = ([Float]) -> Float?

    private let score: Scorer
    private var pending: [Float] = []
    private var context = [Float](repeating: 0, count: VoiceEvidence.contextSamples)
    private var chunks: [(end: Int, voiced: Bool)] = []
    private var start = 0
    private var received = 0
    private var failed = false

    public init(score: @escaping Scorer) {
        self.score = score
    }

    public mutating func append(_ samples: [Float]) {
        received += samples.count
        guard !failed else { return }
        pending.append(contentsOf: samples)
        while pending.count >= Self.chunkSamples {
            let chunk = Array(pending.prefix(Self.chunkSamples))
            pending.removeFirst(Self.chunkSamples)
            guard let probability = score(context + chunk) else {
                failed = true
                chunks.removeAll()
                pending.removeAll()
                return
            }
            context = Array(chunk.suffix(Self.contextSamples))
            chunks.append((end: received - pending.count, voiced: probability >= Self.voiceThreshold))
        }
    }

    public func hasVoice(inFirst count: Int) -> Bool? {
        guard !failed else { return nil }
        let end = start + count
        let overlapping = chunks.filter { $0.end > start && $0.end - Self.chunkSamples < end }
        guard !overlapping.isEmpty else { return nil }
        return overlapping.contains { $0.voiced }
    }

    public mutating func drop(prefix count: Int) {
        start += count
        chunks.removeAll { $0.end <= start }
    }
}
