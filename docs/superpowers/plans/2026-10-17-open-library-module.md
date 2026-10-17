# Open Library as an official module (2026-10-17)

Maintainer, 2026-10-17 (AskUserQuestion): Open Library 「改成官方模組」, like Bangumi, AniList, openBD
and なろう — one module file, no Swift provider of its own, turned off on 模組's page like the rest.
Follows `2026-10-17-module-ecosystem.md` (M1–M8 merged, 270c7a33).

## What Open Library does today (two Swift types)

- `OpenLibrarySearch` (搜索, 「只有資料」 rows): `search.json?q=…&fields=key,title,author_name,cover_i,language,isbn&limit=20`;
  work key `/works/OL…W` as the item, MARC language codes, up to 5 ISBNs, cover by cover id (`-M.jpg`).
  Switch: `GlobalSettings.searchOpenLibrary` (`yd_search_open_library`), a row of its own in 資料來源.
- `OpenLibraryFillProvider` (補資料, level A): a copy with an ISBN-13 → `search.json?q=isbn:(…)` with the
  matched edition; the edition must carry one of the copy's ISBNs; the edition's cover (`-L.jpg?default=false`,
  404 = none), subjects as tags (≤24 characters, no `:`, at most 5, the copy's script), and the
  description from a **second request**, `/works/OL…W.json` (a string or `{value}`), in the copy's script.
  Place `.openLibrary` in `MetadataFillOrder`.
- `OpenLibraryRecommendationResolver` (AI 推薦): `search.json?title=…&author=…&limit=5`, the work whose title
  and authors match (`WorkMatchKey`), then the same second request for its blurb.
- Terms: one request a second (`RequestPacer.openLibrary`), the app's User-Agent, never the user's email.

## What the module format already covers

Search and lookup requests with JSON rules; `isbn` matched against the copy's (an edition's ISBN-10 and -13
normalize to the same value); cover template from the item; cover 404 = none; summary and tags kept only in
the copy's script; tags ≤24 characters, at most 5, de-duplicated; `rateLimit: "1/1000"`; the app's
User-Agent; data-only search rows; `hosts` (`openlibrary.org`, `covers.openlibrary.org`).

## Gaps, and how each is closed

1. **The description is a second request.** The format adds an optional `detail` to the `search` and `lookup`
   entries (a 3.0 field: the app is 3.0.0, and an app that ignores `detail` only fills less): a `request` whose template reads the item (`{{$.key}}`), and the list fields it gives (`intro`,
   `tags`, …), merged into the item where the item's own are empty. Asked only when the copy still misses a
   field `detail` gives, one request per matched record (never per row of a search). Documented in
   `docs/modules/README.md`; `ModuleFormatDocumentationTests` covers it. Any module can use it.
2. **AI 推薦 asks by title and author.** The resolver goes through the module's `search` with
   `"<title> <author>"`, keeps the result whose title and authors match (`WorkMatchKey`, as now) and reads
   `detail` for the blurb. No second search path.
3. **Settings carry over, once:**
   - `.openLibrary` in `MetadataFillOrder` becomes `.module("openlibrary")` at the same position and the same check;
   - `yd_search_open_library` becomes the module's switch in 資料來源 (off stays off).
   The migration runs once and is tested both ways.
4. **Old records keep their name.** Values filled before keep `SourceInstanceKey(.bibliographic, "openlibrary")`
   as their provenance; `FilledMetadata.providerName` still names it "Open Library". New ones carry the module's key.
5. **Reserved id** `openlibrary`; shown in every storefront, as today.

## Disclosed (for veto)

- Search rows no longer carry the `openLibraryWork` identifier (a module item gives only `isbn`). Works still
  merge by ISBN and by title + author, so the loss is a merge with a copy filled by Open Library whose ISBN
  differs from every search row's. Restoring it needs an `identifiers` list rule in the format.
- The ISBN lookup asks the copy's first ISBN-13 only (the old one asked every ISBN of the copy at once).
- Subjects with a `:` were dropped; a module drops tags with digits instead. "Fiction: Science fiction" style
  subjects are now kept when they fit 24 characters.

## Found while writing the file (2026-10-17), and decided

Open Library's saved replies showed four more gaps; three were the maintainer's to decide
(AskUserQuestion, all three recommendations taken):

- **Covers redirect off the hosts.** `covers.openlibrary.org` answers 302 to `archive.org`, which answers
  302 to a numbered `iaNNNNNN.us.archive.org`. The old provider followed any redirect; a module follows only
  to its hosts, and a refused cover redirect threw the whole lookup (intro and tags lost, asked again weekly).
  Decided: **`hosts` may hold `*.example.org`, for redirects only** — a request is still sent only to a host
  written out. And a cover redirect the hosts refuse is no cover, not a failure of the record.
- **Title search is new.** With a `search`, the module fills a copy without an ISBN by title and author, as
  Bangumi and AniList do; the old provider asked by ISBN only. Decided: **as the other modules**.
- **Short keywords.** Open Library answers 422 to a query under 3 characters (「三体」). Decided: **a search
  may declare `minKeywordLength`**; a shorter keyword is not sent: no row in 搜索, nothing to fill from.
- **Several values.** An edition lists its ISBN-10 and -13, a work several authors; the engine joins a
  list with newlines, which matched nothing. `isbn` and `author` rules may give several values (no decision:
  it is what the rule reads).

## Steps (one branch each, tests first, `--no-ff` into main)

- **OL1 `detail`**: merged 556884b6.
- **OL1b format additions** (merged cfeba059): `*.` redirect hosts, `minKeywordLength`, several `isbn`/`author` values, a refused
  cover redirect is no cover; docs + documentation test + `ModuleFormatAdditionsTests`.
- **OL1 `detail`** (as planned): validator, `ModuleProvider` (search/lookup items + detail), `ModuleFillProvider`
  asks it for a missing field; unit tests with saved replies; docs + documentation test.
- **OL2 the file** (merged 095056cc): `Resources/Assets/official-module-openlibrary.json`; `OfficialModuleFilesTests` with
  saved Open Library replies (search, ISBN search, work JSON with both description shapes, cover 404).
- **OL3 switch-over** (merged ab3abbd3): fill order + search switch migration, AI 推薦 resolver on the module, delete
  `OpenLibrarySearch`, `OpenLibraryFillProvider`, `OpenLibraryRecommendationResolver`, the 資料來源 row and
  `RequestPacer` if nothing else uses it (grep each type first). Unit tests: migration, AI 推薦 resolver.
- **OL4 acceptance**: `OfficialModulesLiveTests` gains Open Library (search, ISBN lookup with description);
  the UI tests that launch with `-yd_search_open_library NO` switch to `-no-official-modules`; plan entry.

## Done (2026-10-17)

- OL3: the stored `openLibrary` fill place reads as `module:openlibrary` (same position, same check; the first
  entry of a place counts); with nothing stored Open Library still comes first. `yd_search_open_library` off
  unchecks the module in 搜尋來源 once and is removed. AI 推薦 asks the module's search with `"<title> <author>"`
  and its `detail` for the blurb; 停用 turns its lookups off too. `RequestPacer` had no other user and went.
- OL4: `OfficialModulesLiveTests.openLibrary` (search, ISBN lookup with cover through archive.org and a
  description); the UI tests' `-yd_search_open_library` arguments are gone (every one already launched with
  `-no-official-modules` or its own official folder); 聚合設定 and 資料來源 UI tests no longer look for the
  Open Library row of its own.
- Also disclosed: the AI 推薦 query is `q=title author` (it was `title=` and `author=`); Open Library's search
  rows sort among the libraries, no longer after the sources.

