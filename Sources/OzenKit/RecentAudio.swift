import Foundation

public struct RecentAudio: Sendable {
    public let capacity: Int
    private var storage: [Float]
    private var next = 0
    private var isFull = false

    public init(seconds: Double, sampleRate: Double) {
        capacity = max(1, Int(seconds * sampleRate))
        storage = [Float](repeating: 0, count: capacity)
    }

    public var count: Int { isFull ? capacity : next }

    public mutating func append(_ samples: [Float]) {
        let tail = samples.count > capacity ? samples.suffix(capacity) : samples[...]
        guard !tail.isEmpty else { return }
        let sanitized = tail.map { $0.isFinite ? $0 : 0 }
        let firstCount = min(sanitized.count, capacity - next)
        storage.replaceSubrange(next..<(next + firstCount), with: sanitized[..<firstCount])
        let secondCount = sanitized.count - firstCount
        if secondCount > 0 {
            storage.replaceSubrange(0..<secondCount, with: sanitized[firstCount...])
            next = secondCount
            isFull = true
        } else {
            next += firstCount
            if next == capacity {
                next = 0
                isFull = true
            }
        }
    }

    public func samples() -> [Float] {
        guard isFull else { return Array(storage[..<next]) }
        var result: [Float] = []
        result.reserveCapacity(capacity)
        result.append(contentsOf: storage[next...])
        result.append(contentsOf: storage[..<next])
        return result
    }

    public mutating func clear() {
        next = 0
        isFull = false
    }
}

public struct ProblemAudioStore: Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 5) {
        self.directory = directory
        self.keep = keep
    }

    @discardableResult
    public func save(_ samples: [Float], sampleRate: Int, at date: Date) -> URL? {
        guard !samples.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("problem-\(formatter.string(from: date)).wav")
        do {
            try WAVFile.pcm16(samples, sampleRate: sampleRate).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return nil
        }
        for old in clips().dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }

    public func clips() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("problem-") && $0.hasSuffix(".wav") }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
