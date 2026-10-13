# Discovery, Phase 7a: 為你推薦 on device — plan

> **For agentic workers:** each step has its own branch, its tests and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push.

**Goal:** a home section, 為你推薦, mixed on the device from what the reader's own sources already offer, ranked by the signals in `Technotes/DiscoveryEngine-2026-10-11-draft.md` (source mix, genre match, exploration, cross-source dedupe, recent reading), without the home requesting dozens of sources each time it opens.

**Not in this phase:** a server, a book index of works the reader has no source for, regional charts, licensed metadata APIs, AI ranking. They stay in the draft's later steps; `ForYouInput` is the seam they would join.

## Maintainer's decisions (2026-10-13, by option)

1. **Candidates come from the categories already on the home, and the section can add more.** By default: every book-source category the reader's 首頁配置 shows (`.sourceCategories`) and each source's 「最新」 category (`parameters["latest.category:<url>"]`). The section's own options add or remove categories. Nothing is guessed from a category's name (Phase 5 decision 24).
2. **A local cache, refetched after 12 hours.** The home opens on the cache. A category is fetched again when its cache is older than 12 hours, or on pull to refresh; one source at a time, one category at a time.
3. **Genre preference is recorded on the device.** Opening a book records the categories its source gave it (a book source's `kind`, an OPDS category, an EPUB's subjects) in a local file. The shelf's data and the sync format do not change.
4. **Everyone gets the section once.** A new install's 預設 has it. A saved home gets it inserted once.

## Settled here (each changeable on the maintainer's word)

- **Library rows on the home are inputs too, at no extra request.** As decision 1 makes the home's categories the inputs, the library rows on the same home (Gutenberg's 熱門, 青空文庫's 新着, an OPDS or Calibre 「最新」…) are inputs through what those rows already loaded in this session. 為你推薦 never requests a library itself. A default home has 古騰堡熱門 (not in China), so a home without book sources is not empty.
- **The insertion for saved homes goes into the 首頁配置 the reader is on** (the selected one; 預設 when none is), after 系列下一本 (or 繼續閱讀, or first), once. A one-time flag (`home.forYouInserted`) records it; deleting the section afterwards sticks.
- **No rank, no score is shown** (`docs/design.md`: 不捏造排行或評分). 為你推薦 only orders books. Layouts: `row`, `coverGrid`, `multiRow`, `list`, `featured`; not `rankedList`. Default `row`.

## Architecture

```
DiscoverFirstPages (one per home model)          — the one place a category's first page is fetched
 ├─ per-source lane: one discover request at a time per source, rows and 為你推薦 alike
 ├─ in flight: a second ask for the same category joins the first request
 ├─ cookie priming once per source per sync (moved out of BookSourceProvider)
 └─ writes every result to ForYouCandidateStore (disk, 12 h)

BookSourceProvider (.sourceCategories, 「最新」 rows) → DiscoverFirstPages.fetch       — always fetches, as today
ForYouProvider (.forYou, policy .withHome)
 ├─ inputs: the home's book-source categories + the section's own additions
 ├─ fresh in ForYouCandidateStore → used as is; stale or missing → DiscoverFirstPages.fetch
 ├─ library inputs: the loaded entries of the library rows on this home (no request)
 ├─ ReadingGenreProfile (local file)  — tag weights from books opened
 ├─ ForYouExposureLog (local file)    — works shown, for exploration
 └─ ForYouRanker.rank(...) (pure)     — dedupe, score, mix, explore → [CollectionEntry]
```

