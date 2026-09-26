import Foundation

/// What happened to the captions, kept on disk.
///
/// `PipelineEventLog` lives in memory: when iOS ends the app, or she closes
/// it after an evening that went badly, the account of that evening is gone
/// before anyone can read it. This keeps the same kind of lines (and the
/// slower facts around them: which model and microphone, how long the model
/// took to load, heat, the app leaving the screen) in a small file, so the
/// diagnostics report can still say what happened last time.
///
/// Writes go through a private queue: a line is a few dozen bytes, but the
/// callers are on the main actor in the middle of captioning.
///
/// Lines are held in a memory buffer and only actually written to disk in
/// batches (`flushDelay` apart, or sooner if `entries()` is asked for
/// them), instead of opening, seeking and closing a `FileHandle` for every
/// single line: during captioning the journal is appended to constantly
/// (a line per token, per stat), and unbuffered disk I/O for each one would
/// waste battery and flash wear for no benefit anyone reads in real time.
/// `flushDelay` bounds what a crash could lose; `entries()` always flushes
/// first, so it never misses a line that was already asked to be appended.
public final class SessionJournal: @unchecked Sendable {
    public static let maximumBytes = 96_000
    public static let keptLines = 500
    static let textLimit = 400
    static let flushDelay: TimeInterval = 2

    public struct Entry: Sendable, Equatable {
        public let at: TimeInterval
        public let text: String
    }

    private let fileURL: URL
    /// One queue for every journal, so two of them on one file (tests, or a
    /// second one made by mistake) still write and read in order. Also
    /// guards the pending-lines buffers below, which are keyed by file
    /// rather than by instance for the same reason: a line appended by one
    /// instance must be visible to `entries()` on another instance opened
    /// on the same file right after (e.g. across a simulated relaunch).
    private static let queue = DispatchQueue(label: "ozen.session-journal", qos: .utility)
    /// Only ever touched while running on `queue`, which is what actually
    /// makes these safe to share; `nonisolated(unsafe)` because that
    /// discipline is external to what the compiler can see.
    nonisolated(unsafe) private static var pendingLines: [URL: [String]] = [:]
    nonisolated(unsafe) private static var flushScheduled: Set<URL> = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func append(_ text: String, at time: TimeInterval) {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let clipped = singleLine.count > Self.textLimit ? String(singleLine.prefix(Self.textLimit)) + "…" : singleLine
        let line = "\(String(format: "%.2f", time))\t\(clipped)\n"
        Self.queue.async { [fileURL] in
            Self.pendingLines[fileURL, default: []].append(line)
            guard !Self.flushScheduled.contains(fileURL) else { return }
            Self.flushScheduled.insert(fileURL)
            Self.queue.asyncAfter(deadline: .now() + Self.flushDelay) {
                Self.flushScheduled.remove(fileURL)
                Self.flush(fileURL)
            }
        }
    }

    /// Everything kept, oldest first. Flushes anything buffered first, so
    /// this always sees every line already asked to be appended.
    public func entries() -> [Entry] {
        Self.queue.sync {
            Self.flush(fileURL)
            return Self.read(fileURL)
        }
    }

    /// Writes every buffered line for `fileURL` in one batch. Must only be
    /// called on `queue`.
    private static func flush(_ fileURL: URL) {
        guard let lines = pendingLines.removeValue(forKey: fileURL), !lines.isEmpty else { return }
        write(lines.joined(), to: fileURL)
    }

    /// "2026-09-18 14:02:07 listening", oldest first.
    public func reportLines(utcOffsetSeconds: Int) -> [String] {
        entries().map { entry in
            "\(Self.formattedDay(entry.at, utcOffsetSeconds: utcOffsetSeconds)) \(TranscriptHistoryStore.formattedClockTime(entry.at, utcOffsetSeconds: utcOffsetSeconds)) \(entry.text)"
        }
    }

    private static func write(_ line: String, to fileURL: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        let data = Data(line.utf8)
        try? handle.write(contentsOf: data)
        // Checked against the size after this write, not before: a
        // buffered flush can write many lines at once, and a batch alone
        // can carry the file past the limit in a single call.
        if end + UInt64(data.count) > UInt64(maximumBytes) {
            try? handle.close()
            // Down to half, not to just under the limit, or every line
            // after the first trim would rewrite the whole file.
            var budget = maximumBytes / 2
            var kept: [String] = []
            for entry in read(fileURL).suffix(keptLines).reversed() {
                let line = "\(String(format: "%.2f", entry.at))\t\(entry.text)\n"
                budget -= line.utf8.count
                if budget < 0 { break }
                kept.append(line)
            }
            try? Data(kept.reversed().joined().utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func read(_ fileURL: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let at = TimeInterval(parts[0]) else { return nil }
                return Entry(at: at, text: String(parts[1]))
            }
    }

    static func formattedDay(_ timestamp: TimeInterval, utcOffsetSeconds: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
