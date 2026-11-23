import Darwin
import Foundation
import JavaScriptCore
import os

/// Stops a script a `JSCoreEngine` timeout gave up on.
///
/// The timeout resets the engine onto a new queue and context, and the old context's script
/// kept running for as long as it liked: Crashlytics 9c4b0a95 (3.0.1 build 150, background
/// check of 1424 sources) — MetricKit's CPU exception, 90 s of CPU in 93 s, 27 of 28 samples
/// in one JavaScriptCore Yarr regex under `String.prototype.replace`, on a queue the timeout
/// had already abandoned.
///
/// JavaScriptCore has no public way to stop a running script. Its watchdog,
/// `JSContextGroupSetExecutionTimeLimit` (`JSContextRefPrivate.h`, not in the iOS SDK headers),
/// is the only one, so it is looked up by name. Measured on macOS 27.3 JavaScriptCore,
/// 2026-11-23: it cuts a script inside a single native `replace` (one that ran 8.25 s
/// unwatched stopped 1.5 s after a 1 s limit) and inside a single Yarr match, and the context
/// runs the next script normally afterwards; with it armed, a JS benchmark ran 149–169 ms
/// against 151–161 ms without.
///
/// The watchdog asks `shouldTerminate` once per `tick` of a script's running time. The answer
/// is "no" until the engine abandons the context, so a script is never cut by the watchdog on
/// its own: the engine's timeout (`onJSQueueWithTimeout`, which discounts network and
/// user waits) stays the one place that decides a script ran too long. A "no" does not re-arm
/// the watchdog, so the callback arms it again for the next tick.
///
/// App Review risk: this resolves a symbol JavaScriptCore exports but does not declare in
/// its public headers (maintainer accepted the risk, 2026-11-23). If App Review objects, this
/// file is the whole of it: `arm` returning nil leaves the engine as it was before, abandoned
/// scripts running to their end.
enum JSScriptWatchdog {
    /// How long a script runs between two asks. An abandoned script stops within about this
    /// long once it is back in JavaScript, plus whatever native call (a regex) it is inside.
    static let tick: TimeInterval = 0.5

    /// One context's "abandoned" mark.
    ///
    /// Retained for the life of the process, never released: the watchdog can ask through it
    /// whenever the context's VM runs JavaScript, and an abandoned context outlives the engine
    /// that made it (its script holds it). One small object per context the engine creates.
    final class Handle: @unchecked Sendable {
        private let abandoned = OSAllocatedUnfairLock(initialState: false)
        fileprivate var isAbandoned: Bool { abandoned.withLock { $0 } }
        /// The context's script stops at the watchdog's next ask.
        func abandon() { abandoned.withLock { $0 = true } }
    }

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (
        JSContextGroupRef, Double, ShouldTerminate?, UnsafeMutableRawPointer?
    ) -> Void

    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else {
            AppLogger.parse("JavaScriptCore watchdog unavailable; a timed-out source script keeps running", level: .anomaly)
            return nil
        }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()

    /// Arms the watchdog on `context`'s VM (each `JSContext()` has its own). Nil when the
    /// symbol is missing.
    static func arm(_ context: JSContext) -> Handle? {
        guard let setLimit = setExecutionTimeLimit,
              let group = JSContextGetGroup(context.jsGlobalContextRef) else { return nil }
        let handle = Handle()
        setLimit(group, tick, shouldTerminate, Unmanaged.passRetained(handle).toOpaque())
        return handle
    }

    /// Runs on the script's own thread, with its VM locked.
    private static let shouldTerminate: ShouldTerminate = { context, info in
        guard let info else { return false }
        let handle = Unmanaged<Handle>.fromOpaque(info).takeUnretainedValue()
        if handle.isAbandoned { return true }
        if let context, let group = JSContextGetGroup(context), let setLimit = setExecutionTimeLimit {
            setLimit(group, tick, shouldTerminate, info)
        }
        return false
    }
}
