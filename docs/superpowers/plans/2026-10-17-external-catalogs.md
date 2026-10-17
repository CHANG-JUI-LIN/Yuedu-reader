# External catalogs: Bangumi, AniList, openBD, 小説家になろう — plan

> **Superseded 2026-10-17** by `2026-10-17-module-ecosystem.md`: the maintainer made these official modules, written as module files. The external facts below still hold; the Swift providers, `ProviderType.narou` and the dedicated bindings are void.

> **For agentic workers:** each step has its own branch, its tests (written first) and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push. The main checkout carries other sessions' uncommitted files: commit only your own (temporary worktree + copy, or `git hash-object`), never `git checkout --` / `git restore` / `git reset --hard`.

**Goal:** four outside catalogs join the paths that already exist.
- Bangumi and AniList fill empty fields of shelf books (manga too), appear in 統一搜尋, and give 探索 rows.
- openBD fills Japanese books by ISBN.
- 小説家になろう is read in the app: searched, ranked, added to the shelf, read chapter by chapter, and checked for new chapters.

**Not in this plan:**
- sign-in to any of them (Bangumi collections, AniList lists);
- R18 (ノクターン／ムーンライト);
- MangaDex (its terms forbid paid apps; Yuedu has Pro);
- カクヨム (no API);
- a second metadata or search pipeline.

## Maintainer's decisions (2026-10-17, by option)

1. Bangumi 和 AniList 用在哪 → 「自動補資料」「統一搜尋」「探索首頁欄目」（三個都選）
2. なろう 接成什麼 → 「在 App 裡直接讀」：搜尋、排行、加書架、按章節線上讀、追更新；不含 R18
3. 預設 → 「預設開＋說明」：each has its own switch, and a footer names what is sent to whom

Answer 2 is the maintainer's call on design §17 item 4 (built-in web-novel parsing waits for a terms review) for なろう only. What the terms review found, 2026-10-17:
- the API needs no key and has no usage cap today;
- results must be refreshed or dropped within two weeks;
- R18 lives on a separate API;
- chapter text is not in the API, so it is read from `ncode.syosetu.com` pages, paced;
- several unofficial なろう readers are on the App Store.

## External facts (checked 2026-10-17)

| | Endpoint | Auth | Limit | Terms that bind us |
|---|---|---|---|---|
| Bangumi | `api.bgm.tv/v0` | none to read | not published | The UA must name the developer and the app, and default library UAs may be blocked. |
| AniList | `graphql.anilist.co` | none to read | 90/min, **degraded to 30/min** | Free under US$150/month revenue; above that a commercial licence is needed. No bulk collection. |
| openBD | `api.openbd.jp/v1/get?isbn=` | none | built for bulk | **v1 end of service was announced 2023-07-25**, and it still answers today (probed). Use is limited to introducing books; data is not altered, and removals are honoured. |
| なろう | `api.syosetu.com/novelapi/api/`, `/rank/rankget/` | none | none today | Cache at most 2 weeks. Data lags up to 2 h. |

