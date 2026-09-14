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
        #expect(clusterer.displayName(forClusterID: id) == "דובר 1")
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
        #expect(clusterer.displayName(forClusterID: id) == "דובר 1")

        clusterer.nameCluster(id: id, name: "דנה")
        #expect(clusterer.displayName(forClusterID: id) == "דנה")
    }

    @Test("an unknown or nil cluster id reports as an unknown speaker rather than crashing")
    func unknownClusterIsSafe() {
        let clusterer = EmbeddingClusterer()
        #expect(clusterer.displayName(forClusterID: nil) == EmbeddingClusterer.unknownSpeakerName)
        #expect(clusterer.displayName(forClusterID: 99) == EmbeddingClusterer.unknownSpeakerName)
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

    @Test("generic labels are Hebrew, because that is what the caption screen shows")
    func hebrewLabels() {
        var clusterer = EmbeddingClusterer()
        let id = clusterer.assign(embedding: [1, 0, 0])
        #expect(clusterer.displayName(forClusterID: id) == "דובר 1")
        #expect(clusterer.displayName(forClusterID: nil) == "דובר לא ידוע")
    }

    @Test("renaming a profile relabels its clusters, and forgetting it returns them to a generic label")
    func renameAndForget() {
        var clusterer = EmbeddingClusterer()
        let avi = clusterer.enroll(name: "אבי", embedding: [1, 0, 0])
        let ruti = clusterer.enroll(name: "רותי", embedding: [0, 1, 0])
        clusterer.renameClusters(named: "אבי", to: "אביגדור")
        #expect(clusterer.displayName(forClusterID: avi) == "אביגדור")
        #expect(clusterer.displayName(forClusterID: ruti) == "רותי")

        clusterer.forgetName("אביגדור")
        #expect(clusterer.displayName(forClusterID: avi) == EmbeddingClusterer.genericName(forClusterID: avi))
        #expect(clusterer.displayName(forClusterID: ruti) == "רותי")
    }

    @Test("an enrolled voice moves only a little toward a noisy first live window")
    func enrolledReferenceIsHeavy() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.7)
        let id = clusterer.enroll(name: "סבתא", embedding: [1, 0, 0])
        let assigned = clusterer.assign(embedding: [0.8, 0.6, 0])
        #expect(assigned == id)
        let centroid = clusterer.clusters[0].centroid
        let weight = Float(EmbeddingClusterer.enrollmentWeight)
        #expect(abs(centroid[1] - 0.6 / (weight + 1)) < 0.0001)
        #expect(clusterer.clusters[0].sampleCount == EmbeddingClusterer.enrollmentWeight + 1)

        // A voice found live still starts at one sample.
        let live = clusterer.assign(embedding: [0, 0, 1])
        #expect(clusterer.clusters.first { $0.id == live }?.sampleCount == 1)
    }
}
