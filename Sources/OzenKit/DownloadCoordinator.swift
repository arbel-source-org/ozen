import Foundation

/// Serializes concurrent operations keyed by a resolved URL into one: a
/// second caller for a URL already in flight joins the first caller's task
/// instead of starting a duplicate one of its own.
///
/// Built for `WhisperModelStore.download(variant:progress:)`: a dropped
/// engine's still-running model download can otherwise race a fresh one for
/// the same variant started right after it (see
/// `CaptionPipeline.cachedEngine()`, which drops a still-preparing engine
/// from its cache without cancelling its in-flight download), and two
/// uncoordinated writers over the identical on-disk folder corrupt each
/// other's output. Kept here, portable, rather than in `OzenPlatform`
/// alongside `WhisperModelStore` itself, since the coalescing logic has no
/// platform dependency and is worth testing directly.
public actor DownloadCoordinator {
    public static let shared = DownloadCoordinator()

    private var inFlight: [URL: Task<URL, any Error>] = [:]

    public init() {}

    /// Runs `operation` for `url`, or, if a call for the same `url` is
    /// already running, awaits that call's result instead.
    public func run(for url: URL, _ operation: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let existing = inFlight[url] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }
}
