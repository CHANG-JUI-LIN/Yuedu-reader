# Public-Domain Libraries in Explore — Implementation Plan

> **For astra.** Read [AGENTS.md](../../../AGENTS.md) first, then the sections of [CLAUDE.md](../../../CLAUDE.md) each task touches. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Companion plan: [Aozora Bunko: complete support](2026-10-07-aozora-complete-support.md). Tasks 6–8 here build the Aozora Bunko library that plan relies on.

**Goal:** A reader who has not imported any book source opens 探索 and finds two public-domain libraries: Project Gutenberg and Aozora Bunko (青空文庫).
- Once book sources exist, a menu at the top right of Explore switches between 公有書庫 and today's Explore page (書源).
- The app never switches on its own. A one-time guide points at the menu the next time Explore opens after the first import.

**Today:** without a source that supports discovery, Explore shows only 「尚未啟用支援發現的書源」 and a button to 書源管理. Project Gutenberg exists only as a one-tap example in the OPDS sheet behind the bookshelf's ＋ menu.

---

## Decisions

### The maintainer's (2026-10-07)

1. **Built-in libraries:** Project Gutenberg and Aozora Bunko, nothing else.
2. **No imported book source:** Explore shows 公有書庫 and offers no switch.
3. **Importing sources never switches Explore.** The chosen mode is remembered. The next time Explore opens after the first import, a guide animation points at the switch.
4. **The switch:** a menu at Explore's top right, `✓ 公有書庫 / 書源`.
5. **Aozora Bunko opens only once its official site is back.** It is unreachable as of 2026-10-07; see Context.

### Made while planning

Each comes with its reason; the maintainer can overturn any of them.

6. **An upgrade keeps what readers see.** A reader who already has book sources when this ships starts in 書源, the page they know. A new install, or a reader without sources, starts in 公有書庫. This is decision 3 again: Explore never changes under the reader.
7. **"Imported" means any book source exists:** `BookSourceStore.shared.sources` is non-empty, enabled or not. Switching to 書源 with nothing explorable shows that page's own empty state, which points to 書源管理.
8. **Gutenberg reuses the remote-library path.**
   - `OPDSFeedView` browses it.
   - `RemoteLibraryBookDetailView` and `RemoteLibraryService` read it, add it to the shelf and download it.
   - This keeps one path per concern: no second OPDS browser and no second reader path.
   - It is a built-in connection, id `builtin.gutenberg`, that the reader can neither edit nor delete.
9. **Gutenberg's terms of use shape the client** (https://www.gutenberg.org/policy/terms_of_use.html, OPDS section):
   - an identifying User-Agent with a contact URL;
   - one page per search, and the next page only when the reader asks;
   - no prefetching and no background crawling;
   - `www.gutenberg.org`, not `m.gutenberg.org`. The `m.` host now redirects to www and returned a 504 once on 2026-10-07.
