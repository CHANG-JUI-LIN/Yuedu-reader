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
- **A discovery engine** (Phase 7, maintainer 2026-10-11). The first step is on device: 為你推薦, mixed from the discover pages of the reader's own sources, with source mixing, genre match, exploration, cross-source dedupe and a local cache. A server-side book index and regional recommendations come later. Draft in `Technotes/DiscoveryEngine-2026-10-11-draft.md`. Its recommendations reach the home as more section kinds.
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
10. **Answered 2026-10-11** (maintainer, by option):
    - **Open decision 2:** the flag is a 探索設定 switch, 「使用舊版探索頁」, for that one version.
    - **Open decision 4:** the card is Apple Books style. A 2:3 cover, then the title in at most two lines and the author in one; the row's header names its source.
    - **Open decision 5:** 相關 ships in v1 **including the same work across sources**, not only same author and series. 5b's `ShelfProvider` serves no 相關 yet. It needs the work index kept fresh by one owner (decision 6) before 5c can show it; this is now part of 5c.
    - **Open decision 6:** RSS is a 「訂閱」 tile in 我的書庫 that pushes today's RSS content, with its unread count. An optional 「訂閱的最新文章」 row may follow. The RSS tab stays until open decision 1.
11. **The home's look, stated by the maintainer on 2026-10-11:** 「70% Apple Books 的視覺質感，30% Emby 的資訊密度，但底層採用 Emby 式的來源聚合和動態欄目能力。」 How 5c reads it, to be shown in previews before it ships:
    - **Apple Books' finish:** large covers, generous spacing, the title in two lines and the author in one, no card chrome.
    - **Emby's density:** one more small line per card, holding the source or the copy status (已加入書架, 已下載). 繼續閱讀 cards carry a reading-progress bar. Each row header names its source and leads to 查看全部.
    - **Emby's model underneath:** every source serves its own sections, and 最新 expands per source. 5a and 5b already work this way.
12. **Answered 2026-10-11, while planning 5d** (maintainer, by option and in their own words):
    - **我的書庫 leaves the home.** 「我的書庫我覺得不應該在這個頁面，emby 播放器應該也不會把emby庫的列表放在這吧」. Every library and book source is reached from 範圍, as Emby switches libraries. This replaces decision 3's 「browsed from Explore's 我的書庫 tiles」; settled 2026-10-11 too: no shelf or shelf-group tiles.
    - **The browser** is an item of 範圍, shown unless turned off in 探索設定.
    - **Several home configurations, switchable:** 「探索頁應該是可以自己切換配置的，有預設模塊和空白模塊」. Built in: 預設 (the defaults of decision 6, without 我的書庫) and 空白. The reader can add more.
    - **Custom pages merge into configurations:** a custom page becomes one configuration, and there is one kind of page left. This needs a migration of `custom_explore_pages`; plan decision 2 (custom pages keep their own format) no longer holds once it lands.
    - **Affected, to re-plan when reached:** decision 10's RSS 「訂閱」 tile (5g) has no 我的書庫 to sit in.
13. **Answered 2026-10-11, after 5d-1** (maintainer: 「話說探索頁的設置頁可以拿掉了吧？全部換新的就對了」):
    - **探索設定 goes, and the old roots with it:** `ExploreHomeView`, `PublicLibraryHomeView` and 使用舊版探索頁. This ends decision 9/10's one-version grace.
    - **No global presentation settings.** 「肯定全部刪掉啊，都是自己選擇呈現方式和呈現模塊了」: 列表／雜誌, the magazine's 豎排關鍵詞, 展示數量 and 預加載, the grid, 每列欄數, 首屏頁面 and 封面並發數 are deleted, not moved. Sections choose how they are drawn.
    - **首屏頁面:** 範圍 is remembered; a saved 首屏 source becomes the 範圍 once, on upgrade.
    - **The browser's 隱藏** moves to 編輯首頁 (5d-2), with the other 範圍 entries (recommendation, not answered against).
14. **Answered 2026-10-11, from the maintainer's layout notes** (Featured Reading Card, Horizontal Rail, Multi-row Carousel, Cover Grid, Detailed List, then Hero, Bento, spine shelf, stacked collection and editorial cards later):
    - **Five layouts, and only five for now:** 大型閱讀卡片, 橫向單排, 多行橫向輪播, 固定封面網格, 圖文清單 (with ranks as an option). The seven custom-page kinds map onto them when custom pages migrate (5d-4): 左右滑動 and 推薦卡片 → 橫向單排; 宮格 → 多行橫向輪播; 排行榜 and 網絡排行榜 → 圖文清單 with ranks; 多分類排行榜 → one 圖文清單 section per category; 錯位瀑布流 → 固定封面網格.
    - **A source may suggest a layout; the app decides** what is drawn (small screens, Dynamic Type, VoiceOver), and the reader can change it.
    - **繼續閱讀 defaults to 大型閱讀卡片.** This replaces the 「保留現在的樣子」 row for the default only. 「可以自己改，反正每一個呈現方式還可以在長按名字部分來做編輯或是其他動作」: long-pressing a section's name offers its layout and its other actions.
15. **Answered 2026-10-11, on Gutenberg** (maintainer, looking at 「Latest in Project Gutenberg」 with only 載入: 「每次都要手動加載，還有古騰堡沒有封面不正常吧，這樣我怎麼刮削」):
    - **Gutenberg's rows load when 探索 opens,** every one of them, as other sources' do. Chosen over 「load as each row scrolls into view」. This drops `.onDemandOnly` from the home and the 「開啟首頁不請求 Gutenberg」 promise of `Technotes/PublicLibraries.md`. Gutenberg's robot policy says only that the site is 「intended for human users only」 and that automated access may block the IP; it says nothing of apps, OPDS or covers. Still no prefetch of next pages, no background crawling, nothing at launch.
    - **Covers are Gutenberg's own,** fetched when a card shows and kept in the cover cache; the locally drawn cover stays only for a book without one. A book added to the shelf keeps the same cover.
16. **Answered 2026-10-11, from the maintainer's notes on Emby's home** (home sections are queries over collections the sources already have; metadata providers only fill gaps, so no 「novel TMDB」 is needed, and a search-only source must not pretend to rank). Four new section kinds, all of them, as 5d-6:
    - **古騰堡熱門:** the official download ranking (`PublicLibrary.popularURL`), a default section.
    - **最近加入書庫:** indexed WebDAV, Calibre and OPDS books by when they were added; no section without a library.
    - **系列下一本:** the next volume of a series in 繼續閱讀, Emby's Next Up; only where the source records the series.
    - **書源的排行／最近更新:** only for a book source whose discover categories offer one; a search-only source gets neither.
17. **Answered 2026-10-11, while starting 5d-1b:**
    - **Gutenberg and 青空 search move into the 搜索 tab now,** ahead of Phase 4's unified search. Asked because the old 公有書庫 root's search field is the only place that searches them, and 5d-1b deletes that root. Built with the native search scopes (來源配置｜公有書庫) on the tab's root, so the iOS 17 result table stays as it is. Gutenberg still searches only on submit.
    - **範圍 stays a menu,** with no search for a library of thousands of sources (asked; the maintainer kept the menu).
    - **Amended the same day, after seeing it:** no scope bar and no text naming the search scope. 「搜索不應該有顯示搜索範圍的文字」: the scope bar, the hint's 「Project Gutenberg和青空文庫」 and the sources' 「已啟用 N 個來源配置」 all go. One search covers both. The sources' results come first, then a 公有書庫 section with 「在 Project Gutenberg 搜尋」 and 青空文庫's matches. With no book source, the keyboard's Search asks Gutenberg.

18. **Answered 2026-10-11, starting 5d-2** (maintainer, by option and in their own words):
    - **編輯首頁 is reached from the end of the home:** 「拖到最下面有個編輯按鈕」, not from the bar.
    - **It edits the home in place,** from the maintainer's screenshot of Rex's home editor (「我要這樣子」), replacing a first pushed list page: each section becomes a card with a check mark beside it to show or hide it; cards are dragged to reorder; a card opens its own page (在首頁顯示, 最新's 排除的來源, 刪除), where 5d-5's section form will grow; 完成 at the top and at the end.
    - **The screenshot's ＋ (新增欄目)** comes with 5d-5, not as a button with nothing behind it (recommended option).
    - **The browser's switch** is a 範圍 card at the end of the edited home (recommended option).
    - **A section name's long press** offers 隱藏, 設定 (that section's page) and 刪除, which asks first (recommended option). 5d-3 adds 呈現方式 to the same menu.

19. **Answered 2026-10-11, during 5d-3** (maintainer: 「現在不應該顯示這是古騰堡的…你顯示來源就很不像 emby 的首頁聚合，而且 emby 應該是聚合的內容隨著切換的 emby 庫改變，而不會動到首屏頁面吧」, then by option):
    - **範圍 filters the home; it does not replace it.** Choosing a library keeps every section, its order and its layout, and leaves only that library's books; a section with none of them is not drawn. A library's full catalog is reached from each section's 查看全部. This replaces 5d-1's 「a source's own page in place」.
    - **The home names no source.** No source line under a section's title and none on a card; a book's source shows on its work page only.
    - **最新 is one row.** Under 全部 it mixes every source, newest first; sources without dates take turns. Under one library it is that library's 最新. 排除的來源 stays. This replaces plan decision 10's 「one row per source」.
    - **偏好閱讀語言 is its own step after these** (the maintainer's pasted notes): several languages, in order, default 「prefer, allow others」; Gutenberg's bundled lists tagged per book, 青空 as Japanese; the 全部 home sorts and filters by it; Gutenberg's categories follow it instead of the interface language. China's region rule still holds.

20. **Answered 2026-10-11, after decision 19** (maintainer, by option and in their own words):
    - **A full catalog entry, always visible, at the top of the home:** 「完整目錄入口應該始終可見，但不放在首頁最底部」. Under 全部, one 「瀏覽書庫」 entry for every library; under one library, 「瀏覽完整目錄」, which opens that library's own page (Gutenberg's popular, latest and categories; 青空's author index, 五十音 and categories; a book source's discover page; an OPDS or WebDAV root). It does not depend on what the home holds. Reuse the existing pages: 「不要重新實作第二套目錄系統」.
    - **A sixth layout, 精簡閱讀卡片,** from the maintainer's screenshot of Apple Books' 「繼續」: a small cover beside the title, author and kind・status, with •••. It becomes 繼續閱讀's default; 大型閱讀卡片 stays as a choice. The card takes its cover's main colour, with white text, darkened where white would not read. ••• offers 從繼續閱讀移除 and 標記為已讀完.

21. **Answered 2026-10-11, after 5d-3c** (maintainer, by option): **a new 聚合設定 page, mapped from Emby's own settings** (「新開一個聚合設定，emby的聚合設定怎麼寫的我們就對應過來」). Emby's user settings that shape its aggregation (`UserConfiguration` and the Home Screen page) map one to one:
    - Home sections → 首頁欄目, the same sections and edits as 編輯首頁 (no second editor of the data).
    - `OrderedViews` (library order) → 書庫順序: the libraries' order in 範圍, 瀏覽書庫 and 最新's turns.
    - `LatestItemsExcludes` → each library's 「顯示在最新」. It replaces 最新's per-section 排除的來源: one place, not two.
    - `HidePlayedInLatest` / `HidePlayedInSuggestions` → 最新／相關 hide books already read.
    - Emby's playback language preferences → 偏好閱讀語言 (several, in order; first use: the interface language alone) and 推薦範圍 (優先推薦偏好語言 by default, 只推薦偏好語言, 不限制語言). Within each section the preferred languages come first, in their order; sections keep the order 編輯首頁 gives them. A book of unknown language (most book sources, OPDS) is kept, after the preferred ones, even under 只推薦.
    - **Entry: the 設定 tab only,** as Emby's are in its user settings.
    - Built as 5d-3d (the page and 偏好閱讀語言), then 5d-3e (書庫順序), 5d-3f (顯示在最新), 5d-3g (隱藏已讀).

