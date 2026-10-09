# Concurrency in Yuedu

## Where does this code run? (app target, verified 2026-10-09)

| Code | Runs on |
|---|---|
| Method of a `@MainActor` type (sync or `async`) | main |
| Body of `await MainActor.run { … }` | main |
| `.task { }` / `Task { }` started from a view or `@MainActor` code — the parts between awaits | main |
| `nonisolated` / unannotated `async` func (Swift 5 mode, no `NonisolatedNonsendingByDefault`) | global executor (off main) |
| Synchronous func | the caller's thread — a heavy sync call inside a main-actor `async` method is main-thread work |
| `Task.detached { }` | global executor |
| `actor` method | that actor's executor (off main) |
| `persistQueue.async`, `SourceScriptThread.run` | their GCD queue |
| `queue.sync` from main | **main blocks** until the queue drains everything ahead of it |

Probe used to verify (compile with the toolchain from `scripts/sim.sh xcode`):

```swift
final class Worker { func work() async -> Bool { Thread.isMainThread } }
@MainActor func check() async { print("onMain=\(await Worker().work())") }
// -swift-version 5                                   → onMain=false
// + -enable-upcoming-feature NonisolatedNonsendingByDefault → onMain=true
```

The test targets enable approachable concurrency, so the same helper behaves differently
in tests. Never conclude "this is off main" from a test.

## Rules

- **Heavy work: compute off main, publish once.**

  ```swift
  // Store method (main)
  func reload() {
      Task { [url] in
          let loaded = await Self.decodeLibrary(at: url)   // nonisolated static, off main
          self.apply(loaded)                               // one assignment on main
      }
  }
  nonisolated static func decodeLibrary(at url: URL) async -> [BookSource] {
      SourcePerfTrace.span("sources.load", "main=\(Thread.isMainThread)") { … }
  }
  ```

  Once the project adopts approachable concurrency, mark such functions `@concurrent`.
  Until then they are already off main; `Task.detached` around them is redundant (harmless).

- **Stores that views observe are `@MainActor`.** Of the stores, only the newer ones are.
  `BookStore`, `BookSourceStore`, `ReplaceRuleStore`, `GlobalSettings`, `RSSStore`,
  `ICloudSyncManager`, `WebDAVManager`, `TTSCoordinator`, `ReadingStatsStore` are not, and
  some are read from background threads (`ChapterFetcher` reads `ReplaceRuleStore.shared.rules`,
  attributed-string builders read rules and `GlobalSettings`, `LanWebServer` reads `sources`).
  New code passes a Sendable snapshot taken on main into background work instead of
  reaching for `.shared`.

- **Blocking primitives live only on GCD queues.** Semaphores, `group.wait`, `NSCondition`,
  `queue.sync` are fine on `SourceScriptThread` and dedicated queues (the existing JS bridge
  design), never on main and never on the Swift concurrency cooperative pool (it has one
  thread per core; blocking it starves every `async` func).

- **JS**: `SourceScriptThread.run { BookSourceSession.session(for:).withBridge { … } }` only.
  `BookSourceURLRendering.templateContextCache` and `parsedHeaders`' sync JS evaluation are
  known violations, not patterns to copy.

- **`MainActor.assumeIsolated`** asserts; it does not hop. Only in callbacks guaranteed to be
  on main. `ChapterFetchManager.shared` (lazy static under `assumeIsolated`, reachable from a
  background `async` path) traps if first touched off main.

- **One instance per service.** Inject from `AppDependencies`. A `.shared` twin of an injected
  service duplicates in-flight dedup and cancellation state.

- **Tasks**: prefer `.task(id:)` in views. Keep a handle for any `Task` that outlives a call
  and cancel it. Don't capture `self` in `Task.detached`. Check `Task.isCancelled` in loops
  over books/chapters.

- **No settling delays.** Await the real signal (callback, `onDismiss`, notification,
  async value). Allowed timers: debounce, timeout, external polling — commented.

## Migration order (user decision; never bundle with other changes)

What each setting changes in this target:

| Setting | Compile time | Runtime |
|---|---|---|
| `SWIFT_STRICT_CONCURRENCY = complete` (Swift 5) | data-race diagnostics as warnings | nothing |
| Swift 6 language mode | the same diagnostics as errors | dynamic isolation checks: a `@MainActor` closure invoked off main (ObjC/GCD callbacks) traps instead of racing |
| Approachable concurrency / `NonisolatedNonsendingByDefault` | — | nonisolated `async` funcs run on the caller's actor → work moves onto main |
| Default MainActor isolation | unannotated types become `@MainActor` | everything unannotated runs on main |

Measured 2026-10-09 (Swift 5 + `-strict-concurrency=complete`): 0 errors, 178 warnings in 83
files; 73 are mutable statics (mostly store singletons), 39 region-isolation `sending`, 27
non-Sendable captures, and 9 `WKNavigationDelegate`/`WKUIDelegate` methods that only "nearly
match" their requirement — under Swift 6 they would compile and silently never be called.
Fix those by matching the SDK's `@MainActor @Sendable` handler types before switching.

Swift 6 mode is a correctness upgrade, not a hang fix. Its cost is the error count and the
callbacks that will start trapping; measure both before deciding.

1. Keep Swift 5; set `SWIFT_STRICT_CONCURRENCY = targeted`, then `complete`; count warnings.
2. `@MainActor` the core stores and statics (clears many warnings at once); fix background
   readers by snapshotting.
3. Mark CPU/I-O-heavy nonisolated async funcs `@concurrent`-ready (they are the ~339 that
   would move onto the caller's actor).
4. Only then consider Swift 6 mode / `NonisolatedNonsendingByDefault`.
5. Default MainActor isolation only for a UI target after Core is split into packages
   (like `YueduCoreText`) — parsers, JS bridges, CoreText and the paginator must stay nonisolated.

After any change to these settings, re-run the probe and a `sample`/Time Profiler of launch
to confirm nothing moved onto main.
