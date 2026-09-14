import Foundation

/// Sounds she has alerts for that the classifier heard, but not surely
/// enough to raise one.
///
/// "The doorbell rang and nothing happened" has two very different
/// answers: the classifier never heard a doorbell, or it heard one at 45%
/// against the 60% an alert needs (the phone too far from the door, the
/// microphone's quiet raw signal). The diagnostics report lists these so a
/// real report can tell which.
public struct SoundNearMisses: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let identifier: String
        public var bestConfidence: Double
        public var lastHeardAt: TimeInterval
    }

    /// Sounds remembered at once; the one heard longest ago makes room.
    public static let limit = 12

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Notes `observation` if it's a catalog sound below `alertConfidence`.
    public mutating func record(_ observation: SoundObservation, alertConfidence: Double) {
        guard observation.confidence < alertConfidence,
              observation.confidence.isFinite,
              SoundEventCatalog.event(for: observation.identifier) != nil
        else { return }
        if let index = entries.firstIndex(where: { $0.identifier == observation.identifier }) {
            entries[index].bestConfidence = max(entries[index].bestConfidence, observation.confidence)
            entries[index].lastHeardAt = max(entries[index].lastHeardAt, observation.timestamp)
        } else {
            entries.append(Entry(identifier: observation.identifier, bestConfidence: observation.confidence, lastHeardAt: observation.timestamp))
            if entries.count > Self.limit, let oldest = entries.indices.min(by: { entries[$0].lastHeardAt < entries[$1].lastHeardAt }) {
                entries.remove(at: oldest)
            }
        }
    }

    /// Most recently heard first.
    public var recentFirst: [Entry] {
        entries.sorted { $0.lastHeardAt > $1.lastHeardAt }
    }

    /// "door_bell 45% 17:02:10, knock 38% 16:40:05", or nil when there are none.
    public func reportLine(utcOffsetSeconds: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        return recentFirst.map { entry in
            let percent = Int((entry.bestConfidence * 100).rounded())
            let time = TranscriptHistoryStore.formattedClockTime(entry.lastHeardAt, utcOffsetSeconds: utcOffsetSeconds)
            return "\(entry.identifier) \(percent)% \(time)"
        }.joined(separator: ", ")
    }
}
