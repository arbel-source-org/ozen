import Foundation

public struct PassTally: Sendable, Equatable {
    public private(set) var livePasses = 0
    public private(set) var finalPasses = 0
    public private(set) var liveSeconds = 0.0
    public private(set) var slowestLiveSeconds = 0.0
    public private(set) var lastLiveSeconds: Double?
    public private(set) var segmentsSeen = 0
    public private(set) var segmentsRejected = 0
    public private(set) var emptyFinalPasses = 0

    public init() {}

    public mutating func recordLivePass(seconds: Double) {
        livePasses += 1
        liveSeconds += seconds
        slowestLiveSeconds = max(slowestLiveSeconds, seconds)
        lastLiveSeconds = seconds
    }

    public mutating func recordFinalPass(cameBackEmpty: Bool) {
        finalPasses += 1
        if cameBackEmpty { emptyFinalPasses += 1 }
    }

    public mutating func recordSegments(seen: Int, accepted: Int) {
        segmentsSeen += seen
        segmentsRejected += max(0, seen - accepted)
    }

    public var summary: String {
        let average = livePasses > 0 ? String(format: "%.2f", liveSeconds / Double(livePasses)) : "-"
        let last = lastLiveSeconds.map { String(format: "%.2f", $0) } ?? "-"
        return "live passes \(livePasses) avg \(average)s slowest \(String(format: "%.2f", slowestLiveSeconds))s last \(last)s, final passes \(finalPasses) (\(emptyFinalPasses) empty), segments \(segmentsSeen) rejected by the filter \(segmentsRejected)"
    }
}
