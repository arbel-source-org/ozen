import Testing
@testable import OzenKit

@Suite("EmbeddingClusterer")
struct EmbeddingClustererTests {

    @Test("the very first embedding opens a new, unnamed cluster")
    func firstEmbeddingOpensCluster() {
        var clusterer = EmbeddingClusterer()
        let id = clusterer.assign(embedding: [1, 0, 0])
        #expect(id == 0)
        #expect(clusterer.clusters.count == 1)
        #expect(clusterer.displayName(forClusterID: id) == "Speaker 1")
    }

    @Test("near-identical embeddings join the same cluster instead of opening a new one")
    func similarEmbeddingsMerge() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.9)
        let first = clusterer.assign(embedding: [1, 0, 0])
        let second = clusterer.assign(embedding: [0.98, 0.02, 0])
        #expect(first == second)
        #expect(clusterer.clusters.count == 1)
    }

    @Test("clearly different embeddings open separate clusters")
    func dissimilarEmbeddingsSplit() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.9)
        let a = clusterer.assign(embedding: [1, 0, 0])
        let b = clusterer.assign(embedding: [0, 1, 0])
        #expect(a != b)
        #expect(clusterer.clusters.count == 2)
    }

    @Test("enrolling a name seeds a cluster that later matching audio lands in")
    func enrollmentNamesFutureMatches() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.9)
        let grandmaID = clusterer.enroll(name: "סבתא", embedding: [1, 0, 0])
        let laterMatch = clusterer.assign(embedding: [0.99, 0.01, 0])

        #expect(laterMatch == grandmaID)
        #expect(clusterer.displayName(forClusterID: laterMatch) == "סבתא")
    }

    @Test("naming an already-inferred cluster after the fact updates its display name")
    func tagAfterTheFact() {
        var clusterer = EmbeddingClusterer()
        let id = clusterer.assign(embedding: [1, 0, 0])
        #expect(clusterer.displayName(forClusterID: id) == "Speaker 1")

        clusterer.nameCluster(id: id, name: "דנה")
        #expect(clusterer.displayName(forClusterID: id) == "דנה")
    }

    @Test("an unknown or nil cluster id reports as an unknown speaker rather than crashing")
    func unknownClusterIsSafe() {
        let clusterer = EmbeddingClusterer()
        #expect(clusterer.displayName(forClusterID: nil) == "Unknown speaker")
        #expect(clusterer.displayName(forClusterID: 99) == "Unknown speaker")
    }

    @Test("cosine similarity of a vector with itself is 1")
    func cosineSimilaritySelf() {
        let v: [Float] = [3, 4, 0]
        #expect(abs(cosineSimilarity(v, v) - 1.0) < 0.0001)
    }

    @Test("cosine similarity of orthogonal vectors is 0")
    func cosineSimilarityOrthogonal() {
        #expect(cosineSimilarity([1, 0], [0, 1]) == 0)
    }

    @Test("cosine similarity of mismatched-length or empty vectors is 0, not a crash")
    func cosineSimilarityMismatchedIsSafe() {
        #expect(cosineSimilarity([1, 0], [1, 0, 0]) == 0)
        #expect(cosineSimilarity([], []) == 0)
    }
}
