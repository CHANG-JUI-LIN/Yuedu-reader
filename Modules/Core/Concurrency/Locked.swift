import os

/// A value behind a lock, shaped like `Synchronization.Mutex` — which needs iOS 18. **Replace
/// with `Mutex` once the deployment target reaches iOS 18**; call sites keep the same shape.
///
/// As with `Mutex`, the value comes in `sending` and the body gets it as `inout sending`, so
/// region checking at the call sites still guards what goes in and out. The unchecked part is
/// confined to this type — the conformance and the `nonisolated(unsafe)` storage, which the lock
/// guards — exactly what `Mutex` does internally. This is the one approved hatch for
/// lock-guarded state; use it instead of a per-type `@unchecked Sendable`.
struct Locked<Value>: @unchecked Sendable {
    private final class Storage {
        nonisolated(unsafe) var value: Value

        init(_ value: sending Value) {
            self.value = value
        }
    }

    private let lock = OSAllocatedUnfairLock()
    private let storage: Storage

    init(_ initialValue: sending Value) {
        storage = Storage(initialValue)
    }

    func withLock<Result>(_ body: (inout sending Value) throws -> sending Result) rethrows -> sending Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage.value)
    }
}
