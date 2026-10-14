# Unified library, Phase 3: metadata that fills itself — plan

> **For agentic workers:** each step has its own branch, its tests (written first) and a "What landed" entry at the end of this file. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push.

**Goal:** a book on the shelf whose cover, description or categories are missing gets them filled in automatically from the reader's own book sources and from Open Library. Nothing to press: no 識別 screen. The reader's own edits always win, and a filled value the reader removes stays removed.

**Design:** `Technotes/UnifiedLibrary-2026-10-08-design.md` §8 (precedence, sidecar-only background writes, completeness order), §11.3–11.4 (Open Library), Phase 3 (3a–3d). This plan re-cuts 3a–3d for the maintainer's "fully automatic" answer below.

**Not in this phase:** a 識別 screen and `chooseCandidate` decisions; built-in parsing of web-novel platforms (§17 item 4); generalizing `OnlineCoverSearchService` (封面搜索 stays the manual tool it is); syncing sidecars or decisions; filling title or author.

## Maintainer's decisions (2026-10-14, by option)

The four answers, verbatim:

1. 第一個書目資料庫 → 「Open Library，按了才查（推薦）」
2. 「識別」放哪裡 → 「不是為什麼要識別選項，全自動的吧」
3. 來源配置查到的資料（3b）→ 「也自動補空欄位」
4. 3d 背景自動補齊 → 「做，預設開啟」

Read together:

- **Open Library is the first bibliographic database.**
- **There is no 識別 screen; filling is automatic.** Answer 1's "only when tapped" no longer has anything to tap.
- **On by default.** Answer 4's option text said books with an ISBN are sent to Open Library in the background, and that is the option chosen.
- **The disclosure lives in a settings toggle (on), with a one-sentence footer** naming what is sent and to whom.
- **Book-source values fill empty fields automatically** (answer 3). This is a B-level match (title + author). It amends design §8.1, which wanted B-level confirmed by the reader.

## Settled here (each changeable on the maintainer's word)

