import Foundation

/// Where async code runs synchronous source-script work — a parse, a `loginCheckJs`, a login
/// menu's script.
///
/// Source JS runs on its engine's own queue while the caller waits for the result. A script
/// can stop for the reader — `java.startBrowserAwait`, `java.getVerificationCode` — for as
/// long as the reader takes, and a Swift concurrency thread that waits that long is gone from
/// a pool the size of the CPU: a few sources waiting at once (a search across several
/// Cloudflare-protected sources, 書源驗證) left no thread for any other async work in the
/// app. The threads here are GCD's, which adds threads when its own are blocked — what
/// Legado's IO dispatcher gives its source scripts.
///
/// A book source's own scripts no longer come here: they run on its `SourceScriptHost`, a GCD
/// serial queue for the same reason. What still does is source JS outside a session — login
/// menus, TTS scripts, an RSS category rule, the aggregate search pool's bridges.
enum SourceScriptThread {
    private static let queue = DispatchQueue(
        label: "com.yuedu.sourceScriptCallers",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let qos = dispatchQoS(for: Task.currentPriority)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: qos, flags: .enforceQoS) {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func run<T>(_ body: @escaping @Sendable () -> T) async -> T {
        let qos = dispatchQoS(for: Task.currentPriority)
        return await withCheckedContinuation { continuation in
            queue.async(qos: qos, flags: .enforceQoS) {
                continuation.resume(returning: body())
            }
        }
    }

    /// The caller's priority carried over, so a background download's parse does not run at
    /// search's priority.
    private static func dispatchQoS(for priority: TaskPriority) -> DispatchQoS {
        switch priority {
        case .high, .userInitiated: return .userInitiated
        case .low, .utility: return .utility
        case .background: return .background
        default: return .default
        }
    }
}
