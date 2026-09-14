import Foundation

/// One inferred (or enrolled) speaker. `name` is nil until either the user
/// enrolls a real profile ahead of time or tags this cluster after the
/// fact — until then the UI shows "דובר \(id + 1)".
public struct SpeakerCluster: Sendable, Equatable, Identifiable {
    public let id: Int
    public var centroid: [Float]
    public var sampleCount: Int
    public var name: String?
}

/// Online, embedding-agnostic speaker clustering: nearest-centroid
/// assignment by cosine similarity, opening a new cluster when nothing is
/// close enough. Deliberately decoupled from *how* an embedding is produced
/// (see `SpeakerEmbedder` in OzenPlatform for the v1 MFCC-based embedder) so
/// the clustering logic itself — the part with actual room for bugs — can
/// be verified with synthetic vectors and no audio pipeline at all.
public struct EmbeddingClusterer: Sendable {
    public private(set) var clusters: [SpeakerCluster] = []
    public var similarityThreshold: Float
    private var nextID = 0

    public init(similarityThreshold: Float = 0.75) {
        self.similarityThreshold = similarityThreshold
    }

    /// Assigns an embedding to the best matching cluster (updating its
    /// running centroid), or opens a new cluster if nothing is close
    /// enough. Returns the cluster id.
    @discardableResult
    public mutating func assign(embedding: [Float]) -> Int {
        // A voice print of a different length (a profile saved by an older
        // build's embedder) can't be averaged into this one, whatever the
        // threshold says.
        guard let (bestIndex, bestSimilarity) = bestMatch(for: embedding),
              bestSimilarity >= similarityThreshold,
              clusters[bestIndex].centroid.count == embedding.count
        else {
            return openCluster(with: embedding, name: nil)
        }
        updateCentroid(at: bestIndex, with: embedding)
        return clusters[bestIndex].id
    }

    /// Seeds a cluster with a known name from a reference embedding
    /// recorded during enrollment, before any live audio has arrived for
    /// that person.
    ///
    /// The reference counts as several samples: it was recorded on purpose,
    /// close to the microphone, in a quiet moment, while live windows carry
    /// room noise and cross-talk. Counting it as one would let the very
    /// first live window move the profile halfway.
    @discardableResult
    public mutating func enroll(name: String, embedding: [Float], weight: Int = EmbeddingClusterer.enrollmentWeight) -> Int {
        openCluster(with: embedding, name: name, sampleCount: max(1, weight))
    }

    public static let enrollmentWeight = 6

    /// Tags an existing (already-inferred) cluster with a name after the
    /// fact — the "who is this?" flow on a transcript segment.
    public mutating func nameCluster(id: Int, name: String) {
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return }
        clusters[index].name = name
    }

    /// Hebrew, because this is exactly what the caption rows and the saved
    /// history show.
    public static let unknownSpeakerName = "דובר לא ידוע"

    public static func genericName(forClusterID id: Int) -> String {
        "דובר \(id + 1)"
    }

    public func displayName(forClusterID id: Int?) -> String {
        guard let id, let cluster = clusters.first(where: { $0.id == id }) else {
            return Self.unknownSpeakerName
        }
        return cluster.name ?? Self.genericName(forClusterID: id)
    }

    /// A saved profile was renamed: every cluster showing the old name
    /// shows the new one from now on.
    public mutating func renameClusters(named oldName: String, to newName: String) {
        for index in clusters.indices where clusters[index].name == oldName {
            clusters[index].name = newName
        }
    }

    /// A saved profile was deleted: clusters labeled with its name go back
    /// to a generic label instead of naming someone who was removed.
    public mutating func forgetName(_ name: String) {
        for index in clusters.indices where clusters[index].name == name {
            clusters[index].name = nil
        }
    }

    private func bestMatch(for embedding: [Float]) -> (index: Int, similarity: Float)? {
        guard !clusters.isEmpty else { return nil }
        var bestIndex = 0
        var bestSimilarity = cosineSimilarity(embedding, clusters[0].centroid)
        for index in clusters.indices.dropFirst() {
            let similarity = cosineSimilarity(embedding, clusters[index].centroid)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestIndex = index
            }
        }
        return (bestIndex, bestSimilarity)
    }

    private mutating func openCluster(with embedding: [Float], name: String?, sampleCount: Int = 1) -> Int {
        let id = nextID
        nextID += 1
        clusters.append(SpeakerCluster(id: id, centroid: embedding, sampleCount: sampleCount, name: name))
        return id
    }

    private mutating func updateCentroid(at index: Int, with embedding: [Float]) {
        let count = Float(clusters[index].sampleCount)
        var centroid = clusters[index].centroid
        for i in centroid.indices {
            centroid[i] = (centroid[i] * count + embedding[i]) / (count + 1)
        }
        clusters[index].centroid = centroid
        clusters[index].sampleCount += 1
    }
}

/// Cosine similarity in [-1, 1]; 0 for mismatched/empty vectors so callers
/// never need to special-case a NaN.
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for i in a.indices {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (normA.squareRoot() * normB.squareRoot())
}
