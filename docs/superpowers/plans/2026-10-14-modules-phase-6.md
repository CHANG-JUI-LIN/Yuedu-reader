# Unified library, Phase 6: modules — plan

> **For agentic workers:** each step has its own branch, its tests (written first) and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push.

**Goal:** every content source the app knows describes itself the same way (a manifest), and the reader can add **模組**: rule-only files, no JavaScript. A module puts rows on the Explore home and answers 搜索, through the app's own rule engine and network stack.

**Design:** `Technotes/UnifiedLibrary-2026-10-08-design.md`:

- §14.2: the four steps, list presentation, format, install and update.
- §11.1 and §11.4: App Store 2.5.2 / 4.7, and why rule-only modules are the lowest risk.
- §11.2: Forward's `WidgetMetadata`.
- §13.2: Rex's 選擇內容來源.
- §17 item 11: no third-party JavaScript until Apple grants 4.7.2.

**Not in this phase:**

- **JavaScript modules** (step 4; §17 item 11).
- **「AI 推薦」 as an official module.** The maintainer decided on 2026-10-14 that it gets its own plan.
- **Module metadata in Phase 3's automatic filler.** 6h asks first. The filler is on by default and would send every shelf title to a third-party host.
- **Merging the book-source runtime into modules.** A 來源配置 keeps running through `BookSourceSession`, unchanged.
- **Reading from a module.** It has no table of contents and no chapter rules in v1, so its items are data only (6d).

## Maintainer's decisions (2026-10-14, by option)

1. 宣告式規則模組的格式 → 「新格式，頂層照 Forward（推薦）」
2. AI 推薦 → 「先不做，另開計畫（推薦）」
3. 模組放哪、怎麼上線 → 「資源庫加一組，直接上線」
4. 介面名稱 → 「模組（推薦）」

How these fit together:

- **The format is Yuedu's own; only the top level follows Forward.**
  - The top-level fields are `id`, `title`, `description`, `author`, `site`, `version`, `requiredVersion`, `modules[]`, and an optional `search`.
  - Parameters use Forward's names and types: `input`, `count`, `constant`, `enumeration`, `page`, `offset`.
  - Where Forward has a JS function, each entry carries a declarative `request` and `list` instead (6c).
- **No experimental toggle.** It ships when 6e lands. §11.4's open question about App Store review of downloaded rules stays open; the maintainer chose to ship.
- **In 資源庫, a new group 模組** sits beside 公有書庫, 遠端書庫, 來源配置 and 訂閱. It follows Rex:
  - two groups, 官方模組 and 匯入的模組;
  - each row shows the name, description, version and author;
  - 官方模組 is hidden while the app ships none.

## Settled here (each changeable on the maintainer's word)

- **One owner per fact (6a).** A provider's manifest is computed from what the provider already knows: `instance`, `displayName`, `availability`, `capabilities()`, its client's hosts. It is never a second stored copy.
  - `SectionLoadPolicy` stays **per section**. This is the 5b decision; Gutenberg's bundled lists and its feeds load differently.
  - The manifest says which capabilities a provider has, not how each section loads.
- **Book sources at 50,000 (6b).** A source's manifest is derived on demand, off the main actor, and never stored per source. Measure it with a `SourcePerfTrace` span over 50,000 sources and report the time.
  - Search does not go through the registry; Phase 4 kept the two fan-outs apart on purpose.
- **A module never reaches the JavaScript bridge.** It runs on a bare `ModernRuleEngine` (`jsEvaluator = nil`, as `LegadoRSSScraper` builds one) and never goes through `BookSourceSession`.
  - This is a second rule-evaluation entry point, deliberately. CLAUDE.md's "all online parsing goes through `BookSourceSession`" is about reusing a source's JS bridge, and a module has none.
  - The list-to-fields mapping (`ModernParserBridge.parseSearchResults` / `parseExploreResults`, about 30 lines) is extracted into one shared helper used by both, so there is still one mapping path (6c).
- **The validator rejects at import, not at run time.** It rejects:
  - `@js:` / `<js>` segments (`SourceRule.mode == .js`);
  - any `{{…}}` that is not a declared parameter or `page` / `offset` / `keyword`;
  - `@get` / `@put` (v1 has no variables);
  - a request host outside the module's `hosts`;
  - `requiredVersion` above the running app's version;
  - a file over 256 KB or over 50 entries.

  JS segments otherwise just yield nil silently, so every rejection names the field and the reason.
