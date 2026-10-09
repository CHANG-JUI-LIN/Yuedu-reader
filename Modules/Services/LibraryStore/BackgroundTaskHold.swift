import UIKit

/// Keeps the app running in the background until `release()` — for work handed to a queue
/// as the app leaves the foreground, which would otherwise be suspended half-way.
///
/// Safe to create and release from any thread (`UIApplication`'s background-task calls are
/// thread-safe); `release()` is idempotent, and the expiration handler releases it too, so
/// the system never has to kill the app for holding on past its allowance.
final class BackgroundTaskHold: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let name: String

    init(name: String) {
        self.name = name
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            AppLogger.cache("Background task expired before its work finished", context: ["task": name])
            self?.release()
        }
        lock.withLock { identifier = id }
    }

    func release() {
        let id: UIBackgroundTaskIdentifier = lock.withLock {
            defer { identifier = .invalid }
            return identifier
        }
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
