import Foundation

public actor DownloadCoordinator {
    public static let shared = DownloadCoordinator()

    private var inFlight: [URL: (task: Task<URL, any Error>, listeners: ProgressFanOut)] = [:]
    private(set) var joinCount = 0

    public init() {}

    public func run(
        for url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        _ operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL
    ) async throws -> URL {
        if let existing = inFlight[url] {
            joinCount += 1
            existing.listeners.add(progress)
            return try await existing.task.value
        }
        let listeners = ProgressFanOut(progress)
        let task = Task { try await operation { listeners.report($0) } }
        inFlight[url] = (task, listeners)
        defer { inFlight[url] = nil }
        return try await task.value
    }

    public func run(for url: URL, _ operation: @escaping @Sendable () async throws -> URL) async throws -> URL {
        try await run(for: url, progress: { _ in }) { _ in try await operation() }
    }
}

final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [@Sendable (Double) -> Void]
    private var latest: Double?

    init(_ first: @escaping @Sendable (Double) -> Void) {
        listeners = [first]
    }

    func add(_ listener: @escaping @Sendable (Double) -> Void) {
        let current = lock.withLock { () -> Double? in
            listeners.append(listener)
            return latest
        }
        if let current { listener(current) }
    }

    func report(_ fraction: Double) {
        let current = lock.withLock { () -> [@Sendable (Double) -> Void] in
            latest = fraction
            return listeners
        }
        current.forEach { $0(fraction) }
    }
}
