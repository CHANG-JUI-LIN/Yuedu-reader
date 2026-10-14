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
  "requiredVersion": "3.0",
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
