# Diagnosing hangs, jank, disk writes, and CPU in Yuedu

"Some users are always stuck, the developer never is" almost always means the work
scales with something the developer's device doesn't have: library size, online-book
count × TOC length, source count, downloaded books, RSS volume. Get evidence from the
affected users first, then reproduce at their scale.

## 1. Field evidence (read before reproducing)

**Crashlytics (MetricKit non-fatals).** `MetricKitDiagnosticReporter` forwards
MetricKit diagnostics as non-fatals with domain `MetricKitDiagnostic.<kind>`: `hang`,
`cpu-exception`, `disk-write-exception`, `crash` (includes scene-update watchdog kills).
Each event carries breadcrumbs (`app launch`, `iCloud sync start`, `open/close reader`)
and custom keys (`current_book`, `icloud_syncing`). With the Firebase MCP:

- App id: `1:540650701012:ios:e1db6b9aa1aea37246bb41` (project `yuedu-readerr`).
- `crashlytics_get_report` `topIssues` filtered to `NON_FATAL` → find the MetricKit issues.
- Same report with `versionDisplayNames: ["<version (build)>"]` → is it still live on the current build?
- `crashlytics_list_events` with `issueId` → breadcrumbs: what happened just before.

**What the app sends (from build after 2026-10-09).** Each source answers a different
question; together they replace "please send me your phone":

| Source | Crashlytics shows it as | Answers |
|---|---|---|
| MetricKit hang / cpu / disk-write / crash (`MetricKitDiagnosticReporter`) | Issue `MetricKit.<kind>`, **symbolicated stack** of the heaviest path (`MetricKitCallStack` rebases frames onto loaded images; the backend symbolicates against the uploaded dSYM), one issue per culprit | *Which line* blocked / burned CPU / wrote |
| Main-thread monitor (`MainThreadMonitor`) | Log line `main thread blocked N ms · during <spans> · phase <scene>`; issue `MainThreadStall` (≥ 2 s) grouped by span | *What the app was doing* (its own `SourcePerfTrace` span names), and in which scene phase |
| Died during a stall (marker file, next launch) | Issue `DiedDuringMainThreadStall` | Watchdog kills and force-quits of a frozen app — invisible to Crashlytics otherwise |
| Scale keys (`DiagnosticScale`) | Custom keys `scale_*`, `icloud_auto_sync` on every report | *Why this user and not the developer*: shelf / online / downloaded books, sources, TOC MB |
| Breadcrumbs | Log tab: `refresh.all start/end`, every main-thread span ≥ 100 ms, scale line | What ran just before |
| Install id | Crashlytics **user id** = `CrashContext.installID` | All reports of one install together |
| User report (設定 → 診斷與回報 → 傳送給開發者) | Firestore `diagnosticReports/<YD-XXXX-XXXX>`; key `last_report_id` | The full redacted log + note, found by the number the user quotes; its `installId` leads to the same install's Crashlytics reports |

To read a user report: fetch the document (Firebase console, or the Firebase MCP
`firestore_get_document` on `diagnosticReports/<id>`), then
`python3 scripts/decode_diagnostic_report.py <payload or document JSON>`.
Sending needs Google's servers; where they are unreachable the alert points the user to
the file export instead.

Before the 2026-10-09 build, `callStackTree` held only the first 7 000 characters of the
JSON (root frames) — those older events cannot be symbolicated.

**Xcode Organizer.** Window → Organizer → Reports → Hangs / Disk Writes / Energy /
Launches for the App Store build. Apple symbolicates these server-side when enough
opted-in users report; check it before anything else.

**Ask the reporter for**: approximate shelf size and how many are online books, number
of book sources, whether they have downloaded books, iCloud/WebDAV on or off, device,
and whether it hangs on every launch or only the first after a while (launch refresh
runs on cold launch and on foreground after 300 s).

## 2. Reproduce at the user's scale

Large-shelf fixture (Simulator, measured 2026-10-06): duplicate one big online book
(≈2 000 chapters, 2 MB TOC) 60–100 times in `books_meta.json` with fresh UUIDs and copy
`books_meta.chapters/<id>.json` for each. **Back up the shelf files first and restore after.**
Add downloaded books and a large source library when the hypothesis needs them.
Launch with `-yd_icloud_auto_sync NO` to isolate from iCloud. Use the PID printed by
`simctl launch` — other sessions' test hosts are also named YueduReader.

Quick main-thread view without Instruments: `sample <pid> 30` and read the Main Thread tree.

## 3. Instruments recipe

Use a Release build. Prefer a real device (the Simulator has a different CPU and disk, and
the SwiftUI lane is empty there).

| Question | Template / instrument |
|---|---|
| What is main doing during the hang? | Time Profiler + **Hangs** (lower the threshold to 100 ms) |
| Which views re-render, and why? | **SwiftUI** template (device only): update counts, cause graph |
| Who writes 1 GB? | **File Activity** (or System Trace → File I/O); group by path |
| Is main waiting, not computing? | **System Trace**: main thread state = blocked, and the thread it waits on |
| Cold launch to first usable shelf | **App Launch** |
| Which tasks run on which actor? | **Swift Concurrency** |
| Which of our stages? | **os_signpost / Points of Interest** + `SourcePerfTrace` ⏱ lines in Console |

Command line (device UDID from `xcrun xctrace list devices`):

```bash
# xctrace flags first; everything after `--launch --` is passed to the app
xcrun xctrace record --template "Time Profiler" --device <UDID> --time-limit 60s --output ~/Desktop/launch.trace --launch -- <path/to/YueduReader.app>
xcrun xctrace record --template "File Activity" --device <UDID> --attach YueduReader --time-limit 60s --output ~/Desktop/writes.trace
```

For automated parsing, AvdLee's `swiftui-expert-skill` ships `scripts/record_trace.py`
and `scripts/analyze_trace.py` (correlates Time Profiler, Hangs, Hitches and the SwiftUI
cause graph; `--list-signposts`, `--window START:END`, `--fanin-for <View>`).
Reading a trace: low main-thread running coverage during a hang = blocked (look for a
`sync`/wait); high = CPU-bound (look at the hottest user symbol). A cause graph dominated
by one source (`objectWillChange` of a store, `UserDefaultObserver`, an environment writer)
is a structural invalidation bug — fix that one source.

## 4. Instrumentation to keep in the code

- `SourcePerfTrace.span("stage", "main=\(Thread.isMainThread) books=\(n) bytes=\(b)")` around
  every potentially heavy stage. Existing: `library.shelf.load/save`, `library.chapters.read/write`,
  `toc.network/parse/nextPage`, `sync.encode.books`, `offline.validation`.
- Added 2026-10-09: `refresh.all` breadcrumbs, `bytes=` on `library.chapters.write` and
  `library.shelf.save`, main-thread spans ≥ 100 ms as breadcrumbs, synchronous main-thread
  spans as `MainThreadActivity` (what the monitor names). Still missing: per-book
  `listChanged` in refresh, `offline.reconcileInterrupted`, `library.store.init` split,
  `BookSourceStore.load` (bytes/sources). A span only names a stall if the blocking code is
  inside one — add spans to heavy main-thread paths.
- `CrashContext.breadcrumb` at the start/end of launch refresh, so MetricKit events can be
  lined up with it.
- `OSSignposter` intervals (category `ReaderPerformance` already exists for the reader)
  for anything you want to see on the Instruments timeline.

## 5. Report

Before/after milliseconds (and bytes for write problems) from the same fixture and build
configuration, the stage spans that moved, and which field metric should drop
(e.g. `disk-write-exception` on the next build). State any fallback or new derived index
explicitly.