- **Network:**
  - `WebFetcher` with `safeURL` applied before every request. `WebFetcher` does not apply it itself, and today's URL imports skip it too.
  - `SourceRateLimit.run(rate:key:)` keyed by the module id, with the module's optional `rateLimit` (`"N"` or `"N/ms"`, Legado's syntax).
  - The host allowlist is checked again on every request, against redirects.
  - Installing and updating fetch the module file through the same path.
- **Items are data only (6d).** A module row opens 作品詳情 with the summary it listed and 尋找可用來源 (7b-2), like an Open Library result (`ItemOpening.bibliographic`).
  - `ProviderType` gains `.module`, so a record's `SourceInstanceKey` names the module.
- **Storage:**
  - `Application Support/Modules/<file-safe id>/module.json`, plus `cache/` for pages kept for `cacheDuration`.
  - Removing a module deletes its folder, as §14.2 says of Forward's `Widget.storage`.
  - The subscription URL is kept beside it for 檢查更新.
- **Install and update:**
  - **Install:** by URL, by file, or from a `yuedu://module?src=` link. The link uses the same parser as the book-source deep link.
  - **Update** happens only on 檢查更新 in the module's page. It accepts a newer `version` (numeric dot comparison) and otherwise reports 已是最新版本.
  - Nothing updates by itself.
- **Disclaimer:** adding a module asks for the same acceptance as adding a 來源配置 (`sourceDisclaimerAccepted`), through the same gate.
- **iOS 17:** every importer launched from a menu goes through `DismissalSequencedActionChooser` (`Technotes/iOS17MenuModalPresentation.md`), as 資源庫's ••• already does. The module page is pushed, never a sheet (the 來源配置 rule).

## Format (6c)

```json
{
  "id": "example.newbooks",
  "title": "新書速報",
  "description": "某書店的新書與排行。",
  "author": "someone",
  "site": "https://example.com",
  "version": "1.0.0",
  "requiredVersion": "2.0",
  "hosts": ["example.com", "img.example.com"],
  "rateLimit": "2/1000",
  "modules": [
    {
      "id": "new",
      "title": "新書",
      "description": "每週新書",
      "cacheDuration": 3600,
      "params": [
        { "name": "category", "title": "分類", "type": "enumeration", "value": "novel",
          "enumOptions": [{ "title": "小說", "value": "novel" }, { "title": "漫畫", "value": "comic" }] },
        { "name": "page", "title": "頁", "type": "page" }
      ],
      "request": { "url": "https://example.com/new/{{category}}?p={{page}}", "method": "GET", "headers": {}, "charset": "utf-8" },
      "list": { "items": ".book-list li", "title": "h3@text", "author": ".author@text", "cover": "img@src",
                "intro": ".desc@text", "url": "a@href", "kind": ".tag@text", "language": "" }
    }
  ],
  "search": {
    "title": "搜尋",
    "request": { "url": "https://example.com/search?q={{keyword}}&p={{page}}" },
    "list": { "items": "$.data[*]", "title": "$.name", "author": "$.author", "cover": "$.cover", "url": "$.link" }
  }
}
```

- Rule strings are the rule engine's own syntax: CSS (`@css:` or the default), XPath, JSONPath, Regex, with `||` / `&&` / `%%` / `##`.
- A summary is bounded by `WorkSummary`'s limits. `intro` and `kind` are plain text, as `OPDSClient.plainMetadata` makes them.
- Parameter types:
  - `input`: typed by the reader in the section editor.
  - `count`: a number.
  - `constant`: fixed.
  - `enumeration`: picked.
  - `page` / `offset`: filled by paging.

## Steps

### 6a: manifests for the built-in providers (no behaviour change)

- `ProviderManifest`:
  - `instance`, `type`, `displayName`;
  - `capabilities: Set<ProviderCapability>` (`browse`, `homeSections`, `search(CollectionSearchSupport)`, `metadata`, `reading`);
  - `hosts: [String]`, `rateLimit: String?`, `regions`, the last from `availability`.
- A `manifest` on `SourceProvider`, computed from what each provider already holds: the shelf, OPDS/Calibre, WebDAV, Gutenberg, 青空, subscriptions, 為你推薦, Open Library.
- `SourceProviderRegistry.manifests(shelf:)`.
- **Tests first:** characterize `browsableProviders` and `homeProviders` (order, region filtering, Gutenberg still found by id in China), then each provider's manifest.

### 6b: 來源配置 described by the same manifest

