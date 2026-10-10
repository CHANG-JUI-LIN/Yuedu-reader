# Unified Library, Phase 5 — Implementation Plan (Explore home)

> **For the implementer.** Read [AGENTS.md](../../../AGENTS.md) and [CLAUDE.md](../../../CLAUDE.md) first, then the design sections each task cites. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> - Design: [Technotes/UnifiedLibrary-2026-10-08-design.md](../../../Technotes/UnifiedLibrary-2026-10-08-design.md):
>   - §5 (`HomeSectionTemplate`, `SectionParameter`, `HomeSectionProviding`);
>   - §13.1–§13.9 (the home, its sections, the source center, tabs, the cover wall);
>   - §14.1 (work detail), §15 (2026-10-10 order), §17 items 21–22, §19.
> - Audit: [Technotes/UnifiedLibrary-2026-10-08-audit.md](../../../Technotes/UnifiedLibrary-2026-10-08-audit.md): §12 (discover and custom pages), §13 (detail scaffold).
> - Previous plans: [Phase 1](2026-10-10-unified-library-phase-1.md), [Phase 2](2026-10-10-unified-library-phase-2.md). Their guardrails apply.
>
> Line numbers are from `main` at `c2eb3a8c`.

**Goal:** the cover wall the maintainer chose to ship before unified search (design §15, 2026-10-10). Explore becomes one home of user-ordered rows across every source, Emby/Jellyfin style, with a source center to add sources and a read-only work page.

**Today:**

- **Explore** (`ExploreTabRoot.swift:9-39`) switches between two separate roots: book sources (`ExploreHomeView`) and public libraries (`PublicLibraryHomeView`).
  - The switch is a mode menu, stored in `explore.mode`.
  - Each root owns its own `NavigationStack`. Switching discards it.
- **Remote libraries** (Phase 2) have no browse entry outside the bookshelf ＋ sheets.
- **Custom pages** (`CustomExplorePageStore.swift:9-331`) are the only user-ordered rows:
  - They have 7 layouts, book sources only, and no schema version.
  - Their model fetches with no cookie pre-warm (`CustomExplorePageModel.swift:148-171`).
  - A second next-page loader lives in a view (`DiscoverShowcaseView.swift:742-783`).
- **Discover filters** are written into the source's shared runtime variables (`DiscoverViewModel.swift:384-410`). Two rows of one source would overwrite each other's filters.
- **No home section and no work page exist.**
  - "Continue reading" exists only as the search tab's 最近閱讀 (`RecentReadingSelection`, `SearchRecents.swift:62-106`).
  - Phase 1's work index has no caller.
- **Phase 2 constraints Phase 5 inherits:**
  - `ShelfProvider.browse` and `WorkIndexService.refresh` call `BookSourceStore.source(id:)`, which waits on the main thread until the source library is read.
  - A 20,000-record work-index refresh takes 1.3 s off main (Debug -O). Refresh once per change, not per view.

---

## Scope

**In:**
- 5a: the home model and its migration.
- 5b: section loading through providers.
- 5c: the home screen (cover wall, scope menu, one navigation path).
- 5d: the section editor.
- 5e: the source center.
- 5f: the read-only work page.
- 5g: RSS inside Explore.

**Gated on the maintainer** (open decisions below): 5h, tab order and who gets Explore first.

**Out:**
- **Unified search** (Phase 4) and the work page's 「尋找可用來源」, which needs it.
- **Metadata identification and bibliographic databases** (Phase 3).
- **Modules** (Phase 6).
- **The stats tab's content** (§17 item 22, its own plan).
- **The aggregation settings page** (§13.3 聚合設定). It configures search and metadata sources that do not exist before Phases 3 and 4. Phase 5 ships its one effective rule (prefer the current source) as the default, with no page.
- **Changing `ReadingBook`** (D1).

---

## Decisions

### Settled by the maintainer (2026-10-08 to 2026-10-11)

