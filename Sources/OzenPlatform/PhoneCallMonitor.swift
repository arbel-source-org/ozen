import Foundation
#if os(iOS)
import CallKit
#endif

/// Whether a phone call is going on: a regular call, or one from an app
/// that shows its calls like calls (WhatsApp and most others do). iOS may
/// never say that the audio interruption a call caused is over; the end of
/// the call itself is announced reliably, so this is how the app finds out
/// it can take the microphone back.
@MainActor
public final class PhoneCallMonitor {
    public private(set) var isCallInProgress = false
    public var onChange: (@MainActor (Bool) -> Void)?

    #if os(iOS)
    private let observer = CXCallObserver()
    private let delegate = CallChangeDelegate()
    #endif

    public init() {
        #if os(iOS)
        isCallInProgress = Self.anyCallInProgress(observer)
        delegate.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // The observer keeps only a weak reference; `delegate` keeps it alive.
        observer.setDelegate(delegate, queue: nil)
        #endif
    }

    #if os(iOS)
    /// Reads the calls again rather than trusting the callback's order: a
    /// call that starts and ends quickly reports twice, and the two hops
    /// here may not arrive in that order.
    private func refresh() {
        let inProgress = Self.anyCallInProgress(observer)
        guard inProgress != isCallInProgress else { return }
        isCallInProgress = inProgress
        onChange?(inProgress)
    }

    private static func anyCallInProgress(_ observer: CXCallObserver) -> Bool {
        observer.calls.contains { !$0.hasEnded }
    }
    #endif
}

#if os(iOS)
/// `CXCallObserverDelegate` callbacks arrive on the main queue but aren't
/// typed that way; this passes on only that something changed.
private final class CallChangeDelegate: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onChange?()
    }
}
#endif