- `BookSourceManifest.derive(_:)` derives capabilities from the source's rules:
  - search rule → `search(.onSubmit)`;
  - explore rule → `homeSections`;
  - book-info rule → `metadata`;
  - TOC + content rules → `reading`.
- `hosts` comes from `bookSourceUrl` and `rateLimit` from `concurrentRate`.
- The registry lists sources through it on demand, off the main actor.
- **Measure:** `works.registry.sourceManifests` over 50,000 synthetic sources, reported in ms.
- **Tests:** derivation for rule combinations, empty rules, a source with only `exploreUrl`; the 50k measurement.

### 6c: the module format, validator and store (no UI)

- **`RuleModule`** (Codable), `RuleModule.Entry`, `RuleModule.Param`, `RuleModule.Request`, `RuleModule.ListRules`. Unknown keys are kept, so a newer file round-trips.
- **`RuleModuleValidator`:** every rejection above, each with a typed reason that the import sheet shows.
- **`RuleModuleStore`** (`Application Support/Modules/`): install, replace on update, remove (deletes the folder), list.
  - Writes are atomic.
  - A corrupt file is reported and skipped, never overwritten.
- **Extract the shared list mapping:** `RuleListMapping.items(engine:list:baseURL:)`, used by `ModernParserBridge.parseSearchResults` / `parseExploreResults` and by modules.
  - Book-source behaviour must not change: run the existing search and explore parsing tests before and after.
- **Tests:**
  - decoding (the example above, unknown keys);
  - the validator, one case per rejection, plus a clean module;
  - the store (install, update, remove clears, corrupt file);
  - the mapping helper over the same HTML and JSON fixtures as the bridge tests.

### 6d: the module provider (no UI)

- `ModuleProvider: CollectionBrowsing, HomeSectionProviding`:
  - an entry's page is `request` → `WebFetcher` (+ `safeURL`, host check, `SourceRateLimit`) → bare `ModernRuleEngine` → `RuleListMapping` → `CollectionEntry.item(record, summary, .bibliographic)`;
  - pages are cached per entry and parameters for `cacheDuration`;
  - failures are `SourceFailure`: `rejected(status)`, `parse`, `invalidAddress` (host or `safeURL`), `network`, all logged through `AppLogger`;
  - an empty page is not a failure.
- `ProviderType.module`, `SourceInstanceKey(type: .module, id:)`.
- `HomeSectionBinding.module(moduleID:entryID:params:)` with its own `type` key, `.parallel` (one lane per module through `SourceRateLimit`).
- **Tests** (URLProtocol fixtures):
  - an HTML entry and a JSON entry;
  - paging by `page` and by `offset`;
  - a redirect to an undeclared host is refused;
  - a 403 is `failed`, not `empty`;
  - an empty list is `empty`;
  - the cache answers within `cacheDuration`.

### 6e: 資源庫 「模組」 (UI)

