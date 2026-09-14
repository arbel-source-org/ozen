import Foundation

struct CivilDate: Equatable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(daysSinceEpoch days: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        day = dayOfYear - (153 * mp + 2) / 5 + 1
        month = mp < 10 ? mp + 3 : mp - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    static func localDay(of timestamp: TimeInterval, utcOffsetSeconds: Int) -> Int {
        let days = ((timestamp.rounded(.down) + Double(utcOffsetSeconds)) / 86_400).rounded(.down)
        guard days.isFinite, abs(days) < 1e12 else { return 0 }
        return Int(days)
    }

    static func weekday(ofDay day: Int) -> Int {
        ((day + 4) % 7 + 7) % 7
    }
}
