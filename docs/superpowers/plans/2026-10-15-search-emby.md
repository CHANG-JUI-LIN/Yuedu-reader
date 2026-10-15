# 搜尋與聚合設定照 Emby — plan

> **For agentic workers:** each step has its own branch, tests written first, and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push.

**Goal:**
- 搜尋 looks and behaves like Emby's search (the maintainer's reference, 2026-10-15): filter chips on top, results grouped by kind, everything searched at once, no extra buttons.
- 聚合設定 becomes Emby's 聚合資料: a 數據來源 list where each purpose opens the places it uses, with an n/m count.

## Maintainer's decisions (2026-10-15, by option)

1. **Search layout:** filter chips on top, and the results grouped by kind (書籍／漫畫／有聲書) under a header each. Inside a group the works are a **vertical list**, as today's rows (maintainer: 「直排好了」), not horizontal cards.
2. **No 「載入更多」 and no 「在 Project Gutenberg 搜尋」 row.**
   - Reaching the end of the list loads the next page by itself.
   - Gutenberg is searched with everything else when the search is sent.
3. **Fake results** such as 「没有找到包含：仙子破道曲的小说」 are not listed. The test is whether the result has a book link of its own, not its wording.
4. **聚合設定:**
   - 首頁欄目 goes; it is 編輯首頁's job.
   - A 數據來源 section lists each purpose with its n/m count. Each row opens a checklist of the places that serve it.

## What the code does today (survey, 2026-10-15)

- **Fake results:**
  - When a search list item's book-URL rule yields nothing, `ModernRuleEngine.getString(isUrl: true)` returns the page's own URL (ModernRuleEngine.swift:146-148, 160-162, 197), as Legado does. The test `missingBookURLFallsBackToPage` pins this.
  - A "no results" message parsed as a list item therefore becomes a book whose `bookUrl` is the search page.
  - Our search path has no detail-page landing (`bookUrlPattern` is never used there), so such an item can never be a real book.
  - Two of them from one source also share item keys and merge (SearchWorkResolver.swift:77-82).
- **載入更多:** only book sources page (`SearchAggregator.loadMore`, at most 5 pages, `hasMoreResults`). It is triggered only by the button: on iOS 18 in `UnifiedSearchRows`, on iOS 17 by the `.loadMore` item of `IOS17SearchResultTable`. Nothing fires it on scroll.
- **Gutenberg:**
  - The button pushes Gutenberg's OPDS search page (`submitGutenberg`), a live request to `search.opds/?query=`.
  - Policy (Technotes/PublicLibraries.md): Gutenberg is requested only on submit or a tap, never as you type, with no prefetch.
  - Asking it once per sent search keeps to that.
- **青空文庫** is already merged as you type (local catalog). The 顯示全部 overflow link exists only on iOS 18.
- **Kind:** every candidate has `contentKind`.
  - Book sources say audio or manga.
  - OPDS/Calibre decide by file type.
  - Modules, Open Library, 青空文庫 and Gutenberg are text.
- **「全部來源配置」 chip:** a scope picker for 來源配置 only (`SearchSourceScopeSheet`). There is no kind filter and no sort control.
- **聚合設定 today:** 偏好閱讀語言, 推薦範圍, 書庫順序, 首頁欄目, 隱藏已讀. The per-purpose places are scattered:
  - 顯示在最新 is in 最新's own section form (`AggregationSettings.hiddenFromLatest`);
  - 資料來源 is in 網路設定 (`MetadataFillSourcesView`);
  - 搜尋時也查 Open Library is a toggle in 網路設定.
- **iOS 17 guardrails** (Technotes/iOS17SearchWatchdogPostmortem.md) stay in force:
  - iOS 17 results stay in the UIKit table with bounded value rows;
  - routes are frozen snapshots;
  - there is one destination;
  - no sleeps or retries.

## Settled here (each changeable on the maintainer's word)

- **Fake results — the filter.** A book-source search item whose `bookUrl` resolved to the request's own page is dropped, before it reaches the aggregator.
  - The engine's fallback stays as it is: detail and TOC rules rely on it.
  - Each drop is logged once per search per source (`AppLogger`, with the source name and count), so a device can say why a result is missing.
  - This is a precise condition, not a guess at wording.
  - **First step:** confirm the signal on a real "not found" page. Write the parser test from a saved page; the maintainer's source is asked for only if the fixture does not reproduce it.
- **Auto-load.**
  - When the last row of the list appears, the next page of 來源配置 loads, once per page, with a spinner row while it runs.
    - iOS 18: the last row's `onAppear`.
    - iOS 17: the table's `willDisplay` of the last item.
  - It stops at the existing 5-page limit, or when no source has more.
  - Gutenberg and the libraries do not page.
