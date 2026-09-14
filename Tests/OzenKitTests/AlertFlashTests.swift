import Foundation
import Testing
@testable import OzenKit

@Suite("AlertFlash")
struct AlertFlashTests {
    @Test("safety sounds flash longest, the door briefly, everyday sounds not at all")
    func byImportance() throws {
        let critical = try #require(AlertFlash.pattern(for: .critical, reduceMotion: false))
        let high = try #require(AlertFlash.pattern(for: .high, reduceMotion: false))
        #expect(critical.count > high.count)
        #expect(high.count >= 2)
        #expect(AlertFlash.pattern(for: .medium, reduceMotion: false) == nil)
        #expect(AlertFlash.pattern(for: .low, reduceMotion: true) == nil)
    }

    @Test("no pattern blinks fast enough to risk a seizure")
    func slowEnough() {
        for importance in SoundEvent.Importance.allCases {
            for reduceMotion in [false, true] {
                guard let flash = AlertFlash.pattern(for: importance, reduceMotion: reduceMotion) else { continue }
                #expect(flash.flashesPerSecond < AlertFlash.maximumFlashesPerSecond, "\(importance) reduceMotion=\(reduceMotion)")
                #expect(flash.litSeconds > 0)
            }
        }
    }

    @Test("with Reduce Motion the edge lights once instead of blinking, for about as long")
    func reduceMotion() throws {
        for importance in [SoundEvent.Importance.critical, .high] {
            let blinking = try #require(AlertFlash.pattern(for: importance, reduceMotion: false))
            let steady = try #require(AlertFlash.pattern(for: importance, reduceMotion: true))
            #expect(steady.count == 1)
            let blinkingSeconds = Double(blinking.count) * (blinking.litSeconds + blinking.darkSeconds)
            #expect(abs(steady.litSeconds - blinkingSeconds) <= 1)
        }
    }
}