Pacing (`RequestPacer`, the terms' rate, not a settle-wait):
- Bangumi: 1 request a second.
- AniList: 1 request every 2 s (30/min).
- openBD: 1 request a second.
- なろう API: 1 request a second.
- なろう pages: 1 request a second.

The User-Agent is `RemoteLibraryHTTPClient.userAgent`. Bangumi's adds the developer id: `yuedureader/Yuedu/<version> (iOS) (+https://yuedureader.com/support)`.

## Settled here (each changeable on the maintainer's word)

- **Identity.** Bangumi and AniList are `SourceInstanceKey(type: .bibliographic, id: "bangumi" / "anilist")`, beside Open Library's `"openlibrary"`. They are data only: `ItemOpening.bibliographic`, 「只有資料」, 尋找可用來源. なろう is a new `ProviderType.narou`, a public library like Aozora: readable, and hidden in the CHN storefront (`PublicLibraryAvailability`) as the other public libraries are.
- **New identifier schemes.** `.bangumi` and `.aniList` are value-only: not merging, because a B-grade title match must not merge works. `.ncode` is merging, since an N-code is the work. Each is added in `SourceRecord`, normalisation and `WorkIndex.mergingSchemes` as that rule says.
- **Fill grades.**
  - openBD is **A**: by ISBN, so it may give a cover and identifiers.
  - Bangumi and AniList are **B**: by title, with author compatibility when both sides have one. So no cover and no identifiers, under the runner's existing rule.
  - The fields are intro, tags and series; for openBD, cover, intro and publisher.
  - The existing `WritingScript` filter keeps a value only in the copy's own script. AniList's English intro therefore fills English copies only, and Bangumi's Chinese intro fills CJK copies.
- **Manga gets filled.** The coordinator asks only `.text` copies today (`MetadataFillCoordinator.swift:189`). A provider now declares the content kinds it answers:
  - Open Library, openBD and book sources: `.text`;
  - Bangumi and AniList: `.text` and `.comic`.
  - The coordinator asks a copy only of the providers that take its kind.
- **Fill order.** The new places join `MetadataFillPlace.builtIn` at the end, checked: `openLibrary, bookSources, openBD, bangumi, aniList`. Existing orders gain them appended, checked (the store's existing rule for new built-ins).
- **Search.** `LibrarySearchModel.openLibrary()` becomes the one bibliographic model, holding Open Library, Bangumi and AniList. Each is a `SearchAnswering` with its own `GlobalSettings` switch (default on). The 搜尋來源 footer names all three instead of Open Library alone (5 languages).
  - なろう search is readable. It is sent on submit, and it is a public-library part of the same unified feed, its rows kind `.publicLibrary`.
- **探索 rows.** New `HomeSectionBinding` cases, each served by its provider's `HomeSectionProviding`:
  - `.bangumiRank(category:)`: 漫畫 or 小說, Bangumi rank order;
  - `.aniListTrending(format:)`: manga or light novel;
  - `.narouRank(period:)`: 日間, 週間, 月間 or 四半期;
  - `.narouNew`: newest updated.
  - They are offered in the 欄目 picker. Bangumi and AniList are bibliographic, so their rows open 作品詳情 with 只有資料.
- **資源庫.** なろう gets a card under 公有書庫, beside 古騰堡 and 青空文庫. Its 範圍 page holds its own rows (decision 35). Bangumi and AniList get no card; they are data, reached from 搜尋 and the picker.
- **なろう reading is a new branch of the one online pipeline, not a `BookSource`.**
  - A bundled rule source would show in 來源配置 and run scraping through the rule engine.
  - Instead, `ReadingBook.narou: NarouBookReference?` (Optional, so the sync hash of existing books is unchanged) holds the N-code. `onlineChapters` hold the episode URLs.
  - Then, in each place:
    - `ChapterFetchManager.fetchChapter` gets a third branch, `book.narou`, which calls `NarouClient.chapter`.
    - `BookStore.refreshOnlineBookMetadata` gets a branch that refetches the table of contents and sets `hasNewChapterUpdate`.
    - `SourceRecord.derived` keys it `(.narou, ncode)`.
    - Offline download follows `fetchChapter` and needs nothing else.
  - The table of contents comes from `ncode.syosetu.com/<ncode>/?p=N` (100 episodes a page); an episode from `ncode.syosetu.com/<ncode>/<n>/`. A short story (`novel_type 2`) is one chapter at `ncode.syosetu.com/<ncode>/`.
  - An empty parse is an error, logged with the URL. It is never a silent empty chapter.

## Guardrails (advisor review, 2026-10-17)

1. **Tests stay off the network.**
   - Every new default-on switch reads `object(forKey:) == nil || bool(forKey:)`, so its launch argument `NO` works.
   - Each switch's `NO` argument goes everywhere `-yd_search_open_library NO` appears today.
   - Unit tests that build the bibliographic model stub every part.
   - Before E1, find how UI tests keep the launch-time fill off the network, and extend that to the new places.
2. **なろう's `bookSourceId` is nil, so every nil check routes it as a browser import unless the なろう check comes first.** Each of these gets a test:
   - `fetchChapter` must check なろう before `fetchBrowserImportedChapter`.
   - `refreshOnlineBookMetadata` must check なろう before its `guard let sourceId`.
   - `SourceLabel` must not call it 網頁匯入.
   - `OfflineDownloadManager.hasBookSource` and `OnlineChapterCacheWritePolicy` must not apply the no-source rules to it.
   - `SourceRecord.derived` must key it as なろう before the copy-key fallback.
3. **Parsers are written from saved live responses, not from memory.** Save one real response of each as a fixture before writing its parser:
   - Bangumi search;
   - Bangumi subject;
   - AniList media;
   - openBD;
   - なろう API;
   - なろう ranking;
   - なろう TOC, page 1 and page 2;
   - なろう episode;
   - なろう short story.
4. **B-grade precision.**
   - Fill only on an exact `WorkMatchKey` match of `name` or `name_cn` (AniList: romaji, english, native).
   - When more than one result matches, fill nothing.
   - Author compatibility needs Bangumi's subject detail, a second request; E2 decides it from measured cost.
   - `WritingScript` counts kana as CJK, so a Japanese Bangumi summary could fill a Chinese copy. Add a kana check, or record it in What landed for the maintainer to veto.
5. **`ReadingBook.narou`** goes through the hand-written Codable: CodingKeys, `decodeIfPresent`, encode. A test shows an existing book's sync hash is unchanged. Check how `ProviderType` and `HomeSectionBinding` decode an unknown case for older builds that receive synced data.

## Steps

Each step: tests first (URLProtocol stubs, as `OpenLibraryStub`), the smallest relevant regression, merge `--no-ff`.

- **E1 openBD fill.** `OpenBDFillProvider` (A, `.text`, ISBN), the `MetadataFillPlace.openBD` place with its toggle and its name in `FilledMetadata.providerName`, and `RequestPacer.openBD`. The 5-language name stays 「openBD」.
- **E2 Content kinds + Bangumi fill.**
  - The provider protocol gains `contentKinds`, and the coordinator asks `.comic` copies too.
  - `BangumiClient` handles search with type 1 (書籍) and subject detail.
  - `BangumiFillProvider` is B grade.
  - Its place and name are added.
- **E3 AniList fill.** `AniListClient` (GraphQL, 30/min) and `AniListFillProvider` (B), with its place and name.
- **E4 Search.** `BangumiSearch` and `AniListSearch` (`SearchAnswering`), the bibliographic model holding three parts, the `searchBangumi` and `searchAniList` switches with their footer, and the 「只有資料」 rows. Resolver tests check that they merge with Open Library and with shelf copies by WorkMatchKey.
- **E5 探索 rows for Bangumi and AniList.** `BangumiProvider` and `AniListProvider` (`SourceProvider` + `HomeSectionProviding`), the bindings with hand-written Codable round-trip, the picker entries and titles, and `ProviderManifest` hosts and rate.
- **E6 なろう catalog.** `NarouClient` (API, ranking, TOC page, episode page; SwiftSoup), `NarouProvider` (`CollectionBrowsing` + `HomeSectionProviding`), `ProviderType.narou` (every exhaustive switch the map lists), `ItemOpening.narou(NarouWork)`, the 資源庫 card and 範圍 page, and search on submit.
- **E7 なろう reading.** `ReadingBook.narou`, 加入書架 and 閱讀 from 作品詳情, the `fetchChapter` and update-check branches, and the `SourceRecord` key. Tests cover a 3-episode stub book through to its chapters, a new episode setting `hasNewChapterUpdate`, a short story, and an empty parse being an error.
- **E8 Acceptance.**
  - A live check of each API against the real servers, one request each, with timings.
  - A UI test: 搜尋 shows Bangumi/AniList rows as 只有資料, and a なろう row opens 作品詳情 → 閱讀 → chapter 1 renders.
  - One screenshot.
  - Then `ruby scripts/check_localizations.rb`.

## What landed

(empty)
