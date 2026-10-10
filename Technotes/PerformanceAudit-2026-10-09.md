# Performance & Modern-Swift Audit — 2026-10-09

Read-only audit of `Modules/` + `Targets/` (842 Swift files) against three upstream
skill sets (twostraws/SwiftUI-Agent-Skill `swiftui-pro`, AvdLee/SwiftUI-Agent-Skill
`swiftui-expert-skill`, Dimillian/Skills `swiftui-performance-audit` +
`swift-concurrency-expert`), plus Crashlytics field data. Nothing was changed in
app code. The rules distilled from this audit live in `.agents/skills/yuedu-swift/`.

Every finding below was located by reading code, not by measurement, unless it says
"measured". Per CLAUDE.md, each fix still needs before/after `SourcePerfTrace` numbers.

## 0. Field evidence (Crashlytics, MetricKit non-fatals, 2026-09-10 → 10-09)

| Issue | Users (30 d) | On current build 2.0.7 (127), 206 users |
|---|---|---|
| `disk-write-exception` ≈ 1 077 MB | 169 | 8 users / 11 events |
| `scene-update watchdog` 10 s (background) | 169 | 5 |
| `cpu-exception` 90 s CPU in 104–163 s | 90 | 4 |
| `hang` 1.0–4.7 s | 17 | 0 |

Representative timeline, build 127, iCloud off (`icloud_syncing=0`), online books:
`app launch 08:08:08 → disk-write-exception 1 073 MB at 08:08:50 → cpu-exception at 08:10:24`;
relaunch 08:15:55 → another cpu-exception at 08:18:40.
Hang breadcrumbs on 112/113: 1.0–1.9 s hangs within minutes after launch, after
`iCloud sync start`, and right after `close reader`.

**The reported call stacks are unusable.** `MetricKitDiagnosticReporter.report`
stores `String(stackJSON.prefix(7000))` of the pretty-printed `MXCallStackTree`.
That keeps only the root frames (`start` → `main` → UIKit run loop) and drops the
leaf frames where the work actually happens. Separately, no `.xcarchive` / dSYM is
kept locally (`~/Library/Developer/Xcode/Archives/2026-09-30` is empty), so even a
full tree cannot be run through `atos`. The in-app 診斷與回報 export keeps the full
tree. See `.agents/skills/yuedu-swift/references/diagnosing-hangs.md`.

## Status (updated 2026-10-09, same day)

