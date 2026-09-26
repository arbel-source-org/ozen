import Foundation

/// One inferred (or enrolled) speaker. `name` is nil until either the user
/// enrolls a real profile ahead of time or tags this cluster after the fact
/// — until then the UI shows "dover N" ("speaker N"), N being `number`.
public struct SpeakerCluster: Sendable, Equatable, Identifiable {
    public let id: Int
    public var centroid: [Float]
    public var sampleCount: Int
    public var name: String?
    /// Which unnamed voice of its conversation this is, from 1. Not the id:
    /// ids never repeat, and enrolled people take ids too, so numbering by
    /// id had the first stranger of the day show up as speaker 3, and a
    /// week of listening reach speaker 140.
    public var number: Int = 0
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
    /// How far below the threshold a window has to score, against every
    /// voice heard so far, before it opens a new speaker at once. Between the
    /// threshold and this margin the window is doubtful: a short window of
    /// one steady voice in a noisy or quiet room scores there all the time,
    /// and used to open a "new speaker" every time it did (twelve of them
    /// from one person). A doubtful window is held, counted with the nearest
    /// voice, and only opens a speaker if the very next window agrees with it.
    public var newSpeakerMargin: Float = 0.25
    /// A doubtful window waiting for the next one to agree with it.
    private var doubtful: [Float]?
    private var nextID = 0
    /// Numbers currently shown as "Speaker N" somewhere on screen (active or
    /// retired, since a retired cluster's past lines keep their label). A
    /// plain always-increasing counter reached "Speaker 140" on a TV that
    /// never gave the 90 minutes of silence a new conversation needs, since
    /// `activeUnnamedLimit`/`retiredLimit` cap how many voices are *kept*
    /// but not how high the counter climbed. The lowest free number is
    /// reused instead, once its old line ages out of `retired` for good.
    private var usedNumbers: Set<Int> = []
    /// Unnamed voices from conversations that have ended. New speech is no
    /// longer matched against them, but lines still on screen keep their
    /// labels.
    private var retired: [SpeakerCluster] = []
    static let retiredLimit = 200
    /// Unnamed voices listened for at once. A conversation only ends after
    /// a quiet stretch, and a television never gives one: every voice it
    /// played stayed a speaker for good, and a new person in the room could
    /// be matched to a presenter from hours before. Past this, the voice
    /// heard longest ago is retired the way an ended conversation's are.
    static let activeUnnamedLimit = 12
    /// When each voice was last given a window, in windows since launch.
    private var lastHeard: [Int: Int] = [:]
    private var windowsHeard = 0

    public init(similarityThreshold: Float = 0.75) {
        self.similarityThreshold = similarityThreshold
    }

    /// Assigns an embedding to the best matching cluster (updating its
    /// running centroid), or opens a new cluster if nothing is close
    /// enough. Returns the cluster id.
    @discardableResult
    public mutating func assign(embedding: [Float]) -> Int {
        let id = match(embedding: embedding)
        windowsHeard += 1
        lastHeard[id] = windowsHeard
        retireOldestIfCrowded(keeping: id)
        return id
    }

    private mutating func retireOldestIfCrowded(keeping kept: Int) {
        let unnamed = clusters.filter { $0.name == nil }
        guard unnamed.count > Self.activeUnnamedLimit,
              let oldest = unnamed.filter({ $0.id != kept }).min(by: { lastHeard[$0.id, default: 0] < lastHeard[$1.id, default: 0] })
        else { return }
        clusters.removeAll { $0.id == oldest.id }
        lastHeard[oldest.id] = nil
        retired.append(oldest)
        if retired.count > Self.retiredLimit {
            let overflow = retired.count - Self.retiredLimit
            for evicted in retired.prefix(overflow) { usedNumbers.remove(evicted.number) }
            retired.removeFirst(overflow)
        }
    }

