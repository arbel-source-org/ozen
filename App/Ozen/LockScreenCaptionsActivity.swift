import ActivityKit
import Foundation
import OzenKit

/// The Live Activity itself (see `CaptionActivityAttributes`).
///
/// Only the activity's id is kept, and every call on ActivityKit happens in
/// a nonisolated function that looks the activity up by it: an `Activity`
/// isn't `Sendable`, and handing one from the main actor to its own async
/// methods is what strict concurrency checking refuses.
@MainActor
final class LockScreenCaptionsActivity: LockScreenCaptionsDisplaying {
    /// Updates carry a stale date this far ahead, and the lines are sent
    /// again well before it (`LockScreenCaptionsCoordinator`): if iOS closes the app, the lock
    /// screen then says the captions stopped updating instead of showing an
    /// old sentence as if it were just said.
    static let staleAfterSeconds: TimeInterval = 120

    private var activityID: String?
    private(set) var lastStartFailure: String?

    init() {
        // One left from a previous run (the app was closed while it
        // showed) would sit on the lock screen with that run's last lines.
        // Which ones is read here, before anything can start a new one: read
        // later, in the task, the list could include the one the first
        // `show` just started.
        let leftovers = Activity<CaptionActivityAttributes>.activities.map(\.id)
        guard !leftovers.isEmpty else { return }
        Task.detached { await Self.end(ids: leftovers) }
    }

    var isAllowedBySystem: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    @discardableResult
    func show(_ content: LockScreenCaptionContent, mayStart: Bool) -> Bool {
        let state = CaptionActivityAttributes.ContentState(
            lines: content.lines.map {
                CaptionActivityAttributes.ContentState.Line(speaker: $0.speaker, text: $0.text, isFinal: $0.isFinal)
            },
            status: content.status,
            large: content.textSize == .large
        )
        let staleDate = Date().addingTimeInterval(Self.staleAfterSeconds)
        if let activityID, Self.isRunning(id: activityID) {
            Task.detached { await Self.update(id: activityID, state: state, staleDate: staleDate) }
            return true
        }
        // Ended by iOS (they last eight hours) or swiped away.
        activityID = nil
        guard mayStart, isAllowedBySystem else { return false }
        do {
            activityID = try Self.start(state: state, staleDate: staleDate)
            return true
        } catch {
            let time = TranscriptHistoryStore.formattedClockTime(
                Date().timeIntervalSince1970,
                utcOffsetSeconds: TimeZone.current.secondsFromGMT()
            )
            lastStartFailure = "\(time) \(error)"
            return false
        }
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        Task.detached { await Self.end(ids: [activityID]) }
    }

    private nonisolated static func isRunning(id: String) -> Bool {
        Activity<CaptionActivityAttributes>.activities.contains {
            $0.id == id && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    private nonisolated static func start(state: CaptionActivityAttributes.ContentState, staleDate: Date) throws -> String {
        let content = ActivityContent(state: state, staleDate: staleDate)
        return try Activity.request(attributes: CaptionActivityAttributes(), content: content, pushType: nil).id
    }

    private nonisolated static func update(id: String, state: CaptionActivityAttributes.ContentState, staleDate: Date) async {
        guard let activity = Activity<CaptionActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    /// Ends the activities with these ids.
    private nonisolated static func end(ids: [String]) async {
        for activity in Activity<CaptionActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
