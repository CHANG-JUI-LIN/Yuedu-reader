# Unified Library, Phase 0 — Implementation Plan

> **For the implementer.** Read [AGENTS.md](../../../AGENTS.md) and [CLAUDE.md](../../../CLAUDE.md) first, then the sections of the design each task cites. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Design: [Technotes/UnifiedLibrary-2026-10-08-design.md](../../../Technotes/UnifiedLibrary-2026-10-08-design.md) §15 (Phase 0 and 交接) and §19. Audit: [Technotes/UnifiedLibrary-2026-10-08-audit.md](../../../Technotes/UnifiedLibrary-2026-10-08-audit.md) §8.2, §11.2, §11.3, §12.2–12.3, §16 and appendix B.
>
> Line numbers below are from `main` at `772b0c95`. Re-read each file before editing; other sessions commit to `main` all day.

**Goal:** prepare the code that Phases 1–5 will wrap, before any of it changes:
- lock today's search and discovery behavior in tests (0a);
- make the native search path tell a legitimately empty result from a failure, and log the failure (0b, first half only);
- move WebDAV folder listing out of the view (0c);
- stop a corrupt custom Explore file from being overwritten (0d);
- measure the time to the first remote search result, so Phase 4 has a "before" number (0e).

**Today:**
- Six components that later phases wrap have no tests: `SearchAggregator`'s merge and sort, `BookOriginSearchService`, `OnlineCoverSearchService`, `CustomExplorePageModel`, `DiscoverViewModel.reload` and `DiscoverKindsCache` (audit appendix B).
- The native search path turns 401/403/404/429/5xx, encoding errors, empty pages and parse errors into `[]`, without logging anything. The aggregator then records each of them as a success (audit §11.3).
- `WebDAVDirectoryView` calls the network itself (audit §8.2).
- `CustomExplorePageStore` keeps an empty list after a failed read, and the next edit overwrites the file (audit §16 item 4).
- Nothing measures how long a search takes to show its first result.

---

## Scope

**In:** 0a, 0c, 0d, 0e, and the part of 0b that the design's 交接 table allows now: "區分並記錄 `empty` 與 `failed`".

**Out:**
- **`SourceHealthStore`.** 0b does not change what is recorded there. A failure reported as empty keeps counting as a success, and blocked sources keep never entering cooldown. Changing that is §17 item 9, which the maintainer has not decided.
- **The `try?` in `BookOriginSearchService.searchSourceWithTimeout`** (`BookOriginSearchService.swift:139`). It swallows the same failures for 換源 and 換封面. It is listed under Follow-ups rather than widening 0b.
- **Any visible UI change.** Phase 0 changes no screen, so it needs no UserDefaults flag (§15). 0c moves code without changing what the WebDAV screen shows. 0d keeps a corrupt file aside without showing a message (decision 8).

---

## Decisions

### Made while planning

Each comes with its reason; the maintainer can overturn any of them.

1. **The plan is in English,** like its template `2026-10-07-public-domain-libraries.md`. The design and the audit stay in Chinese.
2. **0a changes no production code.** Its acceptance rule is "the new tests pass on unchanged code" (§15). Where a component has no seam, 0a tests what it can reach and records the rest as a gap. It does not add a seam. The gaps are:
   - `CustomExplorePageModel`'s loading: it reaches the network through `BookSourceSession`'s JS bridge, whose `LegadoJSBridge.requestSession` is a private `URLSession`, so `URLProtocol.registerClass` does not reach it.
   - `DiscoverViewModel`'s section loading, for the same reason.
   Phase 5 replaces both with HomeSection loaders, and those take an injected loader from the start.
3. **0a locks today's quirks and labels them.** For example:
   - title normalization does not strip punctuation;
   - it does not convert between Traditional and Simplified Chinese;
   - the first source to answer fixes a merged book's author.
   Each such assertion carries the comment `// Current behavior (audit §11.2); Phase 4 is expected to change this.` A Phase 4 change then shows up as a test that has to be updated on purpose.
4. **0b keeps one search implementation.** A new `searchOutcome(…)` holds the code that is in `search(…)` today and returns `.results`, `.empty` or `.failed(reason)`. `search(…)` becomes a thin wrapper that maps `.empty` and `.failed` to `[]`, so every caller keeps its exact contract. No second code path is added.
5. **0b keeps the exact current mapping, in both failure modes.**
   - `.propagateTransportError` still returns `[]` for the listed HTTP codes, encoding errors, empty content and parse errors.
   - It still throws only for other transport errors.
   - The mapping becomes a pure function with a table-driven test, so a later change to it is deliberate.
6. **0b logs the source, never the query.** A search URL contains the user's keyword, so the log records the source name, the URL's host and the reason, and never the URL itself. This follows design §10.3 and CLAUDE.md's logging rule.
7. **0c mirrors `OPDSBrowseModel`.**
   - Same shape: `@MainActor final class …: ObservableObject` with `@Published private(set)`.
   - Same test hook: an optional closure in `init`.
   - Same request-ID guard.
   One browsing pattern for both remote-library kinds, not a second one with `@Observable`.
8. **0d keeps the unreadable file aside, then allows writes** (the maintainer chose option (b), 2026-10-10).
   - This follows `BookReaderSettingsStore`: a file that cannot be decoded is copied to `custom_explore_pages.corrupt-<stamp>.json`, and only then may the store write a fresh file.
   - If the copy cannot be made, or the file cannot be read at all, writes stay blocked, so the original is never lost. The design's "讀取失敗後拒絕寫入" survives in that branch.
   - 0d shows no message. Phase 5's migration must also look for `*.corrupt-*.json` (noted in Follow-ups).
9. **0e tags each search with its origin and its cache setting, instead of adding a "from cache" flag.**
   - `SourceSearchSheet` (換源) also calls `search(query:sources:)`. So the span says `origin=searchTab` or `origin=changeSource`, and the baseline counts only the first.
   - A `SearchResultCache` hit reaches `mergeBatch` the same way a network result does. Setting 網路設定 →「搜索結果快取天數」to 0 turns the cache off entirely (`SearchResultCache.freshBooks` returns nil for `days <= 0`). The span records `cacheDays=`, so a cached run can be told apart in the log.
10. **0e's baseline lives in this plan,** in the Baseline section at the end, so Phase 4's "after" has one place to compare against (design §16 item 8).
11. **One branch per step, all from `main`** (§15 交接):
    - `unified-library/0a-characterization`
    - `unified-library/0b-search-outcome`
    - `unified-library/0c-webdav-browse-model`
    - `unified-library/0d-custom-explore-write-guard`
    - `unified-library/0e-search-first-result-span`
    Suggested merge order: 0a, 0d, 0c, 0e, 0b.
    - 0a goes first so 0b and 0e run against the characterization tests.
    - 0e goes before 0b. Both edit the same lines of `SearchAggregator`, and the "before" number should come from a build without 0b's new log lines.

### Open questions for the maintainer

1. ~~**0d, a corrupt `custom_explore_pages.json`.**~~ Settled 2026-10-10: (b), copy it aside and allow writes. See decision 8.
2. **0e, the baseline queries.** The plan suggests 三體, 斗羅大陸 and 凡人修仙傳, three runs each, on the maintainer's iPhone with their own sources. Replace them if other queries better represent real use.

---

## Context

### Search (0a, 0b, 0e)

