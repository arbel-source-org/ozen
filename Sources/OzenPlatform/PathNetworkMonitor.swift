import Foundation
import Network
import OzenKit

/// The phone's connection, from `NWPathMonitor`, reported on the main
/// actor and only when something the download rules care about changed.
@MainActor
public final class PathNetworkMonitor: NetworkMonitoring {
    public private(set) var current: NetworkConditions?
    public var onChange: (@MainActor (NetworkConditions) -> Void)?
    private let monitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let conditions = NetworkConditions(
                isConnected: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor [weak self] in
                self?.update(conditions)
            }
        }
        monitor.start(queue: DispatchQueue(label: "ozen.network-monitor", qos: .utility))
    }

    private func update(_ conditions: NetworkConditions) {
        guard conditions != current else { return }
        current = conditions
        onChange?(conditions)
    }
}
