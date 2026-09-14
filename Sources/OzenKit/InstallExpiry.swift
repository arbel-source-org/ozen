import Foundation

/// When a sideloaded install stops opening, and how to say so in time.
///
/// Installed with a free Apple ID, Ozen stops opening seven days after it
/// was installed, without a word: one morning the icon doesn't open, and
/// captions are gone until someone with a computer installs it again. The
/// date is in the provisioning profile iOS keeps inside the app, so the
/// app can warn a couple of days ahead, while there is still time to plan
/// a visit.
public enum InstallExpiry {
    /// The caption screen starts warning this long before expiry.
    public static let warnAheadSeconds: TimeInterval = 2 * 86_400
    /// A reminder notification goes out at least this long before expiry.
    public static let reminderAheadSeconds: TimeInterval = 24 * 3_600
    /// Local hours a reminder may go out in: not in the night.
    public static let reminderHours = 9..<20

    /// The expiry date in a provisioning profile (`embedded.mobileprovision`):
    /// a signed envelope with an XML property list inside. Nil for anything
    /// else; App Store and TestFlight installs carry no profile at all.
    public static func expirationDate(inProvisioningProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
        else { return nil }
        let xml = Data(data[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }

    /// Whether the caption screen should warn now.
    public static func shouldWarn(expiresAt: Date, now: Date) -> Bool {
        let left = expiresAt.timeIntervalSince(now)
        return left > 0 && left <= warnAheadSeconds
    }

    /// When to post the reminder: the latest daytime moment at least a day
    /// before expiry, or nil when that moment has already passed (the
    /// caption screen is warning by then anyway).
    public static func reminderDate(expiresAt: Date, now: Date, utcOffsetSeconds: Int) -> Date? {
        let latest = expiresAt.timeIntervalSince1970 - reminderAheadSeconds
        let local = latest + Double(utcOffsetSeconds)
        let dayStart = (local / 86_400).rounded(.down) * 86_400
        let hour = Int((local - dayStart) / 3_600)
        let chosenLocal: Double
        if reminderHours.contains(hour) {
            chosenLocal = local
        } else if hour >= reminderHours.upperBound {
            // Evening: the last daytime minute of that day.
            chosenLocal = dayStart + Double(reminderHours.upperBound) * 3_600 - 60
        } else {
            // Night or early morning: the evening before.
            chosenLocal = dayStart - 86_400 + Double(reminderHours.upperBound) * 3_600 - 60
        }
        let chosen = Date(timeIntervalSince1970: chosenLocal - Double(utcOffsetSeconds))
        return chosen > now ? chosen : nil
    }

    /// When it stops opening, as she'd say it, seen from `now`: "hayom besha'a
    /// 10:30" ("today at 10:30"), "machar besha'a 10:30" ("tomorrow at 10:30")
    /// or "beyom shlishi besha'a 10:30" ("on Tuesday at 10:30").
    public static func whenText(expiresAt: Date, now: Date, utcOffsetSeconds: Int) -> String {
        let expiryLocal = Int(expiresAt.timeIntervalSince1970.rounded(.down)) + utcOffsetSeconds
        let nowLocal = Int(now.timeIntervalSince1970.rounded(.down)) + utcOffsetSeconds
        let expiryDay = expiryLocal / 86_400
        let today = nowLocal / 86_400
        let secondsIntoDay = expiryLocal - expiryDay * 86_400
        let time = String(format: "%02d:%02d", secondsIntoDay / 3_600, secondsIntoDay % 3_600 / 60)
        if Localization.language == .english {
            switch expiryDay - today {
            case 0: return "today at \(time)"
            case 1: return "tomorrow at \(time)"
            default:
                let weekday = (expiryDay + 4) % 7
                return "on \(englishWeekdayNames[weekday]) at \(time)"
            }
        }
        switch expiryDay - today {
        case 0: return "היום בשעה \(time)"
        case 1: return "מחר בשעה \(time)"
        default:
            // Day 0 of the Unix epoch was a Thursday.
            let weekday = (expiryDay + 4) % 7
            return "ביום \(weekdayNames[weekday]) בשעה \(time)"
        }
    }

    public static let reminderIdentifier = "install-expiry"

    /// The warning on the caption screen, as seen from `now`.
    public static func warningTitle(expiresAt: Date, now: Date, utcOffsetSeconds: Int) -> String {
        let when = whenText(expiresAt: expiresAt, now: now, utcOffsetSeconds: utcOffsetSeconds)
        return tr("אוזן תפסיק להיפתח \(when)", "Ozen will stop opening \(when)")
    }

    public static var warningDetail: String {
        tr(
            "צריך להתקין אותה מחדש מהמחשב לפני כן, כדי שהכתוביות לא ייעלמו.",
            "It needs to be reinstalled from a computer before then, so captions don't disappear."
        )
    }

    /// The reminder notification, worded for the moment it is delivered
    /// rather than the moment it was scheduled, so "machar" ("tomorrow")
    /// means tomorrow.
    public static func reminderContent(expiresAt: Date, remindAt: Date, utcOffsetSeconds: Int) -> AlertNotificationContent {
        AlertNotificationContent(
            identifier: reminderIdentifier,
            title: warningTitle(expiresAt: expiresAt, now: remindAt, utcOffsetSeconds: utcOffsetSeconds),
            body: warningDetail,
            threadIdentifier: "status",
            isUrgent: true
        )
    }

    private static let weekdayNames = ["ראשון", "שני", "שלישי", "רביעי", "חמישי", "שישי", "שבת"]
    private static let englishWeekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}