- **Title and author are never filled.** Design §8.1, unchanged.
- **A cover is filled only from an A-level match** (an identifier, i.e. Open Library by ISBN), and only when the copy has none. A same-name book-source match is wrong often enough to put the wrong cover on the shelf, and answer 3's option named 簡介 and 分類, not covers.
- **A B-level match writes values, never identifiers.** Sidecar identifiers drive A-level merges in the work index (`WorkIndexService.entry`), so one wrong same-name match would merge two works.
- **Only empty fields.** A field is filled only when its effective value (resolver: override, lock, the copy's own value, any sidecar value) is empty. A field with any decision on it (override or lock) is never filled.
- **Removing a filled value sticks.** The edit sheet shows a filled description or cover with its origin and a 移除 action. 移除 records `override(field, empty)`. The resolver returns it as empty, and the filler skips the field from then on.
- **Sidecar only** (design §8.2). `ReadingBook` is not written, so the iCloud hash does not change. Sidecars do not sync; each device fills its own.
- **Each copy is asked once per provider.** A ledger records `found` / `empty` / `failed` per copy and provider:
  - `found` and `empty` are not asked again.
  - `failed` (network, server) is asked again after 7 days. This is an external failure, so a retry is allowed; it is commented as such.
  - A copy whose title, author or identifiers change is asked again.
- **The work page's 資料不完整 hint (§8.3) is dropped.** With no screen to act on it, it would be a dead end. The completeness score is still used for the fill order.

## Architecture

```
MetadataFillRunner  (one per shelf, @MainActor, modelled on SeriesNumberBackfill)
 ├─ candidates: shelf copies, ordered by completeness (§8.3), least complete first
 ├─ per copy: missingFields = fields whose effective value is empty and that have no decision
 ├─ providers, in order: Open Library (A, by ISBN) → book sources (B, by title + author)
 ├─ MetadataFillLedger   Works/metadata-fill.json: per copy × provider → found/empty/failed, at, inputsHash
 └─ writes ImportedMetadataStore (sidecar) only; never ReadingBook

protocol MetadataFillProvider {
    var key: SourceInstanceKey { get }            // .bibliographic "openlibrary", or a book source's key
    var grade: MatchGrade { get }                  // .a (identifier) or .b (title + author)
    func lookup(_ query: MetadataFillQuery) async throws -> MetadataFillResult  // throws = failed; empty result = empty
}
```

**Display.** Filled values show where values already show:

- **Description and categories:** `CopyMetadata` already reads sidecar intros. Categories already come from the sidecar where they are read (7a-2's genre profile, the work page).
- **Covers:** not shown from the sidecar today.
  - `BookshelfCoverPlan` gains a step after the copy's own cover and its catalog cover, before 預設封面. It reads an in-memory map in `BookStore` (`filledCovers: [UUID: String]`, file names in `Caches/Works/covers`), because the plan must not open files.
  - 強制使用預設封面 still wins.
  - The detail pages draw the same plan.

**One path per concern:**

- Book-source lookups go through `BookOriginSearchService.stream` → `BookSourceSession`. This is the fan-out 換源 and 封面搜索 use. The filler uses the search results' `intro` and `kind` and does not fetch detail pages, so no detail-cache writes.
- Open Library requests go through `WebFetcher` with an injected session.
- Covers are saved by the same writer `WebDAVMetadataFiller` uses for `Caches/Works/covers`.

**Requests and limits:**

- **Open Library:**
  - At most 1 request per second. The User-Agent is `RemoteLibraryHTTPClient.userAgent` (app name + support URL), never the user's email; 3 req/s would need the maintainer's contact address in it.
  - ISBN lookups are batched through `search.json` (`q=isbn:(a OR b …)`, `fields=key,isbn,title,author_name,cover_i,subject,language,publisher,first_publish_year`).
  - The description comes from `/works/{key}.json`, one request, only when the description is missing.
  - Covers come from `covers.openlibrary.org/b/id/{cover_i}-L.jpg?default=false`. These are by cover id, so they are outside the ISBN limit of 100 per 5 minutes.
  - Each copy is asked once (ledger), not in bulk, per the terms.
- **Book sources:**
  - Enabled sources only.
  - The run stops at the first B-level match that carries a description.
  - There is a per-copy time cap and a per-run copy cap.
  - The numbers are measured in 3b with `SourcePerfTrace` and written there.
  - An online copy is not looked up this way: its own source is tier 1 already.
- **When:**
  - Triggers: a run starts after the shelf loads, when the app comes to the foreground, and after an import. It stops when the app goes to the background.
  - It does not run on cellular when 網路設定 limits cellular, nor in Low Power Mode.
  - Exact conditions are in 3d.

**Errors:** a failed lookup is logged (`AppLogger`, never in `#if DEBUG`) and recorded `failed`. An empty answer is recorded `empty`. Neither is swallowed.

## Steps

### 3a-1: the filler (no network)

Branch `metadata/3a-1-filler`. Tests first (`MetadataFillRunnerTests`, `MetadataFillLedgerTests`):

- A stub A provider and a stub B provider.
  - Only empty fields are written.
  - Title and author are never written.
  - B writes no identifiers and no cover; A may write a cover only when the copy has none.
- A field with an override (empty included) or a lock is not asked for and not written.
- Ledger:
  - `found` and `empty` are not asked again;
  - `failed` is asked again only after 7 days;
  - a changed title, author or identifier set re-asks.
- The order is least complete first. The completeness score is a constant weight per field (cover, intro, author, tags, language, series).
- Resolver: the `bibliographicIsALevel` flag goes. Bibliographic values in the sidecar are A-level by construction, because only the filler writes them and only on an identifier match. `MetadataResolverTests` are updated for that.

### 3a-2: showing filled values, and removing them

Branch `metadata/3a-2-display`. Tests first:

- **`BookshelfCoverPlanTests`:** the filled cover is used after own/catalog and before 預設封面; 強制使用預設封面 wins.
- **`CopyMetadataTests`:** a filled intro shows; `override(.intro, "")` hides it.
- **Filler:** after a 移除 it does not fill the field again.
- **UI:** `EditBookSheet` shows a filled description or cover with its origin (「自動補上・Open Library」 / 「自動補上・<來源名>」) and 移除. The strings are in all five `.lproj`, VoiceOver labels are on the button, and there is a `#Preview`.

### 3b: book sources as a provider (B)

Branch `metadata/3b-book-sources`:

- `BookSourceFillProvider` wraps `BookOriginSearchService.stream`. A match is `WorkMatchKey` B-level: the title is equal, and both sides' authors are present and compatible. It yields `intro` and `tags` (from `kind`).
- It runs for local and remote-library copies, not for book-source copies.
- Measure on the simulator with the reader's typical source count. Fix and write down the per-copy time cap, the per-run cap and the concurrency, with before/after numbers.

### 3c: Open Library (A)

Branch `metadata/3c-open-library`:

- `OpenLibraryFillProvider` through `WebFetcher` with an injected `URLSession` (a URLProtocol stub in tests). It handles:
  - batched ISBN search;
  - the work description;
  - the cover by `cover_i`;
  - the 1 req/s limiter;
  - the User-Agent.
- It runs only for copies with an ISBN (`ExternalIdentifier` `isbn13`; ISBN-10 is converted).
- It writes `openLibraryWork` and `openLibraryEdition` identifiers. This is A-level, so it is safe for merging.
- The `.bibliographic` switch sites that label it 書架 or group it with `.library` get their own label:
  - `WorkDetailView.swift:788`
  - `ExploreDestinations.swift`
  - `HomeRowView.swift:271`
  - `SourceLabel.swift:21`
  - `ExploreHome.swift`
  - `LibraryHomePage.swift:24`
  - `HomeModel.swift:295`
  - `LibraryOrder.swift:13`
  - `ShelfProvider.swift:279`
- Tests:
  - request shape;
  - parsing of a recorded response;
  - a 403/429 response is recorded as `failed`;
  - no request is made for a copy without an ISBN.

### 3d: running it, and the setting

Branch `metadata/3d-schedule`:

- **Triggers:** the shelf has loaded, the app comes to the foreground, an import finishes. A run stops when the app goes to the background; it is not delayed by a timer.
- **Network:** no cellular when 網路設定 says so, and not in Low Power Mode.
- **Setting:** 設定 → 網路 (or wherever 網路設定 lives) gets 「自動補齊書籍資料」, on by default. Its footer is one sentence: 書名、作者與 ISBN 會送到 Open Library 與你啟用的來源配置，用來補上空白的封面、簡介與分類。 It is in all five languages. Turning it off stops a running pass.
- **Measure:** a cold run over a test shelf (N local books, M with ISBN): requests, time and fills, reported in "What landed".

## Acceptance

- Two local books on a fresh shelf:
  - an EPUB with an ISBN and no cover gets an Open Library cover and description;
  - a TXT whose title and author match a source gets that source's description and categories.
  - The shelf and the detail page show both.
- 移除 a filled cover: the cover goes back to 預設封面/generated and does not return after a relaunch.
- A copy is not asked twice (ledger); with the setting off, no request is made.
- `MetadataResolverTests`, `CopyMetadataTests`, `MetadataFillRunnerTests`, `MetadataFillLedgerTests`, the Open Library and book-source provider tests, and `BookshelfCoverPlanTests` all pass. Localization check is clean.

## What landed

### 3a-1 (branch `metadata/3a-1-filler`)

- `Modules/Services/Works/MetadataFill.swift`:
  - **`MetadataFillProvider`** (`@MainActor`; `canLookUp`, and `lookUp`, which throws on failure and returns an empty result for "no record").
  - **`MetadataFillRunner`:**
    - least complete first;
    - per copy, the providers in order, each asked only for what is still missing;
    - B never asked for a cover, and its identifiers dropped;
    - one sidecar write per provider that found something, keeping the sidecar's `sourceItem`.
  - **`MetadataFillCandidate.missing`:**
    - `fillable` minus fields with an override or lock;
    - minus the cover when the copy has its own;
    - minus fields the resolver already gives a non-empty value.
  - **`MetadataFillLedger`** (`Works/metadata-fill.json`; failures asked again after 7 days; an unreadable file is moved aside).
  - **`MetadataCompleteness`** (cover 3, intro 2, authors 2, tags/language/series 1).
- **Resolver:** `bibliographicIsALevel` is gone. A database's values in the sidecar are A-level by construction (only the runner writes them, only from A providers).
- **Tests:** `MetadataFillRunnerTests` (12), `MetadataFillLedgerTests` (3), `MetadataResolverTests` (updated); 24/24 on iOS 27.

### 3a-2 (branch `metadata/3a-2-display`)

- **`FilledCoverIndex`** (`@Observable`, owned by `BookStore.filledCovers`, injected at the app root):
  - holds copy id → absolute path of the filled cover;
  - is rebuilt off the main thread from the coverless copies' sidecars (`refreshFilledCovers()`, after every complete shelf load);
  - logs a file that `Caches` lost.
- **Cover plan:** `BookshelfCoverPlan.shelf(…filledCover:)` puts a filled cover in the own-cover slot when the book has neither a saved nor a catalog cover. 強制使用預設封面 still wins.
  - **`ShelfCoverSlot`** reads the index from the environment, so only cover slots redraw. It replaces the direct plan in `BookshelfCoverStyle.artwork` and `HomeCoverArtwork` (作品詳情).
  - The open-book snapshot is passed the same path.
- **`ReadingBook.hasOwnCoverArtwork`:** a saved cover, or a remote library's catalog cover.
- **Removing a filled value:** `BookStore.removeFilledValue(_:of:)` records `override(field, "")`; a cover also leaves the index.
  - `filledValue(_:of:)` returns a value only when the provider in effect has a `found` ledger entry for the copy, so an import's own values are never offered.
  - 書籍資訊 shows 「移除自動補上的封面／簡介」 with 「自動補上・<provider>」 under it. The intro button appears only while the reader's own description is empty.
  - Strings are in all five languages.
- **`OpenLibrary.key`** (`bibliographic/openlibrary`) and `FilledMetadata.providerName`.
- **Tests:** `FilledMetadataTests` (8), `CopyMetadataTests` and `CoverImagePipelineTests` unchanged; 38/38 on iOS 27.