- **Submit path:**
  - 搜索 tab: `BookSearchView.doSearch()` (`BookSearchView.swift:472-487`) calls `SearchAggregator.search(query:sources:)` (`SearchAggregator.swift:481`). It is reached from `.onSubmit(of: .search)` (239), from `initialQuery` (260) and from 最近搜索 (492).
  - 換源: `SourceSearchSheet` (`SourceSearchSheet.swift:39`) searches on appear.
  - `resume()` (762) calls `runSearch` directly; `loadMore()` (671) builds its own task.
- **Fan-out:**
  - `runSearch` (549) runs a `TaskGroup`.
  - Each source goes through `searchSingleSource` (913), which calls `BookSourceFetcher.shared.searchStreaming` (`BookSourceFetcher+Search.swift:191`). That checks `SearchResultCache.shared` first (198), then either the JS runtime or `search(…)`.
  - Results: `.success` → `recordSuccess` (615); `.timeout` and `.failed` → `recordFailure` (619, 623).
- **Swallowed failures:** `BookSourceFetcher+Search.swift:117-145`:
  - `.encodingError`, `.httpError` in [401, 403, 404, 429, 500, 502, 503] and `.emptyContent` return `[]` in both modes;
  - other `FetchError`s throw;
  - other errors throw only in `.propagateTransportError`;
  - a parse error calls `onHasMore(false)` and returns `[]`.
  `.propagateTransportError` is used only by `BookSourceHealthChecker` (949).
- **Merge and sort** are all `private`: `mergeBatch` 1020, `mergeBook` 1063, `sortResults` 1135, `matchScore` 1166/1172.
  - Reachable from tests: `SearchBook.makeKey` 75, `nameKey` 84, `isLikelySameBook` 109, `normalizedName` 55, and the aggregator's `results`, `progress`, `isSearching`.
  - `mergeBook` drops books whose name and author do not relate to the query (1074-1080).
- **Test seam without production changes:**
  1. Set `GlobalSettings.shared.searchCacheDays = 1`.
  2. Call `SearchResultCache.shared.store(books:query:source:days:)`, then `waitForPendingWritesForTesting()` (`SearchResultCache.swift:148`, `#if DEBUG`).
  3. Run the search. `searchStreaming` returns the cached books before any network request.
  - The cache key includes `lastUpdateTime` and runtime variables (157).
  - Clean up with `clear(query:source:)`.
- **0b's test seam:** `BookSourceFetcher(webFetcher: WebFetcher(session:))` (`BookSourceFetcher.swift:31`; `WebFetcher.swift:18`). Give the session's configuration a `URLProtocol` in `protocolClasses`. `registerClass` does not reach a custom session; see `AggregateSearchStreamingTests.swift:149-152`.
- **Logging:** `AppLogger.network` and `.parse` (`Targets/Yuedu/SharedApp/AppLogger.swift:34-40`) write to os_log with `.public` privacy and to `DiagnosticLog.shared`. A line starting with "⏱" is `.trace`, and `DiagnosticLog` keeps trace lines only when `isVerboseEnabled` is on.
- **`SourcePerfTrace`** (`Modules/Core/BookSource/SourcePerfTrace.swift`) offers `now`, `span`, `spanAsync` and `record(_:_:since:thresholdMs:)`. It is compiled into Release. The header comment (3-23) lists every stage name. It has no test sink; a test reads `DiagnosticLog.shared.snapshot()` with verbose on, as `MainThreadMonitorTests.swift:9-31` does.

### Other search callers (0a)

- **`BookOriginSearchService.stream(title:author:sources:concurrency:fetcher:excludingOriginKey:sourceFilter:shouldStop:onBatch:)`** (28-119) takes a `BookSourceFetching` (`AppDependencies.swift:15`).
  - `searchSourceWithTimeout` (124) calls `SourceHealthStore.shared.recordSuccess` (163).
  - Fakes already exist, private to their files: `CountingBookSourceFetcher`, `CancellableTOCFetcher` (`NetworkSettingsSearchTests.swift:269, 343`).
- **`OnlineCoverSearchService.searchCovers(name:author:)`** (68) is the only non-private entry. It calls `URLSession.shared` (95), so `URLProtocol.registerClass` reaches it, as in `OnlineChapterImageCacheTests`. Its providers are `pre-api.tuishujun.com/api/searchBook` and `m.ypshuo.com/api/novel/search`. Matching is at 142-156.

### Discovery (0a)

- **`CustomExplorePageModel`:**
  - `sync(with:)` 39 reads `BookSourceStore.shared.sources`, which tests may set and restore, as `NetworkSettingsSearchTests` does.
  - Then `load` 70, `retry` 76, `reload` 81, `loadMoreWaterfall` 100-127.
  - Fetching uses `BookSourceFetcher.shared.discoverBooks`, which goes through the bridge's own session.
- **`DiscoverViewModel(source:)`** (188), `reload(forceRefresh:)` (414-479):
  - With `enabledExplore == false` or an empty `exploreUrl`, `discoverItems` returns `[]` without network (`BookSourceFetcher+Discover.swift:7-13`).
  - With items pre-seeded in `DiscoverKindsCache.shared` under `DiscoverKindsCache.key(sourceUrl:exploreUrl:variableJSON: nil)`, `reload` takes the cache path (442) into `applyDiscoverItems` (482).
  - `primeDiscoverCookies` does nothing unless `exploreUrl` contains `_csrfToken`.
- **`DiscoverKindsCache`:**
  - `shared` only; the directory is fixed at `Caches/DiscoverKindsCache`.
  - `items(forKey:)` 34, `store(_:forKey:)` 44 (skips empty input), `key(…)` 62 (MD5 of `url|explore|json`).
  - `removeAll()` 53 wipes the real cache. Tests must not call it.

### WebDAV browsing (0c)

- **`WebDAVDirectoryView`** (`RemoteImportViews.swift:13-136`) owns `entries`, `isLoading`, `didLoad` and `loadError` as `@State`.
  - It loads in `load()` (117-135) via `RemoteLibraryConnectionStore.shared.webDAVClient(for:).list(route.url)`.
  - Triggers:
    - `.task(id: route.url)` guarded by `didLoad` (81-85);
    - `.refreshable` (86);
    - `.onReceive(.remoteLibraryDidChange)` for its connection (77-80);
    - the 「重試」 button (32-39).
  - Failures are not logged.
- **`OPDSBrowseModel`** (`Modules/Services/OPDS/OPDSBrowseModel.swift`) is the template:
  - `init(route:fetch:)`;
  - a request-ID guard;
  - `AppLogger.network` on failure;
  - the view holds it as `@StateObject`, built in `init` (`OPDSImportView.swift:270-280`).
  - Its test precedent is `PublicLibraryStorefrontTests.swift:92-114`.
- **Tests today:**
  - `RemoteLibraryNavigationUITests` only opens the WebDAV screen and finds 「Add Server」. It does not browse a folder.
  - Nothing exercises `list()` or the view's loading.

### Custom Explore pages (0d)

- **`CustomExplorePageStore`** (`CustomExplorePageStore.swift:190-289`) is `@MainActor`, `ObservableObject`, with `init(fileURL:)`.
  - `load()` (272-280) logs a read or decode failure and leaves `pages` empty.
  - `save()` (282-289) writes `.atomic` with no guard.
  - Every mutation saves: `createPage`, `deletePage`, and through `update(_:_:)`: `renamePage`, `saveComponent`, `removeComponents`, `moveComponents`, `addCategory`.
  - No other code writes the file.
