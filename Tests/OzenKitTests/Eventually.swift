import Foundation

/// Checks `condition` on the main actor until it holds or `timeout` passes, and
/// says whether it held. Every caller waits for something that happens within
/// milliseconds, so a passing test never gets near the ceiling; it is generous
/// because a CI simulator running hundreds of tests in parallel can take whole
/// seconds to get to a background task, and a short one failed a test that way.
///
/// Lives with the portable tests so both `swift test` and the app's test
/// bundle, which compiles these files too, share this one definition.
@MainActor
@discardableResult
func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