- **Gutenberg merged.**
  - Each sent search asks Gutenberg's first page once, in public-library regions only (`PublicLibraryAvailability`).
  - Its books join the list as 公有書庫 works, like 青空文庫's.
  - Typing never asks it.
  - The 「在 Project Gutenberg 搜尋」 row, `submitGutenberg` and `SearchSubmitPlan.gutenberg` go: a search with no 來源配置 is just a search of the rest.
  - PublicLibraries.md is updated.
- **Groups.**
  - The order is 書籍, 漫畫, 有聲書. A group with nothing in it is not shown.
  - Inside a group, the order is the resolver's, as today.
  - The leading and trailing status lines stay above and below the groups.
- **Chips** (a row of capsules, like the reference):
  - **類型** (不限／書籍／漫畫／有聲書): filters the groups, and is kept for the session.
  - **來源配置**: today's 全部來源配置 capsule, restyled as a chip with the same sheet.
  - The reference's 分類 and 年份 are left out: our results carry neither reliably.
  - Sort is left out: the resolver's order is the relevance order.
- **數據來源 rows in 聚合設定** (n/m = checked/available):
  - **搜尋來源:** the saved OPDS/Calibre libraries, Gutenberg, 青空文庫, Open Library and modules that search, each checked or not.
    - It replaces 網路設定's 「搜尋時也查 Open Library」, which moves here; the stored value carries over.
    - 來源配置 are not listed: they keep their own enable switch and the search's 來源配置 chip.
    - A new optional `hiddenFromSearch` goes in `AggregationSettings`, beside `hiddenFromLatest`.
  - **最新來源:** the same `hiddenFromLatest` toggles that 最新's form shows. Both edit one store.
  - **資料來源:** opens the existing `MetadataFillSourcesView`. 網路設定 keeps its 自動補齊書籍資料 switch and links here instead of hosting the list.
  - 偏好閱讀語言, 推薦範圍, 書庫順序 and 隱藏已讀 stay. 首頁欄目 goes.

## Plan review (2026-10-15)

The maintainer approved 9a–9e as written: the chips are 類型 and 來源配置 only, and 搜尋時也查 Open Library moves into 聚合設定 → 搜尋來源.

## Steps

### 9a — fake results (branch `search/9a-fake-results`)

- A parser test from a saved "not found" page. The item's `bookUrl` equals the request URL; the test asserts it is dropped.
- Another test asserts a normal list is unchanged.
- The filter goes in the search mapping (`parseSearchResults` / `RuleListMapping` for search only), on both the native and the runtime path (each passes its own base).
- The log line.

### 9b — auto-load and Gutenberg merged (branch `search/9b-auto-load`)

- The aggregator's `loadMore` is triggered by the last row: iOS 18 `UnifiedSearchRows`; iOS 17 `IOS17SearchResultTable` `willDisplay`. The button is removed.
- The Gutenberg first page is fetched on submit through `GutenbergProvider`, and merged as a `.publicLibrary` payload.
- The Gutenberg row and `.gutenberg` plan are deleted.
- **Tests:**
  - `IOS17SearchResultTableTests` and `UnifiedSearchTests` updated;
  - `OpenLibrarySearchTests` `.gutenberg` cases rewritten;
  - `PublicLibrarySearchTabUITests.testNoSourcesSearchesThePublicLibraries` now expects Gutenberg works in the list;
  - new: the last row loads the next page once.

### 9c — groups and chips (branch `search/9c-groups`)

- `UnifiedSearchModel` exposes `groups: [(ContentKind, [Row])]` and a `kindFilter`.
- iOS 18: one `Section` per group with a header.
- iOS 17: a UITableView section per group, still bounded value rows.
- A chip row of 類型 and 來源配置, with VoiceOver labels and values.
- **Tests:** grouping order, empty groups hidden, the filter; the iOS 17 table snapshot.

### 9d — 聚合設定 數據來源 (branch `search/9d-aggregation-sources`)

- 首頁欄目 removed.
- 數據來源 section: 搜尋來源 n/m, 最新來源 n/m, 資料來源 n/m, each pushing its checklist.
- `hiddenFromSearch` is honoured by `LibrarySearch`, `ModuleSearch`, Open Library and Gutenberg. The Open Library toggle moves here with its value.
- 網路設定's 資料來源 list becomes a link.
- **Tests:** the counts, the settings round-trip, a library unchecked is not asked.