- **House precedent:**
  - `BookReaderSettingsStore` has `writesBlocked` (38-40), `load()` (151-170), `keepUnreadableFile` (174-191) and a guarded `save()` (194-198). Its test is `BookReaderSettingsStoreTests.swift:73`.
  - `BookStore` has `metadataWritesBlocked` (186).

---

## Guardrails

- **Project rules.** AGENTS.md and CLAUDE.md apply in full. In particular:
  - Run tests with `bash scripts/xctest.sh -- -collect-test-diagnostics never -only-testing:'yuedu appTests/<StructName>'`.
    - Name the `struct`, not the `@Suite` title.
    - Check that the verdict's suite count matches the number of classes you asked for.
  - No `-derivedDataPath`. Delete your own `.xcresult` files.
  - Run the smallest relevant regression after the last related edit.
- **The checkout is shared.** Other sessions edit and build in the same working tree and DerivedData.
  - Never switch the main checkout's branch while another session is working in it. On 2026-10-10 a session ended up building and committing on someone else's branch.
  - A separate `git worktree` gets its own DerivedData, about 4.6 GB, and needs `GoogleService-Info.plist` copied in. Ask the maintainer before creating one.
  - Commit only your own files: `git commit --only -- <files>`.
- **New test files** go in `Tests/iOS/yuedu appTests/`. That folder is file-system-synchronized, so there is no `.pbxproj` edit.
  - Fakes and builders that exist only as `private` in other test files are copied into the new file, not promoted. Each Phase 0 branch then stays self-contained.
- **Tests that touch `.shared` singletons:**
  - mark the suite `.serialized`;
  - restore every value they change: `GlobalSettings.shared.searchCacheDays`, `BookSourceStore.shared.sources`, `DiagnosticLog.shared.isVerboseEnabled`, `URLProtocol.registerClass`, and UserDefaults keys;
  - give cache entries deterministic keys under `.test` hosts, so reruns overwrite instead of accumulating.
  - Polling a condition in a test is fine, as existing tests do with `waitUntil`; a fixed sleep is not.
- **Errors.** No `try?` that discards an error in network or parsing code; log through `AppLogger`, never inside `#if DEBUG`. No timing-based waits in production code.
- **Views don't orchestrate** (0c).
- **UI** (0c only, no visual change): invoke the `yuedu-ios-design` skill, add a `#Preview`, and check that VoiceOver reads the screen as before.
- **Localization.** No step adds a user-facing string. If one does, it goes through `localized(…)` in all five languages, and `ruby scripts/check_localizations.rb` must pass.
- **Outward actions need the maintainer's yes, asked in chat:** pushing, merging into `main`, deleting branches.

---

## File map

**Create**
- `Tests/iOS/yuedu appTests/SearchAggregatorCharacterizationTests.swift` (0a)
- `Tests/iOS/yuedu appTests/BookOriginSearchServiceTests.swift` (0a)
- `Tests/iOS/yuedu appTests/OnlineCoverSearchServiceTests.swift` (0a)
- `Tests/iOS/yuedu appTests/CustomExplorePageModelTests.swift` (0a)
- `Tests/iOS/yuedu appTests/DiscoverViewModelReloadTests.swift` (0a)
- `Tests/iOS/yuedu appTests/DiscoverKindsCacheTests.swift` (0a)
- `Tests/iOS/yuedu appTests/BookSourceSearchOutcomeTests.swift` (0b)
- `Modules/Services/WebDAV/WebDAVBrowseModel.swift` (0c)
- `Tests/iOS/yuedu appTests/WebDAVBrowseModelTests.swift` (0c)
- `Tests/iOS/yuedu appTests/CustomExplorePageStoreWriteGuardTests.swift` (0d)
- `Tests/iOS/yuedu appTests/SearchFirstResultSpanTests.swift` (0e)

