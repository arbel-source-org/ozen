import Foundation
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
        #expect(clusterer.displayName(forClusterID: avi) == EmbeddingClusterer.genericName(number: 1))
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

    @Test("generic labels are in English when the app is")
    func englishLabels() {
        Localization.$override.withValue(.english) {
            var clusterer = EmbeddingClusterer()
            let id = clusterer.assign(embedding: [1, 0, 0])
            #expect(clusterer.displayName(forClusterID: id) == "Speaker 1")
            #expect(clusterer.displayName(forClusterID: nil) == "Unknown speaker")
            #expect(EmbeddingClusterer.genericName(number: 3) == "Speaker 3")
        }
    }
}

@Suite("EmbeddingClusterer numbering across conversations")
struct EmbeddingClustererConversationTests {
    @Test("the first stranger is speaker 1 even with enrolled people ahead of them")
    func numberingSkipsEnrolled() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.9)
        clusterer.enroll(name: "Avi", embedding: [1, 0, 0])
        clusterer.enroll(name: "Ruti", embedding: [0, 1, 0])
        let stranger = clusterer.assign(embedding: [0, 0, 1])
        #expect(clusterer.displayName(forClusterID: stranger) == EmbeddingClusterer.genericName(number: 1))
    }

    @Test("a new conversation numbers voices from 1 again, old lines keep their labels, named voices carry on")
    func newConversation() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.9)
        let grandma = clusterer.enroll(name: "Savta", embedding: [1, 0, 0])
        let first = clusterer.assign(embedding: [0, 1, 0])
        let second = clusterer.assign(embedding: [0, 0, 1])
        #expect(clusterer.displayName(forClusterID: second) == EmbeddingClusterer.genericName(number: 2))

        clusterer.startNewConversation()
        #expect(clusterer.displayName(forClusterID: first) == EmbeddingClusterer.genericName(number: 1))
        #expect(clusterer.displayName(forClusterID: second) == EmbeddingClusterer.genericName(number: 2))

        // The same voice as before is a new speaker 1 in the new conversation.
        let again = clusterer.assign(embedding: [0, 0, 1])
        #expect(again != second)
        #expect(clusterer.displayName(forClusterID: again) == EmbeddingClusterer.genericName(number: 1))
        #expect(clusterer.assign(embedding: [0.99, 0.01, 0]) == grandma)
    }

    @Test("naming a speaker from an ended conversation makes them a voice listened for again")
    func nameRetired() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.9)
        let dana = clusterer.assign(embedding: [0, 1, 0])
        clusterer.startNewConversation()
        clusterer.nameCluster(id: dana, name: "Dana")
        #expect(clusterer.displayName(forClusterID: dana) == "Dana")
        #expect(clusterer.assign(embedding: [0.01, 0.99, 0]) == dana)
    }

    @Test("only so many ended voices are remembered for labels")
    func retiredLimit() {
        var clusterer = EmbeddingClusterer(similarityThreshold: 0.99)
        let oldest = clusterer.assign(embedding: [1, 0])
        clusterer.startNewConversation()
        for index in 0..<EmbeddingClusterer.retiredLimit {
            clusterer.assign(embedding: [Float(index + 2), 1])
            clusterer.startNewConversation()
        }
        #expect(clusterer.displayName(forClusterID: oldest) == EmbeddingClusterer.unknownSpeakerName)
        #expect(clusterer.clusters.isEmpty)
    }
}

@Suite("EmbeddingClusterer with bad input")
struct EmbeddingClustererBadInputTests {
    @Test("a voice print of another length never merges, even with the threshold at zero")
    func mismatchedLengths() {
        var clusterer = EmbeddingClusterer()
        clusterer.similarityThreshold = 0
        let old = clusterer.enroll(name: "שרה", embedding: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let live = clusterer.assign(embedding: [1, 0, 0])
        #expect(live != old)
        #expect(clusterer.clusters.count == 2)
    }
}

@Suite("AppSettings speaker threshold from a file")
struct AppSettingsThresholdDecodingTests {
    @Test("a threshold outside the slider's range is brought back to its nearest edge")
    func clamped() throws {
        func decode(_ value: String) throws -> Float {
            try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speakerSimilarityThreshold":\#(value)}"#.utf8)).speakerSimilarityThreshold
        }
        #expect(try decode("0") == 0.2)
        #expect(try decode("-3") == 0.2)
        #expect(try decode("7") == 0.95)
        #expect(try decode("0.8") == 0.8)
    }
}