1. **The home aggregates across sources like Emby; scope is 「全部」 or one source** (§13.1).
2. **The cover wall comes before unified search** (§15). Covers fall back user → copy or source → bibliographic → `GeneratedBookCover`, whose seed is the series when there is one. Density follows width and Dynamic Type (§13.9).
3. **Connections are libraries, browsed from Explore's 我的書庫 tiles, pushed full page** (Phase 2 decisions 1–2). The bookshelf ＋ entries go once 5c's entry passes UI tests.
4. **RSS moves into Explore with Phase 5, not deleted** (§13.8). Stats becomes a tab after its own plan.
5. **Who gets Explore first, and the final tab order, are decided once the cover wall is usable** (§13.7, §17 item 21).
6. **The default sections** (§13.3, lines 700–704): book-source users get 我的書庫 → 繼續閱讀 → 最新 → 精選; public-library users and new installs get 繼續閱讀 → 我的書庫 → 精選 → 最新; China gets no public-library section.
7. **精選 is Gutenberg's bundled lists, sending no request** (§13.3, line 686).
8. **A book source's 「最新」 is the discover category the reader picks for it** (§13.3, line 691). Until one is picked the source has no 最新 row; nothing guesses a category.
9. **The old Explore roots stay one version behind a fallback flag** (§13.3, line 707). Whether the flag is visible is open decision 2.

### Open, for the maintainer (each with a recommendation)

These change what is built, so no step that depends on one starts until it is answered.

1. **Tab order and who gets it** (gates 5h). Plan A is 書架、探索、搜尋、統計、設定, and §13.7 adds "Explore first".
   - Recommend: decide after 5c, on a build, as settled. Then choose between new installs only and everyone with a one-time notice.
2. **Whether the reader sees the fallback flag** (5c; the flag itself is settled decision 9).
   - Recommend: a 探索設定 switch 「使用舊版探索頁」 (one new string) for that one version.
   - Alternative: an internal flag only.
3. *(Answered by the design; see settled decision 8.)*
4. **The card** (5c).
   - Recommend: Apple Books style. A 2:3 cover with title and author below, at most two lines and one line, and the row's source in its header.
   - Alternative: title over the cover, Emby style.
5. **A 「相關」 row in v1** (5b, 5c): same author and series from the shelf, and the same work across sources from the index.
   - Recommend: yes for same author and series. The cross-source part waits until the index has a caller that keeps it fresh (5f).
6. **Where RSS lives inside Explore** (5g).
   - Recommend: a 「訂閱」 tile in 我的書庫 that pushes today's `RSSListView` content, plus an optional 「訂閱的最新文章」 row. The RSS tab stays visible until decision 1.
7. **New strings.** Each step lists its proposals in five languages before code, as 2d did. Expected: 我的書庫, 精選, 相關, %@・最新, 新增來源, 編輯首頁, 新增欄目, 選擇內容來源, 呈現方式, 資料來源, 參數, 作品詳情, 可用來源, 目前沒有可閱讀的來源, 載入, 訂閱. Existing ones are reused: 繼續閱讀, 最新, 全部, 範圍.

### Made while planning

Each comes with its reason; the maintainer can overturn any of them.

