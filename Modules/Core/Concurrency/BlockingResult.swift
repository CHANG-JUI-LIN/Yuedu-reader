import Foundation
import os

/// One value that a callback on another thread delivers and the calling thread blocks for.
///
/// The JS bridges answer synchronous JavaScript (`java.ajax`, `java.get`, …) by starting an
/// asynchronous request and waiting on a semaphore. Writing the answer into captured `var`s
/// from the completion handler is a data race the compiler rejects, and a real one when the
/// wait times out while the handler is still writing. This keeps the same shape — the caller
/// still blocks — with the value behind a lock, so a late delivery after a timeout is simply
/// never read.
final class BlockingResult<Value: Sendable>: Sendable {
    private let value = OSAllocatedUnfairLock<Value?>(initialState: nil)
    private let semaphore = DispatchSemaphore(value: 0)

    init() {}

    /// Called once by the callback.
    func deliver(_ newValue: Value) {
        value.withLock { $0 = newValue }
        semaphore.signal()
    }

    /// The delivered value, or nil when `timeout` passes first.
    func wait(timeout: DispatchTime) -> Value? {
        guard semaphore.wait(timeout: timeout) == .success else { return nil }
        return value.withLock { $0 }
    }

    /// The delivered value, waiting as long as it takes.
    func wait() -> Value {
        semaphore.wait()
        // `deliver` stores before it signals, so the value is present here.
        return value.withLock { $0 }!
    }
}