- **The new group** shows 官方模組 when there are any, then 匯入的模組. Rows use the 資源庫 card style (memory: 參考圖卡片, never `List`): name, description, version, author.
- **••• → 新增模組:** 從網址, 從檔案, 從剪貼簿, sequenced on iOS 17. The import sheet shows the manifest (name, author, version, site, hosts, entries) and any validator rejection before anything is written.
- **The module's page** (pushed):
  - its entries with their descriptions;
  - its hosts;
  - the subscription URL;
  - 檢查更新;
  - 移除模組 (a confirmation dialog; it clears the module's storage).
- Every string goes through `localized`, in all five languages. VoiceOver labels go on each row and button.
- Add `#Preview`s: an empty group, two modules, the page, the import sheet with a rejection.
- **Tests:**
  - unit tests for the import model (preview, then commit, then rejection);
  - a UI test on iOS 27 and iOS 17.5: add from a fixture URL, the row appears, the page lists the entries, remove.

### 6f: modules in 選擇內容來源 (UI)

- `HomeContentSourcePicker` gains a group 模組 → module → its entries (checkmark on the current one), as in Rex.
- The section form shows the entry's parameters (`enumeration` as a `Picker`, `input` as a text field, `count` as a `Stepper`). It does not show `constant`, `page` or `offset`.
- The live preview (decision 34) loads the module's real first page.
- **Tests:**
  - binding round-trip;
  - the picker lists installed modules;
  - a removed module's section shows the provider-removed state, the same as a removed connection;
  - a UI test adding a module row to the home.

### 6g: modules in 搜索

- A module with `search` takes part in Phase 4's unified search **on submit**: a participant beside the OPDS/Calibre one, with its own timeout and a status line on failure.
- Its results are data-only members of a work. They go through `SearchWorkResolver`, so they merge with the same work from elsewhere.
- **Tests:**
  - the participant's outcomes (results, empty, failed);
  - a module result merges with a shelf copy of the same work;
  - no request is sent before submit.

### 6h: module metadata (asked before starting)

- Whether a module's `metadata` entry may feed Phase 3's automatic filler. That filler would send shelf titles to the module's hosts without the reader acting.
- The options to ask: never; only when the reader asks for it in a work's page; or automatically with a per-module switch.

## Acceptance

- **Built-in providers:** each has a manifest equal to what it reports today. `browsableProviders` and `homeProviders` are unchanged (characterization tests).
- **50,000 來源配置:** manifests derived off the main actor, time reported.
- **A fixture module**, added by URL on iOS 27 and on iOS 17.5:
  - it appears in 資源庫;
  - its entry fills a home row;
  - its search answers 搜索 on submit;
  - removing it clears its folder and its row shows the removed state.
- **A module containing `@js:`** is refused at import with the reason shown, and nothing is written.
- **Requests:** none go to a host outside `hosts`, and none before the reader acts (home row on screen, or submit).
- **Book-source search and explore parsing** unchanged across 6c's extraction (the existing parsing tests).
- **Checks:** `ruby scripts/check_localizations.rb`; VoiceOver labels checked on the new screens (`docs/design.md` §7).

## What landed

### 6a (branch `modules/6a-manifest`)

- **`ProviderManifest`** (`Modules/Services/Works/ProviderManifest.swift`): instance, display name, availability, capabilities, hosts, rate limit.
  - It is computed by `SourceProvider.manifest()` from what the provider already reports: `CollectionBrowsing` gives `.browse` and its `capabilities().search` (left out when `.none`), and `HomeSectionProviding` gives `.homeSections`.
  - Nothing is stored. `SectionLoadPolicy` stays per section.
- **`SourceProvider`** gains three requirements:
  - `hosts` is explicit in every provider, so none can forget it:
    - shelf, 訂閱 and 為你推薦: none (on-device or already fetched);
    - OPDS / Calibre / Gutenberg: their root's host;
    - WebDAV: its normalized root's host;
    - 青空文庫: the catalog's host, then `AozoraLibraryDownloadService.host` (the download guard now reads the same constant);
    - a 來源配置: its `bookSourceUrl`'s host.
  - `additionalCapabilities` and `rateLimit` default to none; 6b fills them for 來源配置.
- **`SourceProviderRegistry.manifests(shelf:)`** lists the browsable providers' manifests in their order.
- **Tests:** `ProviderManifestTests` (4):
  - `browsableProviders` and `homeProviders` pinned: their order, the region gate, Gutenberg still found by id in China, a source without an explore rule absent from the home;
  - every built-in manifest;
  - 訂閱 / 為你推薦.

  These pass with `SourceProviderRegistryTests`, `OPDSProviderTests`, `WebDAVProviderTests`, `AozoraProviderTests`, `ShelfProviderTests` and `AozoraLibraryDownloadServiceTests`: 23/23 on iOS 27. The `HomeModelTests` / `ForYouMeasurementTests` fakes declare `hosts`.

### 6b (branch `modules/6b-source-manifests`)

- **`BookSourceManifest`** (`Modules/Services/Works/BookSourceManifest.swift`, nonisolated) derives a 來源配置's capabilities from its rules. Whitespace is no rule.
  - `searchUrl` gives `search(.onSubmit)`.
  - `exploreUrl` gives `homeSections`.
  - Any book-info rule (name, author, cover, intro, kind, tocUrl) gives `metadata`.
  - `ruleToc.chapterList` together with `ruleContent.content` gives `reading`.
  - `hosts` comes from `cleanedBookSourceURL`, so the `#` comment is dropped.
  - `rateLimit` is `concurrentRate`, or nil when it is empty or `0`.
- **`BookSourceProvider`** reports its hosts, extra capabilities and rate through the same functions, so the Explore home's provider of a source and the registry agree.
- **`SourceProviderRegistry.sourceManifests(in:)`** lists the enabled sources in the library's order, derived off the main actor. The span is `works.registry.sourceManifests`.
  - Nothing is stored per source.
  - Search does not go through it.
- **Measured** (Debug, iOS 27 simulator): 50,000 sources in **111 ms**, off the main actor.
- **Tests:** `BookSourceManifestTests` (5): capabilities per rule and whitespace; hosts and rate; the home provider agrees; the registry skips disabled sources; the 50k measurement. These pass with `ProviderManifestTests`: 9/9 on iOS 27.

### 6c (branch `modules/6c-format`)

- **`RuleListMapping`** (`Modules/Core/RuleEngine/ModernParser/RuleListMapping.swift`) reads one list's items with `RuleListFields`: name, author, url, cover, intro, word count, last chapter and kind.
  - `ModernParserBridge.parseSearchResults` and `parseExploreResults` both read through it, so there is one mapping path. `OnlineBook(_:source:)` builds the 來源配置 result, with an empty `tocUrl` as before.
  - **One order change:** explore now reads `author` right after `name`, where it used to come after `bookUrl` and the cover. This is visible only to a rule with JS side effects across fields. Search's order and its early filter are unchanged.
  - `parseSearchResults` no longer parses the page twice; its first `setContent` was redundant.
- **`RuleModule`** (`Modules/Services/RuleModules/RuleModule.swift`) holds the format above.
  - A parameter's numeric `value` reads as its text.
  - `params` may be left out.
  - The search entry has no `id`.
  - Unknown keys survive because the store keeps the bytes as imported.
  - `RuleModuleVersion` compares numeric dot versions; missing parts count as zero.
- **`RuleModuleValidator`** throws a typed `RuleModuleRejection` that names the field. It rejects:
  - over 256 KB, over 50 entries, or no entry at all;
  - not JSON, or a missing or mistyped field (from the decoding path);
  - an id that is not file-safe, or a duplicate entry id;
  - a non-numeric `version` or `requiredVersion`, or a `requiredVersion` above the running app's;
  - `@js:` / `<js>`, judged by the engine's own `splitSourceRule`, so the two never disagree;
  - `@get` / `@put`;
  - a `{{…}}` that is not declared. In a request that means a parameter, `page` / `offset`, or `keyword` on search only. A list rule declares nothing.
  - an unknown parameter type, or an enumeration without options;
  - a method other than GET / POST;
  - a request URL that is not http(s), whose host is built from a parameter, or whose host is not listed in `hosts`. Hosts compare case-insensitively, and the port is not part of the host.
  - **Legado's `url,{…}` option tail** (`webView`, `js`, …), via `.urlOptions`. The module states its method, body, headers and charset in their own fields. A template after a comma is filled before Legado would split, so it is not a tail. **For 6d:** the request is built from the module's own fields and never goes through `AnalyzeUrl`'s option parsing.
- **Example changed:** its `requiredVersion` was lowered from `3.0` to `2.0`. The app is `2.0.8` (`xcconfig/Yuedu-reader_version.xcconfig`), so the shipping validator rejected the documented example. A test validates it against the running app's version.
- **`RuleModuleStore`** (`Application Support/Modules/<id>/`) holds `module.json` (the bytes as imported), `install.json` (subscription URL and dates) and `cache/`.
  - **Install** writes a hidden staging folder and moves it into place, so a module appears whole or not at all.
  - **Update** needs the same id and a higher version; otherwise it throws `notNewer` (已是最新版本). It drops the cache.
  - **Remove** deletes the folder.
  - **List** re-reads the disk every time and caches nothing. An unreadable or no-longer-valid folder is logged through `AppLogger`, reported in `failures`, and never overwritten.
  - **Open for 6e:** a module the running app now rejects can't be updated in place, because its subscription URL is read only after its file validates. If 6e offers 檢查更新 on a failed row, read `install.json` independently.
- **Tests:** `RuleModuleTests.swift` has 4 suites and 22 tests:
  - the format and versions;
  - the validator, one case per rejection plus a clean module;
  - the store: install, update, remove, corrupt file, empty;
  - the mapping: search and explore through the bridge, explore's own eight rules each in their slot, the early filter, a module's JSON list.

  The bridge-versus-mapping comparison is circular now that the bridge calls the mapping. The real before/after evidence is the existing parsing suites: `CoverLinkRuleTests`, `ModernParserBridgeChapterCompatibilityTests`, `JSONDiscoverBridgeRegressionTests` and `ChangeSourceTOCResolutionTests`, which pass with the new suites, 45/45 on iOS 27.

### 6d (branch `modules/6d-provider`)

- **`RuleModuleClient`** (`Modules/Services/RuleModules/RuleModuleClient.swift`) reads one page of an entry.
  - **Request:** the entry's own `request` fields. `{{name}}` is filled from the values; it is percent-encoded in the URL and body, raw in headers. There is no `AnalyzeUrl`.
  - **Address checks:** `safeURL`, then the module's `hosts`.
  - **Fetch:** through `WebFetcher.fetchPage` under `SourceRateLimit.run(rate: module.rateLimit, key: "module:<id>")`.
  - **Decoding:** `HTMLResponseDecoder.decode(…declaredCharset:)` with the entry's `charset`.
  - **Parsing:** the list rules on a bare `ModernRuleEngine()` (no JS evaluator, never `BookSourceSession`) through `RuleListMapping`. The span is `module.page`.
  - **Redirects:** `WebFetcher.fetchPage` gained an optional `redirect:` gate, a per-task `URLSessionTaskDelegate`. A redirect whose target fails `safeURL` or the hosts list is **never sent**; its 3xx comes back and becomes `invalidAddress`. Every other caller passes nil and is unchanged.
  - **Failures:**
    - non-2xx → `rejected(status)`;
    - an undecodable body → `parse`;
    - a host or `safeURL` refusal → `invalidAddress`;
    - URL errors → `SourceFailure.classify`.

    `ModuleProvider` logs each one through `AppLogger.network` with the module, entry, kind and status.
  - **An empty list is not a failure.**
  - **Cache:** one file per entry and its values (SHA-256 of the sorted values) under the module's `cache/`, answered while younger than `cacheDuration`. No duration means no cache.
    - An unreadable cache file counts as a miss and is logged (`AppLogger.cache`), then replaced.
    - Update and remove already clear the folder (6c).
- **Values:** each parameter's default, else an enumeration's first option. The section's own `parameters` (by parameter name) override it. `page` counts from 1 and `offset` from 0. The next offset advances by the number of items read; an empty page ends the list.
- **`ModuleProvider: CollectionBrowsing, HomeSectionProviding`** (`ModuleProvider.swift`).
  - The root lists the entries as locations; an entry's location is its pages.
  - A home section loads its first page, up to `HomeRow.limit` items, `.parallel`, one lane per module through its rate key. An entry the module no longer has is not served.
  - **Items** are `.item(record, summary, .bibliographic)`. Each record is `viewOnly` and keyed by the item's URL, or by title and author when the list has no url rule (otherwise every item would read the page's address).
  - Summaries are plain and bounded through `OPDSClient.plainMetadata` and `WorkSummary`'s limits. The category comes from `WorkSummary.category(fromSourceKind:)`.
  - **A cover is a request too:** it is taken only from the module's hosts; otherwise it is generated.
  - Search reports `.none` until 6g joins modules to 搜索.
