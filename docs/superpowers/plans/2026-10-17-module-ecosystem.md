# Module ecosystem: official modules as module files, reading, metadata, repositories — plan

> **For agentic workers:** each step has its own branch, its tests (written first) and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push. The main checkout carries other sessions' uncommitted files: commit only your own (temporary worktree + copy, or `git hash-object`), never `git checkout --` / `git restore` / `git reset --hard`.

Supersedes `2026-10-17-external-catalogs.md` (its external facts and fixtures still hold; its Swift providers, `ProviderType.narou` and dedicated bindings are void).

## Maintainer's decisions (2026-10-17)

The maintainer, verbatim: 「這些 api 和公有書庫都算是官方模塊」「不要再建立出公有書庫了」「我希望可以開發用戶導入自建模塊的生態」. Then, by option:

1. 古騰堡、青空文庫 → 「併進官方模組」: 資源庫 has no 公有書庫 group any more.
2. The four new ones → 「用跟使用者一樣的模組檔」: Bangumi, AniList, openBD, なろう are module files bundled with the app, in the format readers import; whatever they need is added to the format.
3. This round of the ecosystem → 「模組能讀書」「模組能補資料」「模組倉庫」「開發文件＋範例」. Still no JS (Apple 4.7.2, Phase 6).

Still standing from the earlier plan:
- Bangumi and AniList: fill, 統一搜尋, 探索 rows. なろう: searched, ranked, added to the shelf, read by chapter, checked for updates; no R18.
- Each one on by default, with its own switch and a footer saying what is sent to whom.
- openBD and 楽天 Books both; 楽天 waits for the maintainer's Application ID and shows "Supported by Rakuten Developers".

## What this means

- **One format.** An official module is a JSON file in the app bundle that passes the same `RuleModuleValidator` as an import. A test validates every bundled file. A capability an official module needs becomes a format field, documented, and open to every reader's module.
- **No new provider types.** No `ProviderType`, `HomeSectionBinding` or `ItemOpening` per site. Rows are `.module(moduleID, entryID)`, search is `ModuleSearch`, fill is `ModuleFillProvider`, as Phase 6 built them.
- **Gutenberg and 青空文庫 are regrouped, not rewritten.** Their `ProviderType`s, stored keys and code stay; only where 資源庫 and 選擇內容來源 list them changes.
- **Reading never builds a `BookSource`.** That path runs `BookSourceSession` and the JS bridge. A module book is fetched by `RuleModuleClient`, inside the reading pipeline's existing chapter cache, offline download and update check.

## Format gaps, found by writing the four files against the fixtures

