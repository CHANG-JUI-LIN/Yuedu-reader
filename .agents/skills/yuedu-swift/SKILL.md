---
name: yuedu-swift
description: Use when writing, reviewing, or refactoring Yuedu Swift/SwiftUI code — stores, persistence, concurrency, SwiftUI data flow, lists, presentation — and whenever a task involves performance, hangs, jank, launch time, disk writes, CPU, MetricKit/Crashlytics diagnostics, or Instruments. Encodes this codebase's verified build facts and the rules that keep the app smooth for users with large libraries.
---

# Yuedu Swift

Write modern Swift that stays smooth for the **heaviest** user, not the developer's
device. Field data (Technotes/PerformanceAudit-2026-10-09.md) shows the hangs, 1 GB disk
writes, CPU exceptions and watchdog kills all come from work that scales with the
user's data — hundreds of online books × 2 000-chapter TOCs, 50 000 book sources,
downloaded books — on paths a small library never exercises.

## Decision order

1. `CLAUDE.md` / `AGENTS.md` and the user's global rules (root cause before fallback,
   measure before optimizing, no `try?` in pipelines, no timing waits, one path per concern).
2. This skill.
3. `yuedu-ios-design` for anything user-facing (titles, tokens, localization, VoiceOver).
4. Upstream skills it was distilled from (twostraws `swiftui-pro`, AvdLee
   `swiftui-expert-skill`, Dimillian `swiftui-performance-audit` / `swift-concurrency-expert`).
   Where they conflict with 1–3, 1–3 win — see "Upstream conflicts" below.

## Verified build facts (re-check with `-showBuildSettings` before relying on them)

- App target `yuedu app`: **Swift 5 language mode**, strict concurrency minimal,
  **no** approachable concurrency, **no** default actor isolation. CLAUDE.md's
  "Swift 6.0" and `xcconfig/Yuedu-reader_common.xcconfig` (never loaded) are not in effect.
- Therefore, in the app: a nonisolated `async` func runs **off** main; anything in a
  `@MainActor` type, a `MainActor.run {}` block, or a `.task`/`Task {}` body started from
  a view runs **on** main — including synchronous heavy calls made from inside it.
- The test targets enable approachable concurrency, so "is this on main?" answered in a
  test does not transfer to the app. Answer it from the type's isolation, or with
  `Thread.isMainThread` in a `SourcePerfTrace` detail on device.
- Data races are not diagnosed. Reading a main-written `@Published` array from a
  background thread compiles and races.

Details and the migration order: [references/concurrency.md](references/concurrency.md).

## Hard rules

### Main thread
1. Nothing whose cost grows with library size, source count, TOC length, or file size runs
   on main: decode/encode, `Data(contentsOf:)`, writes, directory deletes, full-collection
   filter/sort/`first(where:)`, regex over chapters, image decode. Compute in a
   `nonisolated static` function off main; hop to main once to assign/publish.
2. Main never blocks: no `queue.sync`, semaphore/group `wait`, `NSCondition`, or JS-queue
   sync reachable from main. In particular **never `persistQueue.sync` from main** and never
   read `BookSource.parsedHeaders` (it can sync onto a busy JS queue) from a view.
3. `App.init`, view `init`, and `body` do no I/O, no store lookups, no JSON, no JS.
4. Every new path that may be heavy gets a `SourcePerfTrace` span with
   `main=\(Thread.isMainThread)` and a size detail (`books=`, `bytes=`, `sources=`).
   A synchronous span on main is also what `MainThreadMonitor` names when main stops
   answering — code outside any span shows up in field stall reports as "no instrumented span".

### Persistence and identity
5. **A refresh that changed nothing writes nothing.** Compare semantically before assigning
   to a store or marking a file dirty. A type whose synthesized `==` includes a generated
   `UUID` cannot be used for change detection — `OnlineChapterRef` is the shipped example
   that made every refresh rewrite every TOC.
6. Preserve identity across merges (carry the old `id` forward). Allocate ids when storing,
   never while rebuilding.
7. Writes are coalesced and off main; "save now" means enqueue + `beginBackgroundTask` at
   scene exit, not a synchronous wait. Don't read a file back to check if it changed.
8. Persisted decode/write never uses `try?`. Failure is logged via `AppLogger` and must not
   be followed by "mark persisted" or deleting the old copy.
9. Throttles and "last ran" stamps that must survive relaunch are persisted, not `static var`.

Details: [references/persistence.md](references/persistence.md).

### SwiftUI data flow
10. New shared state is `@MainActor @Observable`. Do not add `ObservableObject`/`@Published`.
    When touching an existing store, don't widen what observes it.
11. Rows, covers, and shared modifiers never observe a whole store or `GlobalSettings`.
    They take the few values they read as `let` parameters.
12. Derived collections (shelf pages, groups, enabled sources, unread counts, sorted
    articles) are computed by the owning store at its single write point and read by views.
    `BookStore.books`, `allGroups`, `BookSourceStore.enabledSources`, `RSSStore.unreadCount`
    are O(N) per access — never call them repeatedly in `body`. Disclose any new derived
    index to the user (it is not a new cache layer, but say so).
13. Look sources up by id with `BookSourceStore.source(id:)` (an index), never
    `sources.first { $0.id == … }`. The library is read off the main thread at launch:
    `sources` waits for that read if touched first, so launch-time code on main uses
    `whenLoaded { }` / `await waitUntilLoaded()` instead, and subscribers use
    `sourcesPublisher` knowing it starts with an unloaded `[]`.
