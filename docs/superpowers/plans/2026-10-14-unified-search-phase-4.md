# Unified library, Phase 4: unified search — plan

> **For agentic workers:** each step has its own branch, its tests (written first) and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push.

**Goal:** one search in the 搜索 tab finds a work wherever the reader can get it — the shelf, their OPDS / Calibre libraries, their book sources, the public libraries and Open Library — and shows each work once, saying whether it is on the shelf, readable, or data only.

**Design:** `Technotes/UnifiedLibrary-2026-10-08-design.md` §7 (identity: `WorkMatchKey`, A/B/C levels), §12 (unified search: architecture, rules, 4a–4d), §16 (MVP acceptance), §19 (regressions); audit `Technotes/UnifiedLibrary-2026-10-08-audit.md` §11 (current search, six match rules, error isolation, iOS 17 constraints).

**Not in this phase:** merging the two fan-out engines (`SearchAggregator` for 搜索 / 換源 sheet / 尋找可用來源, `BookOriginSearchService` for the reader's 換源 / 封面搜索 / the metadata filler): they differ in what they stop on and what they hand back, and nothing here needs one engine; WebDAV search (WebDAV has no server-side search, `WebDAVProvider.search == .none`); a scope picker or scope text (maintainer, 2026-10-11: 「搜索他媽不應該有顯示搜索範圍的文字」); a search field on the shelf (§17 item 8: the shelf participant answers it).

## Maintainer's decisions (2026-10-14, by option)

1. 搜索結果「算同一本」的規則 → 「改成作品層規則（推薦）」
2. 搜索要多搜哪些地方 → 「書架（推薦）」「OPDS／Calibre 書庫（推薦）」「Open Library 書目資料庫」
3. 不同地方搜到的結果怎麼排 → 「合成一張作品清單（推薦）」
4. 統一搜尋上線方式 → 「直接取代現在的搜索（推薦）」

Read together:

- **Matching is the work layer's (§7).** `WorkMatchKey` folds punctuation, Traditional/Simplified and kana, so 三體／三体／三體！ are one row. A result is merged by title only when **both** sides have compatible authors (B level); a result without an author is its own row. This overturns three pins in `SearchAggregatorCharacterizationTests` (:26, :33, :62), on purpose.
- **Participants:** book sources and 青空 (as today), Gutenberg (still only when asked), plus the shelf, each OPDS / Calibre connection, and Open Library.
- **One list of works** (4c's end state); 4b shows the new participants in their own sections first.
- **No experimental toggle; one search path.** Each step replaces the old code it supersedes.

## Settled here (each changeable on the maintainer's word)

- **Open Library in search is on submit, behind its own toggle, on by default.** The typed keyword goes to a third party, which the Phase 3 footer does not cover (it names title, author and ISBN, for filling). A toggle 「搜尋時也查 Open Library」 sits in 設定 → 網路設定 next to 自動補齊書籍資料, with a one-sentence footer naming what is sent. Default on follows answer 2 choosing it and Phase 3's 「做，預設開啟」.
- **Open Library rows are 「只有資料」:** no read button; the work page offers 「尋找可用來源」 (7b-2's action). A row that also has a readable member is not data-only.
- **When each participant runs:**
  - shelf and 青空: as you type (local, in memory);
  - book sources, OPDS / Calibre, Open Library: on submit;
  - Gutenberg: only on 「在 Project Gutenberg 搜尋」 (or the keyboard's Search when nothing else is configured, as today). Zero Gutenberg requests otherwise (§16 item 5).
- **Region gate as today:** where public libraries are unavailable (China storefront), 青空 and Gutenberg are both absent — the gate stays at `PublicLibraryAvailability`, through the providers' `.hiddenInRegion`.
- **Ordering (§12.2):** score first (exact 3, prefix 2, contains 1, on `WorkMatchKey`); ties: on the shelf → readable → data only; then shorter title; then more sources.
- **Each participant has its own timeout and outcome** — `results`, `empty`, `failed(reason)`, plus book sources' existing `failedAsEmpty` (Phase 0b). A failed participant marks only its own status; failures go through `AppLogger`.
- **Covers on rows:** a shelf row shows the cover the shelf shows (own cover, else Phase 3's filled cover via `FilledCoverIndex`, under 強制使用預設封面) through the same `BookshelfCoverPlan`; no second cover path. The iOS 17 table gets a row-level cover abstraction (remote URL or local file).
- **Section headers in 4b are kind names (書架, 我的書庫, 來源配置, 公有書庫, 書目資料庫), not scope text;** they disappear in 4c.
- **換源 / 換封面 on `WorkMatchKey` (4d) is asked when 4d starts:** it is stricter than today's soft-author rule and changes what the reader's 換源 offers.

## Architecture

```
BookSearchView (搜索 tab; also the session-scoped and per-source uses)
  └─ UnifiedSearchCoordinator (@MainActor; publishes through SearchResultPublicationGate)
       ├─ ShelfSearchParticipant           as you type (WorkIndexService.search)
       ├─ AozoraSearchParticipant          as you type (AozoraCatalogIndex, off the view body)
       ├─ RemoteLibrarySearchParticipant×N on submit (one per OPDS / Calibre connection)
       ├─ BookSourceSearchParticipant      on submit (SearchAggregator's fan-out, extracted in 4a)
       ├─ OpenLibrarySearchParticipant     on submit (toggle)
       └─ Gutenberg                        explicit request only (stays a pushed OPDS feed)
            ↓ SearchCandidate (value type: bounded, sanitized, SourceRecord + AcquisitionOption)
       SearchWorkResolver (off the main thread; §7 rules, same as WorkIndex)
            ↓
       [UnifiedSearchResult]: WorkSummary + members + availability; per-participant SearchOutcome
```

- `SearchBook` (a class whose author is fixed by the first arrival) stays the book-source participant's internal type until 4c, then goes. `SearchCandidate` is what crosses participant boundaries.
- Routes: `SearchResultRoute<UnifiedSearchResult>`, a new `SearchPagePush` case; still exactly one `navigationDestination(item:)` per page; the destination is an independent view taking the frozen snapshot (audit §11.5, postmortem #11–#13).

## Steps

### 4a: book sources as a participant (no behavior change)

- **Extract** `searchSingleSource` + `mergeBatch` + the fan-out window into `BookSourceSearchParticipant`; `SearchAggregator` keeps its public API (`search`, `loadMore`, `pause`, `resume`, `cancel*`, `progress`, `results`) as a thin owner so 換源 sheet and `WorkSourceFinder` are untouched.
- **Introduce** `SearchParticipant` (protocol: id, kind, `runsWhen` = asYouType / onSubmit / explicitRequest, `search(query:) -> AsyncStream<SearchParticipantEvent>`), `SearchCandidate` (value type) and `SearchOutcome` (`results`, `empty`, `failedAsEmpty`, `failed(reason)`, `timedOut`, `skipped`).
- **Proof of no change:** `SearchAggregatorCharacterizationTests` unchanged and green; plus `SearchFirstResultSpanTests`, `WorkSourceFinderTests`, `SearchSourceScopeTests`, `SearchResultPublicationGateTests`, `NetworkSettingsSearchTests`, `IOS17SearchResultTableTests`, `AggregateSearchStreamingTests`.
- **New tests:** the participant's outcome per source (results / empty / failedAsEmpty / failed / timeout) and its event stream order.

### 4b-1: the shelf

- `ShelfSearchParticipant` over `WorkIndexService.search` (first production caller; its `works.search.local` span starts measuring). As you type, in memory, no network.
- Rows: shelf copies with their shelf cover (`BookshelfCoverPlan` + `FilledCoverIndex`); tapping opens 作品詳情 through `WorkDetailRoute` in the frozen route.
- iOS 17: `IOS17SearchResultTableContent` gains a 書架 section; rows get `SearchRowCover` (remote URL or local path).
- **Measure:** `works.search.local` at 2,000 copies (§16 item 8), before/after not applicable (new); report ms.
- **Tests:** participant matches on folded keys (三体 finds 三體); sections in both table models; the cover plan picks the filled cover.

### 4b-2: OPDS / Calibre libraries

- `RemoteLibrarySearchParticipant` per connection with `OPDSClient.searchFeedURL` (OpenSearch); a connection without a search link is not asked (`.none`, not `failed`). Calibre's 404-is-empty stays `isCalibreEmptySearch`.
- Own timeout per connection; `failed` logged through `AppLogger` with the reason, shown in its section's status line (§16 item 4).
- Rows: `SourceRecord.derived(from: OPDS entry)`; tapping opens 作品詳情 with `ItemOpening.opdsEntry`.
- **Tests:** stub `URLProtocol` per connection: results, empty, 404-empty (Calibre), offline → `failed` and the other sections still show.

### 4b-3: Open Library

- `OpenLibrarySearchParticipant`: `search.json?q=<keyword>&fields=key,title,author_name,cover_i,language,isbn&limit=20`, through `WebFetcher` + `RequestPacer.openLibrary`, app User-Agent (no email).
- Results are `viewOnly` (「只有資料」); 作品詳情 shows 「尋找可用來源」 and, as for every data-only version, a disabled 開始閱讀 with 目前沒有可閱讀的來源 (one path; changed while building 4b-3).
- Setting 「搜尋時也查 Open Library」 (default on) + footer; strings in all five languages.
- **Tests:** stub responses; toggle off → no request; rows are data-only.

### 4c: one list of works

- `SearchWorkResolver` merges candidates across participants off the main thread: A (shared identifier or same `SourceItemKey`) and B (`WorkMatchKey` title equal, both authors present and compatible, same content kind, compatible language); C never merges. Deterministic; the same input gives the same list.
- Book-source merging moves to the same rules (decision 1) for 搜索 only (`SearchMergeRule.work`); 換源 and 尋找可用來源 keep theirs until 4d. `SearchBook` stays the book-source participant's grouping type (換源 sheet, 尋找可用來源, off-shelf records and the health checker use it); only value snapshots (`publicationSnapshot()`) cross into the unified list. The characterization pins at :26/:33/:62 are updated deliberately with the reason in the test. (Amended while building 4c-1: the plan said `SearchBook` retires, which the deferred fan-out merge rules out.)
- Split: 4c-1 the book-source merge rule; 4c-2 a pure `SearchWorkResolver` over every participant's candidates (no UI); 4c-3 one list on both platforms, the route, VoiceOver, section headers removed.
- `UnifiedSearchResult` rows: title, author, cover (best member: shelf → library → source → data), availability badge (在書架上 / 可閱讀 / 只有資料, from `AcquisitionOption`), source count.
- `SearchResultRoute<UnifiedSearchResult>` + `SearchPagePush` case; destination 作品詳情 with all members as versions/sources.
- VoiceOver: one label per row with title, author, number of sources, and on the shelf or not (§16 item 7).
- **Tests:** §16 fixtures (三體 shelf EPUB + Calibre + OPDS zh-Hant + source; 三體II separate); ordering ties; route freeze; VoiceOver label.

### 4d: 換源 and 換封面 on `WorkMatchKey` (asked first)

The six match rules (audit §11.2) and where each ends up:

| Rule | Site | Phase 4 |
|---|---|---|
| search merge | `SearchAggregator` | 4c → `WorkMatchKey` |
| 換源 / 換封面 | `BookOriginSearchService.isLikelySameBook` | 4d, asked first, guarded by `ChangeSourceMatchTests` + new cases |
| 封面搜索 | `OnlineCoverSearchService` | stays (manual tool; Phase 3 left it as is) |
| `checkKeyWord` | `BookSourceFetcher+Search` | stays (it is legado's filter, not identity) |
| already on shelf | `BookStore` sourceId + bookInfoURL | stays (same item, not same work) |
| recent / off-shelf records | `OffShelfReadRecords.makeKey` | stays (keys stored data; changing it orphans records) |

## Acceptance

- §16 items 1–9 on the iOS 27 simulator; item 6 (UIKit table, frozen route, 10 push/pop, no watchdog) on the iOS 17.5 simulator.
- `search.firstResult` after, with the Phase 0 setup repeated exactly (6 sources from `~/Desktop/Test document/RULE` after dedup, cache 0 days, 三体 / 斗罗大陆 / 凡人修仙传, 3 runs each), against 385 / 315 / 366 ms.
- Every shelf book's `stableHash(strippedForSync())` unchanged across the flow.
- Regressions (§19): `IOS17SearchResultTableTests`, `ChangeSourceMatchTests`, `SearchRecentsTests`, plus each step's list; `ruby scripts/check_localizations.rb`.

## What landed

### 4a (branch `search/4a-participants`)

- **Re-cut:** the plan said to extract `searchSingleSource` + `mergeBatch`. `mergeBatch` merges `SearchBook`s by the old rules, which 4c replaces with the work layer's; extracting it only to delete it is churn. What a unified search reuses is the *fetching* half, so 4a extracts that, and the participant protocol arrives in 4b-1 with its second conformer (one conformer would be a protocol shaped by guesswork).
- **`BookSourceSearchFanOut`** (`Modules/Services/Online/BookSourceSearchFanOut.swift`): the sliding window (`concurrency` sources at a time, a finished source hands its slot on), each source against its own timeout (12 s, 30 s for JS-driven ones), page 1 streamed or a later page whole. It fetches and does not merge: `onAnswer` runs on the main actor in finishing order and may stop the rest (auto-pause).
  - `SearchAggregator`'s first search and 載入更多 each had their own copy of this window; both now run this one. Merging, progress, health, auto-pause, resume and paging bookkeeping stay in `SearchAggregator`, unchanged.
  - `searchTimeout(for:normal:aggregate:)` moved to `BookSourceSearchFanOut.timeout(for:…)`.
- **`SearchSourceOutcome`**: `results`, `empty`, `failedAsEmpty` (Phase 0b), `timedOut`, `failed`; `answered` is the first three. It replaces the aggregator's private `SourceAnswer` / `SearchBatchResult`.
- **No behavior change:** `SearchAggregatorCharacterizationTests` and `SearchKeyCharacterizationTests` untouched and green.
- **Tests:** `BookSourceSearchFanOutTests` (4) + `SearchKeyCharacterizationTests`, `SearchAggregatorCharacterizationTests`, `SearchFirstResultSpanTests`, `WorkSourceFinderTests`, `SearchSourceScopeTests`, `SearchResultPublicationGateTests`, `NetworkSettingsSearchTests`, `IOS17SearchResultTableTests`, `AggregateSearchStreamingTests`: 55/55 on iOS 27.

### 4b-1 (branch `search/4b1-shelf`)

- **`ShelfProvider.searchCopies(_:)`**: the shelf copies of the works `WorkIndexService.search` finds (first production caller; `WorkMatchKey` folding, so 三体 finds 三體; equal titles first). WebDAV-indexed files are in the same index; they join with 我的書庫 in 4b-2.
- **`ShelfSearchModel`** (`Modules/Features/Search/ShelfSearchResults.swift`): as you type, owned by the search page, read only by the views drawing it (postmortem guardrail 13). It brings the index up to date (`current()`) before its first search and again only when `BookStore.mutationRevision` moved; each match carries its 作品詳情 route, frozen when found.
- **搜索 tab root:** the combined list now shows whenever there is a query at the tab's root (before: only where the public libraries are offered), so the shelf is searched in China too; the 公有書庫 section keeps its own region gate. Order: 書架, 來源配置, 公有書庫. Only the first row of the first non-empty section anchors the title's scroll.
- **iOS 18:** `ShelfSearchSection`, rows drawn as 最近閱讀's (`SearchBookListRow` + `BookshelfCoverStyle.artwork`, so filled covers and 強制使用預設封面 apply), `NavigationLink(value: WorkDetailRoute)` on the tab's path.
- **iOS 17:** a 書架 section in the UIKit table (`Item.shelfBook`), rows `IOS17SearchResultTableRow(shelfBook:colorScheme:filledCover:)`. `IOS17ShelfCover` carries the shelf's `BookshelfCoverPlan` (own artwork → catalog cover → 預設封面 → generated), loaded through `CoverImagePipeline` like the shelf's slots; a tap appends the frozen route to the tab's one path.
- **Measured** (`WorkIndexBenchmarkTests`, 2,000 copies, iOS 27 simulator): `works.search.local` 1.4 ms per keystroke; the warm refresh that runs once after a shelf change 56.4 ms; cold 332 ms (first search after launch).
- **Not seen on screen:** the simulator tool's text input did not reach the search field this session; the rows are covered by tests, and the 4c acceptance takes screenshots through a UI test.
- **Unrelated failure found:** `SearchRecentsTests.englishSourceCountPlural` fails on main (English 「%d 源」 plural); not this branch's (no strings touched), filed as its own task.
- **Tests:** `ShelfSearchTests` (5) + `IOS17SearchResultTableTests`; `SearchRecentsTests` all but the plural test above.

### 4b-2 (branch `search/4b2-libraries`)

- **`LibrarySearch`** (`Modules/Services/Works/LibrarySearch.swift`): every saved OPDS and Calibre connection (not WebDAV, not Gutenberg) asked at once in a task group, each against its own 20 s timeout. Each answer is `results` / `empty` / `noSearch` / `failed(reason)`; a library whose root advertises no search is `noSearch`, not a failure. The root's search link is read once per connection for the life of the object, so a second search sends one request per library. Calibre's 404-is-empty stays in `OPDSClient` (`isCalibreEmptySearch`). Failures are classified (`SourceFailure.classify`) and logged through `AppLogger.network` with their kind; every answer records a ⏱ `search.library` span (kind, outcome, items).
- **One mapping path:** a library's items go through `OPDSProvider.page(from:…)` (the same as browsing) and `HomeCardContent` (the same as the home's cards), so the row's title, author, cover and frozen `WorkDetailRoute` (`ItemOpening.opdsEntry`) are the ones 探索 shows.
- **`LibrarySearchModel` + `LibrarySearchSection`** (`Modules/Features/Search/LibrarySearchResults.swift`): asked on submit, cleared with the query. Section 我的書庫 comes second (書架, 我的書庫, 來源配置, 公有書庫); rows are `SearchBookListRow` with the library's name as the detail line and `HomeCoverArtwork` covers (the connection's session and headers). Status lines: 「搜索中…」 while no library has answered with a book yet, and 「<名稱>：無法搜尋（<原因>）」 for each library that failed (§16 item 4). Empty libraries say nothing.
- **Submit:** at the tab's root, Search always asks the libraries. With no source but at least one library, it is not an error (no alert, Gutenberg not pushed; the 公有書庫 section still offers it). Without libraries, everything is as before.
- **iOS 17:** a 我的書庫 section in the UIKit table (`Item.libraryBook`, `Item.libraryNotice`), rows `IOS17SearchResultTableRow(libraryMatch:)`; `IOS17RemoteCover` carries the connection's headers and session into the cell's cover load, so a signed-in Calibre's covers load as on iOS 18.
- **Strings:** 我的書庫, `%@：無法搜尋（%@）` in all five languages.
- **Left for 4c:** an empty 我的書庫 with no source shows an empty list rather than 「沒有找到」; 4c's single list owns the one empty state. WebDAV-indexed files join through the work index there too.
- **Not seen on screen:** no OPDS server is reachable from the simulator this session; the rows are covered by tests.
- **Tests:** `LibrarySearchTests` (5, URLProtocol stub per host: results, empty, Calibre 404, offline, no search; timeout of one library while the other answers; root read once; iOS 17 row and reload) + `ShelfSearchTests`, `IOS17SearchResultTableTests`, `SearchSourceScopeTests`: 26 passed on iOS 27.

### 4b-3 (branch `search/4b3-open-library`)

- **`OpenLibrarySearch`** (`Modules/Services/Works/OpenLibrarySearch.swift`): one `search.json?q=…&fields=key,title,author_name,cover_i,language,isbn&limit=20` request on submit, through `WebFetcher` and the same `RequestPacer.openLibrary` as Phase 3's fill (one a second, app User-Agent, no email), 15 s timeout. Each work is a data-only item: key `SourceItemKey(OpenLibrary.key, "/works/OL…W")` (the key Phase 3 records a filled copy's source under), `openLibraryWork` identifier, at most 5 distinct ISBN-13s, `acquisitions: [.viewOnly]`, cover `covers.openlibrary.org/b/id/<cover_i>-M.jpg` (by cover id), language from MARC codes when the work has exactly one. ⏱ `search.openLibrary` span; failures logged through `AppLogger.network` with their kind.
- **`ItemOpening.bibliographic`** (new case): not readable, never where a copy came from (`readsItsCopies` false), 來源 names it Open Library (`FilledMetadata.providerName`, the one naming path), its status says 只有資料. Every other switch treats it as having nothing to open, read, list or edit; 探索 would push it to 作品詳情.
- **One model for both submit parts:** `SearchAnswering` (the saved libraries, Open Library) → `LibrarySearchModel`; Open Library's rows say 只有資料, the libraries' name their library. Section 書目資料庫 comes last on iOS 18; the iOS 17 table's 我的書庫 and 書目資料庫 are the same `IOS17SearchAnswerSection` values.
- **Setting:** 設定 → 網路設定 → 「搜尋時也查 Open Library」 (default on, key `yd_search_open_library`) with a one-sentence footer saying the search words go to Open Library. Off: no request at all.
- **Submit (behaviour change, vetoable):** `SearchSubmitPlan.decide` (pure, tested). With no source at all and something else answering (a saved library, or Open Library with its setting on), Search shows no 「沒有可用的來源配置」 alert and no longer pushes Gutenberg on its own; 公有書庫's row still offers Gutenberg. Since Open Library is on by default, a sourceless user now gets Open Library's data-only results (and in China, results instead of the alert).
- **Not merged with the shelf yet:** an Open Library work and a shelf copy filled from it are separate rows, and 作品詳情 opened from the Open Library row does not list that copy: the work index joins only shelf and file members. 4c's rule A (shared identifier, the `openLibraryWork` id and ISBNs recorded here) merges them.
- **Strings:** 書目資料庫, 只有資料, the toggle and its footer in all five languages (the footer uses each language's 尋找可用來源 wording).
- **Tests:** `OpenLibrarySearchTests` (6: data-only items under Phase 3's key with cover and capped ISBNs, request carries the app UA and no email; setting off sends nothing; empty and 503; rows say 只有資料; the submit decision table; MARC codes), reusing Phase 3's `OpenLibraryStub`; with `OpenLibraryFillProviderTests`, `LibrarySearchTests`, `WorkDetailVersionsTests`, `WorkDetailShelfVersionsTests`, `OPDSProviderTests`, `ShelfProviderTests`, `IOS17SearchResultTableTests`, `ShelfSearchTests`: 57 passed on iOS 27.

### 4c-1 (branch `search/4c-resolver`)

- **`SearchMergeRule`** in `SearchAggregator`, set per search from its `SearchOrigin`: `.work` for 搜索 (`.searchTab`), `.changeSource` for the 換源 sheet and 尋找可用來源, whose behaviour is unchanged until 4d (asked first).
- **Work rule:** a row's key is `WorkMatchKey.title`, so 三體／三体／三體！ merge; a book joins a row only when both name authors and `WorkMatchKey.authorKeysCompatible` holds, and the content kind matches (a novel and an audiobook stay apart). A result with no author is its own row. Relatedness, ranking and the auto-pause exact count use the same folded keys, so a Simplified query finds and ranks a Traditional title as exact.
- **Off the main actor:** `SearchWorkKeys` (title and author folded) are computed in `SearchResultPresentationBuilder.prepareBatch` (`foldsWorkKeys`), carried on `PreparedSearchResult` and kept on `SearchBook` (snapshots copy them), like `normalizedName`; the dedup map and the sort read them, never fold on the main actor.
- **Measured** (`SearchWorkMergeBenchmarkTests`, `TEST_RUNNER_YUEDU_SEARCH_BENCHMARK=1`, 2 sources × 1,000 results, half Traditional, iOS 27 simulator, 3 runs): `search.presentation.workKeys` 80–87 ms per 1,000 books off the main actor (ICU Traditional→Simplified, ≈85 µs a book); `search.presentation.mainMerge` 15–17 ms per 1,000 under 換源's rule (500 rows kept: the Simplified half is unrelated there) and 24–26 ms under the work rule (all 1,000 kept and merged), the same per-book main-actor cost. A source's first batch of 20–50 books pays ≤4 ms more before its rows appear; a 1,000-book aggregate batch ≈85 ms. `search.firstResult` against the 385/315/366 ms baseline is taken at the phase acceptance.
- **Pins changed on purpose** (`SearchAggregatorCharacterizationTests`): 「the first result to arrive fixes the merged row's author」 is now 「a result without an author is its own row」; `tieBreaks` names authors so its two 三體二 still merge; the :26 and :33 key pins stay true and now say they describe 換源's key until 4d. New: the work key folds three spellings into one row; a Simplified query ranks a Traditional title exactly; another content kind stays apart; 換源 keeps its rule.
- **Tests:** `SearchKeyCharacterizationTests`, `SearchAggregatorCharacterizationTests`, `ChangeSourceMatchTests`, `SearchFirstResultSpanTests`, `BookSourceSearchFanOutTests`, `WorkSourceFinderTests` + the benchmark: 37 passed.
- **Also on this branch:** Open Library's MARC codes read through `LanguageTag` (e737b508), the one language path.
