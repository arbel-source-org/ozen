/// What the phone's internet connection looks like right now.
public struct NetworkConditions: Sendable, Equatable {
    public var isConnected: Bool
    /// Cellular data, or a hotspot shared from another phone.
    public var isExpensive: Bool
    /// The person turned on Low Data Mode.
    public var isConstrained: Bool

    public init(isConnected: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static let wifi = NetworkConditions(isConnected: true)
    public static let cellular = NetworkConditions(isConnected: true, isExpensive: true)
    public static let offline = NetworkConditions(isConnected: false)
}

/// Watches the connection. The platform layer wraps `NWPathMonitor`;
/// tests drive a fake.
@MainActor
public protocol NetworkMonitoring: AnyObject {
    /// Nil until the system has reported once.
    var current: NetworkConditions? { get }
    var onChange: (@MainActor (NetworkConditions) -> Void)? { get set }
}

/// Decides whether a speech model may be downloaded right now.
///
/// Models are hundreds of megabytes. On a phone plan that can be a real
/// bill, or a month's data gone in an afternoon, and automatic recovery
/// would otherwise keep retrying a download over cellular without anyone
/// having decided that. So a big download waits for Wi-Fi unless the
/// person said otherwise, and Low Data Mode is respected the same way.
public enum ModelDownloadGate {
    public enum Decision: Sendable, Equatable {
        case proceed
        case waitForWiFi
        case offline
    }

    public static func decide(network: NetworkConditions?, allowCellular: Bool) -> Decision {
        // The system hasn't said yet: let the download itself find out.
        guard let network else { return .proceed }
        guard network.isConnected else { return .offline }
        if (network.isExpensive || network.isConstrained) && !allowCellular {
            return .waitForWiFi
        }
        return .proceed
    }

    /// Whether a change of connection is worth retrying a download that
    /// was waiting for it.
    public static func canRetryDownload(on network: NetworkConditions, allowCellular: Bool) -> Bool {
        decide(network: network, allowCellular: allowCellular) == .proceed
    }
}