| Finding | Status |
|---|---|
| P0-1 chapter `id` breaks change detection | **Fixed**: `mergeOnlineChapters` carries the stored `id`; test `BookStoreBackgroundPublishTests.reparsedUnchangedListIsNoChange` (red before, green after) |
| P0-3 main thread waits on `persistQueue` | **Fixed**: `saveMetaImmediately` / `flushPendingMetadataSave` / `BookSourceStore.flushPendingWrites` enqueue under a `BackgroundTaskHold` instead of waiting; queue bookkeeping no longer `sync`s from main (and no longer re-tells the queue stale bytes after a later write); `replaceOfflineDownloadTask` skips no-op updates (part of P1-5). Remaining main-thread `sync`: store init (empty queue), `commitTXTBookmarks`, iCloud `applySyncSnapshot`, `reloadFromDisk` |
| MetricKit stacks unusable | **Fixed**: heaviest path, rebased to loaded images, sent as `ExceptionModel` frames (Crashlytics symbolicates + groups per culprit) |
| P0-2 launch refresh rewrites TOC caches | **Fixed**: TOC / book-info raw HTML no longer written (never read); TOC package rewritten only when its fingerprint (ids excluded) changes; auto-refresh throttle persisted. Test `TOCCacheWriteBudgetTests` |
| Swift 6 readiness (measured) | Swift 5 + `-strict-concurrency=complete`, after fixing the two `WKScriptMessageHandlerWithReply` conformances: **0 errors, 178 warnings in 83 files**, nearly all "an error in Swift 6": 73 mutable statics, 39 region-isolation `sending`, 27 non-Sendable captures, 9 WKWebView delegate methods that only "nearly match" (they would silently stop being called) |
| P0-4 source library decoded on main in `App.init` | **Fixed** (10-10): `BookSourceStore` reads the file on its own queue from creation; `sources` waits for the read if touched first (a main-thread wait is a `bookSources.waitOnMain` span); `whenLoaded` / `waitUntilLoaded()` for launch readers (Explore mode, `ExploreTabModel`, scale keys, Firestore push, launch refresh, download reconcile). 50 000 sources: main thread 1334 → 0 ms (read 1190 ms in background), Debug simulator |
| P1-6 shelf covers scan all sources + sync JS in init | **Fixed** (10-10): `BookSourceStore.source(id:)` index rebuilt at the single write point; `BookCoverImage` resolves source and header rule in `load()` on `SourceScriptThread`, only when not cached; 25 `sources.first { $0.id == }` sites use the index (`ReaderView.swift` left: another session was editing it). 200 covers × 50 000 sources: 3059 → 0 ms |
| P1-5 download reconcile reads TOCs on main | **Fixed** (10-10): only records are taken on main; each TOC is read on the download actor (`chapterStore` is lock-protected); `shelfRecord(id:)` replaces per-book `store.books` filters. 30 downloaded × 2 000 chapters: longest main-thread stall 130 → 10 ms, wall 707 → 408 ms (`LibraryRefreshScaleTests`, Debug simulator). The no-op task write was already fixed in e1325c1b |
| P1-7 title normalization CPU | **Fixed** (10-10): `ReaderHTMLUtilities.compactTitle` — no markup handling for plain titles, whitespace removed in one scalar pass instead of two compiled regexes per title; shared by title comparison, the volume-separator rules (which also pre-check `第`/`卷` before their regexes) and `normalizedTitleKey`. Equivalence test `CompactTitleTests`. Unchanged 2 000-chapter refresh: 131 → 12 ms CPU |
| P1-8 bookshelf body cost | **Fixed** (10-10, 5facaf9b). Sampling showed the real cost was every visible cell re-rendering (closures defeat diffing) and re-sorting per publish, not `books`' filter: `ReadingBook: Equatable`, cells `.equatable()`, sort order reused while its signature holds, `books`/`allGroups` derived per revision. 300 books: publish 11–13 → 5.6 ms, settings tick 17–19 → 9.6 ms (`ShelfRenderScaleTests`) |
| P1-10 root re-renders per TTS sentence | **Fixed** (10-10, 13daa0c8): root no longer observes `NowPlayingHub`; `update(from:)` assigns only changes; RSS unread counts without copy+sort (10 000 articles 7.6 → 3.3 ms); tab icons cached |
| P1-11 per-frame state writes | **Fixed** (10-10, 68f82b77): shelf cover frames via `onGeometryChange` into an unobserved box (scroll 4.8 → 2.0 ms/frame); detail hero stores the crossing; card chrome is one `@Observable` per card instead of a per-frame environment struct with a closure |
| P1-9 `GlobalSettings` fan-out | **Open — user decision pending**: `@Observable` migration (67 declarations in 51 files) loses the implicit "every observer redraws" that theme/global font/Bold Text rely on (`AppearanceThemePreset.activeAppThemes`, `GlobalAppTypography` statics) |

Feedback system added the same day: see `.agents/skills/yuedu-swift/references/diagnosing-hangs.md` §1.

## 1. Build facts that contradict the docs

- **App target is Swift 5 language mode.** `xcodebuild -showBuildSettings -target "yuedu app"`
  → `SWIFT_VERSION = 5.0`, no `SWIFT_APPROACHABLE_CONCURRENCY`, no default actor
  isolation, strict concurrency = minimal. CLAUDE.md says "Swift 6.0".