22. **Answered 2026-10-11, starting 5d-4** (maintainer, by option and in their own words):
    - **Name: 首頁配置.** The 範圍 menu's section is 首頁配置, ＋ is 新增首頁配置, a category's long press is 加入首頁配置; a bare 「配置」 would read as 來源配置. The reader's own configurations replace 自訂頁, which goes as a name.
    - **預設 is the home the reader has now,** edited since 5d-2, not a fresh copy of the defaults. Every configuration is edited the same way; 空白 only starts with no section.
    - **The old custom page and its block editor are deleted now** (recommended option). Until 5d-5's form, a migrated section's category cannot be changed; its order, visibility, layout and removal can, and 加入首頁配置 adds a category.
    - **新增首頁配置 asks where to start:** 「可以問是要從預設調還是空白」. One alert with the name field, 從預設開始 and 從空白開始.

23. **Answered 2026-10-11, starting 5d-5** (maintainer, by option):
    - **Parameters come with 5d-5,** not as a later step: a book source's discover filters, kept per section instead of in the source's shared variables, and the category a book source's 最新 stands on.
    - **最新 sits in App 資料,** with 繼續閱讀 and 相關: all three gather across sources (recommended option).
    - **新增欄目 is Rex's order:** a layout first, then the section's page (recommended option).
    - **No 外部服務 group** until Phase 3 gives it something (recommended option).

