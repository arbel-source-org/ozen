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
    private let pendingSaves = PendingSaves()

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
        queue.async { [store, failure, lastWritten, pendingRenames, pendingSaves] in
            var saved = true
            if lastWritten.record != record {
                saved = failure.capture { try store.save(record) }
                lastWritten.record = saved ? record : nil
                pendingSaves.records[record.id] = saved ? nil : record
            }
            // Unchanged, this one wasn't written again, so nothing cleared
            // the error of a waiting one that has now gone through.
            if Self.catchUp(pendingSaves, other: record.id, pendingRenames, store: store, failure: failure), saved {
                failure.clear()
            }
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
        queue.sync { [store, failure, lastWritten, pendingRenames, pendingSaves] in
            let saved = failure.capture { try store.save(record, updateSearchCaches: false) }
            lastWritten.record = saved ? record : nil
            pendingSaves.records[record.id] = saved ? nil : record
            Self.catchUp(pendingSaves, other: record.id, pendingRenames, store: store, failure: failure)
        }
    }

    /// Names a conversation in the same queue as the saves, so an autosave
    /// that already read the old summary can't land after the new name
    /// and drop it.
    public func renameNow(id: UUID, title: String) {
        queue.sync { [store, failure, lastWritten, pendingRenames, pendingSaves] in
            lastWritten.record = nil
            failure.capture { try store.rename(id: id, title: title) }
            Self.catchUp(pendingSaves, other: nil, pendingRenames, store: store, failure: failure)
        }
    }

    /// Renames a voice across every saved conversation, queued behind the
    /// saves already waiting so none of them lands the old name back.
    public func renameSpeakerInBackground(from oldName: String, to newName: String, finished: (@Sendable () -> Void)? = nil) {
        queue.async { [store, failure, lastWritten, pendingRenames, pendingSaves] in
            lastWritten.record = nil
            pendingSaves.renameSpeaker(from: oldName, to: newName)
            pendingRenames.list.append((oldName, newName))
            failure.capture { try Self.runRenames(pendingRenames, store: store) }
            Self.catchUp(pendingSaves, other: nil, pendingRenames, store: store, failure: failure)
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

    /// A conversation the disk refused (a full phone) was never tried
    /// again: the next save of another one worked and cleared the error,
    /// and the warning with it, though the refused one was never written.
    /// It stays waiting instead, is tried after every save of another
    /// conversation, and until it is written its error is the one reported.
    private static func retry(_ pending: PendingSaves, other current: UUID?, store: TranscriptHistoryStore, failure: FailureBox) {
        for (id, record) in pending.records where id != current {
            do {
                try store.save(record)
                pending.records[id] = nil
            } catch {
                failure.record(String(describing: error))
            }
        }
    }

    /// Tries again everything the disk refused before, after any write:
    /// a star or a rename that worked used to clear the error, and the
    /// warning with it, while a conversation was still waiting. Says
    /// whether nothing is left waiting.
    @discardableResult
    private static func catchUp(_ saves: PendingSaves, other current: UUID?, _ renames: PendingRenames, store: TranscriptHistoryStore, failure: FailureBox) -> Bool {
        retry(saves, other: current, store: store, failure: failure)
        retry(renames, store: store, failure: failure)
        return saves.records.isEmpty && renames.list.isEmpty
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
    ///
    /// A newer version of the conversation still waiting for room takes the
    /// star instead: starring the older file on disk was undone when the
    /// waiting one was written over it.
    @discardableResult
    public func toggleStarNow(sessionID: UUID, segmentID: UUID) -> Bool? {
        queue.sync { [store, failure, lastWritten, pendingRenames, pendingSaves] in
            lastWritten.record = nil
            var result: Bool?
            if var waiting = pendingSaves.records[sessionID],
               let index = waiting.segments.firstIndex(where: { $0.id == segmentID }) {
                waiting.segments[index].isStarred.toggle()
                pendingSaves.records[sessionID] = waiting
                result = waiting.segments[index].isStarred
                if Self.catchUp(pendingSaves, other: nil, pendingRenames, store: store, failure: failure) {
                    failure.clear()
                }
            } else {
                failure.capture { result = try store.toggleStar(segmentID: segmentID, inSession: sessionID) }
                Self.catchUp(pendingSaves, other: nil, pendingRenames, store: store, failure: failure)
            }
            return result
        }
    }

    /// Deletes a conversation after any autosave of it already queued, so
    /// that autosave can't write it back a moment after it was deleted.
    public func deleteNow(id: UUID) throws {
        try queue.sync { [store, lastWritten, pendingSaves] in
            lastWritten.record = nil
            pendingSaves.records[id] = nil
            try store.delete(id: id)
        }
    }

    /// Deletes every conversation, after the saves already queued.
    public func deleteAllNow() throws {
        try queue.sync { [store, lastWritten, pendingSaves] in
            lastWritten.record = nil
            pendingSaves.records.removeAll()
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

    func clear() {
        lock.lock()
        stored = nil
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

/// Conversations the disk refused, waiting to be written. Only touched on
/// the writer's queue.
private final class PendingSaves: @unchecked Sendable {
    var records: [UUID: TranscriptSessionRecord] = [:]

    /// A voice renamed while they wait would otherwise come back under the
    /// old name when they are finally written.
    func renameSpeaker(from oldName: String, to newName: String) {
        records = records.mapValues { record in
            var record = record
            for index in record.segments.indices where record.segments[index].speakerName == oldName {
                record.segments[index].speakerName = newName
            }
            return record
        }
    }
}

/// The conversation as the writer last wrote it; nil after a failure or
/// anything else that changed history. Only touched on the writer's queue.
private final class WrittenRecord: @unchecked Sendable {
    var record: TranscriptSessionRecord?
}
