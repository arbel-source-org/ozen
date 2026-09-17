import Foundation

/// Produces a fixed-length embedding vector for a chunk of audio, for
/// `EmbeddingClusterer` to cluster by speaker. Kept as a small protocol
/// specifically so the v1 MFCC implementation (`MFCCSpeakerEmbedder` in
/// OzenPlatform, which needs Accelerate) can be swapped for a deep CoreML
/// speaker-embedding model later without touching the clustering logic or
/// anything upstream of it — and so the pipeline can be tested here with a
/// fake that returns whatever vector a test wants.
public protocol SpeakerEmbedding: Sendable {
    /// Returns nil if `samples` is too short to extract even one frame.
    func embed(samples: [Float], sampleRate: Double) -> [Float]?
    var recommendedSimilarityThreshold: Float { get }
}

extension SpeakerEmbedding {
    public var recommendedSimilarityThreshold: Float { AppSettings.default.speakerSimilarityThreshold }
}
