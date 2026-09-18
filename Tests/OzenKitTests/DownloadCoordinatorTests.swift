import Foundation
import Testing
@testable import OzenKit

/// Counts calls and can be awaited up to a threshold, so a test can prove a
/// second `run(for:_:)` call was issued only after the first's operation had
/// genuinely started -- no sleep-based guessing about scheduling order.
private actor Counter {
    private(set) var value = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func increment() {
        value += 1
        waiters.removeAll { threshold, continuation in
            guard value >= threshold else { return false }
            continuation.resume()
            return true
        }
    }

    func waitUntilAtLeast(_ threshold: Int) async {
        if value >= threshold { return }
        await withCheckedContinuation { waiters.append((threshold, $0)) }
    }
}

/// Lets a test hold an in-flight operation open until every caller meant to
/// join it has actually joined, then release them all at once.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct Failure: Error, Equatable {}

@Suite("DownloadCoordinator")
struct DownloadCoordinatorTests {
    @Test("a second call for the same URL joins the first instead of running its own operation")
    func joinsInFlight() async throws {
        let coordinator = DownloadCoordinator()
        let url = URL(fileURLWithPath: "/tmp/ozen-test/model-a")
        let runs = Counter()
        let gate = Gate()

        async let first: URL = coordinator.run(for: url) {
            await runs.increment()
            await gate.wait()
            return url
        }
        // Only issue the second call once the first's operation has
        // genuinely started, so it's guaranteed to find it already
        // in flight rather than racing to register its own.
        await runs.waitUntilAtLeast(1)
        async let second: URL = coordinator.run(for: url) {
            await runs.increment()
            return url
        }
        // `async let` only starts the second call; opening the gate before
        // it has reached the coordinator lets the first finish, and the
        // second then rightly runs an operation of its own.
        while await coordinator.joinCount < 1 { await Task.yield() }
        await gate.open()

        let (a, b) = try await (first, second)
        #expect(a == url)
        #expect(b == url)
        #expect(await runs.value == 1)
    }

    @Test("calls for different URLs never wait on each other")
    func independentURLsRunConcurrently() async throws {
        let coordinator = DownloadCoordinator()
        let urlA = URL(fileURLWithPath: "/tmp/ozen-test/model-a")
        let urlB = URL(fileURLWithPath: "/tmp/ozen-test/model-b")
        let runs = Counter()
        let gateA = Gate()

        // If B's call had to wait on A's coordinator-wide, this would
        // deadlock: A never opens its gate until B's run is observed.
        async let a: URL = coordinator.run(for: urlA) {
            await runs.increment()
            await gateA.wait()
            return urlA
        }
        await runs.waitUntilAtLeast(1)
        let b = try await coordinator.run(for: urlB) {
            await runs.increment()
            return urlB
        }
        #expect(b == urlB)
        await gateA.open()
        #expect(try await a == urlA)
        #expect(await runs.value == 2)
    }

    @Test("a later call for the same URL, after the first finished, runs its own fresh operation")
    func startsFreshOnceThePriorCallFinished() async throws {
        let coordinator = DownloadCoordinator()
        let url = URL(fileURLWithPath: "/tmp/ozen-test/model-a")
        let runs = Counter()

        _ = try await coordinator.run(for: url) {
            await runs.increment()
            return url
        }
        _ = try await coordinator.run(for: url) {
            await runs.increment()
            return url
        }
        #expect(await runs.value == 2)
    }

    @Test("a joining caller sees the same failure the running operation threw, and a later call gets a fresh attempt")
    func propagatesFailureAndRecovers() async throws {
        let coordinator = DownloadCoordinator()
        let url = URL(fileURLWithPath: "/tmp/ozen-test/model-a")
        let runs = Counter()
        let gate = Gate()

        async let first: URL = coordinator.run(for: url) {
            await runs.increment()
            await gate.wait()
            throw Failure()
        }
        await runs.waitUntilAtLeast(1)
        async let second: URL = coordinator.run(for: url) {
            await runs.increment()
            return url
        }
        while await coordinator.joinCount < 1 { await Task.yield() }
        await gate.open()

        // #expect(throws:) can't capture an `async let` binding directly,
        // so each result is caught by hand instead.
        var firstError: (any Error)?
        do { _ = try await first } catch { firstError = error }
        var secondError: (any Error)?
        do { _ = try await second } catch { secondError = error }
        #expect(firstError is Failure)
        #expect(secondError is Failure)
        #expect(await runs.value == 1)

        // The failed attempt must not be remembered: a retry for the same
        // URL should try again, not replay the old failure forever.
        let recovered = try await coordinator.run(for: url) {
            await runs.increment()
            return url
        }
        #expect(recovered == url)
        #expect(await runs.value == 2)
    }
}