### 9e — acceptance (branch `search/9e-acceptance`)

- **UI tests:**
  - type a query and send it: the groups appear and Gutenberg works are among them;
  - scroll to the end: the next page loads with no button;
  - 類型 filters;
  - 聚合設定 → 搜尋來源 → uncheck Gutenberg, and the next search has none.
- Run on iOS 27 and iOS 17.5, plus the search regressions (`DetailReaderBackSwipeUITests` search cases and `ModuleLibraryUITests.testModuleAnswersSearch`).

## What landed

### 9a — branch `search/9a-fake-results` (2026-10-15)

- **The signal is narrower than "the link is the page".** A source *has* a link rule and it finds no link in that row.
  - A "no results" message laid out as a list row has no `<a>`, so the rule finds nothing. Legado then sets the page as its link, and it became a book.
  - An **empty** link rule still means the page itself, as in Legado. `missingBookURLFallsBackToPage` is unchanged.
- **`RuleListMapping.items(onMissingLink:)`.**
  - Only 搜尋 passes it: `parseSearchResults`, the one path both the native and runtime searches use.
  - With it, a row whose non-empty link rule yields nothing is left out and named. The link is read with `getOptionalURL`, which has no page fallback.
  - 發現, modules and 換源's detail paths are unchanged.
- **Logging:** `parseSearchResults` logs once per parsed page, at `.notice` in the parse category, with the source, the count and the first name. A device can say why a row is missing.
- **Fixture fix:** `kindRulesUseStringListSemantics` wrote its search link as a literal URL. On JSON that finds nothing, so the item was silently getting the search page as its link. The fixture now has a real `url` field. The test is about kind parsing.
- **Tests:**
  - `CoverLinkRuleTests.searchRowWithoutItsLinkIsDropped` (new): a biquge-style 「没有找到包含：…」 row is dropped, and a row with a link beside a linkless ad keeps only the book.
  - The parser, search and real-source suites (ModernParser*, Qidian/Qimo/local source fixtures, AnalyzeUrl, AggregateSearchStreaming, BookSourceSearchFanOut, RuleModule*, ChangeSourceTOCResolution): 187/187 on iOS 27.

### 9b — branch `search/9b-auto-load` (2026-10-15)

- **Auto-load.**
  - 載入更多 is gone from both lists.
  - While the sources have more pages, the list ends with a spinner (「正在載入更多」 for VoiceOver; nothing to tap). Showing it loads the next page.
    - iOS 18: `SearchLoadMoreRow`, a `.task` keyed on the row count and `canLoadMore`. It is used in the tab root's list and in the pushed sources' list.
    - iOS 17: the table's `willDisplay` of its `.loadMore` item.
  - A running search does not ask again. When it ends, `canLoadMore` changes: SwiftUI's task id changes, and iOS 17's content compares unequal and reloads, so a spinner still on screen asks then.
  - `SearchAggregator.loadMore` keeps its own guards and the 5-page limit.
- **Gutenberg merged.**
  - `LibrarySearch` asks Gutenberg with the saved OPDS and Calibre libraries, on submit only, where `PublicLibraryAvailability` allows it.
  - Its search address needs no root feed: `searchURL(search: nil)` is tried first, so one search sends one request.
  - Its books are `.library` matches named Project Gutenberg. The resolver counts them as `.publicLibrary`.
- **Removed:**
  - the 「在 Project Gutenberg 搜尋」 row, on both iOS 17 and iOS 18, and its string in all five languages;
  - `submitGutenberg`;
  - `SearchSubmitPlan.gutenberg` and its `offersPublicLibraries` parameter. With no 來源配置, Gutenberg is simply one of the others that answer.
- **Docs:** PublicLibraries.md now says when Gutenberg is asked: once per sent search, first page only.
- **Tests:**
  - `LibrarySearchTests.gutenbergJoins` and `.defaultLibraries` (new);
  - `IOS17SearchResultTableTests.lastRowLoadsMore` (new), with the reload tests rewritten for `hasMore`/`canLoadMore`;
  - `OpenLibrarySearchTests.submitPlan` rewritten;
  - `UnifiedSearchTests` updated;
  - 47/47 on iOS 27.
  - `PublicLibrarySearchTabUITests`, both cases rewritten to find Gutenberg's book in the one list: 2/2 on iOS 27 and on iOS 17.5.

### 9c — branch `search/9c-groups` (2026-10-15)

