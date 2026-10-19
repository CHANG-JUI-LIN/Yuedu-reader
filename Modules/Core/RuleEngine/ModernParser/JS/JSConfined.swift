/// A JavaScriptCore object — a `JSContext`, a `JSValue`, or a closure or value that reaches one —
/// carried across a thread hop whose own synchronization orders every access to it.
///
/// The JS engines run source scripts on one serial queue (`JSCoreEngine.safeJsQueue`, or a
/// detached thread in `JSSandbox`) while the caller blocks on a semaphore, group or `sync`. What
/// crosses that hop is used on exactly one side at a time: built by the caller, used on the JS
/// side, and read back by the caller only after the hand-off says the JS side is done (or, after a
/// timeout, never read). JavaScriptCore's types are not `Sendable`, so the compiler can't see that
/// ordering; this box states it at the hop instead of eleven unchecked captures.
///
/// It is not a lock and adds no synchronization. Only wrap something whose every access is
/// ordered by such a hand-off, and never touch the value from two sides at once. The one approved
/// hatch for JavaScriptCore values; use it instead of a per-site `@unchecked Sendable` or
/// `nonisolated(unsafe)`. **Remove it once the rule pipeline calls JS asynchronously** — an actor
/// on a `SerialExecutor` over the JS queue would then own these values and check the hops itself.
struct JSConfined<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
