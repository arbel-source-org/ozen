import CryptoKit
import Foundation
import OzenKit

/// Fetches release assets over HTTPS, continuing a cut-off file with a
/// range request, and checks files with CryptoKit's SHA-256.
public struct URLSessionReleaseFileFetcher: ReleaseFileFetching {
    public enum Failure: Error, Equatable {
        case notHTTP
        case status(Int)
    }

    /// How many bytes are gathered before each write to disk.
    private static let writeBatch = 1 << 20

    public init() {}

    public func fetch(_ url: URL, from offset: Int64, appendingTo destination: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw Failure.status(http.statusCode) }

        let fileManager = FileManager.default
        // A whole file back when part of it was asked for: the server
        // (or a proxy) ignored the range, so the file starts over.
        if offset > 0 && http.statusCode == 200 {
            try? fileManager.removeItem(at: destination)
            received(-offset)
        }
        if !fileManager.fileExists(atPath: destination.path) {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var batch = Data(capacity: Self.writeBatch)
        for try await byte in bytes {
            batch.append(byte)
            if batch.count >= Self.writeBatch {
                try handle.write(contentsOf: batch)
                received(Int64(batch.count))
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try handle.write(contentsOf: batch)
            received(Int64(batch.count))
        }
    }

    public func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.writeBatch), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
