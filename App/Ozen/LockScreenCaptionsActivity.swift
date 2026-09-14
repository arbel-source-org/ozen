import ActivityKit
import Foundation
import OzenKit

/// Where the view model sends the lock screen's caption lines. A protocol
/// so tests can see what would be shown without ActivityKit.
@MainActor
public protocol LockScreenCaptionsDisplaying: AnyObject {
    /// Shows `content`, starting the Live Activity if none is running and
    /// `mayStart` (iOS only lets an app start one while it is in front).
    /// Returns whether it is on the lock screen now.
    @discardableResult
    func show(_ content: LockScreenCaptionContent, mayStart: Bool) -> Bool
    func end()
}

/// The Live Activity itself (see `CaptionActivityAttributes`).
///
/// Only the activity's id is kept, and every call on ActivityKit happens in
/// a nonisolated function that looks the activity up by it: an `Activity`
/// isn't `Sendable`, and handing one from the main actor to its own async
/// methods is what strict concurrency checking refuses.
@MainActor
final class LockScreenCaptionsActivity: LockScreenCaptionsDisplaying {
    /// Updates carry a stale date this far ahead, and the view model sends
    /// the lines again well before it: if iOS closes the app, the lock
    /// screen then says the captions stopped updating instead of showing an
    /// old sentence as if it were just said.
    static let staleAfterSeconds: TimeInterval = 120

    private var activityID: String?

    init() {
        // One left from a previous run (the app was closed while it
        // showed) would sit on the lock screen with that run's last lines.
        Task.detached { await Self.end(id: nil) }
    }

    @discardableResult
    func show(_ content: LockScreenCaptionContent, mayStart: Bool) -> Bool {
        let state = CaptionActivityAttributes.ContentState(
            lines: content.lines.map {
                CaptionActivityAttributes.ContentState.Line(speaker: $0.speaker, text: $0.text, isFinal: $0.isFinal)
            },
            status: content.status
        )
        let staleDate = Date().addingTimeInterval(Self.staleAfterSeconds)
        if let activityID, Self.isRunning(id: activityID) {
            Task.detached { await Self.update(id: activityID, state: state, staleDate: staleDate) }
            return true
        }
        // Ended by iOS (they last eight hours) or swiped away.
        activityID = nil
        guard mayStart, ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        activityID = Self.start(state: state, staleDate: staleDate)
        return activityID != nil
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        Task.detached { await Self.end(id: activityID) }
    }

    private nonisolated static func isRunning(id: String) -> Bool {
        Activity<CaptionActivityAttributes>.activities.contains {
            $0.id == id && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    private nonisolated static func start(state: CaptionActivityAttributes.ContentState, staleDate: Date) -> String? {
        let content = ActivityContent(state: state, staleDate: staleDate)
        return try? Activity.request(attributes: CaptionActivityAttributes(), content: content, pushType: nil).id
    }

    private nonisolated static func update(id: String, state: CaptionActivityAttributes.ContentState, staleDate: Date) async {
        guard let activity = Activity<CaptionActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    /// Ends the activity with `id`, or every one of them when nil.
    private nonisolated static func end(id: String?) async {
        for activity in Activity<CaptionActivityAttributes>.activities where id == nil || activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