**Modify**
- `Modules/Core/BookSource/BookSourceFetcher+Search.swift` (0b)
- `Modules/Services/Online/SearchAggregator.swift` (0b, 0e)
- `Modules/Features/Bookshelf/RemoteImportViews.swift` (0c)
- `Modules/Services/Online/CustomExplorePageStore.swift` (0d)
- `Modules/Features/BookDetail/SourceSearchSheet.swift` (0e: passes `origin: .changeSource`)
- `Modules/Core/BookSource/SourcePerfTrace.swift` (0e: the header comment's stage list)
- This plan: "What landed" and the Baseline (every step)

---

## Task 0a: Characterization tests

**Branch:** `unified-library/0a-characterization`. **Production files:** none.

Each sub-step adds one test file and one commit. A test that fails on unchanged code means the expectation is wrong, not the code. Read the code, make the test assert what the code does today, and note the surprise under "What landed".

### 0a.1 `SearchAggregatorCharacterizationTests`

- [ ] **Step 1: Pure keys** (`struct SearchKeyCharacterizationTests`, no singletons):
  - `SearchBook.makeKey` and `nameKey` fold case, full-width/half-width and whitespace: 「三體 」, 「三体」 and 「ＡＢＣ」 against their plain forms.
  - **Quirks, labeled per decision 3:**
    - punctuation is kept: 「三體！」 ≠ 「三體」;
    - no Traditional/Simplified folding: 「三体」 ≠ 「三體」.
  - Do not duplicate `ChangeSourceMatchTests`, which already covers `isLikelySameBook`.
- [ ] **Step 2: Merge and sort through a real search** (`@MainActor @Suite(.serialized) struct SearchAggregatorCharacterizationTests`), using the cache seam from Context.
  - Sources: `https://phase0-search.test/<n>`, each with a non-empty `searchUrl` and a fresh UUID. With more than one source, `SourceHealthStore.partition` runs; fresh UUIDs are never in cooldown.
  - Wait with a polling `waitUntil { !aggregator.isSearching }`, then read `results`.
  - Cases:
    - **Same title and author from two sources** → one `SearchBook` with two origins.
    - **First source has no author, second has 劉慈欣** → one row, whose author stays empty. Quirk: the first source to answer wins.
    - **Author containment of at least 2 characters merges; different authors give two rows.**
    - **Ranking for 「三體」:** exact 「三體」, then prefix 「三體II」, then contains 「地球往事三體」, then a match on the author only (score 0).
    - **Ties:** with equal scores, compare name length, then origin count. Assert the direction `sortResults` (1135-1180) actually uses.
    - **A book whose name and author do not relate to the query is dropped** (1074-1080).
  - Teardown:
    - `SearchResultCache.shared.clear(query:source:)` for every stored entry;
    - restore `searchCacheDays`;
    - `aggregator.cancelAndClear()`.
  - Side effect to note in the test file: `recordSuccess` writes health entries for the fake UUIDs. They are never in a real source list.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/SearchKeyCharacterizationTests' \
    -only-testing:'yuedu appTests/SearchAggregatorCharacterizationTests' \
    -only-testing:'yuedu appTests/ChangeSourceMatchTests'
  git commit --only -m "test(search): characterize result merging and ranking" -- "Tests/iOS/yuedu appTests/SearchAggregatorCharacterizationTests.swift"
  ```

### 0a.2 `BookOriginSearchServiceTests`

- [ ] **Step 1: Write the tests** with a fake `BookSourceFetching`, copied from `CountingBookSourceFetcher`. Each fake source returns a scripted list or throws.
  - `stream(…)`:
    - keeps only `isLikelySameBook` candidates;
    - removes duplicates across sources by `ChangeSourceCache.originKey`;
    - drops `excludingOriginKey`;
    - respects `sourceFilter`;
    - stops starting new sources once `shouldStop` returns true;
    - calls `onBatch` once per source that has candidates.
  - `searchSourceWithTimeout(…)`:
    - **a thrown error returns `nil`, the same as a timeout.** This is today's `try?`; label it. It is the follow-up "BookOriginSearchService swallows failures".
    - a fetcher slower than `seconds: 1` returns `nil`.
- [ ] **Step 2: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never -only-testing:'yuedu appTests/BookOriginSearchServiceTests'
  git commit --only -m "test(change-source): characterize origin search" -- "Tests/iOS/yuedu appTests/BookOriginSearchServiceTests.swift"
  ```

### 0a.3 `OnlineCoverSearchServiceTests`

- [ ] **Step 1: Write the tests** (`.serialized`).
  - Use a `URLProtocol` registered with `registerClass` for the two provider hosts; unregister it in `defer`. Responses have the shape `{"data":{"data":[…]}}`.
  - Cases:
    - results from both providers combine. Compare as sets, because provider order depends on which task finishes first.
    - the local title must contain the remote title: 「三體」 keeps 「三體」 and drops 「三體II」;
    - authors that contain one another match;
    - an unknown local author lets any author through;
    - one provider answering 500 still yields the other's results.
- [ ] **Step 2: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never -only-testing:'yuedu appTests/OnlineCoverSearchServiceTests'
  git commit --only -m "test(covers): characterize online cover search" -- "Tests/iOS/yuedu appTests/OnlineCoverSearchServiceTests.swift"
  ```

### 0a.4 `CustomExplorePageModelTests` (network-free state only)

- [ ] **Step 1: Write the tests** (`@MainActor`, `.serialized`; save and restore `BookSourceStore.shared.sources`).
  - `sync(with:)` builds one section per complete component, in page order, using the sources in `BookSourceStore.shared`.
  - A component whose source is missing gets the state `sync` gives it today.
  - `reload()` resets every section's state.
  - `loadMoreWaterfall()` does nothing without a waterfall section, after `hasMore == false`, or while a page is loading.
  - **Optional:** an `exploreUrl` that cannot form a URL. Keep the test only if `bridge.fetch` throws before any network request on every run; otherwise delete it.
- [ ] **Step 2: Record the gap** at the top of the file and under "What landed": loading success, failure and paging are not covered (decision 2).
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/CustomExplorePageModelTests' \
    -only-testing:'yuedu appTests/CustomExplorePageTests'
  git commit --only -m "test(explore): characterize custom page model state" -- "Tests/iOS/yuedu appTests/CustomExplorePageModelTests.swift"
  ```

### 0a.5 `DiscoverViewModelReloadTests`

- [ ] **Step 1: Write the tests** (`@MainActor`, `.serialized`).
  - **Explore disabled:** a source with `enabledExplore = false` → after `reload()`: no categories, no sections, and the `sourceNotice` that state produces today.
  - **Cache path:**
    - Pre-seed `DiscoverKindsCache.shared` under the key for `https://phase0-discover.test/source-a` (no runtime variable), then call `reload(forceRefresh: false)`.
    - Assert `categoryGroups`, the section list and its order, `showcaseItems`, and that no network was needed.
    - The category selection is stored under `discover.categorySelection.<UUID>`. Remove that key in teardown.
  - **Gap,** recorded in the file: `forceRefresh: true`, `loadSection` and paging need the network through the bridge (decision 2).
- [ ] **Step 2: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/DiscoverViewModelReloadTests' \
    -only-testing:'yuedu appTests/ExploreSettingsTests'
  git commit --only -m "test(explore): characterize discover reload" -- "Tests/iOS/yuedu appTests/DiscoverViewModelReloadTests.swift"
  ```

### 0a.6 `DiscoverKindsCacheTests`

- [ ] **Step 1: Write the tests.**
  - `key(…)` is deterministic, and changes when any of its three inputs changes. Also lock how a `nil` variable compares with an empty one.
  - `store` followed by `items` round-trips.
  - `store([])` leaves `items` returning nil.
  - Use deterministic keys under `phase0-kinds.test`. Never call `removeAll()`.
- [ ] **Step 2: Run, check, commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never -only-testing:'yuedu appTests/DiscoverKindsCacheTests'
  git diff main --stat -- Modules Targets   # must print nothing
  git commit --only -m "test(explore): characterize the discover kinds cache" -- "Tests/iOS/yuedu appTests/DiscoverKindsCacheTests.swift"
  ```

**0a acceptance:**
- the six new suites pass on unchanged production code;
- `git diff main --stat -- Modules Targets` is empty;
- the gaps are written down.

---

## Task 0b: Tell an empty search from a failed one, and log the failure

**Branch:** `unified-library/0b-search-outcome`.

**Files:**
- `BookSourceFetcher+Search.swift`
- `SearchAggregator.swift`
- create `Tests/iOS/yuedu appTests/BookSourceSearchOutcomeTests.swift`

**Unchanged on purpose:**
- every `SourceHealthStore` call;
- `SearchProgress.completed` and `failed`;
- `successfulSourceIds`;
- what `search(…)` returns or throws to each caller.

- [ ] **Step 1: Write the failing tests.**
  - **Mapping table** (pure, table-driven): `BookSourceSearchFailure.classify(_ error: Error, mode:)` returns one of three results: swallowed as a failure (with its reason), rethrown, or not a failure.
    - It must reproduce today's lines 117-145 for both modes.
    - Rows:
      - `.encodingError`;
      - each of 401, 403, 404, 429, 500, 502 and 503;
      - an unlisted 418;
      - `.emptyContent`;
      - `.invalidURL`;
      - `URLError(.notConnectedToInternet)`;
      - `CancellationError`.
  - **Through a stubbed fetcher:**
    - Build `BookSourceFetcher(webFetcher: WebFetcher(session:))` whose session has a `URLProtocol` stub in `protocolClasses`.
    - Use a native (non-JS) source at `https://phase0-search.test/s?q={{key}}` with a simple CSS `bookList` rule.
    - Give each test a unique query, so `SearchResultCache` never answers.
    - First confirm that `safeURL` accepts the stub host. If it does not, use another reserved name it accepts and say so in the file.
    - Cases:
      - a 200 page with two items → `.results` with two books;
      - a 200 page with the list container but no items → `.empty`;
      - a 403 → `.failed(.http(403))`, and `search(…)` returns `[]` in both modes;
      - `URLError(.notConnectedToInternet)` → `.failed(.transport)`. `search(…)` returns `[]` in `.emptyResult` and throws in `.propagateTransportError`.
      - a parse failure → `.failed(.parse)`, and `onHasMore` receives `false`. Use a `bookList` rule that makes `parseSearchResults` throw deterministically. If no rule does, the mapping-table row covers it; note that in the file.
  - **Log content:**
    - With the 403 case, `DiagnosticLog.shared.snapshot()` gains one warning line containing the source name, the host and 「403」.
    - No line contains the query string or the full search URL.
- [ ] **Step 2: Implement.**
  - In `BookSourceFetcher+Search.swift`:

    ```swift
    enum BookSourceSearchFailure: Error, Equatable, Sendable {
        case http(Int)
        case encoding
        case emptyContent
        case transport(String)   // the error's description, never the URL
        case parse(String)
    }

    enum BookSourceSearchOutcome: Sendable {
        case results([OnlineBook])
        case empty
        case failed(BookSourceSearchFailure)
    }
    ```

  - **`searchOutcome(query:in:page:earlyFilter:onHasMore:failureMode:)`:**
    - It holds today's body of `search(…)`, unchanged except at the four swallow points. Each of those calls the classifier, logs once, and returns `.failed(reason)`.
    - It still throws what `search(…)` throws today.
    - An empty list after `checkKeyWord` filtering is `.empty`.
    - The JS-runtime path is unchanged. Its errors already throw and reach the aggregator as `.failed`.
  - **`search(…)`** becomes `switch try await searchOutcome(…)`: `.results(let books)` → `books`; `.empty` and `.failed` → `[]`.
  - **The log line:**
    - `AppLogger.network("search failed; shown as no results", error:, context: ["source": source.bookSourceName, "host": url.host ?? "", "reason": …], level: .warning)`.
    - A parse failure uses `AppLogger.parse`.
    - Never pass the query, `resolvedUrlStr` or `url`.
  - **`SearchStreamingOutcome`** gains `failure: BookSourceSearchFailure?`. It is nil for cache hits and the JS path.
  - **In `SearchAggregator`:**
    - `SearchBatchResult.success` carries `failure`.
    - In `runSearch`'s `.success` case, keep every existing line, including `recordSuccess`, and add above it:

      ```swift
      // Phase 0b: a failure the fetcher reported as "no results" still counts as a
      // success here. Counting it in SourceHealthStore (cooldown) is design §17
      // item 9, not yet decided.
      ```

    - Count per search: answered with results, legitimately empty, and failed but reported as empty. Reset the counts in `search(query:sources:)`. Add them to the completion and auto-pause lines of `logPublicationSummary`.
  - **Log volume:**
    - One warning per swallowed failure, plus the existing summary.
    - `DiagnosticLog` keeps a snapshot of at most 6,000 lines (`snapshotLimit`) and rotates its file at 2 MB (`rotateBytes`). Report how many lines a 1,000-source search with many dead sources adds, and whether that can push older lines out of the snapshot.
    - If it can, describe the numbers under "What landed" and ask the maintainer before changing the level. Do not silence the lines on your own.
- [ ] **Step 3: Run the new tests and the regression set from design §19.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/BookSourceSearchOutcomeTests' \
    -only-testing:'yuedu appTests/NetworkSettingsSearchTests' \
    -only-testing:'yuedu appTests/SearchSourceScopeTests' \
    -only-testing:'yuedu appTests/SearchResultPublicationGateTests' \
    -only-testing:'yuedu appTests/IOS17SearchResultTableTests' \
    -only-testing:'yuedu appTests/AggregateSearchStreamingTests' \
    -only-testing:'yuedu appTests/BookSourceHealthCheckerPerformanceTests' \
    -only-testing:'yuedu appTests/ChangeSourceMatchTests'
  ```

  - Once 0a is merged, also run `SearchKeyCharacterizationTests` and `SearchAggregatorCharacterizationTests`; they must pass unchanged.
  - `BookSourceHealthCheckerPerformanceTests` is there because it is the one caller of `.propagateTransportError`.
- [ ] **Step 4: Commit.**

  ```bash
  git commit --only -m "fix(search): tell failed source searches from empty ones and log them" -- <your files>
  ```

**0b acceptance:**
- every caller of `search(…)` gets the same books and the same errors as before;
- `SourceHealthStore` calls are byte-for-byte the same lines;
- each swallowed failure leaves one log line with the source, host and reason, and no query;
- the completion summary separates results, empty and failed-as-empty.

---

## Task 0c: Move WebDAV folder listing into a model

**Branch:** `unified-library/0c-webdav-browse-model`.

**Files:**
- create `Modules/Services/WebDAV/WebDAVBrowseModel.swift`
- `Modules/Features/Bookshelf/RemoteImportViews.swift`
- create `Tests/iOS/yuedu appTests/WebDAVBrowseModelTests.swift`

- [ ] **Step 1: Write the failing tests** (`@MainActor`). Build the model with a `list` closure; to control timing, use `CheckedContinuation`s, not sleeps.
  - **Success:** fills `entries` and sets `didLoad`; `loadError` is nil and `isLoading` is false.
  - **Failure:** `loadError` equals the thrown error's `localizedDescription`, `entries` stays empty, and one `AppLogger.network` line with the host (not the path) reaches `DiagnosticLog`.
  - **Removed connection:** a `connectionID` that `RemoteLibraryConnectionStore.shared` does not know gives the existing message 「書庫連線已移除，請重新加入伺服器。」.
  - **Stale request:** start load A and hold it; start load B and let it finish; then release A. B's entries remain.
  - **Cancellation:** a cancelled load sets no error.
  - **Reload after success:** replaces `entries`, as pull-to-refresh does today.
- [ ] **Step 2: Implement the model,** mirroring `OPDSBrowseModel`:

  ```swift
  @MainActor
  final class WebDAVBrowseModel: ObservableObject {
      @Published private(set) var entries: [WebDAVBrowseClient.Entry] = []
      @Published private(set) var isLoading = true
      @Published private(set) var didLoad = false
      @Published private(set) var loadError: String?

      init(route: WebDAVDirectoryRoute,
           list: ((URL) async throws -> [WebDAVBrowseClient.Entry])? = nil)

      func load() async
  }
  ```

  - `load()` keeps today's order: clear the error, check the connection, list, check cancellation, publish.
  - It adds a request-ID guard and `AppLogger.network("WebDAV listing failed", error:, context: ["host": route.url.host ?? ""])`.
  - With no `list` override, it uses `RemoteLibraryConnectionStore.shared.webDAVClient(for:).list(_:)`.
- [ ] **Step 3: Slim the view.**
  - `WebDAVDirectoryView` holds `@StateObject private var model`, built in `init(route:list:)`; `list` defaults to nil and exists for the preview.
  - Remove the four `@State` loading properties. Keep `searchText`, and `visibleEntries` via `RemoteLibraryBrowsePresentation.filtered(model.entries, …)`.
  - These stay identical and now call `model.load()`:
    - `.task(id: route.url)` with the `didLoad` guard;
    - `.refreshable`;
    - `.onReceive(.remoteLibraryDidChange)` for this connection;
    - the 「重試」 button.
  - The error section, the overlay (`ProgressView` / `ContentUnavailableView`), the navigation links and the toolbar do not change.
  - Add a `#Preview` with two folders and one EPUB from a fake `list`, and one preview in the failed state.
  - Invoke `yuedu-ios-design`. With VoiceOver, the list, the error section and 「重試」 read the same as before.
- [ ] **Step 4: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/WebDAVBrowseModelTests' \
    -only-testing:'yuedu appTests/RemoteLibraryBrowsePresentationTests' \
    -only-testing:'yuedu appTests/RemoteLibraryConnectionTests' \
    -only-testing:'yuedu appTests/RemoteLibraryHTTPTests' \
    -only-testing:'yuedu appUITests/RemoteLibraryNavigationUITests'
  git commit --only -m "refactor(webdav): move folder listing out of the view" -- <your files>
  ```

  - Tell the maintainer before the UI test, so the simulator is left alone.
  - `RemoteLibraryNavigationUITests` only opens the WebDAV screen. The model tests are the evidence for listing.
  - If the maintainer has a WebDAV server at hand, browsing two folder levels in the simulator is a worthwhile manual check. Record whether it was done.

**0c acceptance:**
- `WebDAVDirectoryView` makes no network call;
- the screen looks and reads the same;
- failures are now logged;
- the model tests cover success, failure, a removed connection, staleness and cancellation.

---

## Task 0d: Never overwrite a custom Explore file that failed to load

**Branch:** `unified-library/0d-custom-explore-write-guard`.

**Files:**
- `Modules/Services/Online/CustomExplorePageStore.swift`
- create `Tests/iOS/yuedu appTests/CustomExplorePageStoreWriteGuardTests.swift`

**Decision:** option (b), decision 8. Copy the unreadable file aside, then allow writes; block writes only when the copy cannot be made or the file cannot be read. The template is `BookReaderSettingsStore` (`load()` 151-170, `keepUnreadableFile` 174-191, guarded `save()` 194-198) and its test `BookReaderSettingsStoreTests.swift:73`.

- [ ] **Step 1: Write the failing tests** (`@MainActor`; each uses its own temporary directory, so the corrupt copy lands beside the file and is cleaned up with it).
  - **Decode failure:**
    - Write `"{ not json"` and open the store: `pages` is empty.
    - A file whose name contains `corrupt` now sits beside it, holding exactly the original bytes.
    - `createPage` then writes a valid file, and a second store opened on the same path reads that page back.
    - The corrupt copy is still there and unchanged after the write.
  - **Opening the same corrupt file twice** (two store instances before any write) leaves one copy, not two. Either name the copy after the file's modification time, as `BookStore.keptUnreadableMetadataAside` does, or treat an existing copy with identical bytes as done.
  - **Read failure:** make `fileURL` a directory, so `Data(contentsOf:)` throws. No copy can be made, so writes are blocked: mutations neither crash nor create anything at that path, and one `AppLogger.cache` line says why per refused save.
  - **Copy failure:** if the copy cannot be written (for example, the directory is read-only), writes are blocked and the original bytes stay unchanged.
  - **No file:** `createPage` writes the file, and a second store reads the page back. This guards the normal first launch.
- [ ] **Step 2: Implement.**
  - Add `private var writesBlocked = false`.
  - In `load()`:
    - a missing file stays normal;
    - a failed read sets `writesBlocked = true` and logs;
    - a failed decode logs (keep the existing `⟐ … could not be read` line) and calls `keepUnreadableFile(data)`;
  - `keepUnreadableFile(_:)` writes the bytes to `fileURL.deletingPathExtension().appendingPathExtension("corrupt-<stamp>.json")` with `.withoutOverwriting`. If that fails, it sets `writesBlocked = true` and logs.
  - In `save()`: `guard !writesBlocked else { AppLogger.cache(…); return }`.
  - Comment on `writesBlocked`: what it guards, and that it lifts only on the next launch once the file reads.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/CustomExplorePageStoreWriteGuardTests' \
    -only-testing:'yuedu appTests/CustomExplorePageTests'
  git commit --only -m "fix(explore): never overwrite a custom page file that failed to load" -- <your files>
  ```

**0d acceptance:**
- a file that cannot be decoded is kept aside byte-for-byte before any write; one that cannot be read, or cannot be copied, is never written over;
- a missing file still saves;
- the existing `CustomExplorePageTests` pass;
- Phase 5's migration can find the original, either in place or as the `corrupt` copy.

---

## Task 0e: The `search.firstResult` span

**Branch:** `unified-library/0e-search-first-result-span`.

**Files:**
- `SearchAggregator.swift`
- `SourceSearchSheet.swift`
- `SourcePerfTrace.swift`
- create `Tests/iOS/yuedu appTests/SearchFirstResultSpanTests.swift`

**What it measures:** from `search(query:sources:)`, which `doSearch` calls synchronously on submit, to the end of the first `mergeBatch` that merged at least one book for that search.

- [ ] **Step 1: Write the failing tests** (`@MainActor`, `.serialized`).
  - Use 0a's cache seam. Set `DiagnosticLog.shared.isVerboseEnabled = true` and restore it in `defer`.
  - **One search with cached results** → exactly one new snapshot line starting `⏱ search.firstResult`, containing `origin=searchTab` and `cacheDays=1`. Count lines before and after.
  - **A second search** adds exactly one more line.
  - **`search(…, origin: .changeSource)`** → the line says `origin=changeSource`.
  - **`cancelAndClear()` before anything merged:** start with sources that have nothing cached and a `searchUrl` on an unreachable `.test` host, then cancel at once. No line is added.
- [ ] **Step 2: Implement.**
  - `enum SearchOrigin: String { case searchTab, changeSource }`
  - `func search(query:sources:origin: SearchOrigin = .searchTab)`. `SourceSearchSheet` passes `.changeSource`; `BookSearchView` keeps the default.
  - State: `private var searchGeneration = 0`, and `private var firstResultTrace: (generation: Int, start: TimeInterval, detail: String)?`.
  - `search(…)` increments `searchGeneration` and sets `firstResultTrace` with `SourcePerfTrace.now` and `"origin=… sources=\(activeSources.count) cacheDays=\(GlobalSettings.shared.searchCacheDays)"`.
  - `runSearch` captures `let generation = searchGeneration` and passes it to both of its `mergeBatch` calls. `loadMore` passes `nil`, so it never records.
  - At the end of `mergeBatch`, after `guard mergedCount > 0, !Task.isCancelled`: if `firstResultTrace?.generation == generation`, call `SourcePerfTrace.record("search.firstResult", detail + " books=\(mergedCount)", since: start, thresholdMs: 0)` and set the trace to nil.
  - `pause()`, `cancel()` and `cancelAndClear()` set `firstResultTrace = nil`. A resumed search therefore records nothing; its interval would include the pause.
  - Add `search.firstResult` to the stage list in `SourcePerfTrace.swift`'s header, next to `search.presentation.*`.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/SearchFirstResultSpanTests' \
    -only-testing:'yuedu appTests/NetworkSettingsSearchTests' \
    -only-testing:'yuedu appTests/SearchSourceScopeTests' \
    -only-testing:'yuedu appTests/SearchResultPublicationGateTests' \
    -only-testing:'yuedu appTests/IOS17SearchResultTableTests'
  git commit --only -m "perf(search): measure the time to the first search result" -- <your files>
  ```

  Once 0a is merged, add `SearchAggregatorCharacterizationTests`.
- [ ] **Step 4: Baseline. This is the maintainer's step; an agent cannot take it.**
  1. Build Release onto the maintainer's iPhone, with their own source library.
  2. Set 網路設定 →「搜索結果快取天數」 to 0.
  3. In the 搜索 tab, search each baseline query three times (open question 2).
  4. In Console.app, filter on `⏱ search.firstResult`. Keep only `origin=searchTab cacheDays=0` lines.
  5. Record, per query, the three values, the median and `sources=` in the Baseline table below. Note the date, the build number and the network (Wi-Fi or cellular).
  6. Restore the cache setting.

**0e acceptance:**
- the span appears in a Release build's Console, once per search, tagged with origin and cache setting;
- `loadMore`, cancelled and resumed searches record nothing;
- the baseline table is filled in.

---

## Acceptance (Phase 0)

- [x] 0a: six characterization suites; no production diff; gaps recorded (see What landed).
- [x] 0b: `empty` and `failed` are distinct and logged; callers and `SourceHealthStore` unchanged.
- [x] 0c: the WebDAV view no longer calls the network; behavior and VoiceOver unchanged.
- [x] 0d: a corrupt custom Explore file is kept aside before any write, or never written over.
- [x] 0e: `search.firstResult` in Release Console; baseline recorded (simulator, see Baseline).
- [ ] Every step: its own branch from `main`; its tests and the §19 regression pass after its last edit; nothing pushed or merged without the maintainer's yes.

## Follow-ups found while planning

Not part of Phase 0. Listed so the maintainer can decide.

1. **`BookOriginSearchService` swallows failures with `try?`** (`BookOriginSearchService.swift:139`). 換源 and 換封面 cannot tell a failed source from one without the book. 0a.2 locks the current behavior.
2. **`OnlineCoverSearchService` uses `URLSession.shared` directly** (audit §16 item 10). It bypasses `safeURL` and `SourceRateLimit`.
3. **Discover and custom-page loading have no seam** (decision 2). Phase 5's loaders should take an injected fetcher from the start.
4. **Stale comments in `SearchAggregator`** (audit §16 item 11): the timeout comment says 15 seconds where the code uses 12, and the normalization comment says "strip punctuation" where it does not strip.
5. **Phase 5's migration must also read `custom_explore_pages.corrupt-*.json`** (decision 8), or at least tell the reader that an unreadable copy was kept.

## What landed

_Fill in per step: commit, test verdict lines, surprises, and anything left undone._

### 0a (2026-10-10)

Branch `unified-library/0a-characterization`, six commits on `772b0c95`: `dabdee71`, `1f320e79`, `86bf45e8`, `34ab13c4`, `d6a097f4`, `26938459`. Test files only; `git diff main --stat -- Modules Targets` is empty. Not merged, not pushed.

Evidence (`scripts/xctest.sh`, iPhone 18 Pro, iOS 27.0, in a worktree with its own DerivedData, after the last edit):

```
✔ Test run with 23 tests in 4 suites passed after 1.240 seconds.
   (SearchKeyCharacterizationTests, SearchAggregatorCharacterizationTests,
    BookOriginSearchServiceTests, OnlineCoverSearchServiceTests)
✔ Test run with 32 tests in 5 suites passed after 0.175 seconds.
   (CustomExplorePageModelTests, DiscoverViewModelReloadTests, DiscoverKindsCacheTests,
    plus the existing CustomExplorePageTests and ExploreSettingsTests)
✔ Test run with 8 tests in 1 suite passed after 0.033 seconds.   (ChangeSourceMatchTests)
```

Every new test passed on unchanged code the first time; no expectation had to be corrected.

Behavior the tests now lock that the audit did not mention:
- `OnlineCoverSearchService` keeps a remote title that the local title merely contains, so 「三」 passes for 「三體」.
- `DiscoverKindsCache.key` gives the same key for no variable and an empty one, and joins its inputs with an unescaped `|`, so `("a|b", "c")` and `("a", "b|c")` collide.
- `CustomExplorePageModel.sync` rebuilds an edited block with new section ids (`DiscoverCardItem.id` is a fresh `UUID`), while an unchanged block keeps its ids.
- A `DiscoverViewModel.reload` maps fresh items, so every section gets a new id and starts over, even from the cache.

Left undone, as planned (decision 2): loading, failure and paging for `CustomExplorePageModel` and `DiscoverViewModel`. The optional invalid-URL failure test in 0a.4 was not attempted, because it could not be shown to stay offline.

### 0d (2026-10-10)

Branch `unified-library/0d-custom-explore-write-guard`, one commit on `772b0c95`: `02801265`. Not merged, not pushed.

- `CustomExplorePageStore` (option (b), decision 8):
  - a read failure sets `writesBlocked`;
  - a decode failure copies the bytes to `…corrupt-<mtime>.json` with `.withoutOverwriting`, then writes go on as usual;
  - a second open before any write finds the identical copy and does not add one, as `BookStore.keptUnreadableMetadataAside` does;
  - a copy that cannot be made sets `writesBlocked`;
  - `save()` refuses while blocked and logs `⟐ custom explore pages not saved: <file> could not be read at launch`.
- Tests, `CustomExplorePageStoreWriteGuardTests`:
  - decode failure: the copy is made, then a fresh file is written and reads back;
  - two opens leave one copy;
  - an unreadable file (mode `000`): four edits, four refusals, the original is unchanged;
  - an uncopyable file (read-only folder): one refusal, the original is unchanged;
  - no file: saves normally.
- Before the fix, four of the five failed; only "no file" passed. The unreadable-file test showed the original being replaced, which is the bug. The uncopyable case failed only on the refusal count, since a read-only folder also defeats the atomic write.

```
✔ Test run with 10 tests in 2 suites passed after 0.326 seconds.
   (CustomExplorePageStoreWriteGuardTests 5, CustomExplorePageTests 5)
```

### 0c (2026-10-10)

Branch `unified-library/0c-webdav-browse-model`, one commit on `772b0c95`: `560377f9`. Not merged, not pushed.

- **New `WebDAVBrowseModel`** (`Modules/Services/WebDAV/WebDAVBrowseModel.swift`), shaped like `OPDSBrowseModel`:
  - `@MainActor ObservableObject` with an optional `list` closure in `init`;
  - `isLoading` starts true, as the view's `@State` did;
  - a request-ID guard;
  - `AppLogger.network("WebDAV listing failed (<host>)", error:)` on failure;
  - a cancelled or superseded load returns without touching state, keeping the view's old behavior for cancellation.
  - With a `list` override, the connection lookup is skipped. That is how tests and previews run without a saved connection.
- **`WebDAVDirectoryView`:**
  - four `@State` properties became one `@StateObject`;
  - `init(route:list:)`;
  - `load()` forwards to the model.
  - The body, `.task(id:)` with its `didLoad` guard, `.refreshable`, `.onReceive(.remoteLibraryDidChange)` and 「重試」 are unchanged, so the screen and VoiceOver read the same.
  - Two `#Preview`s were added: a folder with two folders and an EPUB, and the failed state.
- **New behavior, both intended:** an earlier load that answers last no longer overwrites a later one, and failures are logged.
- **`WebDAVBrowseModelTests`** covers success, failure with its log line, failure after a listing, a removed connection, reload, a stale load, and a cancelled load. The stale and cancelled cases are held by a continuation, not a sleep.
- **Static checks:** `yuedu-ios-design` checks pass (`check_localizations`, `git diff --check`, no title-mode change).
- **Manual check not done:** browsing two folder levels against a real WebDAV server was not tried, because none was at hand.

```
✔ Test run with 33 tests in 4 suites passed after 0.598 seconds.
   (WebDAVBrowseModelTests 7, RemoteLibraryBrowsePresentationTests,
    RemoteLibraryConnectionTests, RemoteLibraryHTTPTests)
RemoteLibraryNavigationUITests: Executed 1 test, with 0 failures (0 unexpected) in 36.666 (36.669) seconds
```

`RemoteLibraryNavigationUITests` only opens the WebDAV screen; the model tests are the evidence for listing.

### 0e (2026-10-10)

Branch `unified-library/0e-search-first-result-span`, one commit on `772b0c95`: `b9c83ce1`. Not merged, not pushed. The baseline (Step 4) is still the maintainer's to take.

- **`SearchAggregator`:**
  - `SearchOrigin { searchTab, changeSource }`, and `search(query:sources:origin: = .searchTab)`;
  - `searchGeneration`, plus `firstResultTrace` set in `search(…)` with `origin= sources= cacheDays=`;
  - `runSearch` passes its generation to both `mergeBatch` calls, and `loadMore` passes nil;
  - the span is recorded once, after the first merge that added a book: `⏱ search.firstResult <ms> origin=… sources=… cacheDays=… books=…`, `thresholdMs: 0`;
  - `pause()`, `cancel()` and `cancelAndClear()` clear it.
- **`SourceSearchSheet`** passes `.changeSource`. The `SourcePerfTrace` header lists the new stage.
- **`SearchFirstResultSpanTests`** (five tests) uses 0a's cache seam, with verbose on and restored afterwards:
  - one line per search, tagged with origin, sources, cache setting and books;
  - each new search adds its own line;
  - 換源 is tagged `changeSource`;
  - a search cleared before anything merged adds nothing beyond the next search's line. This is weak evidence: the cleared search never ran.
  - a paused and resumed search adds nothing. This is the test that proves pause clears the trace.
- **Two wrong turns in the test before it was right.** Counting span lines across the whole snapshot failed, because the snapshot holds only the latest 6,000 entries. Filtering by timestamp failed, because the log stores timestamps to the second. Telling new lines from old by entry id works.
- **A production issue surfaced on the way:** `DiagnosticLog`'s `sequence` restarts at 0 every launch, but `snapshot()` sorts several launches by it, and the persisted "acknowledged" sequence is compared with it. It was flagged as a separate task and is not part of Phase 0.

```
✔ Test run with 33 tests in 5 suites passed after 0.827 seconds.
   (SearchFirstResultSpanTests 5, NetworkSettingsSearchTests, SearchSourceScopeTests,
    SearchResultPublicationGateTests, IOS17SearchResultTableTests)
```

### 0b (2026-10-10)

Branch `unified-library/0b-search-outcome`, one commit on `31ca4ba0` (main with 0a, 0c, 0d and 0e merged): `723a8308`. Not merged, not pushed.

- **`BookSourceFetcher+Search.swift`:**
  - New types: `BookSourceSearchFailure` (`http`, `encoding`, `emptyContent`, `transport`, `parse`, `cancelled`) and `BookSourceSearchOutcome` (`results`, `empty`, `failed`).
  - The pure `BookSourceSearchFailure.disposition(of:mode:)` holds the old lines 117-145 mapping, unchanged in both modes.
  - `searchOutcome(…)` holds the old body, and `search(…)` is a one-line wrapper over it.
  - `SearchStreamingOutcome.failure` carries the failure to the aggregator.
  - A cancelled request still comes back as no results, but is classified `.cancelled` and not logged, because it is not the source's fault.
- **Logging:** one `AppLogger` warning per failure: `search failed; shown as no results: <source> (<host>) <reason>`. It never contains the URL or the query.
  - **Maintainer's choice (2026-10-10): only `.emptyResult` searches log.** That covers the 搜索 tab, 換源 and cover search. 書源驗證 (`.propagateTransportError`) does not log, since its own results list each source's failure, and a run over tens of thousands of sources would push everything else out of the 6,000-line diagnostic snapshot.
- **`SearchAggregator`:**
  - `SearchBatchResult.success` carries `answer: .results | .empty | .failedAsEmpty`;
  - a per-search tally is reset in `search(…)` and printed in `search.listPublish.summary` as `answered= empty= failedAsEmpty=`.
  - Every `SourceHealthStore` call and the progress counters are byte-for-byte unchanged. The only added line there is the §17 item 9 comment above `recordSuccess`.
- **Log volume:** at most two lines per failing source per search. Page 1 fails; the source still counts as successful, so 載入更多 asks it for page 2 once. That page adds no books, so the source is marked exhausted. Each line is about 150 bytes, so a 1,000-source search with 300 dead sources adds about 300–600 lines, roughly 45–90 KB of the 2 MB file.
- **Not covered by a test:** the parse-failure path through a real request. No rule was found that makes `parseSearchResults` throw deterministically. The code path is the same `logReportedAsEmpty` call, and the `.parse` reason is set there.
- **`BookSourceSearchOutcomeTests`** has 11 tests:
  - the mapping table, for both modes, cancellation, and unlisted statuses;
  - through a stubbed `WebFetcher(session:)`: a page with books, a legitimately empty page, a 403 in both modes, an unlisted 418 (thrown), a transport error in both modes;
  - the log line's content, and no log in validation mode.

```
✔ Test run with 84 tests in 12 suites passed after 2.471 seconds.
   (BookSourceSearchOutcomeTests 11, NetworkSettingsSearchTests, SearchSourceScopeTests,
    SearchResultPublicationGateTests, IOS17SearchResultTableTests, AggregateSearchStreamingTests,
    BookSourceHealthCheckerPerformanceTests, ChangeSourceMatchTests, and 0a/0e's
    SearchKeyCharacterizationTests, SearchAggregatorCharacterizationTests,
    SearchFirstResultSpanTests, BookOriginSearchServiceTests)
```

**Baseline note:** take 0e's baseline on a build of `31ca4ba0` (before this branch), as decision 11 intends.

## Baseline: `search.firstResult` (before Phase 4)

Taken 2026-10-10 by the agent at the maintainer's request, not on the maintainer's iPhone.

**Setup** (repeat it exactly for Phase 4's "after"):
- **Build:** `31ca4ba0`, the 0e span without 0b. The Debug configuration with Release-level optimization (`SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s`). Not the Release configuration, because its "Crashlytics Upload Symbols" phase would upload simulator dSYMs to Firebase.
- **Device:** iPhone 18 Pro simulator (iOS 27.0) on the Mac's network.
- **Sources:** the eight files in `~/Desktop/Test document/RULE`, merged into `book_sources.json`. The app keeps six after de-duplicating by URL: the 光遇, 大灰狼 and 书山 aggregators, 含遇見, 聚合段评, and 起点.
- **Cache:** 網路設定 →「搜索結果快取天數」 = 0, written to the app container's own preferences. Every line shows `cacheDays=0`.
- **Driver:** a temporary XCUITest, `BaselineSearchUITests`, not committed. It types into the 搜索 tab and waits for the previous run's rows to disappear before the next search. One app launch; the queries run in table order.
- **Queries:** Simplified Chinese, because every source is a Simplified Chinese site and search does not fold Traditional into Simplified (0a locks this). 三體 would match nothing.

| Date | Build | Network | Query | `sources=` | Runs (ms) | Median (ms) |
|---|---|---|---|---|---|---|
| 2026-10-10 | `31ca4ba0`, -O, simulator | Mac host network | 三体 | 6 | 1080, 380, 385 | 385 |
| 2026-10-10 | `31ca4ba0`, -O, simulator | Mac host network | 斗罗大陆 | 6 | 315, 344, 301 | 315 |
| 2026-10-10 | `31ca4ba0`, -O, simulator | Mac host network | 凡人修仙传 | 6 | 366, 368, 330 | 366 |

The first run (1080 ms) is the first search after launch, and it includes creating the sources' JS sessions. The other eight runs fall between 301 and 385 ms.

A first attempt the same day measured cache hits, 20–40 ms with `cacheDays=5`, because the cache setting had gone to the simulator's global defaults instead of the app's. It was discarded.