- **`ProviderType.module`** and **`HomeSectionBinding.module(moduleID:entryID:)`** (type key `module`; an older build keeps it as `.unknown`).
  - **Departure from the plan:** the parameters are not in the binding. They are the section's existing `parameters` dictionary, which was there for exactly this and was unused.
  - Every exhaustive switch got `.module`:
    - it is no library in 書庫順序 or 為你推薦's inputs;
    - it has no 範圍 page and no 查看全部 yet (6e);
    - 選擇內容來源 lists it from 6f;
    - 隱藏已讀 applies.
  - `FilledMetadata.providerName` shows the module's id for now. A module's title needs an owner of the installed list, which comes with 6e.
- **Not yet in the registry:** neither `browsableProviders` nor `homeProviders` lists modules. That comes in 6e and 6f.
- **Tests:** `ModuleProviderTests` (13), with a `URLProtocol` stub on the client's own session:
  - an HTML list (data-only items, plain blurb, a cover from another host generated);
  - defaults;
  - a JSON list with its language;
  - the root;
  - paging by page and by offset;
  - a redirect to an undeclared host is refused and never requested;
  - a redirect within the hosts is followed;
  - 403 is `rejected`;
  - an empty list is empty;
  - the cache (within the duration, per values, after it);
  - the manifest and the binding round-trip;
  - template filling.

  With the 6c suites: 35/35 on iOS 27.
