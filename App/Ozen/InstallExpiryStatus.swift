import Foundation
import Observation
import OzenKit

/// When this install stops opening (see `InstallExpiry`), read once from
/// the provisioning profile inside the app, with a reminder notification
/// scheduled for the day before. Nil on the simulator and for any install
/// that doesn't expire.
@MainActor
@Observable
final class InstallExpiryStatus {
    static let shared = InstallExpiryStatus()

    private(set) var expiresAt: Date?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var hasRead = false

    /// Reads the profile the first time; later calls wait for that read.
    func load() async {
        if loading == nil {
            loading = Task {
                let date = await Task.detached(priority: .utility) { Self.readProfile() }.value
                expiresAt = date
                hasRead = true
                scheduleReminder(expiresAt: date)
            }
        }
        await loading?.value
    }

    /// Schedules the reminder again, e.g. when the app comes back on
    /// screen. The first time round notifications may not have been allowed
    /// yet (the walkthrough asks later), and with background listening the
    /// app can stay running for the whole week without another launch.
    func refreshReminder() {
        // Before the profile has been read there is nothing to schedule,
        // and nothing old to cancel either.
        guard hasRead else { return }
        scheduleReminder(expiresAt: expiresAt)
    }

    private func scheduleReminder(expiresAt: Date?) {
        // The local clock as it will be then: a daylight-saving change can
        // fall inside the week.
        let offset = expiresAt.map { TimeZone.current.secondsFromGMT(for: $0) } ?? 0
        guard let expiresAt,
              let remindAt = InstallExpiry.reminderDate(expiresAt: expiresAt, now: Date(), utcOffsetSeconds: offset)
        else {
            // Reinstalled with a profile that no longer needs one, or too
            // late for it: don't leave an old reminder waiting.
            AlertNotifier.shared.cancelScheduled(identifier: InstallExpiry.reminderIdentifier)
            return
        }
        let content = InstallExpiry.reminderContent(expiresAt: expiresAt, remindAt: remindAt, utcOffsetSeconds: offset)
        AlertNotifier.shared.schedule(content, at: remindAt)
    }

    private nonisolated static func readProfile() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return InstallExpiry.expirationDate(inProvisioningProfile: data)
    }
}