    private mutating func match(embedding: [Float]) -> Int {
        // A voice print of a different length (a profile saved by an older
        // build's embedder) can't be averaged into this one, whatever the
        // threshold says.
        guard let (bestIndex, bestSimilarity) = bestMatch(for: embedding),
              clusters[bestIndex].centroid.count == embedding.count
        else {
            doubtful = nil
            return openCluster(with: embedding, name: nil)
        }
        if bestSimilarity >= similarityThreshold {
            doubtful = nil
            updateCentroid(at: bestIndex, with: embedding)
            return clusters[bestIndex].id
        }
        // Clearly nobody heard so far.
        if bestSimilarity < similarityThreshold - newSpeakerMargin {
            doubtful = nil
            return openCluster(with: embedding, name: nil)
        }
        // Doubtful. If the window before it was doubtful in the same way, that
        // is two windows of a voice that isn't any of these: a new speaker.
        if let held = doubtful,
           held.count == embedding.count,
           cosineSimilarity(held, embedding) >= similarityThreshold {
            doubtful = nil
            let merged = zip(held, embedding).map { ($0 + $1) / 2 }
            return openCluster(with: merged, name: nil, sampleCount: 2)
        }
        // Otherwise it is most likely the nearest voice on a bad window. It
        // is left out of that voice's average so it can't drag it away.
        doubtful = embedding
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
        if let index = clusters.firstIndex(where: { $0.id == id }) {
            clusters[index].name = name
        } else if let index = retired.firstIndex(where: { $0.id == id }) {
            // Someone named from an earlier conversation's line is a known
            // voice now, and is listened for again.
            var cluster = retired.remove(at: index)
            cluster.name = name
            clusters.append(cluster)
        }
    }

    /// A conversation ended (a long quiet stretch, or the screen cleared):
    /// the unnamed voices of the next one are numbered from 1 again, and
    /// aren't matched against the last one's. Named voices carry on.
    public mutating func startNewConversation() {
        doubtful = nil
        let ended = clusters.filter { $0.name == nil }
        retired.append(contentsOf: ended)
        if retired.count > Self.retiredLimit {
            retired.removeFirst(retired.count - Self.retiredLimit)
        }
        clusters.removeAll { $0.name == nil }
        for cluster in ended { lastHeard[cluster.id] = nil }
        usedNumbers.removeAll()
    }

    /// Exactly what the caption rows and the saved history show, in
    /// whichever language the app is in.
    public static var unknownSpeakerName: String { tr("דובר לא ידוע", "Unknown speaker") }

    public static func genericName(number: Int) -> String {
        tr("דובר \(number)", "Speaker \(number)")
    }

    public func displayName(forClusterID id: Int?) -> String {
        guard let id, let cluster = clusters.first(where: { $0.id == id }) ?? retired.last(where: { $0.id == id }) else {
            return Self.unknownSpeakerName
        }
        return cluster.name ?? Self.genericName(number: cluster.number)
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
    /// One voice stops being a known person, whatever it was called: a
    /// saved voice print deleted while another under the same name stays.
    public mutating func forgetName(ofCluster id: Int) {
        guard let index = clusters.firstIndex(where: { $0.id == id }), clusters[index].name != nil else { return }
        clusters[index].name = nil
        clusters[index].number = assignNumber()
    }

    public mutating func forgetName(_ name: String) {
        for index in clusters.indices where clusters[index].name == name {
            clusters[index].name = nil
            clusters[index].number = assignNumber()
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
        var cluster = SpeakerCluster(id: id, centroid: embedding, sampleCount: sampleCount, name: name)
        if name == nil {
            cluster.number = assignNumber()
        }
        clusters.append(cluster)
        return id
    }

    /// The lowest positive "Speaker N" number not already shown on screen.
    private mutating func assignNumber() -> Int {
        var candidate = 1
        while usedNumbers.contains(candidate) { candidate += 1 }
        usedNumbers.insert(candidate)
        return candidate
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
