import Foundation
import Network
import Observation

/// SwiftUI-reactive network status, separate from the kit's `NetworkStatusProvider`
/// (which `RoutingCoordinator` consults per-decision) so this UI-facing banner can
/// update live without the view needing to poll an actor.
@Observable
@MainActor
final class NetworkStatusMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status != .unsatisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.sayantan.aichatrouter.ui-network-monitor"))
    }
}