10. **Aozora Bunko: our catalog, Aozora's files.**
    - There is no official OPDS or API. The third-party OPDS feeds are frozen in 2018 or dead.
    - A scheduled job turns the official CSV into one compact JSON, and the app reads only that JSON.
    - Each download goes straight to the work's テキストファイルURL from the CSV. Aozora's link rules allow linking the zip files of free works (https://www.aozora.gr.jp/guide/linkkijyunn.html, wording not re-verified while the site is down).
    - The download goes through the existing `AozoraBookImporter`.
    - Other Aozora Bunko readers (読書尚友, i文庫HD) likewise serve their catalog from their own server rather than having every device fetch the official files.
11. **Only works whose 作品著作権フラグ is なし are listed.** Works still under copyright carry their own per-work permissions (取り扱い規準), which an automatic download and conversion cannot check.
12. **No mirror fallback.** When aozora.gr.jp cannot be reached, the download fails and the message says so. A mirror would be a fallback for an external outage. The project rules allow that only with an exact trigger, a comment and disclosure, and none is planned.
13. **Library search searches both libraries.** The Aozora catalog is searched locally as the reader types. Gutenberg is searched only when they submit: one request per search (decision 9).
14. **The guide is a TipKit tip** anchored to the menu, with the menu's symbol bouncing while the tip shows (not under Reduce Motion).
    - TipKit is the system's own coach mark, available from iOS 17.
    - VoiceOver reads it.
    - It keeps its own "shown once" state.
15. **Where the catalog is served from.** The app repository is public and the website repository is private, so release assets can be public only in the app repository.
    - The scheduled job runs in this repository and uploads `manifest.json` and `works.json` as assets of a fixed release, `aozora-catalog-v1`. Each run replaces them, so nothing piles up in git history.
    - The website redirects `https://yuedureader.com/catalogs/aozora/v1/*` to those assets, so the app's URL stays on our own domain.
    - The maintainer can swap the storage later (for example Cloudflare R2) without an app update.

### The maintainer's, second round (2026-10-07)

16. **The China mainland storefront hides 公有書庫.** The app is on that storefront.
    - There, Explore keeps today's page (書源) whether or not sources exist. It offers no mode menu and shows no tip.
    - Reason: in China, App Review may ask an app that provides book content for an Internet Publishing Service licence (developer reports, https://developer.apple.com/forums/thread/746605). Readest turned its built-in catalogs off there first, in 2026-01, "to comply with App Store review policies in certain regions" (readest issue #5133; PRs #3031 and #3102).
17. **The User-Agent's contact is `https://yuedureader.com/support`.** Never put a personal email address in it.
18. **Gutenberg OPDS 2: the maintainer is writing to Gutenberg.** Gutenberg writes: "We expect to sunset the existing XML-based OPDS feeds in 2027" (https://www.gutenberg.org/ebooks/offline_catalogs.html), and access to the JSON feed means contacting them first.
    - The recipient is Eric Hellman (`eric (at) pglaf.org`), Executive Director of the Project Gutenberg Literary Archive Foundation and the catalog's technical contact (https://www.gutenberg.org/cache/epub/feeds/about.txt).
    - Task 13 waits for his reply.

---

## Context

Read on 2026-10-07. File and line references are from that day's `main`.

### The app

**OPDS** (`Modules/Services/OPDS/`)
- `OPDSClient.swift` parses OPDS 1.x Atom only. There is no OPDS 2 JSON, no facets and no indirect acquisition. Pagination is `rel="next"` only.
- Search is an Atom template or an OpenSearch description (`OPDSSearch`).
- Book entries choose the best acquisition: EPUB, then PDF, TXT, Markdown.
- `OPDSCatalog.swift`:
  - `OPDSCatalogStore.shared` persists `Library/opds_catalogs.json`, with credentials in the Keychain. Catalogs are not synced and not backed up.
  - `OPDSCatalogStore.presets` (L47-49) holds one example: `Project Gutenberg`, `https://m.gutenberg.org/ebooks.opds/`.
  - `connection(id:)` and `client(for:)` (L119-133) resolve only the stored catalogs.

**The network layer** (`Modules/Services/RemoteLibrary/RemoteLibraryHTTPClient.swift`)
- It uses an ephemeral session with no credential or cookie storage.
- It sets no User-Agent, so requests carry CFNetwork's default.

**Browsing** (`Modules/Features/Bookshelf/OPDSImportView.swift`)
- `RemoteLibraryBrowserView` is a sheet root with its own `NavigationStack` and an xmark button, so it cannot be pushed.
- `OPDSFeedView(route: OPDSFeedRoute)` (L269) can be pushed. It resolves `route.catalogID` through `RemoteLibraryConnectionStore.shared`.
  - It searches inside the catalog ("搜尋此目錄").
  - It pages only through a 「載入更多」 button, which already meets decision 9.
  - Book rows push `RemoteLibraryBookRoute(entry:connectionID:)` → `RemoteLibraryBookDetailView`.

**Reading** (`Modules/Services/RemoteLibrary/RemoteLibraryService.swift`, injected as `AppDependencies.remoteLibrary`)
- An OPDS book is a remote `ReadingBook` that is read over HTTP Range.
- Adding it to the shelf and downloading it are separate use cases (`Technotes/RemoteLibraryReading.md`).
- Nothing goes through `LocalBookImportService`.

**Explore** (`Modules/Features/Explore/ExploreHomeView.swift`)
- The tab root is `BrowserView` (`Modules/Features/WebBrowser/BrowserView.swift` L701-709), which wraps `ExploreHomeView(browser:)`.
- `ExploreHomeView` owns `NavigationStack(path:)`, the browser tile, custom pages and `sourcesBlock`.
  - Its empty state is at L295-326.
  - The trailing toolbar items are at L180-201: `groupMenu`, ＋ 新增自訂頁, ⚙︎ 探索設定.
  - `.searchable(prompt: "搜索書源")` (L202).
  - The title is `.rootTabTitle(localized("探索"), onScroll: .minimizesBar)`.
- Sources come from `DiscoverViewModel.exploreSources(in:)` (`Modules/Services/Online/DiscoverViewModel.swift` L196-201), observed through `BookSourceStore.shared.$sources`.
- Explore's keys live in `ExploreSettings` (`Modules/Services/Online/ExploreSettings.swift`), read with `@AppStorage`. `ExploreLanding` (L91-119) shows the pattern for a string-backed mode.

**Aozora import**
- `AozoraBookImporter.importBook(at:title:store:)` converts a `.txt` or an Aozora zip to an EPUB book.
- `ReadingBook.aozora: AozoraBookSource?` records the original file and its encoding.

**TipKit** is not used anywhere yet.

### Project Gutenberg

All of this was requested live on 2026-10-07.
- **Root:** `https://www.gutenberg.org/ebooks.opds/` is a navigation feed with three children:
  - Popular: `/ebooks/search.opds/?sort_order=downloads`
  - Latest: `/ebooks/search.opds/?sort_order=release_date`
  - Random: `/ebooks/search.opds/?sort_order=random`
- **Search:** `/ebooks/search.opds/?query={q}`.
  - 25 entries a page; the next page has `start_index=26`.
  - Entries are `rel="subsection"` links to `/ebooks/{id}.opds`.
  - Their thumbnails are inline base64 PNG data URIs.
  - A language filter is part of the query: `l.zh` returns "Books: Language: Chinese".
- **The OpenSearch description** `https://www.gutenberg.org/catalog/osd-books.xml` still templates `http://m.gutenberg.org/…`. Do not use it.
- **A book feed** `/ebooks/{id}.opds` has two entries, without images and with images.
  - Acquisitions use rel `http://opds-spec.org/acquisition`: `.epub3.images`, `.epub.images`, `.epub.noimages`, `.kf8.images`, `.kindle.*`.
  - Covers are `/cache/epub/{id}/pg{id}.cover.medium.jpg`.
  - Rights: "Public domain in the USA".
- **Terms:**
  - The robot policy (https://www.gutenberg.org/policy/robot_access.html) blocks automated crawling.
  - The terms of use ask OPDS apps to:
    - send a proper User-Agent with contact details;
    - fetch one page per search and the next page only on demand;
    - not build "mock Gutenberg front-ends that pocket advertising revenues".
  - The name "Project Gutenberg" is a registered trademark. Commercial redistribution of eBooks carrying it owes royalties (https://www.gutenberg.org/policy/permission.html).
    - The app does not redistribute files: readers download the originals from gutenberg.org, licence text included.
    - Whether naming the library in an app's interface counts as trademark use is not stated. KOReader, Readest, Librera and Yomu all do it.
- **Blocks:** Germany now blocks only Alfred Döblin's books, until 2028-01-01 (https://block.pglaf.org/germany.shtml). Italy blocked the site through ISP DNS from 2020; whether it still does is unverified.

### Aozora Bunko

**Unreachable on 2026-10-07**
- `www.aozora.gr.jp` does not resolve: SERVFAIL from 8.8.8.8 and 1.1.1.1.
- `github.com/aozorabunko/aozorabunko` returns 404, and the organization has 0 public repositories.
- A search engine indexed a notice on the official site, which cannot be checked while the site is down:
  - a reception server failure on 2026-08-23;
  - 「作業着手連絡システム」 and 「青空文庫のgithubデータ一式」 suspended.
- The site has been moving to a new system (「新館」) since 2023, aiming to run it in summer 2026 (https://www.aozora.gr.jp/aozorablog/?p=5510, via search index).

**The catalog CSV**
- `https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip`, about 2 MB.
- Format: UTF-8 with a BOM, CRLF line ends, every field quoted.
- One row per work × person: a translation has an author row and a translator row.
- 55 columns, in this order:
  作品ID, 作品名, 作品名読み, ソート用読み, 副題, 副題読み, 原題, 初出, 分類番号, 文字遣い種別, 作品著作権フラグ, 公開日, 最終更新日, 図書カードURL, 人物ID, 姓, 名, 姓読み, 名読み, 姓読みソート用, 名読みソート用, 姓ローマ字, 名ローマ字, 役割フラグ, 生年月日, 没年月日, 人物著作権フラグ, 底本名1, 底本出版社名1, 底本初版発行年1, 入力に使用した版1, 校正に使用した版1, 底本の親本名1, 底本の親本出版社名1, 底本の親本初版発行年1, 底本名2, 底本出版社名2, 底本初版発行年2, 入力に使用した版2, 校正に使用した版2, 底本の親本名2, 底本の親本出版社名2, 底本の親本初版発行年2, 入力者, 校正者, テキストファイルURL, テキストファイル最終更新日, テキストファイル符号化方式, テキストファイル文字集合, テキストファイル修正回数, XHTML/HTMLファイルURL, XHTML/HTMLファイル最終更新日, XHTML/HTMLファイル符号化方式, XHTML/HTMLファイル文字集合, XHTML/HTMLファイル修正回数
- Source: the CSV generator of shinonome, https://github.com/shinonome-app/shinonome/blob/main/app/services/csv_creator.rb.
- Size: 19,502 rows in a third-party snapshot of 2026-08-22.
- Updated whenever works are published, recently daily.

**Licences and file URLs**
- The catalog data (図書カード, 書架情報, this CSV) is CC BY 4.0 since 2022-01-01 (https://current.ndl.go.jp/car/45274). The app must attribute it. The texts themselves are not CC BY.
- A file URL changes when a work is revised. Never build file URLs from IDs; always use the CSV's.

---

## Guardrails

- **Project rules.** AGENTS.md and CLAUDE.md apply in full:
  - Run tests with `bash scripts/xctest.sh -- -only-testing:'yuedu appTests/<Suite>'`.
  - No `-derivedDataPath`.
  - Delete your own `.xcresult` files.
  - Run the smallest relevant regression after the last related edit.
- **UI.** Invoke the `yuedu-ios-design` skill for every view in this plan:
  - native `List` / `Menu` / `Picker` / `ContentUnavailableView`;
  - `DS*` tokens;
  - pushed pages use `.inline`;
  - section notes are `Section { } footer: { }` with `.dsSectionFooter()`;
  - VoiceOver labels on every icon-only control;
  - `#Preview` for every new or changed view.
- **Localization.** Every string goes through `localized(…)` in all five languages (zh-Hant, zh-Hans, en, ja, ko). Run `ruby scripts/check_localizations.rb`.
- **Errors.** No `try?` that discards an error in network or parsing code; log through `AppLogger`. No timing-based waits.
- **Views don't orchestrate.** Downloading, converting and caching live in services. A view calls one use case.
- **Never behind Pro.** Neither library, nor reading, shelving or downloading their books, may require the Pro subscription. The maintainer's email to Gutenberg states this.
- **Outward actions need the maintainer's yes, asked in chat:**
  - enabling the scheduled workflow;
  - creating the release;
  - adding the website redirect;
  - pushing.
- **Shared worktree.** Other agents work in the same checkout. Commit only your own files (`git commit --only`).
- **iOS 17.** The mode menu only switches state; it launches no sheet or importer, so the iOS 17 menu-to-modal rule (`Technotes/iOS17MenuModalPresentation.md`) does not apply. Check again if a menu item ever presents something.
- **The large title.** `rootTabTitle(_:onScroll:)` is allowed only on tab roots. `PublicLibraryHomeView` becomes Explore's second root, so Task 2 adds it to the whitelist in `docs/design.md` and in both copies of the skill, `.claude/skills/yuedu-ios-design/SKILL.md` and `.agents/skills/yuedu-ios-design/SKILL.md`, which must stay byte-identical.

---

## File map

**Create**
- `Modules/Services/PublicLibrary/PublicLibrary.swift`: the registry. `PublicLibraryID`, the Gutenberg connection, the Gutenberg shelves and the search template.
- `Modules/Services/PublicLibrary/AozoraCatalog.swift`: catalog models (v1 schema) and the index.
- `Modules/Services/PublicLibrary/AozoraCatalogStore.swift`: fetch, verify, cache and publish the catalog.
- `Modules/Services/PublicLibrary/AozoraLibraryDownloadService.swift`: download a work's zip and import it.
- `Modules/Features/Explore/ExploreTabRoot.swift`: chooses the mode's root; hosts the mode menu and the tip.
- `Modules/Features/Explore/PublicLibrary/PublicLibraryHomeView.swift`
- `Modules/Features/Explore/PublicLibrary/AozoraCatalogViews.swift`: work lists, author lists, work detail.
- `Modules/Features/Explore/PublicLibrary/PublicLibrarySearchResults.swift`
- `Modules/Features/Explore/ExploreModeTip.swift`
- `scripts/aozora_catalog/build_catalog.py` and `scripts/aozora_catalog/test_build_catalog.py`
- `.github/workflows/aozora-catalog.yml`
- Tests: `ExploreModeTests.swift`, `PublicLibraryRegistryTests.swift`, `AozoraCatalogTests.swift`, `AozoraCatalogStoreTests.swift`, `AozoraLibraryDownloadServiceTests.swift`
- `Tests/iOS-UI/PublicLibraryExploreUITests.swift`
- `Technotes/PublicLibraries.md`

**Modify**
- `Modules/Services/Online/ExploreSettings.swift`: the mode key and `ExploreMode`.
- `Modules/Features/WebBrowser/BrowserView.swift`: host `ExploreTabRoot`.
- `Modules/Features/Explore/ExploreHomeView.swift`: the mode menu in its toolbar.
- `Modules/Services/OPDS/OPDSCatalog.swift`: resolve built-in connections; the Gutenberg example moves to www.
- `Modules/Services/RemoteLibrary/RemoteLibraryHTTPClient.swift`: the User-Agent.
- `Modules/Services/LibraryStore/Models.swift`: `AozoraBookSource.catalogWorkID`.
- `Targets/Yuedu/SharedApp/yuedu_appApp.swift`: `Tips.configure`.
- `Resources/*/Localizable.strings` (all five).
- `docs/design.md`, both copies of the `yuedu-ios-design` skill, and `Technotes/RemoteLibraryReading.md`.
- Website repository `Yuedu-website`: `_redirects` (Task 6, with the maintainer's yes).

---

## Task 1: The Explore mode setting

**Files:** `ExploreSettings.swift`; create `Tests/iOS/yuedu appTests/ExploreModeTests.swift`.

- [ ] **Step 1: Write the failing tests.**
  - `ExploreMode.effective(stored:hasImportedSources:librariesAvailable:)`:
    - returns `.bookSources` whenever the libraries are not available (the China storefront, decision 16);
    - otherwise returns `.publicLibraries` whenever there are no sources, whatever is stored;
    - otherwise, with sources, returns what is stored.
  - First launch of this build (`ExploreMode.initialValue(hasImportedSources:)`): `.bookSources` with sources (decision 6), `.publicLibraries` without.
  - Storage round-trip: the key is `explore.mode`, with raw values `"libraries"` and `"sources"`. An unknown raw value reads as the default for the case above.
- [ ] **Step 2: Implement.**

  ```swift
  enum ExploreMode: String, CaseIterable, Sendable {
      case publicLibraries = "libraries"
      case bookSources = "sources"
  }
  ```

  - Add `ExploreSettings.modeKey = "explore.mode"`.
  - Write the initial value once, at first launch of this build, when the key is absent. App start is the one place that knows the sources before any Explore view exists.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/ExploreModeTests'
  git commit --only -m "feat(explore): add the Explore mode setting" -- <your files>
  ```

## Task 2: The tab root and the mode menu

**Files:**
- Create `ExploreTabRoot.swift` and a placeholder `PublicLibraryHomeView.swift`.
- Modify `BrowserView.swift` and `ExploreHomeView.swift`.
- Update the title whitelist in `docs/design.md` and both skill copies.

- [ ] **Step 1: The root.**
  - `BrowserView.body` shows `ExploreTabRoot(browser:)`.
  - `ExploreTabRoot` observes `BookSourceStore.shared.$sources` and `@AppStorage(ExploreSettings.modeKey)`, and shows `ExploreHomeView` for `.bookSources` or `PublicLibraryHomeView` for `.publicLibraries`.
  - Each root keeps its own `NavigationStack`. Switching modes resets the other mode's path; that is accepted.
- [ ] **Step 2: The menu.**
  - `ExploreModeMenu` is a `Menu` holding a `Picker(selection:)` with two options:
    - 公有書庫 (`books.vertical`);
    - 書源 (`antenna.radiowaves.left.and.right`).
  - The `Picker` gives the native checkmark.
  - The label is an icon-only `ellipsis.circle`, with `.accessibilityLabel(localized("切換探索內容"))` and an accessibility value naming the current mode.
  - It is the leading-most `.topBarTrailing` item in both roots, so it stays in one place.
  - It is present only when sources exist and the libraries are available (decision 16).
  - In 公有書庫 the toolbar holds only this menu. ＋ 新增自訂頁, ⚙︎ 探索設定 and the group menu belong to the 書源 page and stay there.
- [ ] **Step 3: Title and search.**
  - `PublicLibraryHomeView` uses `.rootTabTitle(localized("探索"), onScroll: .minimizesBar)`, as `ExploreHomeView` does.
  - Whitelist it in `docs/design.md` §Title rule and in both skill copies. Keep the copies byte-identical (`cmp` them).
- [ ] **Step 4: Tests.**
  - A unit test that the menu is offered only with sources: factor the condition into `ExploreTabRoot.showsModeMenu(hasImportedSources:)`.
  - `#Preview` for both modes.
- [ ] **Step 5: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/ExploreModeTests'
  ruby scripts/check_localizations.rb
  git commit --only -m "feat(explore): switch between public libraries and book sources from a menu" -- <your files>
  ```

## Task 3: The built-in Gutenberg connection and the User-Agent

**Files:**
- Create `PublicLibrary.swift` and `PublicLibraryRegistryTests.swift`.
- Modify `OPDSCatalog.swift` and `RemoteLibraryHTTPClient.swift`, and extend `RemoteLibraryHTTPTests.swift`.

- [ ] **Step 1: Write the failing tests.**
  - `OPDSCatalogStore.connection(id: "builtin.gutenberg")` resolves to `https://www.gutenberg.org/ebooks.opds/`, named "Project Gutenberg".
  - It is not in `catalogs`, not written to `opds_catalogs.json`, and `remove`/`update` refuse it.
  - The example preset's URL is the www host.
  - Every request of a `RemoteLibraryHTTPClient` carries `User-Agent: Yuedu/<CFBundleShortVersionString> (iOS; +https://yuedureader.com/support)`. The existing `RemoteLibraryHTTPTests` stub transport makes this assertable.
- [ ] **Step 2: Implement.**
  - `PublicLibraryID` has two cases: `gutenberg = "builtin.gutenberg"` and `aozora = "builtin.aozora"`.
  - `OPDSCatalogStore` resolves built-in connections in `catalog(id:)` / `connection(id:)` alongside the stored ones. This keeps one store: `RemoteLibraryService` and `BookCoverLoader.remoteSession` already resolve through it. A remote book read from Gutenberg keeps `connectionID == "builtin.gutenberg"`, so its identity stays stable across launches.
  - Set the User-Agent in `RemoteLibraryHTTPClient` for every remote library: OPDS, WebDAV and Calibre alike. An identifying agent is what calibre and KOReader send, and it is one code path.
  - Leave readers' saved `m.gutenberg.org` connections alone: the server redirects them.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/PublicLibraryRegistryTests' -only-testing:'yuedu appTests/RemoteLibraryHTTPTests' -only-testing:'yuedu appTests/RemoteLibraryConnectionTests'
  git commit --only -m "feat(library): resolve a built-in Project Gutenberg connection and identify the app to remote libraries" -- <your files>
  ```

## Task 4: The library home, Gutenberg section

**Files:** `PublicLibraryHomeView.swift`, `PublicLibrary.swift`; extend `OPDSParserTests.swift` with recorded Gutenberg feeds (bibliographic metadata only, no book text).

- [ ] **Step 1: Record fixtures and write the failing tests.**
  - Save the responses of `ebooks.opds/`, a `search.opds/?query=l.zh` page, and `/ebooks/1342.opds` into `Tests/iOS/yuedu appTests/Fixtures/Gutenberg/`.
  - Assert that `OPDSClient.parseFeed` reads, from these:
    - the navigation entries;
    - `rel="subsection"` book links;
    - `start_index` paging;
    - the EPUB3 acquisition chosen first;
    - the cover links.
  - **Thumbnails:** check whether the existing cover path (`BookCoverLoader`) shows `data:` URI thumbnails. If it does not, make it decode them, with a test. Do not drop them silently.
- [ ] **Step 2: Shelves.** `GutenbergShelf` lists the rows, each an `OPDSFeedRoute(catalogID: "builtin.gutenberg", url:, title:)`:
  - 熱門 (`sort_order=downloads`) and 最新 (`sort_order=release_date`);
  - one row for the interface language when it is not English: 中文 `l.zh`, 日本語 `l.ja`, 한국어 `l.ko`;
  - English `l.en`.

  Language rows sort by downloads.
- [ ] **Step 3: The view.**
  - `PublicLibraryHomeView` is an inset-grouped `List` inside its own `NavigationStack(path:)`, with a "Project Gutenberg" section of those rows.
  - Destinations, registered on the stack:
    - `OPDSFeedRoute` → the existing `OPDSFeedView`;
    - `RemoteLibraryBookRoute` → the existing `RemoteLibraryBookDetailView`.
  - The section footer, with `.dsSectionFooter()`: 「Project Gutenberg 的書在美國屬於公有領域；所在地區的著作權規定可能不同。」
    - It earns its place: it states a risk the reader cannot see from the rows.
  - Every book detail links to `https://www.gutenberg.org/ebooks/{id}`. Check whether `RemoteLibraryBookDetailView` already shows the entry's alternate link; add it if not.
- [ ] **Step 4: Errors.** An offline or blocked request shows `OPDSFeedView`'s existing error with 重試, never an empty list. Check this on the simulator with the network link conditioner, or by pointing a test at an unreachable host.
- [ ] **Step 5: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/OPDSParserTests' -only-testing:'yuedu appTests/PublicLibraryRegistryTests'
  git commit --only -m "feat(library): browse Project Gutenberg from Explore" -- <your files>
  ```

## Task 5: The Aozora catalog builder

**Files:** create `scripts/aozora_catalog/build_catalog.py` and `scripts/aozora_catalog/test_build_catalog.py`, with a synthetic fixture CSV of a few rows. Never commit real catalog data.

- [ ] **Step 1: Write the failing tests** (`python3 -m unittest scripts/aozora_catalog/test_build_catalog.py`). The builder:
  - reads the zip's CSV as UTF-8 and strips the BOM;
  - merges rows by 作品ID into one work with credits `[{person, role}]`, keeping the CSV's role text (著者, 翻訳者, 編者, …) as is;
  - keeps only works whose 作品著作権フラグ is `なし` and whose テキストファイルURL is an `https://www.aozora.gr.jp/…/*.zip` (decision 11);
  - writes `works.json` (schema v1, below) and `manifest.json` with `schemaVersion`, `generatedAt`, the CSV's `Last-Modified`, `workCount`, the SHA-256 of `works.json`, and the attribution text and licence URL;
  - is deterministic: the same CSV gives byte-identical output, with sorted keys, works by 作品ID and persons by 人物ID;
  - exits 0 without writing anything when the CSV cannot be fetched. It logs `::notice::` and leaves the published catalog in place.
- [ ] **Step 2: Schema v1.**

  ```json
  {
    "schemaVersion": 1,
    "persons": [{"id": "000035", "name": "太宰 治", "yomi": "だざい おさむ", "sortYomi": "たさいおさむ",
                 "born": "1909-06-19", "died": "1948-06-13"}],
    "works": [{"id": "1567", "title": "走れメロス", "yomi": "はしれめろす", "sortYomi": "はしれめろす",
               "subtitle": "", "kanaStyle": "新字新仮名", "ndc": "NDC 913",
               "published": "2000-12-04", "updated": "2011-01-17",
               "card": "https://www.aozora.gr.jp/cards/000035/card1567.html",
               "text": "https://www.aozora.gr.jp/cards/000035/files/1567_ruby_4948.zip",
               "textUpdated": "2011-01-17",
               "credits": [{"person": "000035", "role": "著者"}],
               "source": "太宰治全集3", "sourcePublisher": "ちくま文庫"}]
  }
  ```

  Field names are the app's contract. A breaking change bumps `schemaVersion` and the URL path (`/v2/`).
- [ ] **Step 3: Commit.**

  ```bash
  python3 -m unittest scripts/aozora_catalog/test_build_catalog.py
  git commit --only -m "feat(aozora): build a compact catalog from Aozora Bunko's CSV" -- <your files>
  ```

## Task 6: Publishing the catalog

**Files:** create `.github/workflows/aozora-catalog.yml`.

**Outward actions:** enabling the workflow, creating the `aozora-catalog-v1` release, and the website's `_redirects` entry each need the maintainer's yes.

- [ ] **Step 1: The workflow.**
  - It runs daily at 19:00 UTC (04:00 JST), and on `workflow_dispatch`.
  - Its permissions are `contents: write`.
  - It fetches the CSV zip with `User-Agent: Yuedu-catalog/1 (+https://yuedureader.com/support)`.
  - It runs the builder and the builder's tests.
  - When `manifest.json` changed, it uploads both files with `gh release upload aozora-catalog-v1 manifest.json works.json --clobber`.
  - It never commits catalog data.
- [ ] **Step 2: Ask the maintainer.** Before creating the tag, check that no Xcode Cloud workflow (`ci_scripts/`, App Store Connect) starts on tag pushes. Then:
  - create the release (`gh release create aozora-catalog-v1 --title "Aozora Bunko catalog" --notes "書誌データ：青空文庫（CC BY 4.0）…"`);
  - in the website repository, add `/catalogs/aozora/v1/* https://github.com/CHANG-JUI-LIN/Yuedu-reader/releases/download/aozora-catalog-v1/:splat 302` to `_redirects` (its own commit there, built by `bash scripts/build.sh`).
- [ ] **Step 3: Verify.**
  - While aozora.gr.jp is down, a manual run must end green with the notice and upload nothing.
  - Once it is back, `curl -sSL https://yuedureader.com/catalogs/aozora/v1/manifest.json` returns the manifest, and its hash matches `works.json`.
  - Record both in `Technotes/PublicLibraries.md`.

## Task 7: The catalog in the app

**Files:** create `AozoraCatalog.swift`, `AozoraCatalogStore.swift`, `AozoraCatalogTests.swift` and `AozoraCatalogStoreTests.swift`.

- [ ] **Step 1: Write the failing tests.**
  - **Decoding:** a fixture `works.json` decodes; unknown fields are ignored; an unknown `schemaVersion` is an error.
  - **The index:**
    - 新着 is `published` descending.
    - 作家別 groups by the first kana of `sortYomi` into あかさたなはまやらわ, with Latin and others last, and sorts by `sortYomi` within each group.
    - 作品名別 works the same way.
    - 分類別 groups by NDC: 913 小説・物語, 911 詩歌, 914 評論・エッセイ, 91x and 9xx others, then the rest.
  - **Search:** matches title, yomi, author name and author yomi, case- and kana-width-insensitively, ranked by title prefix, then title, then author.
  - **The store,** with a stub transport:
    - a cached catalog is served at once;
    - `manifest.json` is fetched at most once a day, or always when the reader pulls to refresh;
    - an unchanged hash downloads nothing;
    - a changed hash downloads `works.json`, verifies the hash, and replaces the cache atomically;
    - a hash mismatch keeps the old cache and logs;
    - 404 or no network with no cache gives `.unavailable`.
- [ ] **Step 2: Implement.**
  - The store is `@MainActor ObservableObject` and publishes `state: .unavailable | .loading | .ready(AozoraCatalogIndex) | .failed(Error, cached: AozoraCatalogIndex?)`.
  - The URL is `https://yuedureader.com/catalogs/aozora/v1/manifest.json`.
  - Decode and index in `Task.detached` with static functions: under approachable concurrency an `async` function runs on its caller's actor (see the memory note "大書架主執行緒卡").
  - Cache in `Caches/PublicLibrary/aozora/`: it can be rebuilt, so it is not backed up.
  - Measure the decode and index with `SourcePerfTrace` (`aozora.catalog.load`) and record the time for the full catalog.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraCatalogTests' -only-testing:'yuedu appTests/AozoraCatalogStoreTests'
  git commit --only -m "feat(aozora): load and index the Aozora Bunko catalog" -- <your files>
  ```

## Task 8: Aozora browsing and import

**Files:**
- Create `AozoraCatalogViews.swift`, `AozoraLibraryDownloadService.swift` and `AozoraLibraryDownloadServiceTests.swift`.
- Modify `PublicLibraryHomeView.swift` and `Models.swift`.

- [ ] **Step 1: Write the failing tests** for the download service.
  - With a stub downloader serving a zip of `Fixtures/TXTEncodings/aozora-neko-jijo.txt`, `addToShelf(work:)`:
    - downloads to a temporary file;
    - calls `AozoraBookImporter.importBook(at:title:store:)`;
    - sets `book.aozora?.catalogWorkID = work.id`.
  - A work already on the shelf (same `catalogWorkID`) is opened, not imported twice.
  - Error mapping:
    - DNS or connection failure → 「無法連線到青空文庫網站」;
    - HTTP error → its code;
    - a zip without an Aozora text (the importer returns nil) → 「這個檔案不是青空文庫的文字」.
  - Every error is logged with the work ID.
  - Cancellation removes the temporary file.
- [ ] **Step 2: The model.**
  - Add `catalogWorkID: String?` to `AozoraBookSource`, decoded with `decodeIfPresent` and encoded only when present. A book without it must keep its sync hash; see the memory note "ReadingBook 新欄位要 Optional".
  - Add a test that an Aozora book without it encodes exactly as before.
- [ ] **Step 3: The views.**
  - A "青空文庫" section in `PublicLibraryHomeView` with rows 新着作品, 作家別, 作品名別 and 分類別.
    - It shows only when the store has a catalog (`.ready`, or `.failed` with a cache). This is decision 5: no catalog means the official site has not been reachable.
    - Footer: 「書誌資料：青空文庫（CC BY 4.0）」, with the licence as a link in the footer text.
  - Lists use `List` with section index titles for the 五十音 groups.
  - Author rows push that author's works.
  - Work detail (`.inline` title) shows: title and yomi, credits with role, 底本 and publisher, 公開日, 文字遣い種別, and a link to the 図書カード (「在青空文庫網站查看」).
  - The primary button is 「加入書架」, or 「開啟」 once the work is on the shelf.
    - It runs the service and shows progress, and can be cancelled.
    - On success it offers to open the book.
  - Every state is covered, per design.md: loading, empty (`ContentUnavailableView`), error with 重試, offline.
- [ ] **Step 4: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraLibraryDownloadServiceTests' -only-testing:'yuedu appTests/AozoraBookImportTests'
  ruby scripts/check_localizations.rb
  git commit --only -m "feat(aozora): browse Aozora Bunko in Explore and add works to the shelf" -- <your files>
  ```

## Task 9: Library search

**Files:** create `PublicLibrarySearchResults.swift`; modify `PublicLibraryHomeView.swift`.

- [ ] **Step 1:** In 公有書庫, Explore's search field has the prompt 「搜尋公有書庫」.
  - **The 青空文庫 section** shows local catalog matches as the reader types, the first 50 with a 「顯示全部」 push.
  - **The Project Gutenberg section** has one row, 「在 Project Gutenberg 搜尋「…」」, made usable when the reader submits. It pushes `OPDSFeedView` on `https://www.gutenberg.org/ebooks/search.opds/?query=<encoded>`.
    - That is one request per search, and paging stays the reader's 「載入更多」 (decision 9).
    - Use this template from `PublicLibrary.swift`, never the OpenSearch description, which points at `m.`.
- [ ] **Step 2: Tests.**
  - The Gutenberg search URL is encoded correctly for CJK, spaces and `&`.
  - Local search across sections is ranked as in Task 7.
- [ ] **Step 3: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/PublicLibraryRegistryTests' -only-testing:'yuedu appTests/AozoraCatalogTests'
  git commit --only -m "feat(library): search both public libraries from Explore" -- <your files>
  ```

## Task 10: The guide

**Files:** create `ExploreModeTip.swift`; modify `ExploreTabRoot.swift` and `yuedu_appApp.swift`.

- [ ] **Step 1: Configure TipKit** once at launch: `try Tips.configure([.displayFrequency(.immediate)])`, with failures logged through `AppLogger` (no `try?`).
  - UI tests pass `-reset-tips`, which calls `Tips.resetDatastore()` before configuring.
- [ ] **Step 2: The tip.** A sketch; follow the SDK's exact signatures.

  ```swift
  struct ExploreModeTip: Tip {
      @Parameter static var sourcesImported: Bool = false
      static let exploreOpenedAfterImport = Tips.Event(id: "explore.openedAfterImport")
      var title: Text { Text(localized("可以切換探索內容")) }
      var message: Text? { Text(localized("書源已匯入，點這裡切換到書源探索。")) }
      var image: Image? { Image(systemName: "arrow.left.arrow.right") }
      var rules: [Rule] {
          #Rule(Self.$sourcesImported) { $0 }
          #Rule(Self.exploreOpenedAfterImport) { $0.donations.count >= 1 }
      }
      var options: [TipOption] { MaxDisplayCount(1) }
      var actions: [Action] { Action(id: "switch", title: localized("切換到書源")) }
  }
  ```

- [ ] **Step 3: Wiring.**
  - **Detecting the first import:** one observer of `BookSourceStore.shared.$sources`, owned by `ExploreTabRoot`'s model, sets `sourcesImported = true` on the first transition from empty to non-empty.
    - A reader who already has sources at upgrade gets no tip: decision 6 already puts them in 書源.
  - **When it shows:** each time Explore appears with `sourcesImported` true, donate `exploreOpenedAfterImport`. The tip therefore shows the next time Explore opens, not on the screen where the reader imported.
  - **Never on the China storefront:** there is no menu to point at (decision 16).
  - **Placement:** `.popoverTip(ExploreModeTip(), arrowEdge: .top)` on the mode menu.
  - **The bounce:** while `tip.shouldDisplay` (watch `statusUpdates`), the menu's symbol bounces with `.symbolEffect(.bounce, value:)`, skipped when `accessibilityReduceMotion`.
  - **Dismissal:** opening the menu, choosing a mode, or the tip's action invalidates it (`.actionPerformed`). The 「切換到書源」 action sets the mode to 書源; that is the reader's own choice, consistent with decision 3.
- [ ] **Step 4: Tests.**
  - Unit-test the import detector: empty → non-empty sets the flag once; a non-empty start does not.
  - The UI test in Task 11 covers the tip.
- [ ] **Step 5: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/ExploreModeTests'
  git commit --only -m "feat(explore): point at the mode menu the first time Explore opens after importing sources" -- <your files>
  ```

## Task 11: UI tests

**Files:** create `Tests/iOS-UI/PublicLibraryExploreUITests.swift`. Use the launch hooks the existing UI tests use for an empty library and for importing a book source fixture, and add one if none exists.

- [ ] **Step 1:** Ask the maintainer not to touch the simulator during the run (standing rule).
- [ ] **Step 2:** Cases:
  - No sources: Explore shows the libraries, no mode menu, and the Gutenberg rows.
  - Import a source while Explore stays in 公有書庫. Reopen Explore: the tip appears once, the menu bounces, choosing 書源 shows today's page, and relaunching keeps 書源.
  - The tip never appears again.
  - VoiceOver: the menu's label and value read correctly. Use the accessibility inspector, or the `accessibilityLabel` / `accessibilityValue` of the element.
- [ ] **Step 3: Run** the class with `xctest.sh` and the UI test target, then commit.

## Task 12: Documentation and the release checkpoint

- [ ] **`Technotes/PublicLibraries.md`:**
  - the two libraries;
  - endpoints;
  - the terms and how each is honoured;
  - the catalog pipeline, the URLs and the manual workflow run;
  - attribution;
  - the 2027 Gutenberg OPDS sunset and the contact with Gutenberg;
  - the China storefront rule (decision 16).
- [ ] **`Technotes/RemoteLibraryReading.md`:** built-in connections.
- [ ] **Hide 公有書庫 on the China storefront** (decision 16). Build this before the first TestFlight build that includes the libraries.
  - **The source of truth.** `PublicLibraryAvailability` reads StoreKit 2's `Storefront.current` at launch and on `Storefront.updates`.
    - It keeps the last known country code in `UserDefaults`, so a cold start does not flash the libraries before StoreKit answers.
    - `CHN` makes the libraries unavailable.
    - An unknown storefront (`nil`) leaves them available. Document this in the type.
  - **What turns off.** `ExploreTabRoot`, the mode menu and the tip read the availability. Nothing else changes: the OPDS sheet's Gutenberg example stays as it is today.
  - **Tests.**
    - The availability: CHN, another storefront, nil, the cached value on cold start, and an update while running.
    - `ExploreMode.effective` with the libraries unavailable.
  - **Record the review risk** in `Technotes/PublicLibraries.md`.
    - App Review usually runs on US-storefront devices, and one binary serves every storefront.
    - If a China review still objects to the book content, the remaining option is the one Readest took: remove the built-in libraries from App Store builds.
    - That is a maintainer decision.
- [ ] **Measure** the first open of 公有書庫 on the simulator (Gutenberg root and catalog load), with `SourcePerfTrace` spans, and record the numbers.

## Task 13: Gutenberg OPDS 2 (after the maintainer has contacted Gutenberg)

- [ ] Add OPDS 2 JSON (`application/opds+json`) to `OPDSClient`, mapping to the same `OPDSFeed` / `OPDSEntry` models. It is one parser per format behind one client, not a second browser.
- [ ] Test it against fixtures of the endpoint Gutenberg grants. Their test endpoint `https://opds-test.pglaf.org/opds/` is not to be used in production without their consent.
- [ ] Switch `builtin.gutenberg` to it before Gutenberg retires the XML feeds in 2027.

---

## Acceptance

- [ ] **Without book sources:** Explore shows 公有書庫 and no switch. Gutenberg can be browsed, searched, read remotely and added to the shelf.
- [ ] **Aozora Bunko** stays hidden until the catalog exists. Once aozora.gr.jp is back and the workflow has published:
  - a work can be found by browsing and by search;
  - it can be added to the shelf, converted, and opened;
  - adding it a second time opens the existing book.
- [ ] **With book sources:** the menu switches modes and the mode survives relaunch. The tip shows once, the next time Explore opens after the first import.
- [ ] **Readers who had sources before this build** still land on 書源.
- [ ] **Gutenberg traffic:** one request per screen the reader opens, one per submitted search, and no background requests. Verify in the simulator's network log.
- [ ] **Hygiene:** all five localizations, VoiceOver labels, `#Preview`s and design-rule checks pass. Every task's tests pass after its last edit.
