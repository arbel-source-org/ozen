import Foundation

/// Where the lock screen's caption lines are sent: the Live Activity in the
/// app, a fake in tests.
@MainActor
public protocol LockScreenCaptionsDisplaying: AnyObject {
    /// Shows `content`, starting the Live Activity if none is running and
    /// `mayStart` (iOS only lets an app start one while it is in front).
    /// Returns whether it is on the lock screen now.
    @discardableResult
    func show(_ content: LockScreenCaptionContent, mayStart: Bool) -> Bool
    func end()
    /// False when Live Activities are switched off for the app in iOS
    /// Settings, where nothing the app does can show them.
    var isAllowedBySystem: Bool { get }
    /// Why iOS last refused to start one, with the clock time, for the
    /// diagnostics report; nil when it never has.
    var lastStartFailure: String? { get }
}

/// Keeps the lock screen in step with the captions.
///
/// Puts the newest lines there while captions run and takes them away when
/// captions are stopped or the setting is off (`LockScreenCaptions.presence`);
/// paces the updates (`LockScreenUpdateThrottle`), slower while the app is
/// in front; sends the lines again now and then so a quiet room isn't taken
/// for a stopped app; and doesn't ask again with every word after iOS
/// refused to start one.
@MainActor
public final class LockScreenCaptionsCoordinator {
    /// What the captions are doing, read on every refresh.
    public struct Situation: Sendable, Equatable {
        /// The "captions on the lock screen too" setting.
        public var enabled: Bool
        public var phase: PipelinePhase
        public var interruptedByCall: Bool
        public var pausedForSpeech: Bool
        /// The caption text size in the app (see `LockScreenTextSize`).
        public var captionSize: Double

        public init(enabled: Bool, phase: PipelinePhase, interruptedByCall: Bool, pausedForSpeech: Bool, captionSize: Double) {
            self.enabled = enabled
            self.phase = phase
            self.interruptedByCall = interruptedByCall
            self.pausedForSpeech = pausedForSpeech
            self.captionSize = captionSize
        }
    }

    /// After iOS refuses to start one, how long until it is asked again
    /// (sooner when the app comes back to the front).
    public static let startRetrySeconds: TimeInterval = 30

    public let display: any LockScreenCaptionsDisplaying
    private let situation: @MainActor () -> Situation
    private let lines: @MainActor (_ count: Int, _ textSize: LockScreenTextSize) -> [LockScreenCaptionLine]
    private let now: () -> TimeInterval
    /// Nothing said for a while sends nothing, and the lines would turn
    /// stale on the lock screen while captions are in fact running; they
    /// are sent again this often, so "not updating" means the app stopped.
    /// It also moves the "said N minutes ago" note on, so every 30 seconds:
    /// the note is at most that far behind, and the lines' 120-second stale
    /// date is never reached while the app runs.
    private let keepAliveSeconds: TimeInterval

    private var throttle = LockScreenUpdateThrottle(minimumInterval: LockScreenUpdateThrottle.foregroundInterval)
    private var flush: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var nextStartAttempt: TimeInterval = 0
    private var isAppActive = true
    /// Whether the lines are on the lock screen, as far as the app knows.
    public private(set) var isShowing = false
    /// Called once when iOS ended the lock-screen captions while the app
    /// was away (its eight-hour limit, or swiped off): only the app in
    /// front can start them again, so she needs telling to open it.
    public var onEndedWhileAway: (@MainActor () -> Void)?

    /// `situation` and `lines` are asked on every refresh; `lines` gets how
    /// many lines there is room for and how large they are.
    public init(
        display: any LockScreenCaptionsDisplaying,
        keepAliveSeconds: TimeInterval = 30,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        situation: @escaping @MainActor () -> Situation,
        lines: @escaping @MainActor (_ count: Int, _ textSize: LockScreenTextSize) -> [LockScreenCaptionLine]
    ) {
        self.display = display
        self.keepAliveSeconds = keepAliveSeconds
        self.now = now
        self.situation = situation
        self.lines = lines
    }

    /// The app came to the front (`true`) or went away.
    public func appActivityChanged(isActive: Bool) {
        isAppActive = isActive
        // Back in front is the only time a Live Activity can be started
        // (one iOS ended after eight hours included), and a start it
        // refused earlier is tried again: Live Activities may just have
        // been switched on.
        if isActive { nextStartAttempt = 0 }
        throttle.minimumInterval = isActive
            ? LockScreenUpdateThrottle.foregroundInterval
            : LockScreenUpdateThrottle.backgroundInterval
        // A send held back for the slower pace in front goes now.
        flush?.cancel()
        flush = nil
        refresh()
    }

    /// Brings the lock screen up to date. Call whenever a line changes, the
    /// phase changes, or the display settings change.
    public func refresh() {
        let situation = situation()
        let presence = LockScreenCaptions.presence(
            phase: situation.phase,
            interruptedByCall: situation.interruptedByCall,
            pausedForSpeech: situation.pausedForSpeech
        )
        guard situation.enabled, presence.keep else {
            stop()
            return
        }
        let textSize = LockScreenTextSize(captionSize: situation.captionSize)
        let time = now()
        // Under a note ("paused because of a call") there is room for the
        // newest line only.
        var shown = lines(presence.status == nil ? LockScreenCaptions.lineCount : 1, textSize)
        var ageNote: String?
        // Staleness clearing applies whether or not there's a status note:
        // a call arriving right after 15+ quiet minutes correctly cleared
        // the screen must not bring that stale line back just because
        // there's now a note above where it would sit. Only the age-note
        // *text* is status-gated — a call's note already takes the room a
        // moderately-old line's age note would (see the test covering that).
        switch LockScreenCaptions.quiet(newestLineAt: shown.map(\.lastUpdate).max(), now: time) {
        case .recent:
            break
        case .minutesAgo(let minutes):
            shown = lines(1, textSize)
            if presence.status == nil {
                ageNote = LockScreenCaptions.ageNote(minutes: minutes)
            }
        case .over:
            shown = []
        }
        let content = LockScreenCaptionContent(lines: shown, status: presence.status, ageNote: ageNote, textSize: textSize)
        switch throttle.decide(content, now: time) {
        case .nothingNew where isShowing:
            return
        case .send, .nothingNew:
            send(content, at: time)
        case .wait(let delay):
            guard flush == nil else { return }
            flush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.flush = nil
                self.refresh()
            }
        }
    }

    private func stop() {
        flush?.cancel()
        flush = nil
        keepAlive?.cancel()
        keepAlive = nil
        throttle.reset()
        nextStartAttempt = 0
        if isShowing {
            display.end()
            isShowing = false
        }
    }

    private func send(_ content: LockScreenCaptionContent, at time: TimeInterval) {
        // A start iOS refused (Live Activities off, too many running) isn't
        // asked for again with every word that follows.
        let mayStart = isAppActive && time >= nextStartAttempt
        let wasShowing = isShowing
        isShowing = display.show(content, mayStart: mayStart)
        guard isShowing else {
            if mayStart { nextStartAttempt = time + Self.startRetrySeconds }
            // Nothing left for the keep-alive to keep alive.
            keepAlive?.cancel()
            keepAlive = nil
            if wasShowing, !isAppActive { onEndedWhileAway?() }
            return
        }
        throttle.sent(content, at: time)
        guard keepAlive == nil else { return }
        let interval = keepAliveSeconds
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.throttle.reset()
                self.refresh()
            }
        }
    }
}
