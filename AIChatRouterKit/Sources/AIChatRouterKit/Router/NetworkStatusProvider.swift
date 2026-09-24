import Foundation
import Network

/// Reports whether the network is currently reachable, so the router can force all
/// routing to `.local` when offline rather than attempting (and failing) a cloud call.
public protocol NetworkStatusProvider: Sendable {
    var isOnline: Bool { get async }
}

/// `NWPathMonitor`-backed implementation. Defaults to "online" until the first path
/// update arrives, so a brief monitor-startup window never blocks cloud routing that
/// would otherwise succeed.
public actor NWPathMonitorNetworkStatus: NetworkStatusProvider {
    private let monitor = NWPathMonitor()
    private var currentStatus: NWPath.Status?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.updateStatus(path.status) }
        }
        monitor.start(queue: DispatchQueue(label: "com.sayantan.aichatrouter.network-monitor"))
    }

    public var isOnline: Bool {
        currentStatus != .unsatisfied
    }

    private func updateStatus(_ status: NWPath.Status) {
        currentStatus = status
    }
}
