import Combine
import Foundation
import Network

/// Whether the device is on a network that background work may use: Wi-Fi or wired, and
/// neither expensive (cellular, a personal hotspot) nor constrained (Low Data Mode).
/// Unified library 2d starts and pauses WebDAV indexing on it; the indexer's own session also
/// refuses expensive and constrained networks, so a request never slips through between an
/// update and its delivery.
@MainActor
protocol NetworkPathProviding: AnyObject {
    var allowsBackgroundWork: Bool { get }
    var allowsBackgroundWorkPublisher: AnyPublisher<Bool, Never> { get }
}

@MainActor
final class NetworkPathMonitor: ObservableObject, NetworkPathProviding {
    static let shared = NetworkPathMonitor()

    @Published private(set) var allowsBackgroundWork = false
    var allowsBackgroundWorkPublisher: AnyPublisher<Bool, Never> { $allowsBackgroundWork.removeDuplicates().eraseToAnyPublisher() }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.yuedu.networkPath", qos: .utility)
    private var started = false

    /// Starts on first use; the monitor then runs for the life of the app.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in self?.allowsBackgroundWork = allowed }
        }
        monitor.start(queue: queue)
    }
}
