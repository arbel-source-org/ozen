import Dispatch
import Foundation

/// Writes conversations to history away from the caption screen's thread.
///
/// The periodic autosave re-encodes the whole conversation, which for a
/// long afternoon with the family is enough work to stutter the captions
/// if it runs on the main thread every twenty seconds. Autosaves therefore
/// go to a serial queue and return at once.
///
/// Saves that matter right now (listening stopped, the app is leaving the
/// screen, a conversation break) wait instead: they queue behind any
/// autosave still in flight, so an older autosave can never land on top
/// of the final version of a conversation.
///
/// An autosave identical to what this writer last wrote is skipped: in a
/// quiet room the conversation doesn't change for hours, and writing the
/// same file again every twenty seconds only spends battery.
public final class TranscriptHistoryWriter: Sendable {
    private let store: TranscriptHistoryStore
    private let queue: DispatchQueue
    private let failure = FailureBox()
    private let lastWritten = WrittenRecord()

    /// Why the most recent save or rename didn't reach the disk (a full
    /// phone, most likely), or nil when it did. Autosaves have no one to
    /// report to when they fail; without this a conversation could stop
    /// being saved with nothing on screen saying so.
    public var lastFailure: String? { failure.value }

    public init(store: TranscriptHistoryStore, queue: DispatchQueue = DispatchQueue(label: "ozen.history-writer", qos: .utility)) {
        self.store = store
        self.queue = queue
    }

    /// Queues a save and returns immediately. `finished` runs on the
    /// writer's queue once the save is done, with `lastFailure` already
    /// saying how it went.
    public func saveInBackground(_ record: TranscriptSessionRecord, finished: (@Sendable () -> Void)? = nil) {
        queue.async { [store, failure, lastWritten] in
            if lastWritten.record != record {
                lastWritten.record = failure.capture { try store.save(record) } ? record : nil
            }
            finished?()
        }
    }

    /// Waits for earlier queued saves, then writes this one before returning.
    public func saveNow(_ record: TranscriptSessionRecord) {
        queue.sync { [store, failure, lastWritten] in
            lastWritten.record = failure.capture { try store.save(record) } ? record : nil
        }
    }

    /// Names a conversation in the same queue as the saves, so an autosave
    /// that already read the old summary can't land after the new name
    /// and drop it.
    public func renameNow(id: UUID, title: String) {
        queue.sync { [store, failure, lastWritten] in
            lastWritten.record = nil
            failure.capture { try store.rename(id: id, title: title) }
        }
    }

    /// Deletes a conversation after any autosave of it already queued, so
    /// that autosave can't write it back a moment after it was deleted.
    public func deleteNow(id: UUID) throws {
        try queue.sync { [store, lastWritten] in
            lastWritten.record = nil
            try store.delete(id: id)
        }
    }

    /// Deletes every conversation, after the saves already queued.
    public func deleteAllNow() throws {
        try queue.sync { [store, lastWritten] in
            lastWritten.record = nil
            try store.deleteAll()
        }
    }

    /// Deletes conversations that have outlived the retention setting,
    /// after the saves already queued. Returns how many were deleted.
    @discardableResult
    public func deleteExpiredNow(retention: HistoryRetention, now: TimeInterval, protecting protected: Set<UUID>) -> Int {
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        return queue.sync { [store, lastWritten] in
            lastWritten.record = nil
            return store.deleteConversations(inactiveBefore: cutoff, protecting: protected)
        }
    }

    /// Returns once every queued save has been written.
    public func waitUntilIdle() {
        queue.sync {}
    }
}

/// The last save error, shared between the writer's queue and whoever asks.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Runs `work`, keeps its error (or that there was none), and returns
    /// whether it succeeded.
    @discardableResult
    func capture(_ work: () throws -> Any) -> Bool {
        let outcome: String?
        do {
            _ = try work()
            outcome = nil
        } catch {
            outcome = String(describing: error)
        }
        lock.lock()
        stored = outcome
        lock.unlock()
        return outcome == nil
    }
}

/// The conversation as the writer last wrote it; nil after a failure or
/// anything else that changed history. Only touched on the writer's queue.
private final class WrittenRecord: @unchecked Sendable {
    var record: TranscriptSessionRecord?
}
