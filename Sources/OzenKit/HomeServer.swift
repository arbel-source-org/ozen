import Foundation

/// Captions from a computer with a graphics card on the family's own
/// network or reachable over the internet (`server/ozen_server.py`): the
/// phone streams its microphone there and gets the words back as they
/// form. The server runs the same Hebrew model as the phone, only far
/// faster, and the phone's own model takes over whenever it can't be
/// reached (see `CloudCover`).
///
/// Protocol version 1. Text frames are JSON, binary frames are audio:
/// 16 kHz mono PCM16, little-endian. The phone opens with a hello carrying
/// the pairing code; the server answers `ready` or `error`, then sends a
/// `text` frame for every pass over the line being spoken, the last one
/// marked final. A frame may also list the pass's segments with Whisper's
/// own numbers for each, so the phone can run the same checks on them
/// (`WhisperResultFilter`) as on its own model's output.
public enum HomeServer {
    public static let protocolVersion = 1
    public static let defaultPort = 8765
    static let noAddress = "no valid server address"
    static let noCode = "no pairing code"

    /// "192.168.1.20", "grandma-pc:8765", "ws://…" or "wss://…" all work;
    /// a bare host gets the default port and plain `ws`.
    public static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "ws://" + trimmed
        guard var parts = URLComponents(string: withScheme),
              let scheme = parts.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              let host = parts.host, !host.isEmpty
        else { return nil }
        if parts.port == nil, !trimmed.contains("://") { parts.port = defaultPort }
        return parts.url
    }

    /// `purpose` is "check" for a connection test that closes straight
    /// after `ready`, "captions" for a stream; `client` names the app build
    /// and system, so the server's log shows which phone came by and why.
    public static func hello(
        token: String,
        languageCode: String,
        vocabulary: [String],
        purpose: String = "captions",
        client: String = ""
    ) -> String {
        encode([
            "type": "hello",
            "version": protocolVersion,
            "token": token,
            "language": languageCode,
            "vocabulary": vocabulary,
            "purpose": purpose,
            "client": client,
        ])
    }

    public static func vocabularyUpdate(_ terms: [String]) -> String {
        encode(["type": "vocabulary", "terms": terms])
    }

    public static let end = #"{"type":"end"}"#

    /// Clipped to the 16-bit range; the server wants the raw level, since
    /// its speech detector is tuned on the same quiet measurement-mode
    /// audio the phone's is.
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample.isFinite ? sample : 0)) * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The link a home server's pairing page shows as a QR code:
/// `ozen://pair?address=wss://…&code=…`. The phone's camera opens it in
/// the app, which asks before using it: a link like this points the
/// microphone at whatever computer it names.
public struct HomeServerPairing: Sendable, Equatable {
    public static let scheme = "ozen"
    public let address: String
    public let code: String

    public init?(address: String, code: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HomeServer.url(from: address) != nil,
              !code.isEmpty, code.count <= 200, !code.contains(where: \.isWhitespace)
        else { return nil }
        self.address = address
        self.code = code
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme, parts.host?.lowercased() == "pair",
              let address = parts.queryItems?.first(where: { $0.name == "address" })?.value,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        self.init(address: address, code: code)
    }

    /// The computer's name as a person would recognise it: its host.
    public var computerName: String {
        HomeServer.url(from: address)?.host ?? address
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "address", value: address), URLQueryItem(name: "code", value: code)]
        return parts.url!
    }
}

/// The answer to "Test connection" in the home computer's settings.
public enum HomeServerCheck: Sendable, Equatable {
    case connected(milliseconds: Int)
    case codeRefused
    case unreachable
    case notSetUp

    public init(availability: EngineAvailability, seconds: Double) {
        switch availability {
        case .available:
            self = .connected(milliseconds: max(0, Int((seconds * 1000).rounded())))
        case .unavailable(let why):
            switch why.kind {
            case .homeServerRejected: self = why.detail == HomeServer.noCode ? .notSetUp : .codeRefused
            case .homeServerUnreachable: self = why.detail == HomeServer.noAddress ? .notSetUp : .unreachable
            default: self = .unreachable
            }
        }
    }
}

public enum HomeServerMessage: Sendable, Equatable {
    case ready(model: String)
    case refused(code: String, detail: String)
    case text(utterance: Int, text: String, isFinal: Bool, confidence: Float?, segments: [WhisperSegmentSummary]?)

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "ready":
            self = .ready(model: object["model"] as? String ?? "")
        case "error":
            self = .refused(code: object["code"] as? String ?? "", detail: object["detail"] as? String ?? "")
        case "text":
            guard let utterance = object["utterance"] as? Int,
                  let text = object["text"] as? String,
                  let isFinal = object["final"] as? Bool
            else { return nil }
            let confidence = (object["confidence"] as? NSNumber).map { Float(truncating: $0) }
            let segments = (object["segments"] as? [[String: Any]]).map { list in
                list.compactMap { segment -> WhisperSegmentSummary? in
                    guard let text = segment["text"] as? String else { return nil }
                    func number(_ key: String, _ fallback: Float) -> Float {
                        (segment[key] as? NSNumber).map { Float(truncating: $0) } ?? fallback
                    }
                    return WhisperSegmentSummary(
                        text: text,
                        noSpeechProb: number("no_speech", 0),
                        avgLogprob: number("logprob", 0),
                        compressionRatio: number("compression", 1)
                    )
                }
            }
            self = .text(utterance: utterance, text: text, isFinal: isFinal, confidence: confidence, segments: segments)
        default:
            return nil
        }
    }
}

/// One open connection to the server. The real one wraps
/// `URLSessionWebSocketTask` (OzenPlatform); tests script a fake.
public protocol HomeServerSocket: Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    /// The next text frame; throws once the connection is closed.
    func receive() async throws -> String
    func close() async
}

public protocol HomeServerConnecting: Sendable {
    func open(_ url: URL) async throws -> any HomeServerSocket
}

extension EngineUnavailability {
    static func homeServerUnreachable(_ detail: String) -> EngineUnavailability {
        EngineUnavailability(kind: .homeServerUnreachable, detail: detail)
    }

    static func homeServerRejected(_ detail: String) -> EngineUnavailability {
        EngineUnavailability(kind: .homeServerRejected, detail: detail)
    }
}