24. **Answered 2026-10-11, starting 5d-6** (maintainer, by option; all four the recommended one). Decision 16's four kinds, against what 5d-5 already built:
    - **古騰堡熱門** goes into a new install's 預設 only. A saved 預設 is the reader's home and is not changed; 新增欄目 → 書庫 → Project Gutenberg → 熱門 adds it.
    - **最近加入書庫 is not a separate section:** 最新 already merges the libraries' newest (WebDAV's index by server date, OPDS/Calibre, Gutenberg, 青空文庫, the book sources' picked categories), and 聚合設定's 顯示在最新 can keep it to the libraries.
    - **系列下一本 is built now,** only from books that record a series and its number (an imported book's metadata; the WebDAV index once it keeps the number). A book source's web novel has no series data and gets none.
    - **書源的排行／最近更新 is not guessed from category names:** 5d-5's 新增欄目 already picks any source's ranking or recently-updated category.

### Open, for the maintainer (each with a recommendation)

These change what is built, so no step that depends on one starts until it is answered.

1. **Tab order and who gets it** (gates 5h). Plan A is 書架、探索、搜尋、統計、設定, and §13.7 adds "Explore first".
   - Recommend: decide after 5c, on a build, as settled. Then choose between new installs only and everyone with a one-time notice.
2. *(Answered 2026-10-11; see settled decision 10.)* **Whether the reader sees the fallback flag** (5c; the flag itself is settled decision 9).
   - Recommend: a 探索設定 switch 「使用舊版探索頁」 (one new string) for that one version.
   - Alternative: an internal flag only.
3. *(Answered by the design; see settled decision 8.)*
4. *(Answered 2026-10-11; see settled decision 10.)* **The card** (5c).
   - Recommend: Apple Books style. A 2:3 cover with title and author below, at most two lines and one line, and the row's source in its header.
   - Alternative: title over the cover, Emby style.
5. *(Answered 2026-10-11 against the recommendation: cross-source too; see settled decision 10.)* **A 「相關」 row in v1** (5b, 5c): same author and series from the shelf, and the same work across sources from the index.
   - Recommend: yes for same author and series. The cross-source part waits until the index has a caller that keeps it fresh (5f).
6. *(Answered 2026-10-11; see settled decision 10.)* **Where RSS lives inside Explore** (5g).
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
7. **Continue reading is the shelf's copies by `lastOpenedDate`, newest first** (design §13.3: 「書架上最近打開的副本」). Revised in 5b: `RecentReadingSelection` is search's list. It carries search's own clearing time, and its off-shelf records hold only a name, which a tap can only search for.
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
  - Book-source rows load one at a time per source. `HomeModel` queues them itself: `BookSourceSession` does not serialize discover fetches, which run on `bridgeForAsyncOperations` outside its gate (`BookSourceFetcher+Discover.swift:40-44`).
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
- [x] **Step 2: `HomeSectionProviding`** on the 2a providers: `templates()`, `loadPolicy` (`.serialPerSource`, `.parallel`, `.onDemandOnly`) and `load(binding, page)`.
  - **Shelf:** continue reading (`RecentReadingSelection`), related (same author and series).
  - **OPDS and Calibre:** the feed's 最新 navigation, or the root's first group.
  - **Gutenberg:** bundled collections, and feeds on demand.
  - **Aozora:** new works and the index.
  - **WebDAV:** 2d's records, newest first by server date.
  - **Book sources:** a new `BookSourceProvider` in the registry, over its discover categories.
- [x] **Step 3: `SectionPageLoader`,** the one next-page loader (decision 3). Today's two callers move onto it.
- [ ] **Step 4 (skipped, see 5b part 2): Per-row filters** (decision 4): a per-request variable overlay, never a write to the shared store. Prove it with a characterization test first; otherwise skip the step and record it.
  - Test two rows of one source with different filters, and the source page's filter unchanged after both.
- [x] **Step 5: `HomeModel`:**
  - It loads the visible sections by policy, one book-source request at a time per source.
  - It tracks `didLoad`, `loadError` and empty per section.
  - It refreshes on pull and keeps unchanged sections, as `CustomExplorePageModel.sync` does.
- [x] **Step 6: Measure** with 20 sections across 5 sources (fixtures). Report time to first section and the requests sent, and record them in "What landed".

## Task 5c: The home screen

**Branch:** `unified-library/5c-home-screen`. Design §13.3, §13.9; decisions 5, 8, 9; open decisions 2, 4, 7.

- [x] **Step 1: Strings** reviewed with the maintainer. Approved as proposed, 2026-10-11:

  | zh-Hant | zh-Hans | en | ja | ko |
  |---|---|---|---|---|
  | 我的書庫 | 我的书库 | My Library | マイライブラリ | 내 서재 |
  | 相關 | 相关 | Related | 関連 | 관련 |
  | %@・最新 | %@・最新 | Latest in %@ | %@の新着 | %@ 최신 |
  | 載入 | 加载 | Load | 読み込む | 불러오기 |
  | 使用舊版探索頁 | 使用旧版探索页 | Use Classic Explore | 以前の探索画面を使う | 이전 탐색 화면 사용 |
- [x] **Step 2: `ExploreHome`,** the new tab root.
  - It shows the sections in order, as horizontal cover-wall rows. Each row header names its source and pushes 查看全部.
  - Cards are the open-decision-4 style, with the `CoverReference` cover and `CopyLookup` status.
  - 我的書庫 renders as tiles: shelf groups, each connection, Gutenberg, Aozora, each book source, custom pages, the browser, and 訂閱 after 5g.
- [x] **Step 3: Scope menu.**
  - 「全部」 shows the home.
  - Choosing one source shows that source's own page in place: book source → `ExploreSourcePage`; OPDS or Calibre → `OPDSFeedView`; WebDAV → `WebDAVDirectoryView`; Gutenberg → storefront; Aozora → catalog.
  - The choice is stored in UserDefaults and replaces `explore.mode`.
- [x] **Step 4: One navigation path** (decision 5). Fix the `OPDSFeedRoute` clash, and turn the storefront's closure links into value links. Done first, as 5c-1 (see "What landed").
- [x] **Step 5: The fallback** (open decision 2). `ExploreTabRoot` shows the old roots when the switch is on.
- [x] **Step 6: Tests.**
  - **Unit:** section ordering and the scope choice.
  - **UI** `ExploreHomeUITests`: the home shows its default sections (fixtures); a 我的書庫 tile pushes a WebDAV library, using the Phase 2 local-server opt-in; scope switches to one source and back; CHN shows no public libraries.
  - **Existing:** `PublicLibraryExploreUITests` and `DetailReaderBackSwipeUITests` are updated, not deleted. They assert the same behaviors through the new home.
  - One screenshot per screen.
- [x] **Step 7: Remove the bookshelf ＋ library entries** (5c-5), now that browsing has an entry (settled decision 3). `RemoteLibraryNavigationUITests` changes to the new entry.

## Task 5d: The section editor

**Branch:** `unified-library/5d-section-editor`. Design §13.3 (新增欄目, Rex order).

**Re-split 2026-10-11 after settled decision 12**, each on its own branch and merged on its own, so main never offers a layout the home cannot draw and never has two editors:
- **5d-1:** 我的書庫 leaves the home; 範圍 holds the libraries, the book sources, the custom pages and the browser.
- **5d-1b:** 探索設定, the old roots and every global presentation setting are deleted (decision 13); public-library search moves to the 搜索 tab first (decision 17).
- **5d-1c:** Gutenberg's rows load with 探索, and its cards show Gutenberg's covers (decision 15).
- **5d-2:** 編輯首頁: reorder, hide and remove sections, 最新's 排除的來源, and the browser's 隱藏 (store edits that keep unknown sections in place). A section's name, long-pressed, offers the same actions for that section (decision 14).
- **5d-3:** the five layouts of decision 14, drawn by the home for any section, and chosen from the section name's long press. 繼續閱讀's default becomes 大型閱讀卡片.
- **5d-4:** configurations: 預設, 空白 and the reader's own, switched from 範圍; custom pages migrate into them, their blocks mapped onto the five layouts (decision 14).
- **5d-5:** one section form for 新增欄目 and for what were custom-page blocks, with 選擇內容來源. App 資料 offers only bindings that exist (繼續閱讀, 相關); 最近加入書架, 書架分組 and 閱讀統計 have none.
- **5d-6:** the four section kinds of decision 16.

- [ ] **Step 0: Strings, for the maintainer's review before any code** (proposed 2026-10-11). Reused as they are: 預覽, 隱藏, 顯示, 標題, 刪除, 移除, 目前, 全部, 來源配置, 最新.

  | zh-Hant | zh-Hans | en | ja | ko | Where |
  |---|---|---|---|---|---|
  | 編輯首頁 | 编辑首页 | Edit Home | ホームを編集 | 홈 편집 | the home's bar and its page title |
  | 新增欄目 | 新增栏目 | Add Section | セクションを追加 | 섹션 추가 | 編輯首頁's add row and the new section's page |
  | 選擇內容來源 | 选择内容来源 | Choose Content Source | コンテンツのソースを選択 | 콘텐츠 소스 선택 | the source picker's title |
  | 呈現方式 | 呈现方式 | Layout | 表示方法 | 표시 방식 | step 1 of 新增欄目 |
  | 資料來源 | 数据来源 | Data Source | データソース | 데이터 소스 | the section page's source row |
  | 參數 | 参数 | Parameters | パラメータ | 매개변수 | the section page's parameters header |
  | 磚塊 | 砖块 | Tiles | タイル | 타일 | the 我的書庫 layout |
  | 單列 | 单行 | Single Row | 1列 | 한 줄 | the row layout |
  | App 資料 | App 数据 | App Data | アプリのデータ | 앱 데이터 | a source picker group |
  | 書庫 | 书库 | Libraries | ライブラリ | 서재 | a source picker group |
  | 外部服務 | 外部服务 | External Services | 外部サービス | 외부 서비스 | a source picker group (empty until Phase 3) |
  | 排除的來源 | 排除的来源 | Excluded Sources | 除外するソース | 제외된 소스 | 最新's section page |

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
5. **OPDS 「最新」 cannot follow a feed's `sort/new` link:** `OPDSClient` keeps no `rel` on navigation entries. Keeping it is a parser change with its own tests.

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

### 5b, part 2: what each source puts on the home (2026-10-11)

- **`ItemOpening`** (`SourceProvider.swift`): every `CollectionEntry.item` now carries what opening it needs, frozen when the entry is made (CLAUDE.md, freeze data at navigation boundaries).
  - `.copy(UUID)`.
  - `.opdsEntry` and `.webDAVFile`, which `RemoteLibraryBookRoute(entry:connectionID:)` already takes.
  - `.gutenberg(GutenbergBook)`, `.aozora(AozoraWork)`.
  - `.onlineBook(FrozenOnlineBook)`, compared by id as `ExploreNavigationRoute.book` is.
  - The 2a providers fill it. There is one entry type, not a home-only card.
- **`HomeSectionProviding`** (`HomeSectionProviding.swift`) departs from design §5's draft in three ways:
  - `load(_ section:)` returns the first page only. 查看全部 opens the source's own page, which already pages.
  - The policy is asked per section (`loadPolicy(for:)`, nil when not served). Gutenberg's bundled lists are `.local` while its feeds are `.onDemandOnly`, and a book source serves 「最新」 only with a picked category.
  - `templates()` waits for the editor (5d).
- **The row each source serves:**
  - **Shelf:** 繼續閱讀 (decision 7, revised). 相關 is not served (open decision 5).
  - **OPDS and Calibre:** `.opdsFeed`, and 「最新」 as the root's own books, or else its first navigation feed's. The parser keeps no `rel` on navigation entries, so a `sort/new` link cannot be followed yet (follow-up 5).
  - **Gutenberg:** bundled lists `.local` with no request; feeds and 「最新」 (`latestURL`) `.onDemandOnly`; nothing in China.
  - **Aozora:** 新着 and 「最新」 from the catalog, and an index as its groups. Nothing until the catalog is read.
  - **WebDAV:** 「最新」 is the 2d records, newest `getlastmodified` first, undated last, with 2e's cover when read. A connection without a record store serves nothing.
  - **Book sources:** `BookSourceProvider` primes the discover cookies once per provider, so once per home sync, as `DiscoverViewModel.reload` primes once per load. It then loads page 1 through `SectionPageLoader`. 「最新」 uses the category stored in the 「最新」 section's `parameters` under `latest.category:<bookSourceUrl>` (settled decision 8).
- **`SourceProviderRegistry.homeProviders(shelf:)`:** the shelf, connections (WebDAV with `shelf.remoteRecords`), Gutenberg, Aozora, then the explore sources in 探索's order.
- **`HomeModel`** (`HomeModel.swift`):
  - Rows are built only after `waitForSources`, which is `BookSourceStore.waitUntilLoaded` when wired in 5c, so a cold launch never reads as deleted sources.
  - 「最新」 expands into one row per serving source; other sections take the first provider that serves them. 我的書庫 is a tile per source; hidden sections, unserved ones and later builds' bindings have no row.
  - Loading by policy:
    - `.serialPerSource` queues per source;
    - `.local` and `.parallel` start at once;
    - `.onDemandOnly` shows `awaitingRequest` until `request`;
    - pull to refresh returns on-demand rows to 載入.
  - A sync keeps a row whose section and policy are unchanged.
  - Each load records a `⏱ home.row` span.
- **Step 4 skipped:** per-row filters, decision 4. Rows of one source share the source's filter, as custom pages do today.
- **Step 6, measured** (injected 100 ms answers on the simulator, Debug; this measures the home's scheduling, not a network). 20 rows over 5 sources: three book sources × 4 categories, OPDS × 4, Aozora × 4.
  - The first row loaded at 0.7 ms (on-device).
  - All 20 loaded at 418 ms: four queued answers per book source plus 18 ms.
  - Each book source never had more than one load in flight; OPDS had 4.
- **Tests:** `HomeModelTests` (9), `HomeModelSchedulingTests` (1), `BookSourceProviderTests` (3), `LocalHomeRowTests` (2). With the 2a suites (`SourceFailureTests`, `OPDSProviderTests`, `WebDAVProviderTests`, `AozoraProviderTests`, `ShelfProviderTests`, `SourceProviderRegistryTests`) and `OPDSBrowseModelBehaviorTests`, 34 tests in 10 suites passed; the scheduling run passed 10 in 2.
- **Left as it was:** `discover.categorySelection.<source UUID>` (follow-up 3) still keys by the device-local UUID. Re-keying it changes stored reader state, so it waits for its own step with a migration.

### 5b fixes (2026-10-11), before 5c wires anything

- **WebDAV 「最新」 at 20,000 books** (`LocalHomeRowTests.webDAVLatestAtScale`, Debug, simulator):
  - **Before:** 2.99 s, all of it on the main actor. The row read the whole index there, and made a `DateFormatter` for every file.
  - **Split:** 274 ms reading the index; 1,444 ms parsing dates and sorting, even with one formatter.
  - **After:** 340 ms in total, off the main actor (`newestFiles` is `nonisolated`). The longest main-actor stall while it loaded was 0.9 ms.
  - The fixed RFC 1123 form is read by position. Other forms (RFC 850, asctime) still go to `DateFormatter`; `serverDates` checks the two agree.
- **Cookie priming once per sync.** `primeDiscoverCookiesIfNeeded` drops 起点's `_csrfToken` and fetches the search page again on every call. Before this fix, four rows of one source sent four extra requests per home load; now they share one priming task (`primesOnce`).
- **No second load of a row.** A row that is queued or loading is not started again by 重試, 載入 or pull to refresh (`noDuplicateLoads`).
- **Tests:** `HomeModelTests` (10), `BookSourceProviderTests` (4), `LocalHomeRowTests` (4), `HomeModelSchedulingTests` (1): 19 tests in 4 suites passed.

### 5c-1: one navigation path (2026-10-11), before the home is drawn

No screen changed. Branch `unified-library/5c1-navigation`.

- **The `OPDSFeedRoute` clash (Phase 2 follow-up 1):** the route carries `presentation` (`.list` for the libraries' `OPDSFeedView`, `.storefront` for `PublicLibraryFeedView`). One `remoteLibraryDestinations()` registers the feed, WebDAV folder and book pages; the bookshelf's libraries and the storefront both use it.
- **Value links in the store:** `PublicLibraryRoute` (分類, a bundled list, an Aozora works list, an Aozora index) replaces every closure link on the storefront, in 分類 and in search's 顯示全部. `publicLibraryDestinations()` (renamed from `publicLibraryCarouselDestinations()`) registers them with the carousel's author and reader pages. The carousel ties each card to the path's depth, so pages pushed by closure added no depth.
- **Left as it was:** `AozoraIndexedList`'s rows (an author's works, a work's detail) still push by closure or by item. Its iOS 17 branch is a `UITableView` that has no path to append to. Card depth there is unchanged from today.
- **Explore's routes:** `ExploreHomeView`'s destination builder moved, unchanged, into `exploreRouteDestinations(openBrowser:)`, so the 5c home registers the same pages.
- **What a home item opens:** `ExploreItemTarget(ItemOpening, aozoraIndex:)` maps each frozen opening onto a page that already exists:
  - a copy → `PublicLibraryReaderRoute`, Explore's in-stack reader. The shelf's card transition belongs to the shelf's stack.
  - OPDS and WebDAV → `RemoteLibraryBookRoute`.
  - a book-source result → `ExploreNavigationRoute.book`.
  - Gutenberg and Aozora → the storefront's carousel.
- **Contract:** `ExploreMixedNavigationPathContract` pushed the removed `.search` route. It now pushes `.searchInSource` and mixes in a feed route; it compiles and passes with `swiftc` (command in the file).
- **Tests:**
  - Unit: `ExploreItemTargetTests` (7) with the Phase 5 regression units: 22 tests in 5 suites passed.
  - UI: `PublicLibraryStorefrontUITests` (4, one new: a card opened two pages deep pushes its author and backs out through the same pages), `PublicLibraryExploreUITests` (2) and `RemoteLibraryNavigationUITests` (1) passed. `PublicLibraryStorefrontUITests` also passed on iOS 17.5 (4 of 4), since every store page now goes through the path.
- **`DetailReaderBackSwipeUITests`** (fixture: `scripts/navigation_swipe_fixture.py prepare`, then `serve`):
  - **Fixed in the test:** every launch pins `-explore.mode sources`, because a public-library UI test run first leaves its own mode saved. The taps open the source's tile, then its book card (`openDiscoveredBook`). The fixture source and its book share the name "Navigation Swipe Fixture", and since Explore became tiles the first text with that name was the tile.
  - **On 5c-1, 13 of 23 pass,** among them every Explore → source page → detail → reader test. That is the moved `.source` and `.book` destinations working end to end.
  - **10 fail on main the same way.** Run at b85e7637 (5c-1's code removed) with the same test file, the same 10 failed at the same lines:
    - 806: 「Interior pan must turn the page」 (the four edge-back tests);
    - 634: the menu must go away when the page turns (the four turn tests);
    - 590: 「With the menu away, the tap turns the page」;
    - 703: after a relaunch, the shelf list shows no book labelled 「Navigation Swipe Fixture，Regression」 (`testShelfListExposesOneBookButtonAndOpensReader`).
  - Nine fail inside the reader, after navigation has succeeded; the tenth is the shelf list's label. All predate Phase 5 and are recorded here, not fixed in 5c.

### 5c-2: the home's cards and rows (2026-10-11), in a fixture only

Not drawn in the app yet: 5c-3 puts them on the new root. Branch `unified-library/5c2-cards`.

- **The card** (`HomeBookCard`, settled decision 11): a 2:3 cover 140 pt wide (scaled with Dynamic Type, at most 240 pt), the title in at most two lines, the author in one, and one Emby line: 已加入書架 or 已下載 for a library item, 已讀 n% or 已讀完 for a shelf copy. A part-read copy carries a progress bar along its cover. No card chrome. Cards align at the top and reserve no empty lines.
  - Not `PublicLibraryBookCard`: that card draws generated covers only, matched frame by frame to Apple Books' store; the home draws every source's covers. The store keeps its own card.
  - **Covers come from the views that already draw each kind:** a shelf copy from `BookshelfCoverArtwork` (預設封面 and 強制使用預設封面 hold, as on the shelf); an address from `BookCoverImage`, through the connection's signed-in session for OPDS and WebDAV; a file from the cover pipeline; none from `GeneratedBookCover`.
  - **A file cover goes through the pipeline,** as a new source `CoverImageSource.indexedCover(path:)` (the WebDAV index's `Caches/Works/covers`). Not as a `file://` URL into `BookCoverImage`, which would decode on the JS thread through `CoverDecodeService`. `.copyFile` now always holds an absolute path: `ShelfProvider` was handing it a bare filename. An absolute path is safe only because nothing stores it: `WorkSummary` and `CollectionEntry` are not `Codable`, and no stored type holds a `CoverReference`. If one ever does, store it relative, since the app's container path changes across installs.
  - **A shelf copy's line is the shelf's words** (`BookshelfAccessibility.readingStatus`): 新增 for a copy never opened, 已讀完 from 99%, otherwise 已讀 n%. The shelf's VoiceOver text now builds from the same function.
  - **Book-source items show no status:** `CopyLookup` leaves book-source copies out (its key needs `BookSourceStore`). A gap to close if the maintainer wants it.
  - **VoiceOver:** one element per card. A shelf copy reads exactly as the shelf reads it (`BookshelfAccessibility.description`); any other item reads its title, then author, source and status.
- **The row** (`HomeRowView`): the header names the row (the reader's title, else the binding's: 繼續閱讀, 「%@・最新」, a bundled list, an Aozora index) and its source underneath, unless the title already says it. A chevron and the 查看全部 hint appear when the row has a page to push. States: placeholder covers with a spinner while loading, 載入 for Gutenberg's on-demand rows, the error and 重試 when it fails, and nothing at all for a loaded empty row. An index's groups are capsule chips.
- **我的書庫** (`HomeLibraryTiles`): today's 探索 tiles, in the reader's grid, the list at accessibility sizes. A book source keeps its emoji; the other places have a symbol for their kind.
- **Strings:** 我的書庫, 「%@・最新」, 載入, 相關, as approved in Step 1.
- **Fixture:** `-explore-home-fixture` (DEBUG) shows every row state from bundled and made-up data, wearing the theme as `ContentView` would. Screenshots taken with `-debug-force-pro` and 山风 - 春水漾 imported: light, dark, and accessibility extra large.
- **Tests:**
  - `HomeCardTests` (5, new) and `CoverImagePipelineTests` (one new: an indexed cover is read from its absolute path), with `ExploreItemTargetTests`, `HomeModelTests` and `LocalHomeRowTests`: 45 tests in 5 suites passed.
  - The suites in `SourceProviderTests.swift`, and `BookshelfCoverArtworkTests`: 21 tests in 7 suites passed.
  - After the shared reading status, `HomeCardTests` with the §19 Phase 5 row (`ExploreModeTests`, `PublicLibraryAvailabilityTests`, `CustomExplorePageTests`, `ExploreNavigationAndMetadataTests`): 20 tests in 5 suites passed.
- **For 5c-3:** Step 2's 我的書庫 also lists shelf groups, custom pages, the browser and, after 5g, 訂閱. `HomeModel.Tile` is built from providers only, so the model cannot produce those tiles yet; 5c-3 adds them.

### 5c-4: 「相關」 and the one work index (2026-10-11)

Branch `unified-library/5c4-related`. Open decision 5 (cross-source too) and decision 6.

- **One owner, app-wide:** `BookStore.workIndex`, beside the stores the index is built from. Decision 6 says the home holds it, but 5f opens 作品詳情 from the bookshelf, and with 使用舊版探索頁 on the new home is never drawn. So the shelf's store holds it instead.
- **Refreshed when read, not on change.** Every reading-position save bumps `BookStore.mutationRevision`, so refreshing on a shelf change would rebuild on every page turn. A reader calls `WorkIndexService.current()`:
  - one refresh runs at a time; a caller arriving during it waits for it and one more run;
  - the first refresh waits until the book-source library is read;
  - a refresh dropped because the shelf changed mid-build is not retried. The last index stands, and the next caller refreshes, so the row can be one shelf change behind.
- **Series in the index:** each entry keeps a `seriesKey`, from the copy's sidecar or the WebDAV file's metadata, by `MetadataResolver`'s precedence (the reader's override and lock left out, as from the whole index). It never merges works. `WorkIndexFile` is now schema 3; an older file is discarded and rebuilt.
- **What 相關 shows** (`RelatedWorks.pick`), seeded by exactly the copies 繼續閱讀 shows and never repeating them:
  1. the seeds' works from elsewhere: another edition, or a WebDAV file of the same work. Not the file a seed was downloaded from.
  2. other works of a seed's series;
  3. other works by a seed's authors.
  Steps 2 and 3 show one card a work, a shelf copy before a file. A reading record taken off the shelf is never shown. Nothing opened, nothing shown, and the row is hidden.
- **"Across sources" means the shelf and the WebDAV index** in v1. OPDS, Gutenberg, Aozora and book-source items are not in the work index.
- **Not on any default page:** `HomePageDefaults` has no 相關 section, so this changes nothing on screen until a reader adds one (5d's editor). Adding it to the defaults is the maintainer's call.
- **One mapping of an indexed file:** `WebDAVProvider.item(for:root:connectionID:)`, shared by 「最新」 and 「相關」. Files come from the index's memory (`indexedFiles`), not read again.
- **Measured** (`RelatedRowTests.atScale`, simulator, Debug): 20,000 indexed files (a quarter with a series), 300 shelf copies, 20 opened.
  - First load, building the index from nothing (every reader's first launch with schema 3): 2,841 ms, off the main actor.
  - Next load (index current; the WebDAV files read again and compared): 307 ms.
  - The pick alone: 44 ms.
  - Longest main-actor stall during both loads: 17.6 ms.
- **Tests:** `RelatedWorksTests` (3) and `RelatedRowTests` (6), with `WorkIndexTests`, `WorkIndexServiceTests`, `WorkIndexRemoteRecordsTests`, `WebDAVFillIntegrationTests`, `WebDAVMetadataFillerTests`, `MetadataResolverTests`, `HomeModelTests`, `LocalHomeRowTests`, `ShelfProviderTests` and `HomeCardTests`: 72 tests in 12 suites passed.
- **For the maintainer:** whether 相關 grows from every 繼續閱讀 copy (as built) or only the latest one.

### 5c-3: the home is 探索's root (2026-10-11)

Branch `unified-library/5c3-root`. Steps 2, 3, 5 and 6 of Task 5c. Merged after the maintainer approved the look on a real build (2026-10-11: keep it), and chose no shelf or shelf-group tiles in 我的書庫 for now.

- **`ExploreHome`** is the root (`ExploreTabRoot`), behind the same 「source library read」 gate as before. One `NavigationStack` registers Explore's routes, the libraries' feed, folder and book pages, the store's pages, and the store's card carousel over all of it. Rows are `HomeRowView`s, tiles are `HomeLibraryTiles`.
- **Defaults, saved once** (`HomePageStore.pageOrDefaults`): the first read saves `HomePageDefaults` for the reader's effective mode. It runs from the row-building task, never while drawing, and only after the library is read, so a reader with sources is never saved with the new-install order. The region is taken as it stands; a public-library section saved before the storefront is known simply has no row in China, where its provider is hidden.
- **When rows are rebuilt:** the page, the custom pages, the connections, the explore sources, the region or the Aozora catalog changing. Rows read from this device (繼續閱讀, 相關) load again when the home comes back into view (`HomeModel.reloadLocal`), never on a shelf change.
- **我的書庫:** 瀏覽器, the custom pages, then each connection, Gutenberg, Aozora and each explore source. Browser and custom pages lead, as on the old root: with thousands of book sources they would otherwise sit below every one of them. Not the shelf: Explore has no page for it. Long-press keeps the old actions (rename or delete a custom page, Legado's source actions); ＋ 新增自訂頁 and the 分組 filter stay in the bar. The prompts are one modifier shared with the old root (`customExplorePagePrompts`).
- **The search field** stays: it narrows 我的書庫's book sources, as the old root's did (「搜索來源配置」). The design does not mention it; dropping it would take away the only way to find one of thousands of sources.
- **首屏配置** still opens its page on the home, as on the old root.
- **What opens where** (`ExplorePlace`, one mapping): a tile pushes its source's own page (discover page, root feed, root folder, `GutenbergHomePage`, `AozoraHomePage`); 範圍 shows the same page in place; 查看全部 pushes the whole of a row (a bundled list, the picked category, the feed, Aozora's 新着 or index); chips open their feed, folder or index group. No 查看全部 for 繼續閱讀, 相關 or a WebDAV 最新 (no page lists newest files across folders).
- **New store pages:** `GutenbergHomePage` (the storefront without Aozora, with 分類 in its bar) and `AozoraHomePage` (新着 and the three indexes). The old root's storefront is the same view (`PublicLibraryStorefront`), so there is one.
- **範圍** (`explore.scope`, a new key; `explore.mode` stays for the defaults and the old roots): a picker in a menu, 全部, then connections, Gutenberg and Aozora (not in China), and the explore sources in a 來源配置 submenu. One source's page shows at the root with the tab bar; changing scope clears the stack. A stored scope whose source is gone reads as 全部. **Not measured at scale:** a menu holding thousands of sources.
- **使用舊版探索頁** (`explore.classicRoot`) in 探索設定 brings back the old roots. The old 公有書庫 root had no gear, so it gained one: without it a reader could not switch back. 探索設定 is the page's sheet, so it closes as the switch replaces the page.
- **DEBUG launch arguments:** `-reset-explore-home` (no saved home, 全部, the home) and `-debug-storefront-country CHN` (poses as a storefront instead of reading the App Store's).
- **Shelf groups have no tiles yet.** Their page lives inside the shelf (`HomeView`'s pager and folder page, tied to its selection and edit mode); nothing outside the shelf can open one. Asked of the maintainer, not invented.
- **Tests:**
  - Unit: `ExploreHomeTests` (7: defaults per reader and saved once, China, scope encoding and availability, tile pages, 查看全部, chips), `HomeModelTests` (+1 `reloadLocal`; the tile test now covers browser, custom pages and no shelf), with `HomeCardTests`, `ExploreItemTargetTests`, `ExploreModeTests`, `CustomExplorePageTests`, `PublicLibraryAvailabilityTests`, `ExploreNavigationAndMetadataTests`: 45 tests in 8 suites passed.
  - UI `ExploreHomeUITests` (6, new): default sections on a new install; scope to Gutenberg and Aozora in place, kept across a relaunch, back to 全部; Gutenberg and Aozora tiles push their pages; a connection added in 設定 has a tile that pushes its library; China shows no public library in the home or 範圍; 使用舊版探索頁 on and off. All passed.
  - Updated, not deleted: `PublicLibraryStorefrontUITests` (4) now opens cards from the home's 精選 row and the store's pages from the Gutenberg tile; `PublicLibraryExploreUITests` (2) pins `-explore.classicRoot YES`, since the mode switch and its tip belong to the old roots; with `RemoteLibraryNavigationUITests` (1), 7 passed. `DetailReaderBackSwipeUITests` finds a source by its 我的書庫 tile. Its 23 tests: 13 passed and the same 10 failed as on main (edge back ×4, turn hides menu ×4, menu-up tap, shelf list label), each at the same assertion. Two more failed at first and passed when re-run, neither caused by 5c-3: one test still looked for the old root's tile (fixed), and one launch had restored a custom appearance theme's tab set over the test's (the simulator had been left on a theme pack).
  - `testConnectionTilePushesItsLibrary` now asserts its cleanup: a run that failed before it had left a connection behind on the simulator.

### 5c-4b: 「相關」 from one seed (2026-10-11)

Branch `unified-library/5c4b-related-seed`. The maintainer chose one seed: the copy opened most recently, 繼續閱讀's first card. The row is then about one book.

- `RelatedWorks.pick(in:seed:continueReading:shown:limit:)`: the evidence (the work elsewhere, its series, its authors) is the seed's alone. Every copy 繼續閱讀 shows is still left out, as a whole work, so the two rows never repeat each other.
- **Tests:** `RelatedWorksTests` +1 (`latestCopyOnly`: an older 繼續閱讀 copy's author brings nothing). The scale fixture now has 1,000 authors of 20 files each, not 2,000 of 10: with one seed, 10 files could not fill a row. With `RelatedRowTests` and `HomeModelTests`, 21 tests in 3 suites passed.
- **Measured** (same test, simulator, Debug): first load 2,882 ms, next 316 ms, the pick 42 ms, longest main-actor stall 21.7 ms. That is level with 5c-4's 2,841, 307, 44 and 17.6 ms: the time is in building and reading the index, not in picking.

### 5c-5: the bookshelf ＋ keeps its books, not the libraries (2026-10-11)

Branch `unified-library/5c5-entries`. Step 7 of Task 5c (settled decision 3). Two things lived only behind the removed entries; the maintainer chose where they go.

- **＋ (添加書籍)** is 從本地匯入 and 電腦傳書. Both put a book on the shelf. 電腦傳書 (`CalibreWirelessView`) needs no server, so it stays here, now a sheet in its own stack with a leading close. The iOS 17 chooser lists the same two.
- **OPDS's 範例目錄** moved to 設定 → 遠端書庫, a section under OPDS. It is shown while an example is not yet added. It still adds an ordinary connection with no region check (Phase 2 findings, item 2, still open).
- **Removed:** `WebDAVImportView`, `OPDSImportView`, `RemoteLibraryBrowserView` (the per-kind sheets), and their two strings 「尚未加入書庫」「加入伺服器即可瀏覽書籍並開始閱讀。」. A library is browsed from 我的書庫 and set up in 設定 → 遠端書庫. `OPDSFeedView` and `WebDAVDirectoryView`, which those tiles push, stay.
- **Tests (UI):**
  - `RemoteLibraryNavigationUITests` now checks ＋: 從本地匯入 and 電腦傳書 only; 電腦傳書 opens its receiver and closes.
  - `RemoteLibrarySettingsUITests` +1: an example becomes a connection, leaves the list, and returns when removed.
  - With `testAddEditAndDeleteFromSettings` and `ExploreHomeUITests.testConnectionTilePushesItsLibrary`: 4 passed, and the opt-in WebDAV benchmark was skipped.

### 5d-1: the libraries are in 範圍 (2026-10-11)

Branch `unified-library/5d1-scope-entries`. Settled decision 12.

- **The home** draws its sections only: 我的書庫 is skipped wherever a saved page has it (the section is kept, so an older build still shows it), and the defaults no longer add it. `HomeModel` publishes `rows`; `Tile`/`Item` and `HomeLibraryTiles` are gone (`SourceKindSymbol` stays, for 範圍).
- **範圍** lists 全部, the connections and the two public libraries, a 來源配置 submenu, then a 自訂頁 submenu and 瀏覽器. Choosing a library or source shows its page in place, as 5c-3's sources did. 瀏覽器 can be turned off in 探索設定 (`explore.showsBrowser`; moves to 編輯首頁 with decision 13).
- **The home's bar on 全部:** 範圍, ＋ 新增自訂頁, 探索設定. The search field, the groups menu and the source long-press actions left with the tiles. Those actions still live in 設定 → 管理來源配置.
- **A custom page** has a ⋯ menu (重新命名, 刪除, as on the classic root's long press), and closes when it is deleted.
- **An empty home** (every row loaded and empty: a China storefront with no source and nothing read) says 「探索還沒有內容」 and points to 範圍.
- **Strings:** +3 (在範圍選單顯示瀏覽器, 探索還沒有內容, 從右上角的範圍打開書庫或來源配置。), −1 (我的書庫).
- **Tests (unit):** `HomeModelTests` (tiles test replaced by `unservedHaveNoRow`), `HomeSectionTests` and `ExploreHomeTests` defaults without 我的書庫; with `HomePageStoreTests`, `HomeCardTests`, `CustomExplorePageTests` and `ExploreItemTargetTests`: 49 tests in 7 suites passed.
- **Tests (UI):**
  - `ExploreHomeUITests` (6): `testScopeOpensCustomPagesAndTheBrowser` is new (a page made with ＋ opens from 自訂頁 and deletes itself from its ⋯; the browser opens and closes; 探索設定 hides it). `testConnectionIsInScope` replaces the tile test. A menu item does not carry its identifier into the accessibility tree, so 瀏覽器 is found by its label.
  - The China test accepts 繼續閱讀 or the empty state: the shelf is the simulator's own, and here it held a fixture book.
  - `PublicLibraryStorefrontUITests` (4) enters Gutenberg from 範圍 and leaves it on 全部; `RemoteLibraryNavigationUITests` (1). All 11 passed, three of them on a second run after the fixes above.
  - `DetailReaderBackSwipeUITests` reaches a source through 範圍 → 來源配置. Its two 「search」 tests searched Explore's source tiles, which are gone; they now search from the 搜索 tab (`openSearchedBook`). Of the tests that go through 範圍 or search, run on this simulator:
    - **Passed (7):** `testClassicReaderControlsFromExploreAreAccessible`, `testListeningStartsCapsuleAndRolePanelRemainsAvailable`, `testScrollEdgeBack`, `testScrollHidesMenu`, `testShelfMangaOpensOnThePage`, `testWebtoonStripZoomsAndPansSideways`, `testSearchDetailReaderLoadsAndReturns`.
    - **The two known failures from 5c-1** (`testTapWithMenuUpOnlyPutsMenuAway`, `testShelfListExposesOneBookButtonAndOpensReader`), at the same assertions (lines moved by the new helper).
    - **Both manga reader tests** (`testDetailMangaReaderLoadsAndReturns`, `testSearchDetailMangaReaderLoadsAndReturns`) reach the reader, then fail on 「Page 1 / 3」: the reader opens on Page 2 / 3. The fixture manga is on this simulator's shelf with its last page saved (`testShelfMangaOpensOnThePage` adds it), so both routes resume there. Not caused by 5d-1; the test does not reset the book's progress.
- **Not done, disclosed:** 範圍 has no search, which a library of thousands of sources will need; the RSS 「訂閱」 tile (5g) needs re-planning.

### 5d-1b: no global 探索 settings, and the libraries are searched from 搜索 (2026-10-11)

Branch `unified-library/5d1b-remove-explore-settings`. Settled decisions 13 and 17.

- **Search first (decision 17, as amended).** On the 搜索 tab's root, once there is a query, the results are the sources' part and then a 公有書庫 section. The section is `PublicLibrarySearchResults`, the old root's, reshaped into one section: 「在 Project Gutenberg 搜尋」, then 青空文庫's matches as the query changes (50, then 顯示全部 on iOS 18+).
  - **The sources' part** says 搜索中…, 已暫停 or 沒有找到 in a row while it has no result.
  - **Keyboard Search:** it searches the sources; with none, it asks Gutenberg, but only once the source library is read, so a large library is never taken for none.
  - **Navigation:** Gutenberg's results are a `SearchPagePush` case, so the page keeps its one item destination (postmortem guardrail 12). The tab is `SearchTabRoot`: a `NavigationPath` stack carrying the store's destinations and its book carousel.
  - **The carousel's action** is read by `PublicLibrarySearchSection` and `IOS17SearchResults`, never by `BookSearchView` (new guardrail 13).
  - **iOS 17** keeps every row native: `IOS17SearchResultTableContent` carries the section as values (`IOS17SearchLibrarySection`), and the table gains a second section with titled headers. It has no 顯示全部.
  - **Not offered:** a pushed `SearchView` and the China storefront show no section, as before.
  - **First try, dropped:** native search scopes. On iOS 27 they appeared only with `activation: .onSearchPresentation`, and the maintainer rejected them on sight.
- **Deleted:**
  - 探索設定 (`ExploreSettingsSheet`) and its gear on the home;
  - the old roots: `ExploreHomeView`, `PublicLibraryHomeView`, 使用舊版探索頁, the mode menu, its first-import tip, `ExploreImportDetector`, and the app's TipKit setup, which no other tip used;
  - every global presentation setting:
    - 列表/雜誌 and `DiscoverListLayoutView`;
    - the chart keywords (now the constant `ExploreSettings.rankedKeywords`);
    - 豎排／橫滑展示數 (4 and the whole first page, the old defaults);
    - 預加載 (0, the old default, so the queue code went);
    - 格狀 and 每列欄數 (with `ExploreTile`'s grid, list and their tokens; `ExploreTileButtonStyle` stays);
    - 首屏頁面;
    - 封面並發數 (`CoverDownloadGate`).
- **Kept:** `explore.mode`, read once for the home's default sections. `ExploreTabModel` is down to `isLoaded`/`hasSources`.
- **首屏 migration:** `ExploreSettings.migrateLegacyLanding` runs once the library is read and before the home draws. A saved source becomes 範圍 only when no 範圍 was picked and the source still exists. A saved custom page stays saved for 5d-4's configurations, and no longer opens at launch until then; deleting that page clears it. Anything else is dropped.
- **瀏覽器's 隱藏** has no switch until 編輯首頁 (5d-2); `explore.showsBrowser` keeps working.
- **Strings:** −31 in each language (探索設定's, the tip's, the old root's search prompt, 已啟用 %d 個來源配置).
- **Docs:** `CLAUDE.md`, `docs/design.md`, both `SKILL.md` copies and `AGENTS.md` list `ExploreHome` as 探索's only root. `docs/design.md`'s Discover row and `Technotes/PublicLibraries.md` describe 範圍 and the 搜索 scope.
- **Tests (unit):**
  - `ExploreSettingsTests` gains `legacyLandingMigrates`, and loses the keyword, landing and cover-gate tests.
  - `ExploreHomeLogicTests` becomes `ExploreSourceFilterTests`.
  - `ExploreModeTests` loses the import-detector and menu tests.
  - Run with `HomeModelTests`, `ExploreHomeTests`, `CustomExplorePageTests`, `CustomExplorePageModelTests`, `DiscoverViewModelReloadTests`, `BookCoverLoaderHeaderTests`, `IOS17SearchResultTableTests`, `PublicLibraryStorefrontTests` and `SearchRecentsTests`: 79 of 80 passed. The failure is `SearchRecentsTests` 「English counts one source in the singular」, which got "1 sources". This branch touches neither that key, its `.stringsdict`, nor `localized()`.
- **Tests (UI):**
  - iOS 27 (iPhone 18 Pro), before the combined search: `ExploreHomeUITests` 5 of 5, `PublicLibraryStorefrontUITests` 4 of 4 and `BookSourceManagementUITests`' validation test passed.
  - iOS 27, after the combined search: `PublicLibrarySearchTabUITests`, `DetailReaderBackSwipeUITests/testSearchTabMangaResultOpensEveryTime` and `testSearchDetailReaderLoadsAndReturns` passed. The unit rerun (`IOS17SearchResultTableTests`, `SearchRecentsTests`, `PublicLibraryStorefrontTests`) ran 35 tests with the same one failure as above.
  - iOS 17.5 (iPhone 15 Pro), after the combined search: `PublicLibrarySearchTabUITests` (through `IOS17SearchResultTable`) and `testSearchTabMangaResultOpensEveryTime` passed. The 17.5 simulator needs `python3 scripts/navigation_swipe_fixture.py prepare --simulator <UDID>` first; without the fixture sources the manga test finds 「沒有找到…」 and fails.
  - The English-plural failure is the simulator's region: both simulators run `zh_TW`, and `.stringsdict` picks plural rules by locale, which have no "one" for Chinese. Not this branch.

### 5d-1c: Gutenberg loads with 探索 and shows its own covers (2026-10-11)

Branch `unified-library/5d1c-gutenberg-covers`. Settled decision 15.

- **Loading.** `SectionLoadPolicy.onDemandOnly` becomes `.withHome`: Gutenberg's feed rows (最新 and any `gutenbergFeed`) start in parallel as soon as the home shows, from `HomeModel.homeAppeared()`, also the rows below the fold whose views the `LazyVStack` has not made. Every other row still waits for its view. Nothing before 探索 opens, no next pages.
  - **Deleted:** `RowState.awaitingRequest`, the row's 載入 button (`home.row.load.`) and the 「載入」 string in five languages, which nothing else used.
  - **Scope:** the trigger is the home's own view, so a Gutenberg row sends nothing while 範圍 shows one source's page.
- **Covers.** The XML list feeds' 「thumbnails」 are 17×29 and 22×22 book glyphs, not covers, which is why the cards looked coverless. Each book's cover is `cache/epub/<N>/pg<N>.cover.medium.jpg`, the image its own book feed links; it is derived from the ebook number (`GutenbergBook.coverURL`), not fetched per book, which would be a feed request per card. Checked 2026-10-11: the three newest releases already had theirs (HTTP 200).
  - **One URL, one session, one cache entry everywhere:** the home's cards (bundled lists through `CollectionEntry.bundledGutenberg`, feeds through `PublicLibrary.listCoverURL`, now used by `OPDSFeedProviding.page`), the store's covers (`PublicLibraryCoverArtwork`, inside `PublicLibraryCover`), the carousel's overlay, both detail heroes, and the OPDS list rows. They load through the built-in connection's session, as a shelf copy's cover does (`BookCoverLoader.remoteSession(for:)`), and the copy's `coverUrl` is that same medium URL, so a book added to the shelf keeps its cover.
  - **No flash in the carousel:** `BookCoverImage` reads the memory cache in its initializer, so the overlay that the carousel makes mid-animation paints the loaded cover on its first pass.
  - **Without a number** (no Gutenberg id), a book keeps its generated cover; 青空文庫 has no covers and keeps them all.
  - **Decision 7 in practice:** 精選's lists still send no request for their data, but their covers now load from gutenberg.org as the cards show. Decision 19 (lists show thumbnails only) is replaced; `PublicLibraryRegistryTests` now states the new rule.
- **Docs:** `Technotes/PublicLibraries.md` drops 「開啟首頁不請求 Gutenberg」 and the thumbnails rule; its 2026-10-07 network measurement is marked as taken before this step.
- **Tests (unit):** `HomeModelTests` (`withHome` replaces the on-demand test; the Gutenberg test now checks the bundled lists' covers and that the feeds load on `homeAppeared`), `PublicLibraryRegistryTests` (the decision 19 test rewritten to decision 15, plus `gutenbergCoverComesFromTheEbookNumber`), `ExploreHomeTests`, `PublicLibraryStorefrontTests` and `OPDSProviderTests`: 39 of 39 passed. `SourceProviderTests` and `OPDSBrowseModelBehaviorTests`: 5 of 5.
- **Tests (UI), iOS 27 (iPhone 18 Pro):**
  - `ExploreHomeUITests` 6 of 6, including the new `testGutenbergLatestLoadsWithTheHome` (最新 appears with no 載入 to tap). Its feeds now answer from fixtures; covers still load from gutenberg.org as cards show.
  - `PublicLibrarySearchTabUITests` passed.
  - `PublicLibraryStorefrontUITests`: 3 passed in the batch. `testPullDownClosesRestingCard` failed there because the simulator was touched during the run (the maintainer, 2026-10-11), and passed when run again on its own.

### 5d-2: 編輯首頁 (2026-10-11)

Branch `unified-library/5d2-edit-home`. Settled decisions 13, 14 and 18.

- **The edits** are `HomePage` methods (`HomePageEditing.swift`), made through `HomePageStore.edit`, so the home builds its rows again from the saved page. Editing in place, a section's page and the long press use the same ones.
  - **Edited:** the sections a home draws. 我的書庫 (not drawn since 5d-1) and a later build's sections are not shown; reordering moves the shown ones among the places they held, so the others keep theirs.
  - **Hidden** keeps the section, its place and its settings; **deleted** drops it, after a confirmation.
  - **排除的來源** lists the sources that serve 最新 (`HomeModel.latestSources`), checked when excluded. A source excluded and since removed stays excluded, unseen.
- **編輯首頁, in place** (`HomeEditingSections` in `HomeEditor.swift`), from the button at the end of the home:
  - every section, hidden ones too, is a card holding its rows, with a check mark beside it (VoiceOver: the section's name, 顯示 or 已隱藏);
  - a card is dragged onto another to take its place (`draggable`/`dropDestination`); VoiceOver has 上移 and 下移 instead;
  - a tap opens the section's page; the rows inside a card do not take taps;
  - the last card is 範圍's, with the browser's switch (`explore.showsBrowser`), the 隱藏 decision 13 moved here;
  - 完成 sits in the bar (in place of 範圍 and ＋) and at the end; the empty-home message is not shown while editing.
  - **First try, replaced the same day:** a pushed list page with 編輯 to reorder; the maintainer asked for Rex's in-place editor instead.
- **Long press:** a row's name offers 隱藏, 設定 and 刪除. On 最新's rows, one per source, they act on the whole 最新 section; excluding one source is on its page.
- **Strings (5 languages):** 編輯首頁, 在首頁顯示, 排除的來源, 已隱藏, 上移, 下移. Reused: 完成, 顯示, 隱藏, 設定, 刪除, 取消, 範圍, 瀏覽器, 最新, 刪除「%@」？.
- **Not yet:** 新增欄目 and its ＋ (5d-5), so a deleted default section cannot be added back until then; 呈現方式 in the long press (5d-3).
- **Tests (unit):** `HomePageEditingTests`, `HomeSectionTests`, `HomePageStoreTests`, `HomeModelTests`, `ExploreHomeTests` — 37/37 passed (iOS 27).
- **Tests (UI):** `HomeEditorUITests` 2/2 on iOS 27 and iOS 17.5 (the long press's 刪除 → confirmation included); `ExploreHomeUITests` 6/6 on iOS 27. On iOS 27 the minimized bar hides its 完成 while the home is scrolled to the bottom, so the test checks the home's own 完成 there and the bar's after scrolling back up.

### 5d-3: the five layouts (2026-10-11)

Branch `unified-library/5d3-layouts`. From the maintainer's layout notes (decision 14), with their names: 大型閱讀卡片, 橫向單排書架, 多行橫向輪播, 固定封面網格, 圖文資訊清單.

- **Stored as layout strings,** with no new field and no schema bump: `readingCard`, `row` (5c's row, unchanged), `multiRow`, `coverGrid`, `list` and `rankedList` (the list with ranks). `HomeSectionLayout.style` reads any stored layout as one of the five. A custom page's seven kinds map as decision 14 says, so 5d-4 reuses it. 磚塊 and a later build's layout draw as a row and are kept as they are.
- **The app decides what is drawn:** at accessibility text sizes 多行橫向輪播 draws one row, and 大型閱讀卡片 and the list put their text under the cover.
- **The layouts** (`HomeSectionCards`):
  - 大型閱讀卡片 is a large cover beside the title, author, blurb or status, and the progress bar. One card fits a phone, two a regular width, and the next card shows past the edge.
  - 多行橫向輪播 is two rows of 100 pt covers that swipe sideways together.
  - 固定封面網格 has as many columns as fit at 100 pt, never fewer than two.
  - 圖文資訊清單 is a 60 pt cover beside the title, author, blurb and status, with the custom pages' rank badge when ranked.
  - The grid shows three rows and the list five when the section has 查看全部; without it they show everything, since nothing else would.
  - A loading section draws its own layout with blank cards.
  - Every card keeps its `home.card.*` identifier, its VoiceOver label (a ranked list reads the rank first) and the carousel's cover anchor.
- **呈現方式** sits in the section name's long press: the five layouts as a picker, and 顯示排名 when the list is chosen. It is written through `HomePageStore.edit` (`setLayout`).
- **繼續閱讀 defaults to 大型閱讀卡片.** A home saved before this keeps the 橫向單排書架 it was saved with.
- **Fixed on the way, also a 5d-2 bug:** a sync made a row whose section changed in any way idle, and nothing loaded it again, because its view's `.task` had already run. A new layout left the row as blank cards for good, and so did 排除的來源 for 最新's other rows. Now a row whose content is unchanged keeps what it loaded and takes the new layout or title (`HomeSection.loadsSameContent`). A row whose content changed under the same id loads again by itself if it had loaded.
- **Strings:** 呈現方式, 大型閱讀卡片, 橫向單排書架, 多行橫向輪播, 固定封面網格, 圖文資訊清單, 顯示排名, in five languages.
- **Tests (unit):** `HomeLayoutStyleTests` (new, 6), with three new `HomeModelTests` (a layout keeps content, an exclusion keeps the other rows, changed content reloads). `syncKeepsRows` no longer expects a new title to rebuild the row. With `HomePageEditingTests`, `HomeSectionTests`, `HomePageStoreTests`, `HomeCardTests` and `ExploreHomeTests`: 51/51 passed (iOS 27).
- **Tests (UI):** `HomeEditorUITests` 3/3 (new: `testLongPressChangesTheLayout`) on iOS 27 and iOS 17.5; `ExploreHomeUITests` 6/6 on iOS 27. The fixture (`-explore-home-fixture`, now a list in each layout) was checked on iOS 27 afterwards: stacked cards reserve their room below the text, not between title and author.

### 5d-3b: one home, filtered by 範圍 (2026-10-11)

Branch `unified-library/5d3b-aggregate`. Decisions 19 and 20.

- **The home draws one group per section** (`HomeSectionGroup`). 最新's rows, one per source so each loads on its own terms, draw as one row titled 最新: their books take turns in provider order, since no source gives dates. The group shows books as soon as one row has some; else it loads while any row is still to load; else it shows the first failure, and 重試 asks every failed row again; else it takes no room. A failed row beside one with books is not shown (the model logs it). `%@・最新` is gone.
- **The home names no source.** The source line under a row's title and the source in a card's VoiceOver value are gone; the work page still names it.
- **範圍 filters the same home** (`HomeScopeFilter`): sections, order and layouts are unchanged. A source's own rows stay; the shelf's rows (繼續閱讀, 相關) keep the copies whose current source is the chosen one (`SourceRecord.derived(from:)`'s key) and drop groups; every other row goes, and an empty section takes no room. `homeAppeared(in:)` loads only the rows 範圍 keeps, so choosing 青空文庫 sends nothing to Gutenberg. 範圍 no longer replaces the home with the source's page.
- **The full catalog is always at the top** (`HomeCatalogEntry`), whatever the sections hold: under 全部, 瀏覽書庫 lists the remote libraries, the public libraries and the book sources, each opening its existing page (`ExplorePlace.page(of:)`); under one library, 瀏覽完整目錄 opens that page. No second catalog: Gutenberg's popular/latest/categories, 青空's indexes, a book source's discover page and an OPDS/WebDAV root are the pages 範圍 used to show.
- **查看全部** stays for a section of one row; 最新 under 全部 has none, since its books come from several pages.
- **Known gap:** a 青空 copy without a catalog work id keeps its copy key, so it is not under the 青空文庫 scope.
- **Strings:** 瀏覽書庫, 瀏覽完整目錄, in five languages.
- **Tests (unit):** `HomeSectionGroupTests` (new, 3: 最新 is one section in turns, the merged state, the scope filter) and `HomeModelTests.homeAppearedFollowsScope`; `HomeCardTests` titles go through the groups. With the other home suites: 55/55 passed (iOS 27).
- **Tests (UI):** `ExploreHomeUITests.testScopeFiltersTheHomeAndBack` replaces `testScopeShowsOneSourceInPlaceAndBack` (瀏覽書庫 lists the libraries; Gutenberg keeps the home with 瀏覽完整目錄 on top, which opens Gutenberg's page; the scope survives a relaunch; 青空文庫 drops Gutenberg's books; 全部 brings them back), and `testConnectionIsInScope` opens the connection from 瀏覽完整目錄. iOS 27: `ExploreHomeUITests` 6/6 and `HomeEditorUITests` 3/3. iOS 17.5: the scope test and `HomeEditorUITests` 3/3.

### 5d-3c: 精簡閱讀卡片 (2026-10-11)

Branch `unified-library/5d3c-compact-card`. Decision 20, from the maintainer's Apple Books 「繼續」 screenshot.

- **A sixth layout, 精簡閱讀卡片** (`compactReadingCard`, a layout string like the others): a 64 pt cover beside the title, author and 「書籍・已讀 42%」 (漫畫, 有聲書 by the copy's kind), sized and swiped like 大型閱讀卡片. At accessibility text sizes the text goes under the cover.
- **繼續閱讀 defaults to it on a new home;** 大型閱讀卡片 stays a choice. A saved home keeps the layout it was saved with.
- **The card is the cover's colour.** The cover views (`BookCoverImage`, `BookshelfCoverArtwork`, `GeneratedBookCover`, the home's file cover) report the image they draw to a `coverImageObserver` when one is set, so the colour is the cover on screen, with no second load. `CoverTint` averages it (the audiobook player's average, moved there and shared) and darkens it only as far as white text needs: 4.5:1, 7:1 with 增加對比. All the card's text is white; until the cover draws, a dark neutral ground.
- **••• on a shelf copy:** 從繼續閱讀移除 (in 繼續閱讀 only) and 標記為已讀完 (unless finished). The ••• sits beside the card's button, not in it, labelled 更多; the same items are the card's VoiceOver actions. A store book has none.
  - 從繼續閱讀移除 writes `ReadingBook.continueReadingHiddenAt` (optional, encoded only when set, so untouched books keep their sync hash). 繼續閱讀 leaves the book out until it is opened again (`isInContinueReading`); the shelf, its 最近閱讀 order and the progress are untouched.
  - 標記為已讀完 writes progress 1 (已讀完 wherever progress shows) and takes the book out of 繼續閱讀, as Apple Books does. The reader keeps its own position: opening the book resumes where it was, and its next save writes the real progress back.
  - The shelf's rows load again at once, so the card leaves.
- **Open question for the maintainer:** a book read to the end by itself stays in 繼續閱讀, as before; Apple Books drops finished books.
- **Strings:** 精簡閱讀卡片, 書籍, 從繼續閱讀移除, 標記為已讀完, in five languages.
- **Tests (unit):** `HomeCompactReadingCardTests` (new, 5: the ground's contrast, the menu's items and line, 移除 until reopened, 標記為已讀完, the field absent when unset); `HomeLayoutStyleTests.defaults` now expects 精簡閱讀卡片. With the home suites, `LocalHomeRowTests` and `AudiobookSettingsStorageTests`: 66/66 passed (iOS 27).
- **Tests (UI):** `ExploreHomeUITests.testCompactCardMenu` (new, in the design fixture: ••• is its own hittable control labelled 更多 and offers both items). iOS 27: `ExploreHomeUITests` 7/7, `HomeEditorUITests` 3/3. iOS 17.5: `testCompactCardMenu`, `testNewInstallShowsTheDefaultSections`, `HomeEditorUITests` 3/3. The fixture's card was checked on screen: a pale generated cover gives (115, 119, 123).

### 5d-3d: 聚合設定 and 偏好閱讀語言 (2026-10-11)

Branch `unified-library/5d3d-aggregation-settings`. Decision 21: Emby's aggregation settings (emby.media "User Preferences: Home Screen"; dev.emby.media `UserConfiguration`) mapped onto Yuedu's libraries. This step is the page and the language; 書庫順序, 顯示在最新 and 隱藏已讀 follow as 5d-3e to 5d-3g.

- **設定 → 來源配置管理 → 聚合設定**, after 遠端書庫; pushed, `.inline`. The only entry.
- **偏好閱讀語言:** several languages in order, starting as the interface language alone. Rows are reordered by dragging (VoiceOver: 上移／下移, and each row reads 「第 N 優先」), removed by swiping (not the last), and 新增語言 pushes the offered languages (zh, en, ja, ko, fr, de, es, it, pt, ru, nl, la), each named in itself.
- **推薦範圍:** 優先推薦偏好語言 (default), 只推薦偏好語言, 不限制語言.
- **What it does to the home:** within each section, after 最新's round-robin merge, books of the preferred languages come first in the list's order, then books of unknown language, then the rest; the source's own order holds within each. Under 只推薦 the books known to be in another language leave; unknown ones stay. Section order is unchanged, and 繼續閱讀 keeps its recency. A section left with nothing takes no room.
- **Gutenberg's categories** follow the list: 熱門, 最新, then a shelf per reading language in order, then English if absent, titled with the language's own name. This replaces the interface-language rule.
- **Languages known:** Gutenberg books carry `dcterms:language` into the record and summary; every bundled list book is tagged (checked against its Gutenberg page). Gutenberg's 最新 navigation entries and most book sources and OPDS feeds say none, so they count as unknown.
- **Stored on this device** (`yd_aggregation_settings`, one JSON value, nothing written until the reader changes something; an unreadable value is logged and read as the defaults). Not synced through iCloud. `-reset-explore-home` clears it.
- **Strings:** 聚合設定, 偏好閱讀語言, 新增語言, 推薦範圍, the three scopes, two footers, 第 %d 優先, in five languages.
- **Tests (unit):** `ReadingLanguagesTests` (new, 6: the initial value, 優先's order, 只推薦 and 不限制, sections ordered after 最新's turns with 繼續閱讀 untouched, the bundled books' languages, the store); `PublicLibraryRegistryTests.shelvesFollowReadingLanguages` replaces the interface-language test. With the home suites: 69/69 passed (iOS 27).
- **Tests (UI):** `AggregationSettingsUITests.testReadingLanguages` (new: a fresh install shows 中文 第 1 優先 and 優先推薦; adds 日本語, drags it first, picks 只推薦, and a relaunch reads both back). iOS 27: it, `ExploreHomeUITests` 7/7, `HomeEditorUITests` 3/3. iOS 17.5: it and `testScopeFiltersTheHomeAndBack`.

### 5d-3e: 書庫順序 (2026-10-11)

Branch `unified-library/5d3e-library-order`. Decision 21's `OrderedViews`.

- **聚合設定 → 書庫順序:** the libraries there are now (saved connections, then Gutenberg and 青空文庫 where offered), reordered by dragging; VoiceOver reads 「第 N 個」 and offers 上移／下移. Hidden with fewer than two libraries. Book sources are not listed: they keep 來源配置's own order, after the libraries (the footer says so).
- **One order, three places** (`LibraryOrder.arrange`, `LibraryListing.ordered`):
  - 範圍's library picker;
  - 瀏覽書庫: the libraries are now **one section, 「書庫」**, so a public library can go before a remote one. It replaces the 遠端書庫 and 公有書庫 sections. Book sources stay their own section. (The maintainer may prefer the two sections kept, each ordered within itself.)
  - 最新's turns: `HomeScopeFilter.groups` orders a section's rows when it draws them. The shelf's row stays first and book sources' rows after. The providers and rows are untouched, so changing the order reloads nothing.
- **Stored** in `AggregationSettings.libraryOrder` (optional; nil until the reader moves one, and settings saved by 5d-3d read as nil). A library added since follows the ordered ones; one removed, or Gutenberg in China, is passed over.
- **Strings:** 書庫, 書庫順序, 第 %d 個, the footer, in five languages.
- **Tests (unit):** `LibraryOrderTests` (new, 5: the default order and China, the reader's order with one added and one gone, the shelf and book sources keeping their places, 最新's turns, old settings decoding and the store). With the home suites, `ReadingLanguagesTests` and `PublicLibraryRegistryTests`: 54/54 in 9 suites (iOS 27).
- **Tests (UI):** `AggregationSettingsUITests.testLibraryOrder` (new: drags 青空文庫 above Gutenberg, then checks 瀏覽書庫 and 範圍 list it first). iOS 27: `AggregationSettingsUITests` 2/2, `ExploreHomeUITests` 7/7, `HomeEditorUITests` 3/3. iOS 17.5: `AggregationSettingsUITests` 2/2, `testScopeFiltersTheHomeAndBack`.

### 5d-3f: 顯示在最新 (2026-10-11)

Branch `unified-library/5d3f-show-in-latest`. Decision 21's `LatestItemsExcludes`, which replaces 最新's 排除的來源: one place, not two.

- **聚合設定 → 顯示在最新:** a switch per library, in 書庫順序 (saved connections, Gutenberg, 青空文庫). Off: that library gets no 最新 row and is not asked for one. The home builds its rows again when a switch changes (`HomeModel.sync(with:hiddenFromLatest:)`).
- **The 最新 section no longer has a list of its own.** `HomeSectionBinding.latest` has no `excluded` value, and the section's page in 編輯首頁 loses 排除的來源; the string is gone from the five tables.
- **Moving the old list:** `HomePageStore` reads a pre-5d-3f file's `excluded` once (`legacyLatestExcluded`); `AggregationSettingsStore.shared` adopts its libraries as 顯示在最新 off, only while that was never set, and logs it. The file drops the list the next time it is saved; an older build reads such a file as nothing excluded.
- **Book sources** are not listed: one serves 最新 only through the category picked for it in the section (`latestCategory`, which 5d-5's form will offer), so a book source in an old list is not moved.
- **Not covered:** a WebDAV connection has a switch but no 最新 row until its books are indexed, as before.
- **Tests (unit):** `ShowInLatestTests` (new, 3: an old home file reads, hands its list over and loses it once saved; the libraries move once and never over the reader's choice; the switch is saved). `HomeModelTests` now hide sources through `sync(hiddenFromLatest:)`; the 排除的來源 editing test is gone. With the home suites: 71/71 in 13 suites (iOS 27).
- **Tests (UI):** `ExploreHomeUITests.testShowInLatestOff` (new: Gutenberg off in 聚合設定, then its fixture book is not on the home; `testGutenbergLatestLoadsWithTheHome` shows the same scroll finds it when on). iOS 27: `AggregationSettingsUITests` 2/2, `ExploreHomeUITests` 8/8, `HomeEditorUITests` 3/3. iOS 17.5: `testShowInLatestOff`, `AggregationSettingsUITests` 2/2, `HomeEditorUITests` 3/3.

### 5d-3g: 隱藏已讀 (2026-10-11)

Branch `unified-library/5d3g-hide-read`. Decision 21's `HidePlayedInLatest` / `HidePlayedInSuggestions`.

- **聚合設定 → 隱藏已讀:** two switches, 最新 and 相關, both on until turned off (Emby starts `HidePlayedInLatest` on). VoiceOver hears 「隱藏已讀」 as each switch's hint. Footer: a book counts when read to the end or marked 已讀完, in any copy.
- **What counts as read:** a copy on this device at progress ≥ 0.99, the shelf's own 已讀完 (`ReadingBook.isReadToEnd`), so 標記為已讀完 counts. `CopyLookup.isRead` checks the shelf copy a card stands for and every copy made from the entry's item. Book-source items have no copies in `CopyLookup`, so they are never hidden.
- **Where:** `HomeScopeFilter.groups(readFilter:)` drops read books from 最新's and 相關's rows when the home draws, before 最新's turns and the languages' order. Nothing reloads; the shelf lookup is the memoised one the cards already use. A book finished in the reader leaves on the next return to 探索 (`reloadLocal`).
- **Strings:** 隱藏已讀 and the footer, in five languages (the switches reuse 最新 and 相關).
- **Tests (unit):** `HideReadTests` (new, 3: a copy read to the end marks its Gutenberg item and its shelf card read; 最新 and 相關 each follow their own switch while other sections keep read books; both start on and are saved). With the home suites, `CopyLookupTests` and `HomeCompactReadingCardTests`: 59/59 in 11 suites (iOS 27).
- **Tests (UI):** `AggregationSettingsUITests.testHideReadSwitches` (new: both on; 相關 off survives a relaunch). The page is longer now, so the suite scrolls to each control first. iOS 27: `AggregationSettingsUITests` 3/3, `ExploreHomeUITests` 8/8. iOS 17.5: `AggregationSettingsUITests` 3/3, `testNewInstallShowsTheDefaultSections`.

### 5d-3h: 首頁欄目 in 聚合設定 (2026-10-11)

Branch `unified-library/5d3h-home-sections`. Decision 21's home sections: the same sections and edits as 編輯首頁.

- **聚合設定 → 首頁欄目** (first on the page) pushes the saved home's editable sections in order: a section's name, and 已隱藏 when hidden. Drag to reorder (`HomePage.moveEditable`; VoiceOver 上移／下移); a tap pushes the section's own page, the one 編輯首頁 pushes (`HomeSectionPage`: 在首頁顯示, 刪除). The footer says it is the same as 編輯首頁.
- **Before 探索 first opens** there is no saved home (`pageOrDefaults` needs the book-source library read); the page says so with `ContentUnavailableView` rather than making the home itself.
- **Strings:** 首頁欄目, the footer, the empty state, in five languages.
- **Tests (UI):** `AggregationSettingsUITests.testHomeSections` (new: empty before 探索 opens; then the sections are listed, and hiding the first from its page shows 已隱藏 on its row). iOS 27: `AggregationSettingsUITests` 4/4, `HomeEditorUITests` 3/3. Not run on iOS 17.5.

### The catalog entry is gone (2026-10-11)

Branch `unified-library/remove-catalog-entry`. The maintainer, after 5d-3h: 「不要瀏覽這個完整目錄了，要什麼自己添加不就好了」. This reverses decision 20's first half (5d-3b's entry).

- **Removed:** the entry at the top of the home (瀏覽書庫 under 全部, 瀏覽完整目錄 under one library), its page and route (`HomeCatalogEntry.swift`: `HomeLibrariesPage`, `HomeLibrariesRoute`, `HomeCatalogEntryLabel`, `ExplorePushLink`), and the strings 瀏覽書庫, 瀏覽完整目錄 and 書庫. A reader adds the sections they want; a row's 查看全部 still opens the rest of what it shows (`ExplorePlace.page(of:)` stays for it). The empty home no longer passes touches through for the entry.
- **書庫順序** now orders 範圍 and 最新's turns; its footer says so (the string changed in five languages).
- **Tests (UI):** `testScopeFiltersTheHomeAndBack` and `testConnectionIsInScope` check there is no entry; `testLibraryOrder` checks 範圍 alone; `testHomeSections` waits for 精選's first card. iOS 27: `AggregationSettingsUITests` 4/4, `ExploreHomeUITests` 8/8, `HomeEditorUITests` 3/3.

### 青空文庫 never loaded: its catalog was never published (2026-10-11)

The maintainer: 「青空文庫一直連結不上」. `AozoraCatalogStore` reads `https://yuedureader.com/catalogs/aozora/v1/manifest.json`, which answered 404: the catalog was built by `scripts/aozora_catalog/build_catalog.py` but its first publication waited on the maintainer (`Technotes/PublicLibraries.md`). Aozora's own site answers.

- **Published** (maintainer's choice: the website repository, not a GitHub release): built from the official CSV (Last-Modified 2026-08-21), 17,344 works, `works.json` 9.4 MB, its SHA-256 matching the manifest's. Yuedu-website `4484749`, with a README note on updating it. Live and verified by hash.
- **The home's pull to refresh now fetches the catalog again** (`aozora.load(forceRefresh:)`), as 青空文庫's own page does. A failed check counts toward the daily check, so a device that got the 404 today would otherwise wait up to a day. The daily check itself is unchanged; its comment's reason (the official site's outage) no longer applies now that the manifest is ours.
- **Tests (UI, live, opt-in `AOZORA_CATALOG_LIVE_UI`):** `PublicLibraryLiveUITests.testAozoraCatalogFromTheWebsite`: a pull, then 範圍 → 青空文庫 shows its works from the website. Passed on iOS 27.

### 5d-4: 首頁配置 (2026-10-11)

Decision 22. Branch `unified-library/5d4-configurations`.

- **`explore_home.json` is schema 2** (`HomeConfigurations`): 預設's sections stay under the top-level `sections`, beside `configurations` (空白 once edited, then the reader's own), `selected`, and `customPagesPending`. A build before 5d-4 reads a schema-2 file as a newer build's: 預設 only, never written over.
- **`HomePageStore.page`, `edit` and `save` act on the selected 首頁配置**, so 編輯首頁, a section name's long press and 聚合設定 → 首頁欄目 all edit the one 範圍 shows. Choosing another one, or deleting the one being edited, ends 編輯首頁.
- **範圍** has a 首頁配置 picker (預設, 空白, the reader's own) where the 自訂頁 submenu was; the browser stays last. ＋ is 新增首頁配置: one alert with the name, 從預設開始 (預設's sections copied under new ids) and 從空白開始. 編輯首頁 ends with a 首頁配置 card: its name, and for the reader's own, 重新命名 and 刪除 (asks first). 預設 and 空白 are neither renamed nor deleted.
- **An empty 首頁配置** says 「這個首頁配置還沒有欄目」 and how to fill it until 5d-5 (長按來源配置的分類，選擇「加入首頁配置」). The empty state carries 編輯首頁 itself; it used to sit under the overlay.
- **加入首頁配置** (a category's long press, the category page's menu) adds a 橫向單排書架 of the category to any 首頁配置, ticked where it is already.
- **The custom pages move in once:** when a schema-1 file is read, or when the first home is made. Each page becomes a 首頁配置 under its own id; blocks map as decision 14 says (多分類排行榜 → one ranked list per category, each under a new id and titled by its category; 錯位瀑布流 → 固定封面網格, which no longer keeps loading; 推薦卡片 loses its intros). A block with too few categories, or of several sources, is logged and left out. The old 首屏頁面 choice of a page (`explore.landing = page:<uuid>`) selects that 首頁配置, then the key goes. A pages file that cannot be read sets `customPagesPending`, and the move is tried again on a later launch; the landing key waits for it. `custom_explore_pages.json` is read, never written or deleted, for older builds; a page such a build adds afterwards does not move in.
- **Deleted:** the custom page, its editor and block sheet, `CustomExploreBlocks`, `CustomExplorePageModel` (the waterfall's paging), `CustomExplorePageStore` (now `LegacyCustomExplorePages`, read-only), the `customPage`/`customPageEditor` routes, three unused `DSLayout` tokens (the rank badge's became `homeRankBadgeSize`), and 29 strings in each language. Until 5d-5, a moved section's category cannot be changed.
- **Strings:** +9 (首頁配置, 新增首頁配置, 加入首頁配置, 空白, 從預設開始, 從空白開始, 首頁配置裡的欄目會一起刪除。, 這個首頁配置還沒有欄目, 長按來源配置的分類，選擇「加入首頁配置」。), −29.
- **Tests:** `HomeConfigurationTests` (mapping; moving from a schema-1 file with the landing; once only; an unreadable pages file waits; a first home; a newer build moves nothing; create, rename, delete and edits on the selected one). `HomeSectionTests`, `SectionPageLoaderTests` lose what tested deleted code. Unit: 16 suites, 86 tests, iOS 27. UI: `ExploreHomeUITests` (all 9, with the new `testConfigurationsAndTheBrowser` and `testCustomPageMovesIn` via `-seed-custom-explore-page`) and `AggregationSettingsUITests.testHomeSections`, on iOS 27 and iOS 17.5.
- **Fixed the same day (`unified-library/5d4-configuration-menu`):** inline in 範圍, the picker's header was drawn by neither OS, and its check mark read as a second 範圍 choice beside 全部's. 首頁配置 is now a submenu, as 來源配置 is, with the current one as its subtitle (VoiceOver reads both). `testConfigurationsAndTheBrowser` opens it, and taps the dialog's 刪除 rather than the card's button of the same name. ExploreHomeUITests, all 9, on iOS 27; the two 5d-4 tests on iOS 17.5.
- **Not done:** a newer build's file is read for 預設 alone. A schema-1 file's 最新 exclusions are handed to 聚合設定 only in the launch that rewrites it as schema 2, if that launch makes `AggregationSettingsStore.shared`; only development simulators had a schema-1 file (5a–5d never shipped).

### 5d-5: 新增欄目 and the section form (2026-10-11)

Decision 23. Branch `unified-library/5d5-section-form`.

- **新增欄目** is the ＋ beside 完成 in 編輯首頁, a card after the sections, and the empty 首頁配置's own button (with 編輯首頁). In Rex's order: a sheet lists the five layouts, then pushes the form; 新增 adds the section at the end of the selected 首頁配置, and the home scrolls it into view (`ScrollViewReader`, on iOS 17 too, where the lazy cards were off screen). 取消 changes nothing. The empty state's 「長按來源配置的分類，選擇「加入首頁配置」。」 is gone.
- **One form** (`HomeSectionForm`, `HomeSectionEditor`) for a new section and for one on the home, replacing 5d-4's 在首頁顯示/刪除 page: 預覽 (the section loaded in a home of its own, `HomeModel.preview`, hidden or not), 標題 (empty follows the choice; a feed's item name fills it until the reader types one), 呈現方式 with 顯示排名, 資料來源 (「來源 › 子項目」), then 在首頁顯示 and 刪除 for a section on the home. A section on the home is written on every change, in its place (`HomePage.replaceSection`).
- **選擇內容來源** (`HomeContentSourcePicker`): App 資料 (繼續閱讀, 最新, 相關), 書庫 (OPDS/Calibre connections — WebDAV serves 最新 only, so it is not listed — Gutenberg's lists and feeds, 青空文庫's new works and indexes, when available), 來源配置 (every explore source, searchable, `HostedCollectionList`, then its categories under its group labels, searchable). 「目前」 marks the source in use. A sheet over the form; pushed instead on iOS 17 when the form is a sheet already. No 外部服務 group.
- **最新's parameters:** the category each book source stands on in 最新, one per source (`latest.category:<url>`); 新增來源配置 pushes the sources, a row changes it, swiping or the VoiceOver action 移除 takes the source out.
- **A section's own discover filters** (decision 23). The categories page draws the source's `select` filters above its categories; changing one lists them again for this section only. The values are read by the explore rule in place of the stored ones and never stored: `LegadoSourceBridge.withVariableOverlay`, set on the engine's queue around one evaluation (`JSCoreEngine.evaluateIsolated(_:bindings:variableOverlay:)`), merges them over the stored variable in `getVariable`/`get`; a script that writes the variable back (光遇's cloud settings) keeps its own keys, and the overlay's keys keep their stored values. A variable that is not a JSON object is read as stored, logged. A new 发现页类型 starts its 发现页来源 where the source's page would (`DiscoverViewModel.discoverPlatform`, now static), read only: no 更多设置, no per-类型 memory, no poisoned-variable reset. The section keeps the values by source (`filters:<url>`, sorted keys), 最新 too; the form shows them as 篩選, which reopens the categories under them. A source that writes them into the category's URL (光遇) shows them; a source that reads them again when its books load reads its shared ones there.
- **iOS 17 freeze, found by the UI test before merging:** on iOS 17.5, 最新's 新增來源配置 froze the app (XCUITest: 「Timed out while evaluating UI query」). `_logChanges`: `HomeSectionFormHost: _dismiss changed.` 13,830 times, the host reading `dismiss` while the form under it held four `navigationDestination`s — the search page's freeze (`Technotes/iOS17SearchWatchdogPostmortem.md`, guardrail 12). Now the form has one item destination (`HomeSectionFormPush`), nothing in the form or 新增欄目's sheet reads `dismiss` (the home closes the sheet by its binding), and only the leaf `HomeSectionDeleteButton` leaves the page, through `presentationMode` as `ReaderView` does. `testAddSections` now also deletes from the form.
- **Strings:** +7 (新增欄目, 選擇內容來源, 資料來源, App 資料, 書庫, 參數, 來源配置要選一個分類代表它的最新，沒選的不會出現在最新。), −1 (長按來源配置的分類，選擇「加入首頁配置」。).
- **Tests:** `HomeSectionEditorTests` (adds at the end; writes in place; the title follows the choice; 最新's categories with filters), `HomeSectionFilterTests` (lists under the section's values; a new 类型's platform; kept by source), `SourceVariableOverlayTests` (the rule reads the overlay through `getVariable` and `get`, the stored JSON unchanged byte for byte; a write-back keeps its keys and stores none of the overlay's; a non-object variable). Unit, with the explore/variable suites (`ModernParserBridgeExploreTests`, `LegadoSourceBridgeTests`, `DiscoverViewModelReloadTests`, `DiscoverKindsCacheTests`, `ExploreSourceFilterTests`): 11 suites, 75 tests, iOS 27. UI: `HomeEditorUITests.testAddSections` (a Gutenberg list as 固定封面網格 with its preview; a book source's category under its 頻道 filter set to 女, kept as 篩選; renaming; 最新's parameters; 刪除 from the form). iOS 27: `HomeEditorUITests` 4, `ExploreHomeUITests` 9, `AggregationSettingsUITests.testHomeSections`, all passed. iOS 17.5: `HomeEditorUITests` 4 passed.
- **Added the same day (`unified-library/5d5-settings-configuration-name`, maintainer: 「要」):** 聚合設定 → 首頁欄目's first row names the 首頁配置 it edits (首頁配置 · 預設), since 範圍 chooses it elsewhere. No new string. `AggregationSettingsUITests.testHomeSections` checks it; passed on iOS 27.
- **Not done:** 聚合設定 → 首頁欄目 has no 新增欄目. A section holding several categories (a migrated custom-page block) shows no 篩選 row; 資料來源 replaces them with one.
