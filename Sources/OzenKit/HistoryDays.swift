import Foundation

public struct HistoryDay: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public var sessions: [TranscriptSessionSummary]
}

public enum HistoryDays {
    public static func grouped(
        _ sessions: [TranscriptSessionSummary],
        now: TimeInterval,
        utcOffsetSeconds: (TimeInterval) -> Int
    ) -> [HistoryDay] {
        let today = CivilDate.localDay(of: now, utcOffsetSeconds: utcOffsetSeconds(now))
        var days: [HistoryDay] = []
        var indexOfDay: [Int: Int] = [:]
        for session in sessions {
            let day = CivilDate.localDay(of: session.startedAt, utcOffsetSeconds: utcOffsetSeconds(session.startedAt))
            if let index = indexOfDay[day] {
                days[index].sessions.append(session)
            } else {
                indexOfDay[day] = days.count
                days.append(HistoryDay(id: day, title: title(day: day, today: today), sessions: [session]))
            }
        }
        return days
    }

    public static func title(day: Int, today: Int) -> String {
        let weekday = "יום \(weekdayNames[CivilDate.weekday(ofDay: day)])"
        switch today - day {
        case 0: return "היום"
        case 1: return "אתמול"
        case 2...6: return weekday
        default:
            let date = CivilDate(daysSinceEpoch: day)
            let year = date.year == CivilDate(daysSinceEpoch: today).year ? "" : " \(date.year)"
            return "\(weekday), \(date.day) ב\(monthNames[date.month - 1])\(year)"
        }
    }

    private static let weekdayNames = ["ראשון", "שני", "שלישי", "רביעי", "חמישי", "שישי", "שבת"]
    private static let monthNames = ["ינואר", "פברואר", "מרץ", "אפריל", "מאי", "יוני", "יולי", "אוגוסט", "ספטמבר", "אוקטובר", "נובמבר", "דצמבר"]
}
