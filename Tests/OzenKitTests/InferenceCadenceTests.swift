import Testing
@testable import OzenKit

@Suite("InferenceCadence")
struct InferenceCadenceTests {
    @Test("a cool phone refreshes the live text at the base rate")
    func cool() {
        #expect(InferenceCadence.secondsBetweenLivePasses(heat: .nominal, lowPowerMode: false, lastPassSeconds: 0.2) == InferenceCadence.baseSeconds)
        #expect(InferenceCadence.secondsBetweenLivePasses(heat: .fair, lowPowerMode: false, lastPassSeconds: nil) == InferenceCadence.baseSeconds)
    }

    @Test("the hotter the phone, the slower the live preview")
    func heatSlowsDown() {
        let intervals = DeviceHeat.allCases.map {
            InferenceCadence.secondsBetweenLivePasses(heat: $0, lowPowerMode: false, lastPassSeconds: nil)
        }
        #expect(intervals == intervals.sorted())
        #expect(intervals[DeviceHeat.serious.rawValue] > InferenceCadence.baseSeconds)
        #expect(intervals[DeviceHeat.critical.rawValue] > intervals[DeviceHeat.serious.rawValue])
    }

    @Test("Low Power Mode slows a cool phone but never speeds up a hot one")
    func lowPower() {
        let coolSaver = InferenceCadence.secondsBetweenLivePasses(heat: .nominal, lowPowerMode: true, lastPassSeconds: nil)
        #expect(coolSaver > InferenceCadence.baseSeconds)
        let critical = InferenceCadence.secondsBetweenLivePasses(heat: .critical, lowPowerMode: false, lastPassSeconds: nil)
        let criticalSaver = InferenceCadence.secondsBetweenLivePasses(heat: .critical, lowPowerMode: true, lastPassSeconds: nil)
        #expect(criticalSaver == critical)
    }

    @Test("a pass that took longer than the interval doubles it, so an actual rest follows a slow pass")
    func slowPass() {
        // The interval is measured from one pass's start to the next's
        // (see InferenceCadence's own comment): since audio keeps arriving
        // for the whole lastPassSeconds a pass takes, only double that
        // leaves any rest after the pass actually finishes.
        #expect(InferenceCadence.secondsBetweenLivePasses(heat: .nominal, lowPowerMode: false, lastPassSeconds: 1.7) == 3.4)
    }

    @Test("a nonsense pass duration is ignored")
    func badDuration() {
        #expect(InferenceCadence.secondsBetweenLivePasses(heat: .nominal, lowPowerMode: false, lastPassSeconds: .infinity) == InferenceCadence.baseSeconds)
        #expect(InferenceCadence.secondsBetweenLivePasses(heat: .nominal, lowPowerMode: false, lastPassSeconds: -3) == InferenceCadence.baseSeconds)
    }
}