- **Regressions (iOS 27):** 78/79 pass. The suites are `HomeSectionTests`, `HomePageStoreTests`, `ExploreHomeTests`, `OpenLibrarySearchTests`, `HomeModelTests`, `HomeModelSchedulingTests`, `LocalHomeRowTests`, `ProviderManifestTests`, `LibraryHomePageTests`, `CoverLinkRuleTests`, `ModernParserBridgeChapterCompatibilityTests` and `ChangeSourceTOCResolutionTests`.
  - The one failure, `LibraryHomePageTests.gutenbergSections`, is stale on main and not caused by this step.
  - It was written 2026-10-12. a338bbea (2026-10-13) put `.gutenbergLists` at the front of `gutenbergCollections`, so the test's suffix of `PublicLibraryCollection.all.count` is one short.
  - It is handed off as a separate task.

### 6e (branch `modules/6e-library-ui`)

- **Part A (26b245a5), no UI:**
  - `SourceDisclaimerGate` holds the 免責聲明 step that `BookSourceAddFlow` had inline; both add flows now pass through it.
  - `RuleModuleLibrary` (`@MainActor`, `.shared`) owns the installed list: it loads, installs, updates and removes off the main actor, then reloads (span `modules.library.load`). `FilledMetadata.providerName` now names a module by its title.
  - `RuleModuleImportModel` drives the import sheet: it fetches from an address, a file or the clipboard, shows a preview, checks for updates, then commits. Downloads go through `RuleModuleClient.download`, with the same host gate on every redirect as 6d.
  - `RuleModuleMessages` gives every rejection and store error a localized sentence. 53 keys in all five languages.
  - `RuleModuleImportTests` (8).