- `xcconfig/Yuedu-reader_common.xcconfig` is **never loaded** (the only
  `baseConfigurationReference` is `Yuedu-reader_version.xcconfig`). Its
  `SWIFT_VERSION = 6.0`, `SWIFT_TREAT_WARNINGS_AS_ERRORS`, `ENABLE_MODULE_VERIFIER` are dead.
- Only the two test targets set `SWIFT_APPROACHABLE_CONCURRENCY = YES`. So in the app,
  a nonisolated `async` func **runs on the global executor** (verified with a probe
  compiled by Xcode 27's swiftc: `-swift-version 5` → `onMain=false`; with
  `NonisolatedNonsendingByDefault` → `onMain=true`). The memory note and the comment at
  `BookStore.swift:1852` claiming "async runs on the caller's actor" are wrong for the app;
  they hold only in the test targets. Tests and app therefore disagree on where code runs.
- "All my code is @MainActor" does not hold: 146/345 classes and 71/89 `ObservableObject`s
  are `@MainActor`. The 18 unannotated ones are the core stores: `BookStore`,
  `BookSourceStore`, `ReplaceRuleStore`, `GlobalSettings`, `RSSStore`, `ICloudSyncManager`,
  `WebDAVManager`, `TTSCoordinator`, `ReadingStatsStore`, …

## 2. Ranked findings — launch / bookshelf hangs, 1 GB writes, CPU

### P0-1 `OnlineChapterRef ==` compares a random UUID → every refresh rewrites every book (verified)
- `BookSource.swift:714` `struct OnlineChapterRef: Identifiable, Codable, Equatable { var id: UUID = UUID() … }`, synthesized `==` includes `id`.
- Parsers create refs without an id (`ModernParserBridge.swift:1319`, `JSRuleEngineRunner.swift:409`, `WebNovelParser.swift:102`), and `BookStore.mergeOnlineChapters` (~2964) carries over `cachedFilename`/`runtimeVariables` but **not `id`**.
- So `listChanged: mergedChapters != existingChapters` (1958) and `merge != existing` (2180) are always true → `commitRefreshedList` writes `records` (one `objectWillChange` per book) → `BookChapterStore.setChapters` sees `entry.chapters == list` false → every refreshed TOC is dirty, exempt from LRU eviction, and rewritten on the next flush.
- Scale: online books × TOC size. `normalizedChaptersWithNextURL` (`BookSourceFetcher+TOC.swift:11-24`) stores the next chapter URL in every chapter's `runtimeVariables`, roughly doubling TOC bytes.
- Fix direction: preserve `id` in merge **and** give `OnlineChapterRef` a semantic `==` (index/url/title/flags/cachedFilename) or compare semantically in `setChapters`; skip the `records` write when nothing changed.

### P0-2 Launch "check new chapters" force-refreshes every book and writes 3–4 cache files per book
- `refreshOnlineBookMetadata` always passes `forceRefresh: true` (1975) → `saveTOCPackage` writes raw HTML + full TOCPackage JSON (`BookSourceFetcher+Cache.swift:80-108`), multi-page TOCs append raw HTML per page (`+TOC.swift:228-259`), sometimes `saveBookInfoPackage` too, plus the P0-1 TOC rewrite.
- Throttle `ChapterUpdater.lastAutoRefresh` is an in-memory static (`yuedu_appApp.swift:278`): resets every cold launch; foreground after > 300 s re-runs it (259).
- Estimate: 100 books × 2 000 chapters ≈ 5–10 MB each ≈ 0.5–1 GB in ~40 s at concurrency 3 — matches the field timeline.
- Fix direction: the update-check path should not write TOCPackage/raw HTML unless content changed; persist the throttle timestamp; consider legado's "only books allowed to update".