- **One path per concern:** every first-page request, a row's or 為你推薦's, goes through `DiscoverFirstPages` → `SectionPageLoader.live` → `BookSourceFetcher.discoverBooks` → `BookSourceSession.session(for:)`. HomeModel's own per-source queue (`queueTails`) stays for rows; the lane under it is what serializes 為你推薦 against them (the JS bridge's shared state is not safe for parallel discover fetches; Phase 5 plan, Requests).
- **Requests:** a category a row and 為你推薦 both want is requested once when they ask together. 為你推薦 refetches only stale categories (12 h), one at a time; it may refetch a category its row then fetches again on view, at most once per 12 hours (rows keep always fetching, as today). It starts when the home appears, after the withHome library rows it reads have settled, and stops when the home goes away.
- **Work identity:** `WorkMatchKey` (title key, compatible authors), the rule `WorkIndex` uses for its B-level match. A work shows once; the entry kept is the one from the source ranked first, and the others are kept as alternatives in the cache only (opening uses the kept one).
- **Errors:** a failed category keeps its last cached books and is logged (`AppLogger`), never swallowed; a category with no cache and a failure contributes nothing. The section fails only when every input failed and nothing is cached.

## Steps

**Test-first for 7a-1 to 7a-3:** each is a new pure or storage type, so its tests are written and seen failing before the code.

### 7a-1: the candidate cache and the one first-page fetch

- `OnlineBook` becomes `Codable` (its fields already are).
- `ForYouCandidateStore`: `Caches/ForYou/<md5(sourceURL|category url)>.json` holding `{sourceURL, categoryURL, fetchedAt, books: [OnlineBook]}` (first page, at most 40). `isFresh(at:)` is 12 hours. Reads tolerate a missing or undecodable file (logged, treated as absent); writes are atomic on a serial queue.
- On reading, each book's `sourceId` is set to the current source's id (a re-imported source has a new one).
- `DiscoverFirstPages`: the per-source lane, in-flight joining and cookie priming above; `BookSourceProvider` moves onto it (its rows behave as before: always fetched, primed once).
- Tests: round trip; freshness at 11:59 and 12:01; undecodable file is absent and logged; a re-imported source's id; two asks for one category send one request; two categories of one source never run at once; another source's do; a row's fetch is written to the store. `BookSourceProviderTests` unchanged and passing.

### 7a-2: the genre profile

- `ReadingGenreProfile`: `Application Support/ForYou/genres.json`, local only. `record(tags:at:)` adds weight 1 per tag; weights decay with a 30-day half-life when read. `weights(at:)` returns normalized weights; at most 200 tags kept (lowest dropped).
- Tags are normalized: trimmed, NFKC, Traditional/Simplified folded (as `WorkMatchKey` folds), digits-only and one-character tags dropped, `WorkSummary.category(fromSourceKind:)`'s separators split a `kind`.
- **Where it is recorded:** a service, `ReadingGenreRecorder.bookOpened(_:)`, called once by each reader's open path (`ReaderView`, the fixed-page reader); the views do not assemble tags. Tags come from: the copy's sidecar `MetadataField.tags` (EPUB subjects, Calibre tags, Aozora NDC), else an online copy's cached `BookInfoPackage.kind`. Opening the same book again within a day does not count twice.
- File errors are logged through `AppLogger`, never dropped with `try?`.
- Tests: decay; normalization; the cap; the once-a-day rule.

### 7a-3: the ranker (pure)

