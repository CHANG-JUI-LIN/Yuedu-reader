import UIKit

/// Keeps the app running in the background until `release()` — for work handed to a queue
/// as the app leaves the foreground, which would otherwise be suspended half-way.
///
/// Created on the main actor (every caller is a scene-phase or main-actor store path) and
/// released from any thread — typically the write queue it waits for. `UIApplication` is
/// main-actor state, so the end itself runs on main. `release()` is idempotent, and the
/// expiration handler ends it synchronously too, so the system never has to kill the app for
/// holding on past its allowance.
final class BackgroundTaskHold: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let name: String

    @MainActor
    init(name: String) {
        self.name = name
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            AppLogger.cache("Background task expired before its work finished", context: ["task": name])
            // On main, and before the handler returns: UIKit suspends the app right after.
            self?.end()
        }
        lock.withLock { identifier = id }
    }

    /// Ends the hold from any thread; the end runs on the main actor's next turn.
    func release() {
        Task { @MainActor in self.end() }
    }

    @MainActor
    private func end() {
        let id: UIBackgroundTaskIdentifier = lock.withLock {
            defer { identifier = .invalid }
            return identifier
        }
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