### P0-3 Main thread waits synchronously on `persistQueue` while it flushes dozens of dirty TOCs
- `writeMetadata` always `chapterStore.flush()`es first (2647), then encodes the whole shelf with `.sortedKeys`, then `file(_:holds:)` (2674) **reads the whole shelf file back** for a byte compare.
- Main-thread `persistQueue.sync` sites: `flushPendingMetadataSave` (2463, every scene inactive/background via `yuedu_appApp.swift:244`), `saveMetaImmediately` → `persist(inBackground:false)` (2616), `markMetadataPersisted` (2714, called on main after **every** background write), `notePersistedReadingData` (2695), `reloadFromDisk` (2760), `commitTXTBookmarks` (2486), 2817, 2910; `BookSourceStore.flushPendingWrites` (`yuedu_appApp.swift:238`).
- Best match for the 10 s background scene-update watchdog and the 1–1.9 s hangs after closing the reader.
- Fix direction: never `sync` onto `persistQueue` from main; keep `persistedFiles` bookkeeping on the queue; on background use `beginBackgroundTask` + async write; compare by size/hash, not full read-back.

### P0-4 `BookSourceStore.shared` decodes the whole source library on main in `App.init`
- `yuedu_appApp.swift:92` `!BookSourceStore.shared.sources.isEmpty` → `load()` (`BookSourceStore.swift:934-941`): `Data(contentsOf:)` + `JSONDecoder` + `dedupedByURL`, swallowed with `try?`. File comment says ~290 MB at 50k sources. No span.
- Same on iCloud restore: `FirestoreSyncManager.adoptRestoredLocalData` (107-109) and `ICloudSyncManager` (1188-1191) decode again on main.
- Fix direction: background load (`nonisolated static`), assign once on main; the "has sources" check should not trigger a full load.

### P1-5 Offline-download reconcile does main-thread TOC reads and immediate saves
- `reconcileOfflineTaskMetadata` (`BookStore.swift:2234-2238`) replaces the task unconditionally for every downloaded book → state `.available` → `saveMetaImmediately()` (969-971) on main (P0-3 cost) + `DownloadLiveActivityController.refresh`.
- `OfflineDownloadManager.swift:237-240` `reconcileInterruptedDownloads` runs in `MainActor.run` on launch and every `.active`: `store.readingBook(id:)` per downloaded book → `BookChapterStore.chapters(for:)` → `Data(contentsOf:)` + 2–4 MB decode on main (LRU holds 8).
- Affects only users with downloaded books — the developer likely has none.

### P1-6 Shelf covers run a linear source scan and possibly synchronous JS in view init (verified)
- `BookCoverImage.init(readingBook:)` (`BookCoverImage.swift:161-166`, `@MainActor`, built per cell in `BookshelfCoverArtwork.swift:292`): `BookSourceStore.shared.sources.first { $0.id == id }` (O(sources)) then `source?.parsedHeaders`.
- `parsedHeaders` (`BookSourceURLRendering.swift:238-260`): JSON parse every read; `@js` headers go through `JSCoreEngine.onJSQueue` = `safeJsQueue.sync` (`JSCoreEngine.swift:308-313`, verified). If that source's JS queue is mid-parse, **main blocks in view init** (JS timeout 30 s). Header cache caps at 32 and then `removeAll()`s.
- 40 `sources.first { $0.id == … }` sites; UI ones: `OnlineBookView.swift:31`, `AudiobookDetailView.swift:28`, `ReaderView+Toolbars.swift:499`, `ReaderView+PageBuilding.swift:229`.
- Fix direction: resolve headers in the pipeline / `.task`, an id index on `BookSourceStore` maintained at its single write point, LRU instead of clear-all.

### P1-7 Title normalization CPU (background, explains `cpu-exception`)
- `normalizeChapterTitle` (`BookStore.swift:3005`) runs `ReaderHTMLUtilities.displayText` + a `.regularExpression` replace (compiles an NSRegularExpression) per title, several passes per list, per book: ~10⁴ per book, ~10⁶ per refresh. Plus `dumpRuntimeVariables()` per chapter in TOC parse and repeated TOC encode/decode.