- **Groups.**
  - `UnifiedSearchGroup.groups(of:kind:filter:)` groups by the lead's `contentKind` in the order 書籍, 漫畫, 有聲書, keeping the resolver's order within each group and leaving out empty groups. The resolver merges only within one kind, so every work belongs to exactly one group.
  - `UnifiedSearchModel.groups` uses it.
  - The headers use their own keys, 「搜尋分組：…」, because en needs the plural (Books, Audiobooks) and the existing 書籍 / 有聲書 keys are singular.
  - **iOS 18:** one `Section` per group with a headline header. The title's scroll anchor stays on the first row, because a plain list pins its header.
  - **iOS 17:** the table has one section per group, plus a section for the leading status line and one for the trailing status lines and spinner.
    - Headers come from the delegate's `viewForHeaderInSection`, since the diffable data source owns `dataSource`. Each header is a single heading element for VoiceOver.
    - `sectionHeaderTopPadding` is 0.
    - Rows remain bounded value rows (`IOS17SearchWorkGroup`).
- **Chips.**
  - **類型** is a `Menu` holding a `Picker` (全部 / 書籍 / 漫畫 / 有聲書). It opens no modal, and `UnifiedSearchModel.kindFilter` keeps the choice for as long as the page lives. Its VoiceOver label is 類型, and its value is the current choice.
  - **來源配置** is the same capsule and the same sheet, restyled as a chip (title plus chevron, tinted when the scope is custom). It is still a Button, not a menu item, because of the iOS 17 menu → sheet race.
  - The chip row shows at the tab root even with no 來源配置 (only 類型 then). The pushed sources-only page has neither groups nor 類型: its rows are the sources' results, not works.
  - The chips show no per-kind counts, so the page body never reads the results (guardrail 13).
- **When 類型 filters everything out**, the page shows 「沒有這個類型的作品」 instead of a blank page (`UnifiedSearchStatus(filteredOut:)`). A search still running shows 搜索中… first.
- **Tests:**
  - `UnifiedSearchTests.groups` and `.filteredOut`, `IOS17SearchResultTableTests.groupSections` (all new); the existing ones were updated for `groups`. 25/25 on iOS 27.
  - `PublicLibrarySearchTabUITests.testNoSourcesSearchesThePublicLibraries` now also checks the 書籍 header and the 類型 chip. It passes on iOS 27 and iOS 17.5, and the screenshots were checked.

### 9d — branch `search/9d-aggregation-sources` (2026-10-15)

- **聚合設定 is laid out like Emby's 聚合資料.** 數據來源 comes first, then 偏好閱讀語言, 推薦範圍, 書庫順序 and 隱藏已讀.
  - 首頁欄目 is removed (it belongs to 編輯首頁), together with its five strings.
- **數據來源** (`AggregationDataSourcesSection`): each row is a `LabeledContent` with an n/m count and pushes its checklist. VoiceOver reads the count in words: 「已勾選 2 個，共 3 個」.
  - **搜尋來源** (`SearchSourcesView`):
    - It lists the saved OPDS and Calibre libraries, Gutenberg and 青空文庫, all in 書庫順序, then the installed modules that have a search. WebDAV is left out because it has no search.
    - 搜尋時也查 Open Library moved here as its own switch. It still uses the same `GlobalSettings.searchOpenLibrary` value, so nothing needed migrating, and it was removed from 網路設定.
    - 來源配置 are not listed: they are chosen with the search's own chip.
    - The other switches are the new optional `AggregationSettings.hiddenFromSearch`. Settings saved before this change read as all checked.
  - **最新來源** (`LatestSourcesView`): the same `hiddenFromLatest` switches that 最新's own options show. Both pages edit one store.
  - **資料來源** opens the existing `MetadataFillSourcesView`. 網路設定 keeps its own 資料來源 link to the same page: one list, one store, two ways in.
- **Where 搜尋來源 is honoured:**
  - `LibrarySearch.libraries(shown:)` covers OPDS, Calibre and Gutenberg.
  - `ModuleSearch(shown:)` covers the modules.
  - 青空文庫's search as you type now requires both `offersPublicLibraries` and its own switch.
  - Open Library uses its existing switch.
- **Tests:**
  - New `AggregationDataSourcesTests` (round trip and old values, places and count, an unchecked library is not asked), plus a check in `ModuleSearchTests`. The aggregation, latest, hide-read, order, language, editor, module-search and library-search suites pass, 40/40 on iOS 27.
  - UI tests:
    - `AggregationSettingsUITests.testDataSources` replaces `testHomeSections`;
    - `ExploreHomeUITests.testShowInLatestOff` now goes through 最新來源;
    - all of `AggregationSettingsUITests`, `testShowInLatestOff` and `ModuleLibraryUITests.testModuleInMetadataFillSources` pass on iOS 27;
    - `testDataSources`, `testShowInLatestOff` and `testModuleInMetadataFillSources` pass on iOS 17.5.

