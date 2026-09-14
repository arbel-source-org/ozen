import Foundation
import OzenKit

extension HistoryDays {
    static func localOffset(at time: TimeInterval) -> Int {
        TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: time))
    }

    static func heading(startedAt: TimeInterval) -> String {
        let day = title(of: startedAt, now: Date().timeIntervalSince1970, utcOffsetSeconds: localOffset)
        return "\(day) בשעה \(Date(timeIntervalSince1970: startedAt).formatted(date: .omitted, time: .shortened))"
    }
}