### P1-8 `HomeView` body is O(N)–O(N log N) and re-runs on every store/settings change
- `BookStore.books` is `records.filter` per access (89); body reads it many times; `allGroups` = filter + Set + sort (1238); each laid-out page runs `entries(onPage:)` → `sortedBooks` with `localizedCompare` (401); `.animation(value: entries.map(\.id))` (1058, 1166). ≈ 8–12 O(N) + 2–3 O(N log N) per body.
- Triggers: every `BookStore` publish (×P0-1), any `GlobalSettings` change, `SubscriptionStore`, each selection toggle.
- `ReadingBook` (40 fields, not `Equatable`) passed whole to rows with 5 closures — rows cannot be skipped.

### P1-9 `GlobalSettings`: one `ObservableObject`, 137–156 `@Published`, ~600 observers
- Shared modifiers observe the whole object (`InterfaceEffects.swift:105,225,250,306`, `Components.swift:107,124,160`, `GeneratedBookCover.swift:654`) plus root `ContentView`, `HomeView`, `ReaderView`, `RSSListView`, `BookSourceListView`.
- The reader brightness slider writes `readerBrightness` per tick (`ReaderQuickThemePanelView.swift:277-280`) → re-renders root, reader, the shelf behind it, and every surface modifier.
- Fix direction: `@MainActor @Observable` (no `$property` subscribers; `objectWillChange` used only at `FirestoreSyncManager.swift:287`, `ICloudSyncManager.swift:424`). Cheap stopgap: keep slider drag in local `@State`, commit on end.

### P1-10 Root `ContentView` observes 7 objects and does I/O in body
- `rssUnreadCount` → `RSSStore.totalUnreadCount()` (map+sort over all articles) twice per body; custom tab icons re-read `UIImage(contentsOfFile:)` + re-render per body, uncached (`RootTabCustomization.swift:197-206`).
- `NowPlayingHub.update(from:)` assigns 5 `@Published` unconditionally on every TTS segment (`TTSCoordinator.swift:755-778`) → root re-renders per spoken sentence.

### P1-11 Per-frame state writes while scrolling
- `HomeView.swift:98-112` `reportBookshelfCoverFrame`: `.global` GeometryReader + preference → `@State liveCoverFrame` per visible cell per frame. The existing `PublicLibraryCoverFrames` UIKit-anchor approach reads it on demand instead.
- `BookDetailComponents.swift:183-187` writes `heroBottom` per frame (use `onGeometryChange(for: Bool.self)`).
- `PublicLibraryBookSheet.swift:611` writes an environment value containing a closure + scroll offset per frame (uncommitted work in progress).

### P1-12 Explore / Search observe the 50k-source store and filter in body
- `ExploreHomeView` `visibleSources` ×3, `groups` flatMap/split/Set/sort per body; `@EnvironmentObject store: BookStore` used only to re-inject.
- `BookSearchView` reads `enabledSources` (`sources.filter`) 3–5× per body. `BookSourceListView` already shows the fix (`BookSourceManagementModel`).

### P1-13 RSS recomputes sorted article lists in body
- `RSSStore.articles(for:)`/`allArticles()`/`unreadCount` sort on every call; `RSSListView` calls them per folder/source/smart feed, builds both `.fileExporter` documents in body, eager `VStack`; `RSSFeedView` stores a `DateFormatter` as a struct property.

## 3. Correctness findings