14. Per-frame values (scroll offset, geometry, drag, slider drag, playback ticks) never go
    into `@State` that re-renders a big body, nor into the environment. Use
    `onGeometryChange(for: Bool.self)` threshold crossings, `scrollTransition`/`visualEffect`,
    or a UIKit anchor read on demand. Slider drags stay local; commit on end.
15. Assign `@Published`/observable properties only when the value differs, especially in
    per-segment, per-frame, or per-chapter callbacks.
16. Environment values never hold closures or rapidly changing values; inject a
    stable-identity `@Observable` model instead. New keys use `@Entry` with a stable default.

Details: [references/swiftui.md](references/swiftui.md).

### Lists, presentation, navigation
17. `ForEach` identity comes from the element (never `.indices`/`\.offset`); each element
    yields a constant number and kind of views — filter before `ForEach`, wrap branching
    rows in a container. Lazy stacks for anything that can grow.
18. A sheet/cover whose content needs an optional uses `item:`, never `isPresented:` +
    `if let` (a blank `fullScreenCover` traps the user).
19. A `NavigationStack(path:)` / `navigationDestination(for:)` stack uses only
    `NavigationLink(value:)`.
20. Layout width comes from the render size/viewport, never `UIScreen.main.bounds`
    (brightness is the allowed exception).

### Concurrency hygiene
21. Book-source JS has one path: `SourceScriptThread.run` + `BookSourceSession.session(for:)`.
    No new `JSContext`. Blocking primitives only on `SourceScriptThread`/dedicated GCD
    queues; add `dispatchPrecondition(condition: .notOnQueue(.main))` at new blocking points.
22. One service, one instance: if `AppDependencies` injects it, there is no `.shared` twin.
23. `MainActor.assumeIsolated` only in callbacks guaranteed on main (UIKit delegates,
    `queue: .main` observers) — never in a lazy static initializer.
24. Background code never reads `XxxStore.shared.<published>`; pass a Sendable snapshot
    taken on main.
25. Prefer `.task`/`.task(id:)` (auto-cancelled) over `onAppear { Task {} }`; stored `Task`s
    are cancellable; `Task.detached` captures values, not `self`.
26. No `asyncAfter`/`Task.sleep` to let UI or state "settle". Allowed: debounce, timeout,
    external-site polling/rate limits, toast dismissal — each with a comment saying which.

## Workflows

**Writing code:** decide where each piece runs (rules 1–4) and what observes it (10–16)
before writing views. Ask "what happens with 300 books, 50 000 sources, 2 000 chapters, 50
downloads?" for every loop, publish, and write.

**Reviewing code:** report only genuine problems, by file:line, rule number, and a short
before/after. Separate correctness/perf findings from pure modernization; never mix
modernization into feature work.

**"Make X faster" / "users say it's stuck":** state the measurable goal, constraints (no
source-compat change, no new cache layer, no wider WebView), and acceptance evidence first.
Then follow [references/diagnosing-hangs.md](references/diagnosing-hangs.md): field data →
reproduce with a large-library fixture → measure → fix the root cause → report before/after ms.

## Upstream conflicts (project wins)

- UIKit stays where the project chose it (reader engine, paging, swizzles,
  `DismissalSequencedActionChooser`); "avoid UIKit" does not apply.
- twostraws suggests `try?` as an alternative to force unwraps; here `try?` is banned in
  parsing/network/persistence unless empty is truly equivalent.
- "Never use GCD": existing GCD queues (`persistQueue`, `SourceScriptThread`, JS queues) are
  deliberate and stay. Don't add new GCD for new code; don't rewrite old GCD without a measured reason.
- Deployment target is iOS 17: `Tab`, `enumerated()` in `ForEach`, iOS 26/27 APIs need
  `#available` or stay out. `presentationMode` → `dismiss` only after reading
  `Technotes/iOS17SearchWatchdogPostmortem.md`.
- "Use `Text(…, format:)` instead of formatters" — fine for new UI; existing user-visible
  strings go through `localized()` per CLAUDE.md.
- Language-mode and isolation settings are the user's decision; never flip them as a side
  effect of another task. Know what each one does here: Swift 6 language mode adds
  compile-time data-race checking (it would have caught the background reads of store
  arrays and the `ChapterFetchManager.shared` trap) and runtime isolation assertions, but
  does not move work between threads and does not fix hangs. Approachable concurrency
  (`NonisolatedNonsendingByDefault`) and default MainActor isolation **do** move work onto
  the caller's actor / main. See [references/concurrency.md](references/concurrency.md).

## References

- [references/concurrency.md](references/concurrency.md) — where code runs here, probes, migration order.
- [references/persistence.md](references/persistence.md) — BookStore/BookChapterStore write path, change detection, background saves.
- [references/swiftui.md](references/swiftui.md) — observation fan-out, body cost, lists, environment, geometry.
- [references/diagnosing-hangs.md](references/diagnosing-hangs.md) — Crashlytics/MetricKit, Xcode Organizer, Instruments recipe, large-library fixture, signposts.
- `Technotes/PerformanceAudit-2026-10-09.md` — the dated findings ledger (file:line) this skill was distilled from.
