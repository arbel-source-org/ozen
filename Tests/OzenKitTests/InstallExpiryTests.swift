import Foundation
import Testing
@testable import OzenKit

@Suite("InstallExpiry")
struct InstallExpiryTests {
    /// Israel in September: UTC+3.
    private let israel = 3 * 3_600

    /// 14 September 2026 (a Monday), at the given local time in Israel.
    private func monday(_ hour: Int, _ minute: Int = 0, plusDays days: Int = 0) -> Date {
        let midnightUTC: TimeInterval = 1_789_344_000
        return Date(timeIntervalSince1970: midnightUTC + Double(days * 86_400 + hour * 3_600 + minute * 60 - israel))
    }

    private func profile(expiring date: String) -> Data {
        // A real profile wraps the property list in binary signature data.
        var data = Data([0x30, 0x82, 0x3C, 0x3F, 0x00, 0xFF, 0x06, 0x09])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key>
            <string>Ozen</string>
            <key>CreationDate</key>
            <date>2026-09-14T04:24:00Z</date>
            <key>ExpirationDate</key>
            <date>\(date)</date>
            <key>TimeToLive</key>
            <integer>7</integer>
        </dict>
        </plist>
        """.utf8))
        data.append(Data([0xA0, 0x82, 0x0B, 0x3C, 0x2F, 0x00]))
        return data
    }

    @Test("the expiry date is read out of the signed profile")
    func readsProfile() {
        let date = InstallExpiry.expirationDate(inProvisioningProfile: profile(expiring: "2026-09-21T04:24:00Z"))
        #expect(date == Date(timeIntervalSince1970: 1_789_964_640))
    }

    @Test("anything that isn't a profile has no expiry")
    func notAProfile() {
        #expect(InstallExpiry.expirationDate(inProvisioningProfile: Data()) == nil)
        #expect(InstallExpiry.expirationDate(inProvisioningProfile: Data([0x30, 0x82, 0x00])) == nil)
        #expect(InstallExpiry.expirationDate(inProvisioningProfile: Data("<?xml version=\"1.0\"?><plist><dict>".utf8)) == nil)
        let withoutDate = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>AppIDName</key><string>Ozen</string></dict></plist>".utf8)
        #expect(InstallExpiry.expirationDate(inProvisioningProfile: withoutDate) == nil)
    }

    @Test("the screen warns only in the last two days")
    func warningWindow() {
        let expiry = monday(10, 30, plusDays: 7)
        #expect(InstallExpiry.shouldWarn(expiresAt: expiry, now: monday(10, 29, plusDays: 5)) == false)
        #expect(InstallExpiry.shouldWarn(expiresAt: expiry, now: monday(10, 30, plusDays: 5)))
        #expect(InstallExpiry.shouldWarn(expiresAt: expiry, now: monday(10, 29, plusDays: 7)))
        #expect(InstallExpiry.shouldWarn(expiresAt: expiry, now: monday(10, 30, plusDays: 7)) == false)
    }

    @Test("when it stops opening reads as today, tomorrow, or the day of the week")
    func wording() {
        let now = monday(9)
        #expect(InstallExpiry.whenText(expiresAt: monday(22, 5), now: now, utcOffsetSeconds: israel) == "היום בשעה 22:05")
        #expect(InstallExpiry.whenText(expiresAt: monday(0, 30, plusDays: 1), now: now, utcOffsetSeconds: israel) == "מחר בשעה 00:30")
        #expect(InstallExpiry.whenText(expiresAt: monday(7, 24, plusDays: 2), now: now, utcOffsetSeconds: israel) == "ביום רביעי בשעה 07:24")
        #expect(InstallExpiry.whenText(expiresAt: monday(7, 24, plusDays: 6), now: now, utcOffsetSeconds: israel) == "ביום ראשון בשעה 07:24")
        #expect(InstallExpiry.whenText(expiresAt: monday(7, 24, plusDays: 5), now: now, utcOffsetSeconds: israel) == "ביום שבת בשעה 07:24")
        // Midnight UTC is already 03:00 the same day in Israel.
        #expect(InstallExpiry.whenText(expiresAt: Date(timeIntervalSince1970: 1_789_344_000), now: now, utcOffsetSeconds: israel) == "היום בשעה 03:00")
    }

    @Test("the reminder goes out a day ahead, moved out of the night")
    func reminder() {
        let now = monday(8)
        // Expires Monday next week at 14:00: remind Sunday at 14:00.
        #expect(InstallExpiry.reminderDate(expiresAt: monday(14, plusDays: 7), now: now, utcOffsetSeconds: israel) == monday(14, plusDays: 6))
        // Expires at 07:24: a day before is 07:24, too early; the evening before that instead.
        #expect(InstallExpiry.reminderDate(expiresAt: monday(7, 24, plusDays: 7), now: now, utcOffsetSeconds: israel) == monday(19, 59, plusDays: 5))
        // Expires at 23:00: a day before is 23:00, too late; that evening, earlier.
        #expect(InstallExpiry.reminderDate(expiresAt: monday(23, plusDays: 7), now: now, utcOffsetSeconds: israel) == monday(19, 59, plusDays: 6))
        // Already inside the last day: nothing to schedule.
        #expect(InstallExpiry.reminderDate(expiresAt: monday(20), now: now, utcOffsetSeconds: israel) == nil)
    }

    @Test("the reminder is worded for when it arrives, not when it was scheduled")
    func reminderWording() {
        let expiry = monday(7, 24, plusDays: 7)
        let content = InstallExpiry.reminderContent(expiresAt: expiry, remindAt: monday(19, 59, plusDays: 5), utcOffsetSeconds: israel)
        // Delivered on Saturday evening, two days ahead: named by weekday.
        #expect(content.title == "אוזן תפסיק להיפתח ביום שני בשעה 07:24")
        #expect(content.identifier == InstallExpiry.reminderIdentifier)
        #expect(content.body == InstallExpiry.warningDetail)

        let dayBefore = InstallExpiry.reminderContent(expiresAt: expiry, remindAt: monday(12, plusDays: 6), utcOffsetSeconds: israel)
        #expect(dayBefore.title == "אוזן תפסיק להיפתח מחר בשעה 07:24")
    }

    @Test("a reminder is always in daytime and at least a day before expiry")
    func reminderInvariants() {
        let now = monday(0)
        for minutes in stride(from: 0, to: 24 * 60, by: 7) {
            let expiry = monday(0, minutes, plusDays: 7)
            guard let reminder = InstallExpiry.reminderDate(expiresAt: expiry, now: now, utcOffsetSeconds: israel) else {
                Issue.record("no reminder for an expiry a week away")
                continue
            }
            let localSeconds = (Int(reminder.timeIntervalSince1970) + israel) % 86_400
            #expect(InstallExpiry.reminderHours.contains(localSeconds / 3_600))
            let ahead = expiry.timeIntervalSince(reminder)
            #expect(ahead >= InstallExpiry.reminderAheadSeconds)
            #expect(ahead < InstallExpiry.reminderAheadSeconds + 14 * 3_600)
        }
    }
}
