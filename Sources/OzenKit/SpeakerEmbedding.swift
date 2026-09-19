import Foundation

public protocol SpeakerEmbedding: Sendable {
    func embed(samples: [Float], sampleRate: Double) -> [Float]?
    var recommendedSimilarityThreshold: Float { get }
    var embeddingLength: Int? { get }
}

extension SpeakerEmbedding {
    public var recommendedSimilarityThreshold: Float { AppSettings.default.speakerSimilarityThreshold }
    public var embeddingLength: Int? { nil }
}