### 9e — branch `search/9e-acceptance` (2026-10-15)

- **9b's scroll-to-load is reversed** (maintainer, mid-acceptance: 「別分頁了，能請求多少就請求多少，但是根據手機性能請求」). Options chosen: 上限 10 頁, 暫停翻頁、降溫自動繼續, 低電量照樣抓完、併發減半.
  - `SearchAggregator` now asks for the later pages by itself, in rounds, inside the same search task; `isSearching` stays true until the last round. Only sources whose page 1 had results are paged. A source stops when a page adds nothing or fails, and every source stops at page 10.
  - Only the 搜索 tab pages (`origin == .searchTab`). 換源 and 尋找可用來源 stay at page 1.
  - The aggregator is held weakly between rounds (static functions with a `[weak self]` getter), so leaving the page ends the search. Pause/resume continue the later pages from where they stopped.
  - Page publications go through the existing 0.5 s gate, with one forced publication at the end.
  - Removed as the second path: `loadMore()`, `hasMoreResults`, `SearchLoadMoreRow`/`SearchPaging`, the iOS 17 table's load-more cell and `willDisplay`, the `paging` parameters, and the 「正在載入更多」 string in all five languages.
- **The phone sets the pace** (`SearchDevicePacing`, `SearchDeviceConditions`):
  - page 1 runs at 網路設定's 並發數;
  - later pages run at half that width while `thermalState` is `.fair` or Low Power Mode is on;
  - at `.serious` or `.critical` they wait on the thermal/power-state notifications (an `AsyncStream` that ends on cancellation) and carry on once the phone has cooled. No sleeps, no polling.
  - The processor count is not used: every iOS 17 iPhone has six cores.
  - `⏱ search.page` records page, sources, width, low power, thermal state and rows; `⏱ search.pages.hold` records a wait. `⏱ search.listPublish` now carries milliseconds.
- **iOS 17: 類型 never opened from VoiceOver.** The chip's accessibility modifiers sat after its `frame`, which made a container element around the `Menu`; activating that element (a VoiceOver double tap, an XCUITest tap) did nothing on iOS 17. The modifiers now come first and the row height after (`searchFilterChipRowHeight()`, also on the 來源配置 capsule).
- **Measured** (Mac simulator, not a phone: 20 never-ending sources × 10 pages = 4,000 books, scrolling throughout):
  - `search.listPublish` (main thread) 1→7 ms on iOS 27, ≤7 ms on iOS 17;
  - `unified.candidates` (main thread) 1→6 ms, 12 ms at 4,025 rows on iOS 27, ≤14 ms on iOS 17;
  - `unified.resolve` (off the main thread) 12→79 ms;
  - iOS 17 `nativeTableApply` 4–8 ms. No hang was seen.
- **Tests:**
  - New `SearchAutoPagingTests`: the width, the hot hold, pages until a source runs dry, the stop at 10, 換源 at page 1, waiting for the phone to cool, pause/resume while waiting. `IOS17SearchResultTableTests`, `UnifiedSearchTests` and `SearchSourceScopeTests` lose their load-more cases. 41/41 with `BookSourceSearchFanOutTests` on iOS 27.
  - New `SearchEmbyAcceptanceUITests` over `scripts/search_paging_fixture.py` (localhost:18768; `/reset`, `/log`, and `/heavy/<n>` for measuring): the groups with Gutenberg among them; pages 1–4 asked with no scrolling; 類型 → 有聲書 → 全部; scrolling reaches page 3's last book with nothing more asked; Gutenberg unchecked in 搜尋來源 is not searched.
  - Regressions, all passing: on iOS 27, both `SearchEmbyAcceptanceUITests`, both `PublicLibrarySearchTabUITests`, `ModuleLibraryUITests.testModuleAnswersSearch` and the four `DetailReaderBackSwipeUITests` search cases (they need `scripts/navigation_swipe_fixture.py` clean, prepare and serve on 18765); on iOS 17.5 the same nine.
  - On iOS 17.5, `testHeroNamesTheAuthorAndInfoListsTheOthers` was killed once inside the batch and then passed when run alone. At that moment Xcode's StoreKit test server was looping on 「Sending storefront changed notification for Xcode test」, about 19,000 log lines a second from storekitd and ASOctaneSupportXPCService, with both the runner and the app as clients. No StoreKit code was touched here.
