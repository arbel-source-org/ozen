import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CloudHTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeoutSeconds: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeoutSeconds: TimeInterval = 20) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct CloudHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol CloudHTTP: Sendable {
    func send(_ request: CloudHTTPRequest) async throws -> CloudHTTPResponse
}

public struct URLSessionCloudHTTP: CloudHTTP {
    public init() {}

    public func send(_ request: CloudHTTPRequest) async throws -> CloudHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeoutSeconds)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        return CloudHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
