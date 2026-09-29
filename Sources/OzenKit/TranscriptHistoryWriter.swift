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
    private let pendingRenames = PendingRenames()

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
        queue.async { [store, failure, lastWritten, pendingRenames] in
            if lastWritten.record != record {
                lastWritten.record = failure.capture { try store.save(record) } ? record : nil
            }
            Self.retry(pendingRenames, store: store, failure: failure)
            finished?()
        }
    }

    /// Waits for earlier queued saves, then writes this one before
    /// returning. Called directly from the main actor when a conversation
    /// stops or the app leaves the screen, so what it blocks on matters:
    /// the summary and search-text caches are skipped here (see
    /// `TranscriptHistoryStore.save(_:updateSearchCaches:)`) so this holds
    /// the caller up only for the one write that must not be lost, not for
    /// the whole conversation's search index too.
    public func saveNow(_ record: TranscriptSessionRecord) {
        queue.sync { [store, failure, lastWritten, pendingRenames] in
            lastWritten.record = failure.capture { try store.save(record, updateSearchCaches: false) } ? record : nil
            Self.retry(pendingRenames, store: store, failure: failure)
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

    /// Renames a voice across every saved conversation, queued behind the
    /// saves already waiting so none of them lands the old name back.
    public func renameSpeakerInBackground(from oldName: String, to newName: String, finished: (@Sendable () -> Void)? = nil) {
        queue.async { [store, failure, lastWritten, pendingRenames] in
            lastWritten.record = nil
            pendingRenames.list.append((oldName, newName))
            failure.capture { try Self.runRenames(pendingRenames, store: store) }
            finished?()
        }
    }

    /// A rename the disk refused part way (a full phone) left the rest of
    /// the saved conversations with the old name, and the next save that
    /// worked cleared the error. It stays waiting instead, is tried again
    /// after every save until it goes through, and until then its error
    /// is the one reported.
    private static func retry(_ pending: PendingRenames, store: TranscriptHistoryStore, failure: FailureBox) {
        guard !pending.list.isEmpty else { return }
        do {
            try runRenames(pending, store: store)
        } catch {
            failure.record(String(describing: error))
        }
    }

    /// The waiting renames, oldest first; one refused stops the rest.
    private static func runRenames(_ pending: PendingRenames, store: TranscriptHistoryStore) throws {
        while let next = pending.list.first {
            try store.renameSpeaker(from: next.from, to: next.to)
            pending.list.removeFirst()
        }
    }

    /// Stars or unstars a line of a saved conversation, in order with the
    /// saves already queued. Nil when the line wasn't found or couldn't be
    /// saved.
    @discardableResult
    public func toggleStarNow(sessionID: UUID, segmentID: UUID) -> Bool? {
        queue.sync { [store, failure, lastWritten] in
            lastWritten.record = nil
            var result: Bool?
            failure.capture { result = try store.toggleStar(segmentID: segmentID, inSession: sessionID) }
            return result
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

    func record(_ error: String) {
        lock.lock()
        stored = error
        lock.unlock()
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

/// Voice renames not yet written to every saved conversation. Only
/// touched on the writer's queue.
private final class PendingRenames: @unchecked Sendable {
    var list: [(from: String, to: String)] = []
}

/// The conversation as the writer last wrote it; nil after a failure or
/// anything else that changed history. Only touched on the writer's queue.
private final class WrittenRecord: @unchecked Sendable {
    var record: TranscriptSessionRecord?
}