- `ForYouRanker.rank(candidates:profile:recent:exposure:languages:seed:limit:)` → `[CollectionEntry]`:
  1. **Dedupe** by work key; drop books already on the shelf: `WorkMatchKey` against every shelf copy (`store.books`), online copies included (`CopyLookup` leaves book-source copies out, so it is not used here).
  2. **Score:** genre match (sum of the book's tag weights), recent reading (same author as a book in 繼續閱讀: a fixed bonus; a shared tag: half), a small position bonus from the source's own order. Weights are constants in one place, placeholders until measured.
  3. **Mix:** no input source holds more than `ceil(limit / 3)` of the result; a source's next book is taken only after every other source has had a turn at that score band.
  4. **Explore:** a quarter of the slots go to books not shown in the last 7 days (`ForYouExposureLog`), chosen by `seed` (the refresh day), so a refresh brings unseen books and the order is stable within a day.
  5. **Languages:** `ReadingLanguagePreferences.arrange`, as the home's other sections.
- With no profile (a new reader), the score is the sources' own order, still mixed and explored.
- Tests: dedupe across sources; the shelf excluded, an online shelf copy included; the cap; exploration share and stability for a seed; a new reader; languages.

### 7a-4: the section

- `HomeSectionBinding.forYou` (stored `"forYou"`; an older build keeps it as `.unknown`). App 資料 lists it (`HomeSectionBinding.appData`); its title is 為你推薦; `HomeReadFilter` hides read books in it; `HomeSectionGroup` orders it like 「最新」.
- `ForYouProvider` (registry: one, after the libraries). Policy `.withHome`. Load: resolve inputs; read the cache; take the library rows' loaded entries; fetch the stale categories through `DiscoverFirstPages`, a source's one at a time and the sources side by side (changed in 7a-5 from one at a time overall); rank. Pull to refresh treats every category as stale.
- **Options** (the section form): 來源分類 — the inputs, each removable, with 「加入分類」 pushing the existing category picker. Stored in `section.parameters` (`forYou.categories`, `forYou.excluded`), so the schema version is unchanged. The home's library rows always count (the 書庫欄目 switch was dropped in review: a library the reader keeps on the home is one they want).
- **Defaults and migration:** `HomePageDefaults` puts it after 系列下一本; `HomePageStore` inserts it once into the selected 首頁配置 (`home.forYouInserted`).
- `#Preview`s with real-shaped data and a large-text variant; VoiceOver reads each card as the other rows' cards do.
- Tests: binding round trip and unknown-build preservation; defaults in both modes and China; the one-time insertion into the selected 首頁配置 (and not again after deletion); provider: fresh cache sends no request, a stale category is fetched once, a row and 為你推薦 sharing a category send one request, a failure keeps the old books and is logged, library inputs send no request. UI (iOS 27 and 17.5): the section appears on a new install's home from a fixture source and opens a book; 新增欄目 offers it.

### 7a-5: measurement

- `SourcePerfTrace` spans: `forYou.cache`, `forYou.fetch` (per category), `forYou.rank`. Report, on a fixture of 5 sources × 3 categories with a Gutenberg 熱門 row: every request (book-source and library) and milliseconds for a cold home, a warm home (expected: no request added by 為你推薦) and a pull to refresh.

## Acceptance

- Opening the home with a fresh cache adds no request of 為你推薦's own, book-source or library (measured, 7a-5).
- No single source fills the section; a work appears once; a new reader still sees a mixed section; China shows no public-library input.
- Every step's tests pass on iOS 27 and iOS 17.5 where it has UI; the Phase 5 regression passes after the last step.

## What landed

### 7a-1 (branch `discovery/7a-1-candidate-cache`)

- `OnlineBook` is `Codable`.
- `Modules/Services/ForYou/ForYouCandidateStore.swift`: `ForYouCandidates` (12 h freshness, 40 books) and the store, an actor writing `Caches/ForYou/<md5>.json` atomically; a missing file is absent, an unreadable one is absent and logged; read books take the source's current id.
- `Modules/Services/ForYou/DiscoverFirstPages.swift`: one per home (`HomeModel.live(shelf:)`, used by 探索's home, a library's home and the section form's preview). `firstPage(of:in:)` returns the shared task: a second ask for a category joins it; a source's fetches queue one after another; cookies are primed once per source until `beginSync()`, which `SourceProviderRegistry.homeProviders(shelf:sources:firstPages:)` calls each time it makes the providers (once per sync, as before). Every page is written to the store.
- `BookSourceProvider` loads through it; its test initializer (`pageLoader:primeCookies:`) makes a fetcher of its own, so `BookSourceProviderTests` are unchanged.
- Tests (written first): `ForYouCandidateStoreTests` (round trip, freshness, cap, undecodable + log, re-imported id) and `DiscoverFirstPagesTests` (joining, lanes, priming per sync, a row writes the store, a failure is fetched again). With `BookSourceProviderTests`, `HomeModelTests`, `HomeModelSchedulingTests`, `LocalHomeRowTests`, `ExploreHomeTests`: 41 passed on iOS 27.

### 7a-2 (branch `discovery/7a-2-genre-profile`)

- `Modules/Services/ForYou/ReadingGenreProfile.swift`: `ReadingGenreProfile` (30-day half-life, strongest tag scaled to 1, 200 tags, a book counts once a day) and `ReadingGenreRecorder`, an actor keeping it in `Application Support/ForYou/genres.json`; an unreadable file starts empty and is logged; a failed save is logged.
- Tags: `WorkMatchKey`'s fold; dropped when one character or only ASCII digits after NFKC (a Chinese numeral is not a digit here). A source's `kind` splits on `WorkSummary.sourceKindSeparators`, now shared with `category(fromSourceKind:)`. A copy's sidecar tags win over its source's kind.
- Recorded by `BookStore.updateLastOpened`, which every open path calls (the reader, the fixed-page reader, the shelf, 搜索's 最近閱讀), through the recorder only the app's own store is given (`readingGenres: .shared`, as `offShelfReadRecordsDefaults`); the once-a-day rule absorbs the paths that both call it. Tag reading (sidecar, cached detail page) runs off the main thread.
- Tests (written first): `ReadingGenreProfileTests` (decay, scaling, normalization, cap, once a day, a copy's tags), `ReadingGenreRecorderTests` (persists, unreadable + log): 8 passed on iOS 27; `FeaturedLayoutTests`, `HomeCompactReadingCardTests`, `RemoteReadingRecordTests` still pass.

### 7a-3 (branch `discovery/7a-3-ranker`)

- `Modules/Services/ForYou/ForYouRanker.swift`: `ForYouCandidate` (entry, source, position, normalized tags) and `ForYouRanker.rank(candidates:shelf:weights:recent:recentlyShown:languages:seed:limit:)`.
  - Dedupe and shelf exclusion by `WorkMatchKey` title + compatible authors; `shelfWorks(_:)` takes every shelf copy, online ones included. Under 只推薦, books known to be in another language are left out before the slots are filled.
  - Score: tag weights + 繼續閱讀 author (1.0) / shared tag (0.5) + up to 0.2 for the source's own order; constants in one place.
  - Mix: bands of 0.25; within a band sources take turns; at most `ceil(limit / 3)` per source (so with fewer than three sources the section is shorter than `limit`).
  - Explore: `limit / 4` books not shown in 7 days, shuffled by the seed (`SplitMix64`, moved out of `PurchaseCelebration` into `Modules/Core/SplitMix64.swift` to be shared), placed at every fourth place; leftovers fill when too few are unseen.
  - Languages: `ReadingLanguagePreferences.arrange` last, as the other sections.
- `ForYouExposureLog`: work keys with the date shown, 7-day window, pruned on record.
- Tests (written first): `ForYouRankerTests` (dedupe, shelf incl. online, cap, new reader, preferences, exploration, languages), `ForYouExposureLogTests`: 8 passed on iOS 27.

### 7a-4a (branch `discovery/7a-4a-for-you-section`)

- `HomeSectionBinding.forYou` (stored `"forYou"`), in App 資料 after 系列下一本, titled 為你推薦 (five languages), hidden-read like 最新, no 查看全部 page.
- `Modules/Services/ForYou/ForYouProvider.swift`:
  - `ForYouInputs.categories(on:for:)`: the enabled sections' categories and 「最新」's picked ones, then `forYou.categories`, less `forYou.excluded`, once each.
  - `ForYouProvider` (registry: after the libraries, policy `.withHome`): reads the candidate cache; a category older than 12 hours, or than the last pull to refresh (`HomeModel.refreshedAt`), is asked for through the home's `DiscoverFirstPages`, one at a time; a failure keeps the cached books and is logged; the section fails only when every category failed with nothing cached. Library rows: `HomeModel.settledLibraryEntries()` waits for the `.withHome` library rows on its way, then hands over what they loaded. Inputs come from the selected 首頁配置 (`HomePageStore.page`), so the form's preview sees the same. Ranked with the shelf, the genre profile, 繼續閱讀, the exposure log (`ForYouExposureStore`, `Application Support/ForYou/shown.json`) and the reading languages; the day is the seed.
  - `ForYouFile`: the one read/write path for 為你推薦's local JSON files (the genre recorder now uses it too).
  - The provider holds the home weakly (`WeakHomeModel`, made in `HomeModel.live`); a closed home stops its remaining fetches.
- Defaults: after 系列下一本 in both modes and China. `HomePageStore(insertsForYouOnce:)`, true only for `.shared`, inserts it once into the selected 首頁配置 (預設 when 空白 is selected: the reader keeps 空白 empty on purpose) after 系列下一本, else 繼續閱讀, else first; `home.forYouInserted` is set then, and by a new install's defaults, so a deletion sticks. A test's store reads the home as saved.
- Tests: `ForYouSectionTests` (binding, defaults, insertion once + deletion sticks, selected configuration, new install, inputs), `ForYouProviderTests` (fresh cache no request, stale once + pull to refresh, a row's fetch leaves nothing to ask, failure keeps books + log, all failed throws, library rows no request). Updated default-order expectations in `ExploreHomeTests` and `HomeSectionTests`. With the home suites (`HomePageStoreTests`, `HomeConfigurationTests`, `HomeSectionEditorTests`, `HomeSectionFilterTests`, `HomePageEditingTests`, `ShowInLatestTests`, `SubscriptionArticlesSectionTests`, `HomeModelTests`, `HomeModelSchedulingTests`, `BookSourceProviderTests`, `LocalHomeRowTests`, `DiscoverFirstPagesTests`): all pass on iOS 27.

### 7a-4a review fixes and 7a-4b (branch `discovery/7a-4a-fixes`)

- Review fixes:
  - One `DiscoverRequestLanes.shared` for the app: the home, the 探索 tab's home and the form's preview queue on one lane per source, and join one request per category.
  - `HomeSectionProviding.inputsKey(for:)`: a row keeps what it loaded only while its key is unchanged; 為你推薦's key is its categories, so a category added or removed anywhere on the home loads it again. `readsHomeLibraryRows`: 為你推薦's key also holds the home's library rows, so turning one off (顯示在最新, a section removed) takes its books away at once (found by `ExploreHomeUITests.testShowInLatestOff`); and a library row that loads after 為你推薦 finished (one brought back, whose view asks after the sync) loads 為你推薦 again.
  - `ForYouExposureLog.recentlyShown` counts only showings before today: every load of a day gives the same section.
  - Every category failed and nothing cached: the section is empty and takes no room (maintainer, 2026-10-13); logged.
  - The `forYou.libraries` switch is gone (see Options).
- 7a-4b, the form: 來源分類 lists the categories 為你推薦 reads (`HomeSectionEditor.forYouCategories`), each removable by swipe or the VoiceOver action 移除 (`forYou.excluded`); 加入分類 pushes the source picker and adds a category (`forYou.categories`). `#Preview`s at default and accessibility3 text. `-reset-explore-home` also clears `home.forYouInserted`.
- Spans (7a-5): `forYou.cache` (categories asked, fetched, time reading the cache), `forYou.fetch` per category, `forYou.rank` (candidates, shelf works, entries).
- `HomeEditorUITests`' layout tests take 熱門's own card (`popularCard`): 為你推薦, above it, holds the same Gutenberg book.
- Tests: `HomeModelTests.libraryRowsChangeReloadsTheirReader` (goes, then comes back), `ForYouSectionTests.addAndRemove`, `ForYouProviderTests` (`stableWithinADay`, `restartsOnNewInputs`, `emptyWhenNothing`); UI `ForYouSectionUITests` (new install shows it above 熱門 and opens a book; the form adds and removes a category; 新增欄目 offers it).

### 7a-5 (branch `discovery/7a-5-measurement`)

Measured with `ForYouMeasurementTests` (iOS 27 simulator, Debug): a home of 5 sources × 3 categories and a Gutenberg-like library row loading with the home, built through `HomeModel.make` (the same wiring as `HomeModel.live`), 40 ms per request.

| | before | after |
|---|---|---|
| cold home (nothing cached): requests | 31 (15 categories asked twice) | 16 (15 categories + 1 library) |
| cold home: 為你推薦 ready | 744 ms | 191 ms |
| pull to refresh: requests | 16 | 16 |
| warm home (cache < 12 h): requests | 16, none of 為你推薦's | 16, none of 為你推薦's |
| warm home: 為你推薦 ready | 72 ms | 70 ms |
| ranking 600 candidates, 2000 shelf books (main actor) | 450 ms (`shelfWorks` 187 + `rank` 260) | 0 on the main actor; 240 ms off it (`shelfWorks` 180 + `rank` 62) |

- **Cold duplicates.** 為你推薦 fetched every stale category as the home appeared; each row then fetched its category again on coming into view. `DiscoverFirstPages` now answers from the candidate store a page saved since the home was made or since its last pull to refresh (`refresh()`, called by `HomeModel.reload`): one request per category in a home's life, and a row coming into view shows the page 為你推薦 fetched moments before. A failure saves nothing, so the next ask fetches again. `HomeModel.make(firstPages:waitForSources:providers:)` is `live`'s wiring, so the measurement exercises it.
- **Serial fetches.** 為你推薦 asked its stale categories one after another; now a source's run in turn and the sources side by side (the lanes already serialize per source). A closed home still stops each source's remaining fetches.
- **Ranking.** Folding a title or tag (`WorkMatchKey.fold`: two ICU transforms) costs about 0.1 ms each; `shelfWorks` folds the whole shelf. `rank` now folds each candidate once and compares the shelf and kept books through a title index; tag folding, `shelfWorks`, `rank` and the exposure keys run in one detached task. `WorkMatchKey.fold` itself is shared with search merging and left as is.
- **Inputs changing during a load.** A library row that changes while 為你推薦 is loading restarted nothing (the row was active), and the stale result was then shown. `HomeModel` now marks such a row `rerun` and starts it again when the load ends, and a load's result is applied only if the row's `inputsKey` is still the one it started with (`isCurrent`). Test: `HomeModelTests.inputsChangeDuringALoad`.
- Known edge, left: a library row that finishes loading after 為你推薦 read the settled library entries but before its own load ends is not picked up until the next sync (pull to refresh, or the home changing).
- Tests: `DiscoverFirstPagesTests` (`answersFromTheStore`, `olderPagesFetchAgain`; `primingPerSync` asks a third category), `ForYouProviderTests.stale` refreshes `firstPages` as `HomeModel.reload` does, `ForYouMeasurementTests` (`requests`, `largeRanking`).

### Phase 7a acceptance (2026-10-13, main 623fb96b)

- UI, iOS 27 and iOS 17.5: ForYouSection, RemoteLibraryNavigation, PublicLibraryStorefront, ExploreHome, HomeEditor, AggregationSettings, LibraryTab, DiscoverDisplaySettings, RemoteLibrarySettings, BookSourceManagement, PublicLibrarySearchTab — 43 tests each (5 skipped by design). iOS 27 all passed. iOS 17.5 failed one: `ForYouSectionUITests.testFormAddsAndRemovesACategory` tapped the 設定 *tab*, which iOS 17 lists before the header menu's 設定; the test now takes the button outside the tab bar (48138941) and passes on both, with HomeEditor, 11 of 11 each.
- `AggregationSettingsUITests.testLibraryOrder`, flaky in an earlier run, passed on both.
