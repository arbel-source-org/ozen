import Foundation
import OzenKit

public struct URLSessionHomeServerConnector: HomeServerConnecting {
    public init() {}

    public func open(_ url: URL) async throws -> any HomeServerSocket {
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return URLSessionHomeServerSocket(task: task)
    }
}

final class URLSessionHomeServerSocket: HomeServerSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func send(data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: continue
            @unknown default: continue
            }
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