- **Data races (Swift 5 mode does not report them):** background readers of main-written `@Published` arrays — `ChapterFetcher.swift:646` (`ReplaceRuleStore.shared.rules`), `TXTLazyAttributedStringBuilder.swift:220`, `MarkdownAttributedStringBuilder.swift:9`, `OnlineProviderAttributedStringBuilder.swift:544`, `SourceImageDecoder.swift:58`, `LegadoImageSourceResolver.swift:57`, `LanWebServer.swift:276`; `GlobalSettings.shared` read from CoreText/TTS background code.
- **`ChapterFetchManager.shared` can trap:** `OnlineReadingPipeline.swift:87-88` lazily initializes under `MainActor.assumeIsolated`, but first access can come from a background `async` path (`OnlineChapterContentService.swift:76`); probe reproduced SIGTRAP. It is also a second instance beside the DI one → two dedup tables; `AudiobookPlayer.swift:727` cancels only one.
- **Presentation:** `fullScreenCover(isPresented:)` + separate optional (`OnlineBookView.swift:304`, `AudiobookDetailView.swift:279`, `ContentView.swift:238`) can show a blank, undismissable cover; use `item:`.
- **Navigation:** `NavigationStack(path:)` mixed with view-destination `NavigationLink`s (`PublicLibraryHomeView.swift` — uncommitted work; `OPDSImportView.swift:81`; `CustomExploreComponentSheet.swift:32`).
- **Layout width from `UIScreen.main`:** `TXTLazyAttributedStringBuilder.swift:116,177` unconditionally — wrong in Split View / Stage Manager / two-page.
- **`try?` in persistence:** `BookStore.swift:2839` migration writes with `try?` then marks persisted and deletes the old data; `GlobalSettings.swift:2257,2500,2532,2549` silently fall back to defaults and later overwrite user data; `ChapterCacheRepository.swift:440-441`; `BookOriginSearchService.swift:139` (`try? await` search). 1 105 `try?` total (many legitimate probes).
- **Timing waits:** `ReaderTOCViews.swift:348`, `ReaderView+TXTVerticalScroll.swift:221`, `CoreTextPageView.swift:493`, `CoreTextCollectionScrollViewController.swift:478`, `BrowserView.swift:577-595,662,666`.
- **Force unwraps on untrusted input:** `JsoupDefaultExtractor.swift:546`, `AICharacterMemoryStore.swift:145`, `AISourceSnapshot.swift:23`.
- **Localization:** 189 `String(format: localized(…))`; `check_localizations.rb` does not check placeholder parity across the 5 languages.
- **Second JS path:** `BookSourceURLRendering.templateContextCache` (292-363) — unbounded `JSContext` per source outside `BookSourceSession`.
- `BookStore.delete` removes a whole chapter-cache directory on main (1306-1310).

## 4. Pure modernization (low priority, never mixed into feature work)

`foregroundColor` 338, `cornerRadius` 10, `accentColor` 2, `navigationBarLeading/Trailing` 22,
`EnvironmentKey` → `@Entry` 12, `Task.sleep(nanoseconds:)` 41, `String(format:"%…")` 157,
`AnyView` 12 (9 in `ReaderView.buildBody`), formatters in hot paths (`LegadoJSBridge.swift:1238,2017`,
`LegadoRSSScraper.swift:363`, `ReadingStatsView.swift:213`). Not replaceable at iOS 17:
`tabItem` (`Tab` is iOS 18), `ForEach(x.enumerated())` (iOS 26). `presentationMode` → `dismiss`
only after reading `Technotes/iOS17SearchWatchdogPostmortem.md`.

Clean already: no `NavigationView`, no single-param `onChange`, no value-less `.animation`,
no `PreviewProvider`, no `@ObservedObject var x = Foo()`, cover decode is off-main and downsampled,
JS semaphores only on `SourceScriptThread`/GCD queues, `BookChapterStore` lock + LRU.

## 5. Concurrency migration assessment

- Do **not** turn on Approachable Concurrency now: ~339 nonisolated async funcs would move from
  background to the caller's actor (iCloud sync, WebDAV, Readium open, HTML builders, zip archives,
  online chapter payloads, parts of `refreshOnlineBookMetadata`). Prerequisite: mark CPU/I-O-heavy
  async funcs `@concurrent` first.
- Do **not** turn on default MainActor isolation for the single app target: parsers, JS bridges,
  CoreText and the paginator are called synchronously from GCD/`SourceScriptThread`.
- Order: `SWIFT_STRICT_CONCURRENCY = targeted` → `complete` (stay Swift 5) → `@MainActor` the
  core stores + statics → Swift 6. Never in the same commit as a refactor.