- **Part B, the UI:**
  - **資源庫 「模組」** (`RuleModuleSection`): after 來源配置, in the 資源庫 card style.
    - It shows the installed modules, with name, version and author.
    - A module that no longer validates appears as a card with its reason and a remove action.
    - The empty card opens 從網址.
  - **••• → 新增模組** (`RuleModuleAddFlow`):
    - It offers 從網址, 從檔案 and 從剪貼簿.
    - From iOS 18 it is a nested menu. On iOS 17 it adds three rows to the chooser, sequenced by dismissal.
    - The disclaimer is shared with 來源配置.
    - The file importer sits on the inner stack, not beside `bookSourceAddFlow`, because SwiftUI presents only one of two `.fileImporter`s on one view.
  - **The import sheet** (`RuleModuleImportSheet`) shows the manifest before anything is written: information, entries, the sites it connects to, and any rejection.
  - **The module's page** (`RuleModuleDetailView`) is pushed through `ExploreNavigationRoute.module(id:)`. It shows the manifest, the subscription URL with 檢查更新, and 移除模組 behind a confirmation dialog. `ExplorePlace.page(of:)` now opens it for `.module`.
  - Previews:
    - the group empty, with two modules, and with a failure;
    - the page;
    - the import sheet, valid and rejected.
- **Decisions taken here (each changeable on the maintainer's word):**
  - **Hosts on update:** an update that adds sites lists them under 新增的網站 before it replaces anything. Nothing is written until the reader confirms.
  - **官方模組:** the subgroup is not drawn until the app ships a module.
  - **Deep link:** `yuedu://module?src=` moves to its own step, 6e-2. `JsBridgeBrowserView` treats every `yuedu://` host as a 來源配置 link and has to learn the difference first.
  - **A rejected module offers only 移除.** 檢查更新 on it would need `install.json` read without validating the file (the open point from 6c), and is left out.
- **Not yet in the registry:** `browsableProviders` and `homeProviders` still do not list modules. That comes in 6f, with 選擇內容來源.
- **Tests:**
  - `ModuleLibraryUITests.testAddFromAddressThenRemove`, against a local fixture server: ••• → 新增模組 → 從網址 → load → commit; the card appears; the page lists the entry and the URL; remove. It passes on iOS 27 (37.9 s) and iOS 17.5 (29.7 s).
  - `LibraryTabUITests.testMoreMenu`, since the ••• changed: passes on iOS 27 and iOS 17.5.
  - `check_localizations`, `git diff --check` and the title-mode grep are clean.

### 6e-2 (branch `modules/6e2-deeplink`)

- **One parser:** `BookSourceImportDeepLink.target(from:)` returns `.sources(URL)` or `.module(URL)`. `yuedu://module?src=` (or `url=`, under any path) is a module, on the `yuedu` scheme only. `sourceURL(from:)` keeps its callers and never answers for a module link, so a module can never be imported as 來源配置.
- **`RuleModuleLinkPresenter`** opens a module link from both entries:
  - the app's `onOpenURL`;
  - a page in the in-app browser. `JsBridgeBrowserView` already intercepted every `yuedu://` link and now routes module links here.
- **What it shows:** the same `RuleModuleImportSheet` as 從網址, with the address already loading and no address field.
  - The first time, the source disclaimer comes first, through the same `SourceDisclaimerGate`. The sheet opens from the disclaimer's real dismissal completion.
  - It presents from the top view controller, because a root SwiftUI sheet cannot show over the reader or the browser. The browser presents its own 來源配置 links the same way.
  - Nothing is written until ✓.
- **Investigated and not a bug:** after opening a link the UI test found the app back on 書架. A first guess was that the multi-scene app opens a new scene per URL. `handlesExternalEvents` did not change the result, so it was reverted.
  - Logging showed a new pid: `XCUIApplication.open(_:)` relaunches the app.
  - `simctl openurl` keeps the same pid.
  - The test now opens the link through `XCUIDevice.shared.system.open(_:)`, the way a link tapped elsewhere arrives, and accepts SpringBoard's confirmation.
- **Also fixed:** in `testAddFromAddressThenRemove`, the ••• could not be tapped on iOS 27 after scrolling to the module card, because the bar slides away (`.minimizesBar`). `tapMore` now scrolls back to the top first.
- **Tests:**
  - `BookSourceImportDeepLinkTests`: 9/9, 2 of them new.
  - `ModuleLibraryUITests`: 2/2 on iOS 17.5 and 2/2 on iOS 27. The new `testOpenLinkShowsDisclaimerThenImport` goes link → disclaimer → preview → ✓ → card, with the tab still 資源庫 at the end.

### 6f (branch `modules/6f-content-source`)

- **Registry:** `homeProviders` lists one `ModuleProvider` per installed module (`SourceProviderRegistry.moduleProviders(in:)`), after 青空文庫. `HomeModel.live` waits for `RuleModuleLibrary.loadIfNeeded()` along with the 來源配置 library.
  - ExploreHome observes the library. Each module's id and version are part of its sync key, so an install, update or removal resyncs the home.
  - `ModuleProvider.inputsKey` is the module's version, so an update restarts its rows.
- **Ownership:** `HomeContentOwner.module(id:)`, named by the module's title, or its id once it is removed.
- **選擇內容來源:** a 「模組」 group appears when any module is installed. A module opens its lists (`HomeModuleChoices`) with the current one checked, and a list titles the section after itself (`HomeContentChoice.lists(of:)`). A module's search entry is not listed.
  - The 來源配置 row's symbol is now `square.grid.2x2.fill`, the one 資源庫 uses for 來源配置. `puzzlepiece.extension` was shared with the new modules group in the same list. *(Changeable on the maintainer's word.)*