1. **One branch per step, `5a → 5g`**, each cut from `main` after the previous one merges.
2. **One section type, but the home lives in its own file, `explore_home.json`.** This departs from the letter of §13.4, which makes the home the custom page whose id is `home`.
   - Home sections and custom-page blocks are both `HomeSection`. A custom-page block reads as a `.sourceCategories` section, so 5b has one loader for both.
   - Writing the home, or any new binding, into `custom_explore_pages.json` would make an older build fail to decode that file. It would keep the file aside as corrupt (0d's rule) and show no custom pages after a downgrade.
   - So the custom-page file keeps its format byte for byte. The new file has a `schemaVersion`, tolerant decoding (an unknown binding or layout is kept, not dropped), keep-aside, and blocked writes for unreadable or newer files, as 1d does.
   - Custom pages gain new bindings only in 5d, which decides how to stay downgrade-safe.
10. **「最新」 is one section that expands into one row per source,** with an exclusion list. This follows Jellyfin's 最新加入 (`LatestItemsExcludes`, §13.2, line 629) and the default tables, which list 最新 once.
11. **精選 is one section per bundled list,** titled by the list (中文書籍, 小說與文學…), as the storefront shows them today. No new string is needed for the rows.
3. **One section loader.** `DiscoverCategoryBookList.loadMoreIfNeeded` and `CustomExplorePageModel.loadMoreWaterfall` become one `SectionPageLoader` that owns paging, dedup (`uniqueAdditionalBooks`) and errors.
   - Book-source rows prime discover cookies first, as `DiscoverViewModel.reload` does (§13.4, audit §12.3).
4. **Per-row discover filters: the planned apply-and-restore does not work; needs a design before 5b step 4.** Found while starting 5a (2026-10-11):
   - The filter values live in `BookSourceRuntimeStateStore`, one persisted store per source URL.
   - The bridge's JS reads it live through `getVariableHandler` (`ModernParserBridge.swift:373-379`). So does search, and the review context copies it (`BookSource.swift:820`).
   - Network and async operations run outside `BookSourceSession`'s lock (`BookSourceSession.swift:21-24`).
   - So a row that writes its values, requests, and restores would leak its filter into a search or another row running at the same time. It could also leave the reader's own choice overwritten if the app quits mid-request.
   - **Direction to verify in 5b:** a per-request overlay. The row's values are passed with its request, and `getVariableHandler` answers from the overlay only for that evaluation. The store is never written.
   - The overlay's scope has to follow the evaluation across the async hop. Until a characterization test shows it can, rows of one source share the source's filter, as custom pages do today.
5. **One navigation path for the home.**
   - Every route the home can push (`ExploreNavigationRoute`, `OPDSFeedRoute`, `WebDAVDirectoryRoute`, `RemoteLibraryBookRoute`, Aozora, author pages, the work page) is registered once, on the home's stack.
   - **The `OPDSFeedRoute` clash** (Phase 2 follow-up 1): the route gains its destination kind, so one route opens one view.
   - **Value links:** closure `NavigationLink`s inside the public-library storefront become value links.
6. **Work-index freshness** (Phase 2 constraint): the home holds one `WorkIndexService`, refreshed when the shelf, a WebDAV index or the decisions change, never per view. The first refresh waits for `BookSourceStore.whenLoaded`.
7. **Continue reading reuses `RecentReadingSelection`**, which already merges shelf and off-shelf records; there is no second recents list.
8. **Gutenberg rows never request on their own.** Bundled collections need no request. A Gutenberg feed row shows 載入 until the reader taps it (`Technotes/PublicLibraries.md:15`).
9. **China region:** no public-library row, tile, scope option or source-center entry. `ProviderAvailability` drives this through the 2a registry, not view checks.

---

## Context

- **Explore today:** `ExploreTabRoot.swift`, `ExploreHomeView.swift` (destinations 389-427), `ExploreNavigationPath.swift` (routes 4-63), `ExploreSettings.swift` (`explore.mode` 9-23 and 65-86), and the TipKit flags (`ExploreModeTip.swift:37-86`).
- **Custom pages:**
  - Store: `CustomExplorePageStore.swift`, layouts at 43-102.
  - Model: `CustomExplorePageModel.swift`.
  - Views: `CustomExploreBlocks.swift`.
  - Editor: `CustomExplorePageEditor.swift`, `CustomExploreComponentSheet.swift`.
- **Discover:** `DiscoverViewModel.swift`, with reload 414-480, filters 384-410, 900-935 and 1067-1073, and the section queue 601-673. Also `DiscoverKindsCache.swift`.
- **Public libraries:** `PublicLibraryHomeView.swift` (storefront 48-95) and `PublicLibraryCollections.swift` (bundled lists).
- **Phase 2 pieces:** `SourceProviderRegistry`, `CollectionBrowsing`, `CopyLookup`, `WebDAVIndexCoordinator`, `WorkIndexService`.
- **Tabs:**
  - `RootTabCustomization.swift:5-42, 258-309`.
  - `ContentView.swift:316-382`.
  - RSS badge at 330 and 350.
  - Tests: `RootTabCustomizationTests:27-68`, and `LocalizedScreenshotUITests:52, 136`, which taps tab index 0.
- **Docs to update with the home:**
  - The root whitelist in `docs/design.md:66`, `CLAUDE.md:132` and `AGENTS.md:26`. The last two lack `PublicLibraryHomeView` today.
  - The Discover archetype at `docs/design.md:355`.
  - `Tests/Contracts/ExploreMixedNavigationPathContract.swift`, which pushes a removed route.

---

## Guardrails

Phase 1's and Phase 2's guardrails apply. In addition:

- **UI:**
  - Run `yuedu-ios-design` for every step from 5c on.
  - Pushed pages are `.inline`; only the Explore root keeps `rootTabTitle`.
  - Every row and card is one VoiceOver element: title, author, source, and status (已加入書架, 已下載).
  - Every view gets a `#Preview` with real-shaped data and a large-text variant.
- **iOS 17:**
  - The scope menu is a `Picker` in a `Menu`, with no modal.
  - 「選擇內容來源」 is pushed when the editor is already a sheet (§13.3).
  - Read `Technotes/iOS17MenuModalPresentation.md` first.
- **Strings:** reviewed per step (open decision 7), plus `ruby scripts/check_localizations.rb`.
- **Requests:**
  - The home sends none for Gutenberg.
  - Book-source rows load one at a time per source (`BookSourceSession`).
  - Nothing loads for a row off screen beyond the first screen's worth (measured in 5b).
- **Regression:**
  - From 5c on, run the §19 Phase 5 row: `ExploreModeTests`, `PublicLibraryAvailabilityTests`, `CustomExplorePageTests`, `ExploreNavigationAndMetadataTests`, `PublicLibraryExploreUITests`.
  - Also run the Phase 2 regression names (Phase 2 plan, Guardrails), and `DetailReaderBackSwipeUITests`, which assumes Explore's source tiles.

---

## Task 5a: The home model and its migration (no UI)

**Branch:** `unified-library/5a-home-model`. Design §5, §13.3 (default sections), §13.4.

- [x] **Step 1: Types.** In `Modules/Services/Works/HomeSection.swift`:
  - **`HomeSection`:** `id`, `binding`, `layout` (today's 7 plus tiles and single row), `title?`, `isEnabled`, `parameters: [String: String]`.
  - **`HomeSectionBinding`:** `.myLibrary`, `.continueReading`, `.latest(excluded: [SourceInstanceKey])`, `.sourceCategories([ExploreCategoryReference])`, `.opdsFeed(connectionID, url)`, `.gutenbergCollection(id)`, `.gutenbergFeed(url)`, `.aozoraNew`, `.aozoraIndex(kind)`, `.related`.
  - **Unknown bindings** decode as `.unknown(raw JSON)` and are written back unchanged.
  - **`HomePage`:** `schemaVersion` and sections.
- [x] **Step 2: `HomePageStore`** (`explore_home.json`): serial atomic writes, 0d's keep-aside and blocked writes, and tolerant decoding.
- [x] **Step 3: Default sections.** A pure function from the effective `explore.mode` and public-library availability to a `HomePage` (settled decisions 6–7):
  - **Book-source users:** 我的書庫 → 繼續閱讀 → 最新 → 精選.
  - **Public-library users and new installs:** 繼續閱讀 → 我的書庫 → 精選 → 最新.
  - **China:** no 精選.
  - **Nothing calls it at launch, and nothing writes `explore_home.json`, until 5c's home first reads it.** A file written now would freeze defaults before open decision 2 is answered, and changing them later would need a second migration. `explore.mode` stays for the fallback.
- [x] **Step 4: Tests** (`HomeSectionTests`, `HomePageStoreTests`):
  - round trip;
  - an unknown binding kept;
  - corrupt kept aside, unreadable never written over;
  - each migration row, CHN included;
  - an existing custom page untouched.

## Task 5b: Section loading through providers (no UI)

**Branch:** `unified-library/5b-home-loading`. Design §5 (`HomeSectionProviding`), §13.3 (「最新」 per provider), §13.4; decisions 3, 4, 7, 8.

- [ ] **Step 1: Characterize first,** on unchanged code:
  - `CustomExplorePageModel`'s serial loading and waterfall paging;
  - `DiscoverCategoryBookList`'s next page;
  - `DiscoverViewModel`'s filter write.
- [ ] **Step 2: `HomeSectionProviding`** on the 2a providers: `templates()`, `loadPolicy` (`.serialPerSource`, `.parallel`, `.onDemandOnly`) and `load(binding, page)`.
  - **Shelf:** continue reading (`RecentReadingSelection`), related (same author and series).
  - **OPDS and Calibre:** the feed's 最新 navigation, or the root's first group.
  - **Gutenberg:** bundled collections, and feeds on demand.
  - **Aozora:** new works and the index.
  - **WebDAV:** 2d's records, newest first by server date.
  - **Book sources:** a new `BookSourceProvider` in the registry, over its discover categories.
- [x] **Step 3: `SectionPageLoader`,** the one next-page loader (decision 3). Today's two callers move onto it.
- [ ] **Step 4: Per-row filters** (decision 4): a per-request variable overlay, never a write to the shared store. Prove it with a characterization test first; otherwise skip the step and record it.
  - Test two rows of one source with different filters, and the source page's filter unchanged after both.
- [ ] **Step 5: `HomeModel`:**
  - It loads the visible sections by policy, one book-source request at a time per source.
  - It tracks `didLoad`, `loadError` and empty per section.
  - It refreshes on pull and keeps unchanged sections, as `CustomExplorePageModel.sync` does.
- [ ] **Step 6: Measure** with 20 sections across 5 sources (fixtures). Report time to first section and the requests sent, and record them in "What landed".

## Task 5c: The home screen

**Branch:** `unified-library/5c-home-screen`. Design §13.3, §13.9; decisions 5, 8, 9; open decisions 2, 4, 7.

- [ ] **Step 1: Strings** reviewed with the maintainer.
- [ ] **Step 2: `ExploreHome`,** the new tab root.
  - It shows the sections in order, as horizontal cover-wall rows. Each row header names its source and pushes 查看全部.
  - Cards are the open-decision-4 style, with the `CoverReference` cover and `CopyLookup` status.
  - 我的書庫 renders as tiles: shelf groups, each connection, Gutenberg, Aozora, each book source, custom pages, the browser, and 訂閱 after 5g.
- [ ] **Step 3: Scope menu.**
  - 「全部」 shows the home.
  - Choosing one source shows that source's own page in place: book source → `ExploreSourcePage`; OPDS or Calibre → `OPDSFeedView`; WebDAV → `WebDAVDirectoryView`; Gutenberg → storefront; Aozora → catalog.
  - The choice is stored in UserDefaults and replaces `explore.mode`.
- [ ] **Step 4: One navigation path** (decision 5). Fix the `OPDSFeedRoute` clash, and turn the storefront's closure links into value links.
- [ ] **Step 5: The fallback** (open decision 2). `ExploreTabRoot` shows the old roots when the switch is on.
- [ ] **Step 6: Tests.**
  - **Unit:** section ordering and the scope choice.
  - **UI** `ExploreHomeUITests`: the home shows its default sections (fixtures); a 我的書庫 tile pushes a WebDAV library, using the Phase 2 local-server opt-in; scope switches to one source and back; CHN shows no public libraries.
  - **Existing:** `PublicLibraryExploreUITests` and `DetailReaderBackSwipeUITests` are updated, not deleted. They assert the same behaviors through the new home.
  - One screenshot per screen.
- [ ] **Step 7: Remove the bookshelf ＋ library entries**, now that browsing has an entry (settled decision 3). `RemoteLibraryNavigationUITests` changes to the new entry.

## Task 5d: The section editor

**Branch:** `unified-library/5d-section-editor`. Design §13.3 (新增欄目, Rex order).

- [ ] 編輯首頁: reorder, hide and remove sections; exclude sources from 最新.
- [ ] 新增欄目:
  - choose a layout, then configure the section;
  - a live preview of one real page; Gutenberg loads only that page, on the reader's tap;
  - title, data source and parameters.
- [ ] 選擇內容來源, grouped: App data, libraries, book sources (pushing their discover categories), external services (empty until Phase 3). On iOS 17 it is pushed inside the editor's stack.
- [ ] Today's custom-page editor reuses the same configuration screen, so there is one editor.
- [ ] Tests: unit tests for the editor model; one UI test adding a book-source row and a library row.

## Task 5e: The source center

**Branch:** `unified-library/5e-source-center`. Design §13.6.

- [ ] **One screen, 新增來源,** reached from the home toolbar and from 設定 → 遠端書庫. Three blocks:
  - **Public libraries:** one tap adds the library's default sections. Hidden in CHN.
  - **Connect my library:** WebDAV, OPDS, Calibre through the existing editor, pushed.
  - **Modules:** absent until Phase 6.
- [ ] **Adding a source adds at least one home section** (§13.6). Removing a source removes its sections.
- [ ] **Tests:**
  - adding Gutenberg adds its section, and removing it removes the section;
  - adding a WebDAV connection shows its tile and, once indexed, its 最新 row (opt-in local server).

## Task 5f: The read-only work page

**Branch:** `unified-library/5f-work-page`. Design §14.1; decision 6.

- [ ] **`WorkDetailView`** on `BookDetailScaffold`, reached from a card or the scope's source page:
  - Header: the resolved title, authors and cover (`MetadataResolver`).
  - **可用來源:** versions → source records → separate actions (繼續閱讀, 線上閱讀, 下載, 加入書架, 查看來源詳情). The existing detail pages are pushed as 「來源詳情」.
- [ ] **Only data, nothing readable:** the page says 「目前沒有可閱讀的來源」 and shows no reading button. 「尋找可用來源」 waits for Phase 4.
- [ ] **作品詳情 from the bookshelf's long-press menu** (§14.1).
- [ ] **Tests:**
  - a work with a copy, a remote record and a public-library record shows each version's actions;
  - a data-only work shows the message and no reading action;
  - VoiceOver order: header, versions, actions.

## Task 5g: RSS inside Explore

**Branch:** `unified-library/5g-rss-in-explore`. Design §13.8; open decision 6.

- [ ] **A 訂閱 tile in 我的書庫** pushing today's RSS content (all articles, unread, starred, feed management), with its unread count in the tile's label.
- [ ] **An optional 「訂閱的最新文章」 row,** through an RSS provider whose items are articles, never `Book`.
- [ ] **The RSS tab stays** until open decision 1. Its badge stays where it is until then.
- [ ] **Tests:** the tile opens the same content; unread count; RSS UI tests unchanged.

## Task 5h: Tabs (gated on open decision 1)

- [ ] Planned when the maintainer has decided on a 5c build.
- [ ] **Changes the plan expects:**
  - `RootTabItem` order and migration of `yd_root_tab_visible_ids`;
  - theme icons per tab id;
  - the RSS badge's new place;
  - `docs/design.md`, `CLAUDE.md` and `AGENTS.md` whitelists;
  - `RootTabCustomizationTests`;
  - UI tests that tap tab index 0.

---

## Acceptance (Phase 5)

- [ ] 5a–5g as each task's tests state.
- [ ] **Design §15 cover-wall acceptance:** after adding Gutenberg, one OPDS catalog and one Calibre, the home shows a section for each; the work page tells readable from data-only.
- [ ] **No Gutenberg request** without the reader's action. **No public-library surface in CHN.**
- [ ] **Every step:** its own branch, its tests and the Phase 5 regression after its last edit, merged only on the maintainer's yes (or standing instruction), never pushed.

## Follow-ups found while planning

1. **`Tests/Contracts/ExploreMixedNavigationPathContract.swift:12`** pushes `.search("三體")`, a route that no longer exists, and nothing runs it. Fix it with 5c's navigation work, or delete it with the maintainer's yes.
2. **`CLAUDE.md:132` and `AGENTS.md:26`** list only `ExploreHomeView` as Explore's root. `docs/design.md:66` also lists `PublicLibraryHomeView`. 5c rewrites all three.
3. **`discover.categorySelection.<source UUID>`** (`DiscoverViewModel.swift:262`) is keyed by the source's device-local UUID, so a re-imported source loses its shown categories. 5b should key it by `bookSourceUrl` (design D4).
4. **The audit's third next-page loader** (`DiscoverViewModel.swift:625-673`) loads page 1 only. There are two next-page loaders, not three.

## What landed

### 5a: the home model (2026-10-11)

- **`HomeSection.swift`:**
  - `HomeSectionLayout` is a string, so a later build's layout survives.
  - `HomeSectionBinding` has the ten bindings plus `.unknown(PreservedJSON)`, written back byte-equivalent.
  - `HomeSection` reads missing `title`, `isEnabled` and `parameters` as their defaults. `HomeSection(component:)` reads a custom-page block.
  - `HomePage` carries `schemaVersion` 1.
  - `HomePageDefaults.page(mode:publicLibrariesAvailable:)` builds the §13.3 orders.
- **`HomePageStore.swift`:** `explore_home.json` beside the custom pages, written on a serial queue with sorted keys.
  - An undecodable file is kept aside as `explore_home.corrupt-<mtime>.json`.
  - An unreadable file, or one from a newer schema, is read-only for the launch. A newer file is read section by section.
- **Nothing is wired.** No launch path creates the store or calls the defaults (step 3).
- **Tests:** `HomeSectionTests` (8) and `HomePageStoreTests` (6), 14 tests in 2 suites, passed. No existing code changed, so no other regression applies.
- **Found while starting:** per-row filters cannot be apply-and-restore (decision 4, rewritten).

### 5b, part 1: one next-page loader (2026-10-11)

- **`SectionPageLoader.swift`:**
  - `SectionPaging` owns which page is next, whether there is one, one request at a time, and the failure reason. A page with no new books ends the category.
  - `SectionPageLoader` fetches, drops books already shown, and makes them displayable. It takes an injected `fetchPage`; `.live` is `BookSourceFetcher.discoverBooks`.
- **Callers moved onto it:**
  - `DiscoverCategoryBookList` (查看全部 and the list layout) keeps no paging state of its own. Its failures are now logged; they were shown but never logged before.
  - `CustomExplorePageModel` (`init(pageLoader:)`) moves its waterfall onto it, and its first page also goes through the injected fetch.
  - `WaterfallPaging` keeps its read-only fields, so the views did not change.
- **Step 1, characterization on unchanged code, was not possible.** The Phase 0a note at the top of `CustomExplorePageModelTests` records why: the fetch reached the network through the JS bridge's own session. The injection came first, with behavior unchanged, and the tests followed: `SectionPagingTests` (4), `SectionPageLoaderTests` (2), `CustomExploreWaterfallPagingTests` (2). The waterfall tests cover page 1 then 2, repeats dropped, the end on a page of repeats, and the retry asking for the same page.
- **Regression:** with `CustomExplorePageModelTests` and `CustomExplorePageTests`, 19 tests in 5 suites passed.
- **Left in 5b:** step 2 (providers), step 4 (per-row filters, needs the overlay to be proven), step 5 (`HomeModel`) and step 6 (measurement).

