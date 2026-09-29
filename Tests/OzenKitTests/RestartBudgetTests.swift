import Testing
@testable import OzenKit

@Suite("Restarting something that keeps failing")
struct RestartBudgetTests {
    private func answers(_ budget: inout RestartBudget, at times: [Double]) -> [Bool] {
        times.map { budget.spend(at: $0) }
    }

    @Test("allows the limit within the window, then refuses")
    func limitWithinWindow() {
        var budget = RestartBudget(limit: 3, windowSeconds: 600)
        #expect(answers(&budget, at: [0, 10, 20, 30, 599]) == [true, true, true, false, false])
    }

    @Test("a bad patch early in the evening doesn't use up restarts for good")
    func recoversAfterTheWindow() {
        var budget = RestartBudget(limit: 5, windowSeconds: 600)
        #expect(answers(&budget, at: [0, 1, 2, 3, 4, 300, 600, 601, 601.5])
            == [true, true, true, true, true, false, true, true, false])
    }

    @Test("a rough patch of a few seconds doesn't spend every restart at once")
    func spacedAttempts() {
        var budget = RestartBudget(limit: 5, windowSeconds: 600, minimumSpacingSeconds: 15)
        let patch = stride(from: 0.0, through: 2.0, by: 0.05).map { $0 }
        #expect(answers(&budget, at: patch).filter { $0 }.count == 1)
        #expect(answers(&budget, at: [14.9, 15, 20, 30]) == [false, true, false, true])
    }

    @Test("a clock that jumped backwards doesn't block restarts")
    func clockJumpBack() {
        var budget = RestartBudget(limit: 2, windowSeconds: 600)
        #expect(answers(&budget, at: [5_000, 5_001, 100]) == [true, true, true])
    }

    @Test("a limit of zero never restarts")
    func zeroLimit() {
        var budget = RestartBudget(limit: 0, windowSeconds: 600)
        #expect(answers(&budget, at: [0, 10_000]) == [false, false])
    }
}
