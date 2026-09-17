import Testing
import Foundation
@testable import OzenKit

@Suite("QuietHours")
struct QuietHoursTests {
    @Test("off by default, and off means never quiet whatever the hours are")
    func offByDefault() {
        #expect(QuietHours.default.isEnabled == false)
        let hours = QuietHours(isEnabled: false, startHour: 22, endHour: 7)
        #expect(hours.isQuiet(now: 0, utcOffsetSeconds: 0) == false)
    }

    @Test("a window that wraps past midnight covers both sides of it")
    func wrapsPastMidnight() {
        let hours = QuietHours(isEnabled: true, startHour: 22, endHour: 7)
        // 1970-01-01 is a Thursday; timestamps are seconds since then, UTC.
        #expect(hours.isQuiet(now: 23 * 3_600, utcOffsetSeconds: 0))
        #expect(hours.isQuiet(now: 6 * 3_600, utcOffsetSeconds: 0))
        #expect(hours.isQuiet(now: 12 * 3_600, utcOffsetSeconds: 0) == false)
        #expect(hours.isQuiet(now: 7 * 3_600, utcOffsetSeconds: 0) == false)
        #expect(hours.isQuiet(now: 22 * 3_600, utcOffsetSeconds: 0))
    }

    @Test("a window within one day only covers that stretch")
    func sameDayWindow() {
        let hours = QuietHours(isEnabled: true, startHour: 13, endHour: 15)
        #expect(hours.isQuiet(now: 13 * 3_600, utcOffsetSeconds: 0))
        #expect(hours.isQuiet(now: 14 * 3_600, utcOffsetSeconds: 0))
        #expect(hours.isQuiet(now: 15 * 3_600, utcOffsetSeconds: 0) == false)
        #expect(hours.isQuiet(now: 12 * 3_600, utcOffsetSeconds: 0) == false)
    }

    @Test("equal start and end hours cover the whole day")
    func fullDayWindow() {
        let hours = QuietHours(isEnabled: true, startHour: 9, endHour: 9)
        #expect(hours.isQuiet(now: 0, utcOffsetSeconds: 0))
        #expect(hours.isQuiet(now: 20 * 3_600, utcOffsetSeconds: 0))
    }

    @Test("the timezone offset shifts which UTC hour counts as local")
    func timezoneOffset() {
        let hours = QuietHours(isEnabled: true, startHour: 22, endHour: 7)
        // 21:00 UTC is midnight in a +3h timezone: inside the window.
        #expect(hours.isQuiet(now: 21 * 3_600, utcOffsetSeconds: 3 * 3_600))
        // The same moment reads as 18:00 four hours further west: outside it.
        #expect(hours.isQuiet(now: 21 * 3_600, utcOffsetSeconds: -3 * 3_600) == false)
    }

    @Test("hours outside 0...23 are clamped, both from init and from decoding")
    func clampedHours() throws {
        let hours = QuietHours(isEnabled: true, startHour: -5, endHour: 99)
        #expect(hours.startHour == 0)
        #expect(hours.endHour == 23)

        let decoded = try JSONDecoder().decode(QuietHours.self, from: Data(#"{"isEnabled":true,"startHour":-1,"endHour":30}"#.utf8))
        #expect(decoded.startHour == 0)
        #expect(decoded.endHour == 23)
    }

    @Test("a settings file from before this existed decodes as off")
    func decodesMissingKeysAsOff() throws {
        let decoded = try JSONDecoder().decode(QuietHours.self, from: Data("{}".utf8))
        #expect(decoded == QuietHours.default)
    }
}
