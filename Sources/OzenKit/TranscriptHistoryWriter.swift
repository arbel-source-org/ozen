import Dispatch

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
public final class TranscriptHistoryWriter: Sendable {
    private let store: TranscriptHistoryStore
    private let queue: DispatchQueue

    public init(store: TranscriptHistoryStore, queue: DispatchQueue = DispatchQueue(label: "ozen.history-writer", qos: .utility)) {
        self.store = store
        self.queue = queue
    }

    /// Queues a save and returns immediately.
    public func saveInBackground(_ record: TranscriptSessionRecord) {
        queue.async { [store] in
            _ = try? store.save(record)
        }
    }

    /// Waits for earlier queued saves, then writes this one before returning.
    public func saveNow(_ record: TranscriptSessionRecord) {
        queue.sync { [store] in
            _ = try? store.save(record)
        }
    }

    /// Returns once every queued save has been written.
    public func waitUntilIdle() {
        queue.sync {}
    }
}