| | Gap | Answer |
|---|---|---|
| a | `fill(body, encode: true)` percent-encodes; Bangumi and AniList take a JSON body and would get `%E8…` as the keyword and return nothing | `request.bodyEncoding`: `"form"` (absent: today's behaviour) or `"json"` (JSON string escaping). Stated, never sniffed from Content-Type |
| b | `ModuleProvider.entry` hard-codes `.text`; the fill coordinator takes only `.text` copies | entry-level `contentKind` (`text`/`comic`), and an item rule `contentKind` whose value `comic` makes that item a comic (`$.platform##漫画##comic`, the engine's own `##`) |
| c | one `title` rule; one category; no publisher/ISBN/series | list rules `aliases` (several), `tags` (several), `publisher`, `isbn`, `series` |
| d | fill only by title through `search` | a `lookup` entry: `{{isbn}}`, with `isbnPrefixes` (openBD: `9784`) so other books never leave the device. A lookup by identifier is level A: it may give a cover (from `hosts` only) |
| e | no reading | `book` (detail rules), `toc` (list + `nextPage` rule), `content` (text + `nextPage`). A page with no chapter list is one chapter only when `toc.singleChapter` says how to tell (なろう short story: `.p-novel__body` on the work's own page). Never a fallback for an empty list |
| f | なろう's ranking API needs a Tuesday date | not needed: `novelapi?order=weeklypoint` (checked 2026-10-17, `Fixtures/Narou/narou-api-weekly.json`) |
| g | 楽天's credit | top-level `attribution` (text + link), shown on the module's page and in the footers that name it |
| h | Bangumi's tags carry format words (漫画, 单行本…) and names | `tags` keeps the app's `BookSourceFillProvider.tags` bounds, plus a module's own `excludeTags` list. Raw top tags were the alternative; listed for veto |

Each gap is a field with a validator rule and a test; a module that uses one sets `requiredVersion` to the app version that reads it.

## Guardrails

1. **Reserved ids.** `bangumi`, `anilist`, `openbd`, `narou`, `rakuten-books` (and every later official id) cannot be imported; an import with one is refused by name. Official modules cannot be removed, update with the app, and never show under 匯入的模組.
2. **Switches.** An official module can be turned off on its page (its footer says what it sends to whom). Off means: no rows load, no search part, no fill place. An imported module is removed instead, as today.
3. **Storefront.** Which official modules a storefront hides (Gutenberg and 青空 today, なろう planned) is app-side policy keyed by official id, never a manifest field.
4. **Tests stay offline.** UI tests launch with official modules off (`-official-modules NO`), as `-yd_search_open_library NO` does for Open Library; the tests that want one turn it on and point it at a local fixture host.
5. **Fill changes reach every module.** `ModuleFillProvider` moves from "first match" to "one match or nothing", matches on title and aliases, and skips a summary in another script (Japanese for a copy with no kana). This changes Phase 6h for readers' modules too; listed for veto.
6. **Pacing** stays `SourceRateLimit` via the module's `rateLimit`: Bangumi `1/1000`, AniList `1/2000`, openBD `1/1000`, なろう `1/1000`.
7. **Repository updates never widen silently.** An update that adds a host is listed and asked before it is written, as 6e's 檢查更新 does.

## Steps

- **M1 format core** — gaps a, b, c, g, h: `bodyEncoding`, content kinds, list fields (`aliases`, `tags`, `publisher`, `isbn`, `series`, `contentKind`), `attribution`, `excludeTags`; validator rules; `ModuleProvider.entry` carries kind and tags. Tests from the Bangumi/AniList fixtures through the real client with `OpenLibraryStub`.
- **M2 official modules** — bundled files under `Resources/OfficialModules/`, loaded by `RuleModuleLibrary` beside the store; reserved ids; switch + footer on the module's page; storefront policy; `-official-modules`; 資源庫's 官方模組 lists AI 推薦, 古騰堡, 青空文庫 and the bundled modules, and the 公有書庫 group goes; 選擇內容來源 groups the same way. A test validates every bundled file.
- **M3 Bangumi + AniList** — their files: search, rows (Bangumi 漫画/小说 rank; AniList trending manga/light novel), fill. `ModuleFillProvider` per guardrail 5; the coordinator offers comic copies to modules that list `comic`.
- **M4 lookup + openBD** — gap d; the openBD file. 楽天 as its own file once the Application ID arrives (M4b).
- **M5 reading** — gap e. M5a format + client (`book`/`toc`/`content`, paging, single chapter) on the なろう fixtures. M5b the pipeline: optional `ReadingBook.module` reference (sync-hash rule), a `fetchChapter` branch before browser import, the update check before `refreshOnlineBookMetadata`'s `sourceId` guard, offline download, `SourceLabel`, `SourceRecord.derived`, the item's acquisition (add to shelf, read). M5c the なろう file and a UI test on a local fixture host.
- **M6 repository** — an index file (`{"name", "modules": [{id, title, description, version, url}]}`), subscribe by URL, browse, install through the import sheet and validator, check for updates (asks before widening hosts).
- **M7 docs** — `docs/modules/README.md`: every field, every rule, the validator's refusals, with the bundled files as the examples. A test fails when a format field is missing from the doc.
- **M8 acceptance** — each official module live once, the UI tests, a screenshot of 資源庫, `check_localizations.rb`.

Open question, not blocking: Open Library is the same kind of service as the four. Whether it moves under 官方模組 is asked when the next question comes up.

## What landed

### M1 format core (2026-10-17)

- `request.bodyEncoding` (`form`/`json`); `RuleModuleClient.fill(_:_:encoding:)` escapes a JSON string's contents.
- Entry `contentKind` (`text`/`comic`) and `excludeTags`; list rules `aliases`, `tags`, `publisher`, `isbn`, `series`, `contentKind` (an item's `comic` overrides the entry); top-level `attribution`, shown on the module's page (and the import sheet) as a link.
- A list rule may read a rule in place, `{{$.id}}` / `{{@css:…}}` (`SourceRule.looksLikeRule`, which the engine already evaluates as a rule, never JS); anything else in `{{…}}` is still refused. Needed to build `https://bgm.tv/subject/{{$.id}}` from an id.
- A module that uses any 3.0 field must declare `requiredVersion` ≥ `3.0` (`RuleModuleFormat.version3`), else `.needsRequiredVersion(field:minimum:)`; unknown `contentKind`/`bodyEncoding` values are `.unknownValue`.
- `ModuleProvider.entry` carries the kind, an ISBN as `ExternalIdentifier.isbn13`, and, without a kind rule, the first genre tag as the category.
- Tags (gap h, **for veto**): a `tags` rule's values are one tag each (AniList's "Slice of Life" is not split), at most 24 characters, no digits, at most 5, minus the entry's `excludeTags` **and minus the item's own author, publisher and series** (Bangumi tags 山田鐘人 and 小学館). Raw top tags were the alternative.
- `RuleListItem`'s new fields are Optional, so pages cached before them still decode.
- Tests: `RuleModuleFormatTests/format3`, `ModuleProviderTests/jsonBody`, `bangumi` (the saved Bangumi reply through the real client: body, comic kind, aliases, tags, work URL), `kindsAndISBN`. Module suites 72/72.

### M2a official modules: loading, reserved ids, 資源庫 cards (2026-10-17)

M2 is split: LibraryTabRoot, HomeContentSourcePicker, ExploreHome and BookSearchView carry another session's uncommitted tab-bar work in the main checkout, so moving 古騰堡／青空文庫 into 官方模組 (M2b) waits until that lands.

- `OfficialRuleModules`: bundled `Resources/Assets/official-module-<id>.json`, validated by `RuleModuleValidator` at the running app's version; a file whose id is not reserved or does not match its name is logged and left out. Reserved ids: `bangumi`, `anilist`, `openbd`, `narou`, `rakuten-books`.
- `RuleModuleLibrary.modules` is now the official modules this storefront has, then the imported ones, so rows, search, fill, a section's form and 選擇內容來源 take them with no change of their own; `imported` feeds 匯入的模組, `official` feeds 官方模組 (cards after AI 推薦, sharing `RuleModuleCard`). なろう is left out in CHN (`OfficialRuleModules.isAvailable`, app policy).
- **No per-module master switch** (guardrail 2 revised): an official module is turned off where any module is — 搜尋來源 and 資料來源 already list every module with its own check, and rows exist only when added. Its page says so in a footer instead of 訂閱網址／移除模組.
- An import with a reserved id is refused (`RuleModuleStoreError.reservedID`) in the import sheet and in the store. An official module's page cache lives under the store's hidden `.official/<id>/cache`, which `list()` skips.
- `-no-official-modules` / `-official-modules-dir <path>` (DEBUG); the four UI test files that send searches launch with the first.
- Tests: `OfficialRuleModulesTests` (5), and the module suites, 72/72.

### M3 Bangumi + AniList (2026-10-17)

- `Resources/Assets/official-module-bangumi.json`: search (POST JSON, `nsfw:false`), 漫畫排行 (`cat=1001`) and 小說排行 (`cat=1002`, checked live), both `series=true&sort=rank`, 20 a page, a day's cache. Title `name_cn||name`, aliases `name` + 别名, author 原作 before 作者 (ベルセルク's 作者 is a sentence), tags with `excludeTags` for format words. Sends `User-Agent: yuedureader/Yuedu (iOS) (+https://yuedureader.com/support)` as Bangumi asks; `1/1000`.
- `official-module-anilist.json`: GraphQL search (keyword as a variable, `isAdult:false`), 熱門漫畫 (`MANGA,ONE_SHOT`) and 熱門輕小說 (`NOVEL`) by `TRENDING_DESC`, page paging, 6 h cache. AniList is read as an English catalog: title `english||romaji`, author the first staff's full name, genres as tags, `native`/`romaji`/synonyms as aliases; `1/2000`.
- Format 3.0 `localizations` (`{lang: {title, description, entries: {id: {title, description}}}}`): applied by `RuleModuleLibrary` in the app's language (`Bundle.main.preferredLocalizations`), only from a localization of the same language **and script** — `zh-Hans` never stands in for `zh-Hant`. The validator refuses a non-tag key or an entry id the module lacks. Both official files carry zh-Hans, en, ja, ko (zh-Hant is the file's own).
- Fill (guardrail 5, **for veto**): `ModuleFillProvider` now reads the search's raw items (`ModuleProvider.searchItems`), so a summary is whole, not a row's 300-character blurb; it fills only when **exactly one** item is the copy's work (title or alias, compatible author, same kind); a summary in another script, or a Japanese one for a copy with no kana, is dropped; tags keep the title's script. Its tags are now every genre the item names (was the first category).
- Comics: `MetadataFillQuery`/`Candidate.contentKind`; the coordinator offers comic copies; Open Library and 來源配置 still take text only; a module takes a comic when its search can list one (entry `contentKind` or an item rule).
- UI tests: every launch passes `-no-official-modules` (guardrail 4); the official modules otherwise fill the fixture shelf from bgm.tv.
- Tests: `OfficialModuleFilesTests` (both files through the real client from saved replies, the fill rule, kinds, localizations), `MetadataFillOrderTests/moduleFills` (two same works → nothing).

### M2b 古騰堡、青空文庫 into 官方模組 (2026-10-17)

- 資源庫: the 公有書庫 group is gone; 官方模組 comes first (where 公有書庫 was) and lists AI 推薦, 古騰堡, 青空文庫, then the bundled modules. The tiles keep `library.public.<id>`, their pages and storefront hiding.
- 選擇內容來源: 書庫 holds only the reader's connections (and is left out without one); 官方模組 holds AI 推薦's rows, 古騰堡, 青空文庫 and the bundled modules; 模組 the imported ones.
- `LibraryTabUITests` (grid: AI 推薦 beside 古騰堡, 青空文庫 below; no 公有書庫 header), `HomeEditorUITests/testAddSections`: 3/3.

### M4 lookup + openBD (2026-10-17)

- Format 3.0 `lookup` (an entry asked by `{{isbn}}`, an ISBN-13) with `isbnPrefixes` (digits; only on a lookup). The validator needs `{{isbn}}` in its url or body and a `list.isbn` rule: the record whose own ISBN is the one asked is the copy's. A module may have only a lookup (no rows, no search).
- `ModuleFillProvider` is level A when its module has a lookup: by ISBN it gives a cover (`RuleModuleClient.image`: the module's hosts only, its `rateLimit`, a 404 or a non-image is no cover; saved as `module-<id>-<isbn>.jpg`), description, tags, publisher and series. Then, for what is still missing, the module's search by title as before (level B values only). **Disclosed:** that second question is the module's own search, asked only for the fields the record did not give; not a retry of the lookup.
- `official-module-openbd.json`: `api.openbd.jp/v1/get?isbn=`, prefixes `9784`, long description (ONIX 03) before the short (02), publisher; `cover.openbd.jp`; `1/1000`. Series is not read: openBD's `summary.series` is the imprint (カドカワBOOKS).
- 匯入/模組頁 lists 以 ISBN 查詢; the hosts footer says ISBNs are sent when a module has a lookup.
- Risk to watch: openBD announced v1's end in 2023 (successor promised) and still answers.
- Tests: `OfficialModuleFilesTests/openBDLookup`, `openBDBounds`, `lookupRules`, `lookupFills`; module and fill suites 74/74 + format 2/2.
