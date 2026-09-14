import Foundation

/// Something that happened to the captions worth knowing about afterwards.
public struct PipelineEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case failed(PipelineFailure)
        case retryScheduled(attempt: Int, afterSeconds: Double)
        case listening
        case microphoneStalled
        case phoneCall(began: Bool)
        /// iOS said memory is running out; it ends the biggest apps next.
        case memoryWarning(footprintMegabytes: Int?)
    }

    public let at: TimeInterval
    public let kind: Kind

    public init(at: TimeInterval, kind: Kind) {
        self.at = at
        self.kind = kind
    }

    /// One line of the diagnostics report, in plain English for whoever
    /// is helping: "14:02:07 failed: audioSessionFailed (…)".
    public func reportLine(utcOffsetSeconds: Int) -> String {
        let time = TranscriptHistoryStore.formattedClockTime(at, utcOffsetSeconds: utcOffsetSeconds)
        return "\(time) \(description)"
    }

    var description: String {
        switch kind {
        case .failed(let failure):
            var text = "failed: \(failure.kind.rawValue)"
            if let why = failure.engineUnavailability {
                text += "/\(why.kind.rawValue)"
            }
            let detail = failure.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                text += " (\(PipelineEventLog.clipped(detail)))"
            }
            return text
        case .retryScheduled(let attempt, let seconds):
            return "retry \(attempt) in \(Int(seconds.rounded()))s"
        case .listening:
            return "listening"
        case .microphoneStalled:
            return "microphone stopped delivering audio"
        case .phoneCall(let began):
            return began ? "audio taken by a call or another app" : "audio given back"
        case .memoryWarning(let megabytes):
            return "iOS low on memory" + (megabytes.map { " (app using \($0) MB)" } ?? "")
        }
    }
}

/// The last few things that happened to the captions, newest last.
///
/// The counters on the diagnostics screen say how often something went
/// wrong; they don't say what, when, or in what order. When she calls to
/// say "it stopped at lunch", this is the part of the copied report that
/// answers it: the microphone stalled at 12:41, a retry was scheduled,
/// captions were back at 12:41:05.
public struct PipelineEventLog: Sendable, Equatable {
    public static let capacity = 40
    static let detailLimit = 160

    public private(set) var events: [PipelineEvent] = []

    public init() {}

    public mutating func record(_ kind: PipelineEvent.Kind, at time: TimeInterval) {
        // "Listening" after "listening" (a pause and resume) says nothing.
        if case .listening = kind, case .listening? = events.last?.kind { return }
        events.append(PipelineEvent(at: time, kind: kind))
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    public func reportLines(utcOffsetSeconds: Int) -> [String] {
        events.map { $0.reportLine(utcOffsetSeconds: utcOffsetSeconds) }
    }

    /// Error text from the system can run to paragraphs; the start says
    /// what it was.
    static func clipped(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > detailLimit else { return singleLine }
        return String(singleLine.prefix(detailLimit)) + "…"
    }
}
