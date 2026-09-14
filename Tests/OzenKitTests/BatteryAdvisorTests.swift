import Testing
@testable import OzenKit

@Suite("BatteryAdvisor")
struct BatteryAdvisorTests {
    /// Feeds a sequence of readings and returns the warnings produced.
    private func run(_ readings: [(Float?, Bool)], advisor: inout BatteryAdvisor) -> [BatteryWarning?] {
        readings.map { advisor.update(level: $0.0, isPluggedIn: $0.1) }
    }

    @Test("a draining phone gets one low warning and one critical warning, not one per percent")
    func drain() {
        var advisor = BatteryAdvisor()
        let levels: [Float] = [0.5, 0.25, 0.2, 0.19, 0.15, 0.11, 0.1, 0.09, 0.05]
        let warnings = run(levels.map { ($0, false) }, advisor: &advisor).compactMap { $0 }
        #expect(warnings == [.low(percent: 20), .critical(percent: 10)])
    }

    @Test("opening the app already at 8% goes straight to critical, with no stale low warning after")
    func startsCritical() {
        var advisor = BatteryAdvisor()
        let warnings = run([(0.08, false), (0.07, false), (0.06, false)], advisor: &advisor)
        #expect(warnings == [.critical(percent: 8), nil, nil])
    }

    @Test("charging silences warnings, and running down again after a charge warns again")
    func chargeCycle() {
        var advisor = BatteryAdvisor()
        _ = advisor.update(level: 0.18, isPluggedIn: false)
        #expect(advisor.update(level: 0.18, isPluggedIn: true) == nil)
        #expect(advisor.update(level: 0.6, isPluggedIn: true) == nil)
        #expect(advisor.update(level: 0.19, isPluggedIn: false) == .low(percent: 19))
    }

    @Test("a level flickering around the threshold doesn't nag")
    func hysteresis() {
        var advisor = BatteryAdvisor()
        let warnings = run([(0.2, false), (0.21, false), (0.2, false), (0.22, false), (0.19, false)], advisor: &advisor)
        #expect(warnings.compactMap { $0 } == [.low(percent: 20)])
        // Climbing clearly above the margin re-arms it.
        #expect(advisor.update(level: 0.3, isPluggedIn: false) == nil)
        #expect(advisor.update(level: 0.2, isPluggedIn: false) == .low(percent: 20))
    }

    @Test("an unknown battery level never warns")
    func unknown() {
        var advisor = BatteryAdvisor()
        #expect(advisor.update(level: nil, isPluggedIn: false) == nil)
        #expect(advisor.update(level: -1, isPluggedIn: false) == nil)
    }

    @Test("the phone notification names the level; the 10% one replaces the 20% one and is urgent")
    func notification() {
        let low = BatteryWarning.low(percent: 20).notificationContent
        let critical = BatteryWarning.critical(percent: 9).notificationContent
        #expect(low.title == "הסוללה ב-20%")
        #expect(critical.title == "הסוללה ב-9%")
        #expect(low.identifier == critical.identifier)
        #expect(!low.isUrgent && critical.isUrgent)
        #expect(low.body != critical.body)
    }
}
