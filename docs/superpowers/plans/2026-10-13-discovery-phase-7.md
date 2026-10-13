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
- `ForYouProvider` (registry: one, after the libraries). Policy `.withHome`. Load: resolve inputs; read the cache; take the library rows' loaded entries; fetch the stale categories through `DiscoverFirstPages`, one at a time; rank. Pull to refresh treats every category as stale.
- **Options** (the section form): 來源分類 — the inputs, each removable, with 「加入分類」 pushing the existing category picker; 書庫欄目 — whether the home's library rows count. Stored in `section.parameters` (`forYou.categories`, `forYou.excluded`, `forYou.libraries`), so the schema version is unchanged.
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
  - `ForYouProvider` (registry: after the libraries, policy `.withHome`): reads the candidate cache; a category older than 12 hours, or than the last pull to refresh (`HomeModel.refreshedAt`), is asked for through the home's `DiscoverFirstPages`, one at a time; a failure keeps the cached books and is logged; the section fails only when every category failed with nothing cached. Library rows: `HomeModel.settledLibraryEntries()` waits for the `.withHome` library rows on its way, then hands over what they loaded (`forYou.libraries` = "off" leaves them out). Inputs come from the selected 首頁配置 (`HomePageStore.page`), so the form's preview sees the same. Ranked with the shelf, the genre profile, 繼續閱讀, the exposure log (`ForYouExposureStore`, `Application Support/ForYou/shown.json`) and the reading languages; the day is the seed.
  - `ForYouFile`: the one read/write path for 為你推薦's local JSON files (the genre recorder now uses it too).
  - The provider holds the home weakly (`WeakHomeModel`, made in `HomeModel.live`); a closed home stops its remaining fetches.
- Defaults: after 系列下一本 in both modes and China. `HomePageStore(insertsForYouOnce:)`, true only for `.shared`, inserts it once into the selected 首頁配置 (預設 when 空白 is selected: the reader keeps 空白 empty on purpose) after 系列下一本, else 繼續閱讀, else first; `home.forYouInserted` is set then, and by a new install's defaults, so a deletion sticks. A test's store reads the home as saved.
- Tests: `ForYouSectionTests` (binding, defaults, insertion once + deletion sticks, selected configuration, new install, inputs), `ForYouProviderTests` (fresh cache no request, stale once + pull to refresh, a row's fetch leaves nothing to ask, failure keeps books + log, all failed throws, library rows no request + off). Updated default-order expectations in `ExploreHomeTests` and `HomeSectionTests`. With the home suites (`HomePageStoreTests`, `HomeConfigurationTests`, `HomeSectionEditorTests`, `HomeSectionFilterTests`, `HomePageEditingTests`, `ShowInLatestTests`, `SubscriptionArticlesSectionTests`, `HomeModelTests`, `HomeModelSchedulingTests`, `BookSourceProviderTests`, `LocalHomeRowTests`, `DiscoverFirstPagesTests`): all pass on iOS 27.