- **The form** shows the list's parameters under 篩選, an existing key, written to the section by name (`HomeSectionEditor.setParameter`).
  - `enumeration` is a `Picker`.
  - `count` is a `Stepper` from 1 to max(100, current). The format gives no bound.
  - `input` is a text field kept on submit or focus loss, never per keystroke, because each value reloads the preview with a real request.
  - `constant`, `page` and `offset` are not shown.
  - `Param.currentValue(in:)` is the one rule for both the form and the request (`Entry.values` uses it).
- **The preview** loads the module's real first page, through the same `homeProviders` as the home.
- **Removed module:** nothing serves the section, so it has no row, exactly as for a removed connection (`HomeModel.sync` logs it).
- **Deferred to 6f-2: 查看全部 for a module row.** No page yet browses a provider's location with paging, and building one (view, paging model, previews, UI test) is its own step. The row header has no chevron until then.
- **Tests:**
  - `ModuleContentSourceTests` (6) on iOS 27: owner and name; lists, never search; editable parameters and current values, the same as the request's; editor round trip, with a cleared parameter going back to the default; rows follow the library through a removal; the version changes the inputs.
  - Regressions on iOS 27, 58/58: `HomeSectionEditorTests`, `HomeModelTests`, `ModuleProviderTests`, `RuleModuleImportTests`, `ExploreHomeTests`, `HomeSectionTests`.
  - `ModuleLibraryUITests.testModuleListOnTheHome`: install from 資源庫, then 編輯首頁 → 新增欄目 → 選擇內容來源 → 模組 → 新書. 資料來源 reads 「測試模組 › 新書」, the preview loads the fixture list (`new.html`), and after 新增 the home shows the row. The whole class passes 3/3 on iOS 27 and 3/3 on iOS 17.5.
