# Unified Library, Phase 2 — Implementation Plan

> **For the implementer.** Read [AGENTS.md](../../../AGENTS.md) and [CLAUDE.md](../../../CLAUDE.md) first, then the design sections each task cites. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> - Design: [Technotes/UnifiedLibrary-2026-10-08-design.md](../../../Technotes/UnifiedLibrary-2026-10-08-design.md):
>   - §5 (protocols), §8.3, §9 (capabilities and the registry), §10.1, §13.6;
>   - §15 (Phase 2, and the 2026-10-10 order with 2d), §17 item 10, §19.
> - Audit: [Technotes/UnifiedLibrary-2026-10-08-audit.md](../../../Technotes/UnifiedLibrary-2026-10-08-audit.md): §8 (remote libraries; §8.2–§8.4), §9 (Gutenberg), §14 (DI).
> - Previous plans: [Phase 0](2026-10-10-unified-library-phase-0.md) and [Phase 1](2026-10-10-unified-library-phase-1.md). Their guardrails apply here too.
>
> Line numbers are from `main` at `1c80d1eb`. Re-read each file before editing; other sessions commit to `main` all day.

**Goal:** one way to reach every content source, and a library that fills itself in, ahead of Phase 5's cover wall:

- **2a:** a provider registry and `CollectionBrowsing`, with adapters for the shelf, OPDS (including Calibre and Gutenberg), WebDAV and Aozora. The existing browse screens fetch through them, so there is one browse path.
- **2b:** 設定 → 遠端書庫, a pushed configuration page for every WebDAV, OPDS and Calibre connection. Book-source management (來源配置) is pushed on every iOS version.
- **2c:** browse rows show 已加入書架 and 已下載, from a lookup instead of a scan.
- **2d:** WebDAV libraries are indexed in the background: their book files become source records the work index can use.
- **2e:** indexed WebDAV EPUBs get their OPF metadata and cover, most incomplete first.

**Today:**

- **No registry or provider abstraction exists.** `PublicLibraryAvailability` is read only by `ExploreTabRoot` (`ExploreTabRoot.swift:8, 14, 23, 42`).
- **Browse paths:**
  - `OPDSBrowseModel` (`OPDSBrowseModel.swift:21-97`) and `WebDAVBrowseModel` (`WebDAVBrowseModel.swift:18-54`, from 0c) each call their own client.
  - Errors are strings, so empty and failed cannot be told apart, and a catalog without search reports a failure (`OPDSBrowseModel.swift:57`).
  - Gutenberg is special-cased inside `OPDSBrowseModel` (`:33-35`, `:53-54`; audit §9).
- **Entry points:**
  - Remote libraries are reached only from the bookshelf ＋ menu (`HomeView.swift:732-775`). Each kind opens a sheet with its own `NavigationStack` (`RemoteLibraryBrowserView`, `OPDSImportView.swift:19-139`).
  - Settings has no entry point.
  - Book-source management is a sheet on iOS 18+ and pushed on iOS 17 (`BookSourceManagementPresentationPolicy`, `DismissalSequencedPresentation.swift:25-42`).
- **"On shelf" and "downloaded":**
  - Browse rows never show either.
  - The detail page finds the copy with a scan of every reading record (`RemoteLibraryService.swift:41-43`) and calls `fileExists` on every body evaluation (`:140-143`; audit §8.3).
- **WebDAV:**
  - Listing is one `PROPFIND Depth: 1` per folder (`WebDAVBrowseClient.swift:31-40`). Nothing recurses.
  - The work index sees only copies (`WorkIndexService.swift:186`).
  - Nothing monitors the network path (no `NWPathMonitor` anywhere).

---

## Scope

**In:** 2a–2e as above.

**Out:**

- **Browsing from anywhere new.** Browsing moves to Phase 5's Explore home (the 我的書庫 section, a pushed page per library). Until then the bookshelf ＋ entries stay exactly as they are. They are removed only after Phase 5's entry passes its UI tests, not in 2b.
- **Book sources in the registry.** Design §9 lists them; they join with Phase 5, which is their first caller.
- **Search through providers** (`CatalogSearching`, Phase 4) and home sections (`HomeSectionProviding`, Phase 5).
- **Background processing tasks.** Indexing runs in the foreground only (settled below).
- **Calibre's structured `/ajax/books` fields** (§9 "v2") and the `OPDSFeedRoute` clash between two stacks. Both are recorded under Follow-ups.
- **Changing `ReadingBook`.** No field is added (D1).

---

## Decisions

### Settled by the maintainer (2026-10-10)

1. **Connections are libraries, not modules** (the Emby model).
   - A WebDAV, OPDS or Calibre connection is a content source, like an Emby media library.
   - Managing it is configuration, in Settings.
   - Browsing it is a tile in Explore's 我的書庫 section, pushed full-page (Phase 5).
   - Aggregation is the work index and the home sections.
   - Modules (Phase 6) shape how sections look.
2. **2b is configuration only.** 設定 → 遠端書庫 is pushed and lists every connection. Browsing waits for Phase 5; the bookshelf ＋ entries stay until then.
3. **The page is named 遠端書庫.** The string already exists in five languages (1a).
4. **Book-source management (來源配置) is pushed on every iOS version**, not a sheet on iOS 18+.
5. **WebDAV indexing runs in the foreground only.** On entering the background it finishes the batch in hand under a background-task assertion and stops. The next foreground session resumes. No `processing` background mode is added.
6. **Indexing is on by default for connections the reader added, and off for the one copied automatically from the WebDAV backup account** (`OPDSCatalog.swift:63-73`). That one is a backup server the reader never added as a library; they turn it on in 遠端書庫.
7. **Covers and summaries come in a second step** (2e): list files first, then read OPF and cover by range, most incomplete first (design §8.3).

### Made while planning

Each comes with its reason; the maintainer can overturn any of them.

1. **One branch per step, `2a → 2b → 2c → 2d → 2e`, each cut from `main` after the previous one merges.**
   - Branches: `unified-library/2a-registry`, `2b-remote-library-settings`, `2c-shelf-status`, `2d-webdav-index`, `2e-webdav-metadata`.
   - 2b's book-source change is its own commit, so it can be reverted alone.
2. **The adapters are the browse path, not a second one.**
   - `OPDSBrowseModel` and `WebDAVBrowseModel` already take a fetch seam. Their default seam becomes the provider's `browse`. The views do not change.
   - This gives `CollectionBrowsing` a real caller and test coverage in Phase 2.
   - Adapters added beside the models would be a second path with no caller until Phase 5.
3. **Browse failures are typed.**
   - `SourceFailure`: authentication, network, timeout, parse, rejected(HTTP status), removed connection.
   - An empty page is not a failure.
   - A catalog without search reports `capabilities().search == .none` instead of an error string.
   - The models keep their `loadError` strings for the views, built from the typed failure.
4. **2c keys everything by `SourceItemKey`.**
   - Today's lookup keys by `(connectionID, entryID, extension)` with the absolute URL for WebDAV. 1a's `SourceItemKey` uses the path below the root (`SourceRecordDerivation.swift:74-76, 200`).
   - 2d's records, the work index and Phase 5's cards are all `SourceItemKey`-based, so 2c uses it too.
   - The lookup lives in `BookStore`, memoized on `mutationRevision`, as `allGroups` is (`BookStore.swift:1304-1311`).
   - Maps come from the same plain dictionaries `WorkIndexService.liveContext` builds, without touching the keychain.
5. **已下載 means the copy records an offline file** (`remoteSource.offlineFilename != nil`), not that the file exists right now.
   - A `fileExists` per row is disk I/O in `body`.
   - The detail page keeps its existence check when the reader opens it.
6. **2d gets its own HTTP client per connection**, never the shared one:
   - It sets `allowsExpensiveNetworkAccess = false` and `allowsConstrainedNetworkAccess = false`, so the system itself refuses cellular. On the shared client that would break reading on cellular.
   - `OPDSCatalogStore`'s client cache is an unlocked dictionary on a store that is not `@MainActor` (`OPDSCatalog.swift:45, 124-130`). An indexer actor sharing it with the main actor is a data race.
   - Credentials are read once, on the main actor, when a run starts.
7. **Wi-Fi is checked twice.** A new `NetworkPathMonitor` (`NWPathMonitor`) decides when to start and pause. The client's session configuration enforces it per request.
8. **2d's records live in `Works/remote/<connection id>.json`.**
   - They are derived: they can be rebuilt by crawling again. A file that does not decode is discarded and rebuilt; an unreadable one is not written over (design §10.1).
   - Removing a connection removes its file.
   - The work index gains a second input beside copies. Non-copy entries are keyed by `SourceItemKey`, fingerprinted by `(etag, lastModified, size)`. The store has a revision of its own beside `mutationRevision`.
9. **2d's limits are measured, not guessed.**
   - The measurement uses an in-process PROPFIND responder in the test target. It is a small `NWListener` HTTP server like `LanWebServer`'s (`LanWebServer.swift:37`) and serves a synthetic tree.
   - GCDWebServer is not linked into this project, and adding a dependency is out of scope.
   - The numbers go into "What landed" before 2d merges, as with 1c's benchmark.
10. **Privacy in logs** (Phase 1, decision 11). WebDAV paths and titles are the reader's private library. Indexer logs and spans carry counts, kinds, connection ids and failure categories, never paths, host names or titles.
11. **New strings are proposed here for review** (Task 2d). Nothing else adds a string. 2c reuses 已加入書架 and 已下載, and 2b reuses 遠端書庫 and the existing kind names.

---

## Context

### Providers and browsing (2a)

- **OPDS:**
  - `OPDSClient.fetchFeed(_:isSearch:)` (`OPDSClient.swift:131`) returns `OPDSFeed`: entries, `nextPageURL`, `search`.
  - Calibre's 404 "No books found" on search is already an empty feed (`:139-158`).
  - Entry ids: OPDS 1 uses Atom `<id>`, falling back to acquisition, then navigation URL (`:289, 306`). OPDS 2 uses `metadata.identifier` (`OPDS2FeedParser.swift:168`).
- **Calibre vs Calibre-Web:** both are `RemoteLibraryKind.calibre`, browsed over OPDS. Only `CalibreServerAPI.libraryInfo()` tells them apart (`CalibreServerAPI.swift:118-131`; a 404 means Calibre-Web). `RemoteLibraryWritingService.capabilities` already uses it (`:80-96`).
- **Gutenberg:**
  - `PublicLibrary.gutenberg` is a synthetic `OPDSCatalog`, injected by `catalog(id:)` and not stored (`OPDSCatalog.swift:121`; `PublicLibrary.swift:108-117`).
  - Transport is `PublicLibraryFeedTransport` (`PublicLibraryBookPresentation.swift:140-155`); search URL is `PublicLibrary.gutenbergSearchURL`.
- **WebDAV:** `WebDAVBrowseClient.list(_:)`, `Entry` (`WebDAVBrowseClient.swift:5-15`). The client asks for no content type and parses `lastModified` as a raw string.
- **Aozora:**
  - `AozoraCatalogStore` (`AozoraCatalogStore.swift:7-12, 74-121`) has states `unavailable / loading / ready / failed`.
  - `AozoraCatalogIndex` (`AozoraCatalog.swift:64-151`) provides `newWorks`, author, title and classification groups, and a local `search`.
- **Shelf groups:** `BookStore.allGroups`, `setGroup(s)` (`BookStore.swift:1304-1323`). The pages are computed in `HomeView` (`:9-23, 434-470`).
- **Phase 1 derivations** to reuse: `SourceRecord.derived(from:)` for `OPDSEntry`, WebDAV `Entry`, `AozoraWork`, `GutenbergBook` and `ReadingBook` (`SourceRecordDerivation.swift:44-178`).
- **DI:** `AppDependencies` (`AppDependencies.swift:350-361`) has no registry or connection store yet. Design §9 puts the registry there.

### Configuration (2b)

- **`RemoteLibraryConnectionEditor`** (`OPDSImportView.swift:141-267`): name, URL, credentials, `syncProgress` (Calibre), 測試連線; save calls `add` then `update`.
- **`OPDSCatalogStore`** = `RemoteLibraryConnectionStore`:
  - `add`, `update`, `remove` (`OPDSCatalog.swift:77-114`), persisted to `Library/opds_catalogs.json`, credentials in Keychain.
  - It is not `@MainActor`.
- **Settings root** is `ProfileView`. Its 「來源配置管理」 section (`ProfileView.swift:111-132`) holds 管理來源配置, 下載管理 and 網路設定. 遠端書庫 joins that section.
- **Book-source policy:** `BookSourceManagementPresentationPolicy` (`DismissalSequencedPresentation.swift:30-42`). It is read in `ProfileView.swift:297, 307` and `ExploreHomeView.swift:443-445`, and tested in `DismissalSequencedPresentationTests` and `Tests/Contracts/DismissalSequencedPresentationContract.swift`. CLAUDE.md and `Technotes/iOS17MenuModalPresentation.md` describe the iOS 18 sheet.

### Lookups (2c)

- `RemoteLibraryService.book(for:format:store:)` scans `readingBooks` (`:41-43`); `RemoteBookReference.matches` compares connection, entry id and extension (`RemoteLibraryItem.swift:38-53`).
- Aozora scans `store.books` by `catalogWorkID` (`AozoraCatalogViews.swift:113`).
- Rows:
  - OPDS: `OPDSImportView.swift:376-415`;
  - WebDAV: `RemoteImportViews.swift:98-123`;
  - public-library cards: `PublicLibraryBooksView.swift:33`.

### WebDAV indexing (2d, 2e)

- **Background work today:**
  - `BackgroundTaskHold` (`BackgroundTaskHold.swift:9-31`).
  - `OfflineDownloadBackgroundTask`, ref-counted with an expiration hook (`OfflineDownloadBackgroundTask.swift:20-65`).
  - The RSS refresh loop, which checks `Task.isCancelled` per item (`RSSFeedRefreshService.swift:6-50`), is the template.
  - The scene-phase hooks are in `yuedu_appApp.swift` (around `:237`).
- **Per-connection settings:** `OPDSCatalog` has custom `CodingKeys` and a `decodeIfPresent` decoder (`OPDSCatalog.swift:13, 26-35`). Its only toggle today is `syncProgress`.
- **Status UI to follow:** `CalibreProgressStatusView` with `CalibreProgressState` (`RemoteLibraryManagementView.swift:228-249`; `CalibreProgressService.swift:4-5, 30`).
- **Throttling:** `PerHostSemaphore` (`FetchRetryPolicy.swift:11-110`).
  - `FetchRetryPolicy` cannot read `OPDSError.http`: it parses a localized "HTTP 錯誤" string (`:183-195`).
  - 2d therefore classifies failures itself and does not retry through it.
- **Range reads (2e):**
  - `RemoteEPUBArchiveOpener` reads the ZIP tail and entries on demand (`RemoteEPUBArchiveOpener.swift:9-122`).
  - `RemoteLibraryResourceClient` caches ranges and rejects changed versions (`RemoteLibraryCache.swift:47-120`).
  - `RemoteLibraryService.probe` (`RemoteLibraryService.swift:374-409`).
  - `PublicationSession.retrievePackage(sourceURL:httpClient:)` returns the OPF without building a session (`PublicationSession.swift:1761-1785`), but it is private.
- **Work index inputs:** copies only (`WorkIndexService.swift:63-102, 186`). `WorkIndexEntry.nodeKey = record.copyKey ?? record.key` (`WorkIndex.swift:74`), and `build` joins entries that share `record.key` (`:193-198`). A WebDAV record and the shelf copy of the same file therefore join on their own.

---

## Guardrails

Phase 0's and Phase 1's guardrails apply in full:
- run tests with `scripts/xctest.sh` and `-collect-test-diagnostics never`, checking the suite count;
- no `-derivedDataPath`;
- delete your own `.xcresult`s;
- commit only your own files;
- no `try?` that discards a parse or network error;
- every fallback is disclosed.

**The §19 Phase 2 regression, by the names `-only-testing` needs** (checked against the suite count in 2a):

- Swift Testing structs: `OPDSParserTests`, `OPDS2ParserTests`, `GutenbergOPDS2FixtureTests`, `PublicLibraryStorefrontTests`, `PublicLibraryRegistryTests`, `PublicLibraryAvailabilityTests`, `RemoteLibraryBrowsePresentationTests`, `RemoteLibraryConnectionTests`, `RemoteLibraryHTTPTests`, `RemoteLibraryServiceTests`, `RemoteLibraryWritingTests`, `RemoteLibraryReadFailureTests`, `RemoteReadingRecordTests`, `RemoteEPUBPublicationTests`, `WebDAVBrowseModelTests`, `CalibreCFIMapperTests`, `CalibreProgressServiceTests` (both in `CalibreProgressTests.swift`), `AozoraCatalogStoreTests`, `AozoraCatalogTests`.
- XCTest classes: `RemotePDFReaderTests`.
- UI (`yuedu appUITests/…`): `RemoteLibraryNavigationUITests`, `PublicLibraryStorefrontUITests`, `PublicLibraryExploreUITests`.
- From 2a on, also `SourceFailureTests`, `OPDSProviderTests`, `WebDAVProviderTests`, `AozoraProviderTests`, `ShelfProviderTests`, `SourceProviderRegistryTests`, `OPDSBrowseModelBehaviorTests`.

Phase 2 adds:

- **UI** (2b, 2c, 2d):
  - Invoke `yuedu-ios-design`. Pushed pages are `.inline`; settings rows use `SettingsRows`.
  - Footers only where they earn it (design rule 14).
  - Every view gets a `#Preview` and is read with VoiceOver: row status is part of the row's label, never a separate focusable element.
- **iOS 17 modals:**
  - No `Menu` that opens a sheet. 遠端書庫 adds a connection through one row per kind section, not a kind-picking `Menu`.
  - Read `Technotes/iOS17MenuModalPresentation.md` before touching presentation.
  - The connection editor may stay a sheet from the pushed page.
- **No browse routes in the Settings stack.** `OPDSFeedRoute` already opens different views in two stacks (`OPDSImportView.swift:81-89`; `PublicLibraryHomeView.swift:29`), and Phase 5 needs it from Explore.
- **Strings:** only Task 2d's reviewed list. Run `ruby scripts/check_localizations.rb`.
- **Region gate:** Gutenberg and Aozora providers report `hiddenInRegion` when `PublicLibraryAvailability.isAvailable` is false, and the registry never lists them.

---

## File map

**Create**
- `Modules/Services/Works/SourceProvider.swift` (2a): `SourceProvider`, `ProviderAvailability`, `CollectionBrowsing`, `CollectionCapabilities`, `CollectionLocation`, `CollectionCursor`, `CollectionPage`, `CollectionEntry`, `WorkSummary`, `CoverReference`, `SourceFailure`.
- `Modules/Services/Works/SourceProviderRegistry.swift` (2a).
- `Modules/Services/Works/Providers/` (2a): `ShelfProvider`, `OPDSProvider` (OPDS and Calibre), `GutenbergProvider`, `WebDAVProvider`, `AozoraProvider`.
- `Modules/Features/Settings/RemoteLibrarySettingsView.swift` (2b).
- `Modules/Services/LibraryStore/CopyLookup.swift` (2c), or an extension of `BookStore`.
- `Modules/Services/Network/NetworkPathMonitor.swift` (2d).
- `Modules/Services/Works/WebDAVIndexer.swift`, `RemoteRecordStore.swift`, `WebDAVIndexCoordinator.swift` (2d).
- `Modules/Services/Works/RemoteEPUBMetadataReader.swift` (2e).
- Tests:
  - `SourceProviderRegistryTests`, `OPDSProviderTests`, `WebDAVProviderTests`, `AozoraProviderTests`, `ShelfProviderTests` (2a);
  - `RemoteLibrarySettingsUITests` (2b);
  - `CopyLookupTests` (2c);
  - `WebDAVIndexerTests`, `RemoteRecordStoreTests`, `WebDAVIndexCoordinatorTests`, `WorkIndexRemoteRecordsTests`, and an env-gated `WebDAVIndexBenchmarkTests` with its `NWListener` PROPFIND fixture (2d);
  - `RemoteEPUBMetadataReaderTests` (2e).

**Modify**
- `Modules/Services/OPDS/OPDSBrowseModel.swift`, `Modules/Services/WebDAV/WebDAVBrowseModel.swift` (2a): default seams through the providers; Gutenberg special cases out.
- `Targets/Yuedu/SharedApp/AppDependencies.swift` (2a): the registry.
- `Modules/Features/Settings/ProfileView.swift` (2b): the 遠端書庫 row; book-source management always pushed.
- `Modules/SharedUI/Components/DismissalSequencedPresentation.swift`, `Modules/Features/Explore/ExploreHomeView.swift`, `ExploreNavigationPath.swift` (2b): the policy and its readers.
- `CLAUDE.md`, `Technotes/iOS17MenuModalPresentation.md` (2b): the book-source rule.
- `Modules/Features/Bookshelf/OPDSImportView.swift`, `RemoteImportViews.swift`, `RemoteLibraryBookDetailView.swift`, `Modules/Features/Explore/PublicLibrary/*` (2c): row status; the detail page reads the lookup.
- `Modules/Services/RemoteLibrary/RemoteLibraryService.swift` (2c): `book(for:format:store:)` through the lookup.
- `Modules/Services/OPDS/OPDSCatalog.swift` (2d): the per-connection indexing setting.
- `Modules/Features/Bookshelf/OPDSImportView.swift` (2d): the toggle in `RemoteLibraryConnectionEditor`.
- `Modules/Services/Works/WorkIndexService.swift` (2d): remote records as a second input.
- `Targets/Yuedu/SharedApp/yuedu_appApp.swift` (2d): start and stop on scene phase.
- `Modules/Core/EPUB/PublicationSession.swift` (2e): an internal OPF-and-cover read over range requests.
- `Resources/*.lproj/Localizable.strings` (2d): the reviewed strings.
- This plan: "What landed" after each step.

---

## Task 2a: The registry and `CollectionBrowsing`

**Branch:** `unified-library/2a-registry`, from `main`. Design §5, §9; audit §8, §9, §14.

- [ ] **Step 1: Types** (`SourceProvider.swift`), from design §5, all `Sendable` values except the protocols:
  - **`SourceProvider`** (`@MainActor`, `AnyObject`): `instance: SourceInstanceKey`, `displayName`, `availability: ProviderAvailability` (`available`, `hiddenInRegion`, `needsSetup`, `catalogNotReady`).
  - **`CollectionBrowsing`:**
    - `capabilities() async -> CollectionCapabilities`, which covers search (none, on submit, explicit request only) and pagination. Calibre and Calibre-Web differ, so it is async.
    - `browse(_ location: CollectionLocation?, after cursor: CollectionCursor?) async throws(SourceFailure) -> CollectionPage`.
  - **`CollectionPage`:** `entries: [CollectionEntry]` and `next: CollectionCursor?`.
  - **`CollectionEntry`:** `.location(CollectionLocation)` (a folder, a navigation feed, a group, an author) or `.item(SourceRecord, WorkSummary)`.
  - **`WorkSummary`** is bounded at construction, per design §5 and audit §11.5. `CoverReference` is `.copyFile`, `.remote(URL, headers)` or `.generated(seed)`.
  - **`SourceFailure`:** `authentication`, `network`, `timeout`, `parse`, `rejected(status)`, `connectionRemoved`. An extension maps `OPDSError`, `URLError` and `RemoteLibraryWriteError`.
- [ ] **Step 2: Adapters.** Each wraps today's client and returns what the model consumed before.
  - **`OPDSProvider`**, one per OPDS or Calibre connection: locations are navigation links, items are acquisition entries, and the cursor is `rel=next`. Capabilities come from the last feed's `OPDSSearch`, and for Calibre also from `libraryInfo()`.
  - **`GutenbergProvider`:** the built-in connection. It owns `PublicLibraryFeedTransport` and `gutenbergSearchURL`, which move out of `OPDSBrowseModel` (design §9, audit §9). Search is `explicitRequestOnly`.
  - **`WebDAVProvider`**, one per connection: one `PROPFIND Depth: 1` per location. Folders are locations, and every file is an item. Files that are not importable books get no acquisitions (1a's derivation already does this).
  - **`AozoraProvider`:** locations are 新着, authors, titles and classifications from `AozoraCatalogIndex`. It reports `catalogNotReady` until the store is `ready`, and `hiddenInRegion` per the gate.
  - **`ShelfProvider`:** locations are groups; items are copies, keyed by `SourceItemKey.copy`.
- [ ] **Step 3: `SourceProviderRegistry`.**
  - `@MainActor`, injected through `AppDependencies` (design §9).
  - It builds the instances from `OPDSCatalogStore.connections`, `PublicLibraryAvailability` and the shelf, and republishes when connections or availability change.
  - A removed connection's provider disappears. Any model still holding it gets `connectionRemoved`.
- [ ] **Step 4: One path.**
  - `OPDSBrowseModel` and `WebDAVBrowseModel` take a provider instead of building a client. Their test seams stay.
  - `OPDSBrowseModel`'s two Gutenberg branches are deleted, since `GutenbergProvider` answers for them.
  - Nothing on screen changes. The `loadError` strings stay as they are, built from the typed failure. "此目錄不支援搜尋" stays too, now built from `capabilities().search == .none` instead of a failed search. Hiding the search field instead would change what readers see, so it is left for the maintainer to decide in Phase 5.
- [ ] **Step 5: Tests.**
  - **`SourceProviderRegistryTests`:** instances from connections; the region gate hides Gutenberg and Aozora; a removed connection drops its provider.
  - **`OPDSProviderTests`:**
    - fixture feeds (OPDS 1 and 2) give locations, items and the next cursor;
    - an empty feed gives an empty page, not a failure;
    - 401 maps to `authentication`, 404 to `rejected(404)`, an invalid feed to `parse`, `URLError.timedOut` to `timeout`;
    - Calibre's empty search stays empty.
  - **`WebDAVProviderTests`, `AozoraProviderTests` and `ShelfProviderTests`:** the same shape, against fixtures.
  - **Existing guards:** `PublicLibraryStorefrontTests` (including `sharedBrowseModelLoadsOnePagePerActionAndDeduplicatesNextPage`), `WebDAVBrowseModelTests`, `OPDSParserTests`, `OPDS2ParserTests`, `GutenbergOPDS2FixtureTests`, `PublicLibraryRegistryTests`, `PublicLibraryAvailabilityTests`, `RemoteLibraryBrowsePresentationTests`, `RemoteLibraryConnectionTests`, `RemoteLibraryHTTPTests`.
- [ ] **Step 6: Run and commit.** Run the §19 Phase 2 row (the remote library and OPDS suites, and `RemoteLibraryNavigationUITests`) plus the new suites. Then UI-check one OPDS, one WebDAV and the Gutenberg storefront in the simulator; nothing on screen should differ.

**2a acceptance:**
- every browse in the app goes through a provider;
- failures are typed, and empty is not failure;
- Gutenberg has no special case left in `OPDSBrowseModel`;
- the existing suites pass unchanged.

---

## Task 2b: 設定 → 遠端書庫, and book-source management pushed

**Branch:** `unified-library/2b-remote-library-settings`, from `main` after 2a. Design §13.6; maintainer decisions 1–4.

- [ ] **Step 1: `RemoteLibrarySettingsView`.**
  - Pushed from a new row in `ProfileView`'s 「來源配置管理」 section, titled 遠端書庫 with a `SettingsRowLabel`.
  - It has one section per kind (WebDAV 書庫, OPDS 書庫, Calibre 書庫), listing that kind's connections from the registry.
  - Each row opens `RemoteLibraryConnectionEditor` for that connection, as a sheet, the way the browser opens it today.
  - Each section ends with an add row for its kind, using the existing add-server string. There is no kind-picking `Menu`.
  - Swipe deletes, as `RemoteLibraryBrowserView` does (`OPDSImportView.swift:51-55`).
  - No browse routes are registered here.
- [ ] **Step 2: States.**
  - **No connections:** `ContentUnavailableView`, with the three add rows still reachable.
  - **The built-in Gutenberg** is not listed: it is not a connection the reader manages.
  - **Rows read as one VoiceOver element:** name, then kind, then URL host. Status joins the label in 2d.
- [ ] **Step 3: `#Preview`s** for no connections, all three kinds, and a long name with large Dynamic Type.
- [ ] **Step 4: UI test `RemoteLibrarySettingsUITests`:**
  - Settings → 遠端書庫 → each add row opens the editor for its kind, and Close returns.
  - A connection added in the editor appears in its section, and swipe-delete removes it.
  - `RemoteLibraryNavigationUITests` is left as it is and must still pass.
- [ ] **Step 5: Book-source management pushed everywhere,** in a separate commit:
  - Delete `BookSourceManagementPresentationPolicy`, and push from `ProfileView` and `ExploreHomeView` on every version.
  - Update `DismissalSequencedPresentationTests`, `Tests/Contracts/DismissalSequencedPresentationContract.swift`, CLAUDE.md's 「Do not nest the book-source importer under a sheet on iOS 17」 bullet, and the technote.
  - Grep UI tests for any that close book-source management with Close on iOS 18, and update them.
  - Then run the book-source import UI tests on iOS 18+ and on iOS 17 (`reference_ios17_simulator_testing`: XCUITest with fixtures).
- [ ] **Step 6: Run and commit.** Run `RemoteLibrarySettingsUITests`, `RemoteLibraryNavigationUITests`, `DismissalSequencedPresentationTests`, `RemoteLibraryConnectionTests` and the book-source management UI tests found in Step 5. Run `check_localizations.rb` (no new keys expected).

**2b acceptance:**
- every connection can be added, edited and deleted from Settings, without the bookshelf;
- the bookshelf ＋ entries are unchanged;
- book-source management is pushed on every version;
- VoiceOver reads each row as one element.

---

## Task 2c: 已加入書架 and 已下載 in browse rows

**Branch:** `unified-library/2c-shelf-status`, from `main` after 2b. Audit §8.3; decisions 4–5.

- [ ] **Step 1: `CopyLookup`.**
  - Maps `SourceItemKey` → copy ids, built from `readingBooks` with `SourceRecord.derived(from:context:)` and plain maps of connections and roots. Each copy's own key is included too.
  - Memoized on `mutationRevision`; rebuilt on the next read after a change, never per row.
  - It answers `isOnShelf(key)` (some copy `isInBookshelf`) and `hasDownload(key)` (some copy records `offlineFilename`).
  - Aozora works key by `aozoraWork` through the same map, so the `catalogWorkID` scans go too.
- [ ] **Step 2: Callers.**
  - `RemoteLibraryService.book(for:format:store:)` goes through the lookup; its format-specific match stays.
  - The detail page's `isOnShelf` scan (`RemoteLibraryBookDetailView.swift:105`) is replaced. Its offline existence check stays, evaluated on appear instead of in `body`.
  - `AozoraCatalogViews.swift:113` and `AozoraLibraryDownloadService.swift:35` use the lookup.
- [ ] **Step 3: Rows.**
  - OPDS rows, WebDAV rows and public-library cards show 已加入書架, or 已下載 when downloaded but not on the shelf, as secondary text. The strings are existing ones.
  - The status is part of the row's VoiceOver label.
  - Add `#Preview`s with both states.
- [ ] **Step 4: Tests.**
  - **`CopyLookupTests`:**
    - an OPDS copy, a WebDAV copy (absolute URL in `RemoteBookReference`, relative path in the key) and an Aozora copy are each found by their browse item's key;
    - an unlisted reading record is not on the shelf;
    - a mutation rebuilds;
    - 10,000 copies build once, measured (span `library.copyLookup.build`).
  - **Guards:** `RemoteLibraryServiceTests`, `RemoteReadingRecordTests`, `AozoraLibraryDownloadServiceTests`.
- [ ] **Step 5: Run and commit.** The §19 Phase 2 row plus the above.

**2c acceptance:**
- rows show both states;
- no per-row scan or file-system call;
- the lookup is keyed like the work index.

---

## Task 2d: WebDAV background indexing

**Branch:** `unified-library/2d-webdav-index`, from `main` after 2c. Design §8.2, §15 2026-10-10 order, §17 item 10; maintainer decisions 5–6; decisions 6–10.

- [ ] **Step 1: Review the new strings with the maintainer before any code.** The proposals:

  | Key (zh-Hant) | zh-Hans | en | ja | ko | Where |
  |---|---|---|---|---|---|
  | 在背景建立書籍索引 | 在后台建立书籍索引 | Index Books in Background | バックグラウンドで本を索引 | 백그라운드에서 책 색인 | Editor toggle, WebDAV only |
  | 只在連接 Wi-Fi 且 App 開著時進行。 | 只在连接 Wi-Fi 且 App 打开时进行。 | Runs only on Wi-Fi while the app is open. | Wi-Fi 接続中、アプリを開いている間だけ行います。 | Wi-Fi에 연결되어 앱이 열려 있을 때만 진행합니다. | That toggle's footer (a non-obvious precondition) |
  | 正在建立索引（%d 本） | 正在建立索引（%d 本） | Indexing (%d books) | 索引を作成中（%d 冊） | 색인 생성 중 (%d권) | Status |
  | 已建立索引（%d 本） | 已建立索引（%d 本） | Indexed (%d books) | 索引を作成済み（%d 冊） | 색인 완료 (%d권) | Status |
  | 已暫停：未連接 Wi-Fi | 已暂停：未连接 Wi-Fi | Paused: Not on Wi-Fi | 一時停止：Wi-Fi 未接続 | 일시 정지: Wi-Fi 미연결 | Status |
  | 已達上限（%d 本） | 已达上限（%d 本） | Limit Reached (%d books) | 上限に達しました（%d 冊） | 한도 도달 (%d권) | Status |
  | 建立索引失敗：%@ | 建立索引失败：%@ | Indexing Failed: %@ | 索引の作成に失敗：%@ | 색인 생성 실패: %@ | Status; `%@` is the failure's existing localized message |

- [ ] **Step 2: Measure and set the limits.**
  - **The fixture:** `WebDAVIndexBenchmarkTests`, enabled by `YUEDU_WEBDAV_BENCHMARK=1`, starts an in-process `NWListener` PROPFIND responder (decision 9). It serves synthetic trees: 1k, 5k and 20k files across depths 3, 6 and 10.
  - **What it measures:** PROPFIND milliseconds per folder at 10, 100 and 1,000 children; memory of a listing; total crawl time; `Works/remote` file size and load time; work index refresh with those records added.
  - **What it sets** (filled in from the numbers): maximum depth, folders per batch, files per connection, and the minimum interval between full crawls.
  - Before 2d merges, also run one crawl against a real server the maintainer names, and record its numbers next to the synthetic ones.
- [ ] **Step 3: `NetworkPathMonitor`.**
  - One `NWPathMonitor` on a private queue, publishing on the main actor: `satisfied`, `isExpensive`, `isConstrained`, Wi-Fi or wired.
  - Injectable, with a fake for tests.
- [ ] **Step 4: The per-connection setting.**
  - `OPDSCatalog` gains `indexesBooks: Bool?`, decoded with `decodeIfPresent`.
  - `nil` resolves to on for connections the reader added, and to off for the connection the backup-account migration created (`OPDSCatalog.swift:63-73`, flag `remote_library_webdav_migrated`). The migration writes `false` explicitly from now on. An already-migrated connection is recognized by matching the backup account's URL and username at first read; record the rule in "What landed".
  - The editor shows the toggle for WebDAV with Step 1's footer.
- [ ] **Step 5: `WebDAVIndexer`.** An actor per connection.
  - **Client:** its own `RemoteLibraryHTTPClient` (decision 6), credentials passed in at start.
  - **Crawl:** breadth-first `PROPFIND Depth: 1` from the root within the limits.
  - **Records:** each importable book file becomes a `SourceRecord` via `SourceRecord.derived(from:connectionID:root:)`, with `etag`, `lastModified` and `size` kept for fingerprinting.
  - **Resumable:** the frontier is saved after each batch, so a pause loses at most one folder.
  - **Outcomes:** `completed(count)`, `limitReached(count)`, `paused(reason)` (no Wi-Fi, background, disabled), `failed(SourceFailure)`, `empty`.
  - **Failure handling:** an authentication failure stops the connection until its credentials change. Network and timeout failures retry at the next start, with no in-run retry loop. Every failure is logged with category and counts only (decision 10).
- [ ] **Step 6: `RemoteRecordStore`.**
  - `Works/remote/<connection id>.json`: `schemaVersion`, root, frontier, records, last outcome and times.
  - Serial atomic writes; discard-and-rebuild on decode failure; never write over an unreadable file.
  - Removing a connection deletes its file. A change of root URL or credentials resets it.
- [ ] **Step 7: `WebDAVIndexCoordinator`.**
  - **Starts** a connection's indexer when the app is active, the path is Wi-Fi, the connection's setting is on, and the last full crawl is older than the measured interval.
  - **Pauses** when any of those stops holding.
  - **On entering the background,** it finishes the batch in hand under a `BackgroundTaskHold`, then stops (maintainer decision 5).
  - One connection at a time.
  - It publishes each connection's state for 遠端書庫's rows and the editor, following `CalibreProgressStatusView`.
- [ ] **Step 8: The work index's second input.**
  - `WorkIndexService.refresh` reads `RemoteRecordStore` records beside copies.
  - Non-copy entries are fingerprinted by `(key, etag, lastModified, size)`. The remote store's revision joins `mutationRevision` in the stale check.
  - A WebDAV record and the shelf copy of the same file join through `sameSourceItem` (`WorkIndex.swift:193-198`).
- [ ] **Step 9: Tests.**
  - **`WebDAVIndexerTests`**, with a fake lister:
    - depth, batch and total limits;
    - pause and resume lose at most one folder;
    - empty vs failed;
    - authentication stops it;
    - non-book files are skipped;
    - cancellation is prompt.
  - **`RemoteRecordStoreTests`:** round trip, corrupt discarded, unreadable not written over, deleted with the connection.
  - **`WebDAVIndexCoordinatorTests`**, with fake path, scene phase and settings:
    - starts only when everything holds;
    - pauses on losing Wi-Fi or on background, finishing the batch;
    - the migrated backup connection stays off.
  - **`WorkIndexRemoteRecordsTests`:** remote records index; a record joins its shelf copy; incremental equals a full rebuild; a stale remote revision is dropped.
  - **UI:** `RemoteLibrarySettingsUITests` extended with a fixture connection's status line.
- [ ] **Step 10: Run and commit.** The §19 Phase 2 row, the new suites, the benchmark (numbers to "What landed"), and `check_localizations.rb`.

**2d acceptance:**
- a WebDAV library added by the reader is indexed on Wi-Fi in the foreground without being opened;
- the backup-account connection is not, until turned on;
- limits come from measurement;
- progress, pause and failure are visible on 遠端書庫;
- records reach the work index;
- nothing runs on cellular or in the background beyond the batch in hand.

---

## Task 2e: OPF and covers for indexed WebDAV EPUBs

**Branch:** `unified-library/2e-webdav-metadata`, from `main` after 2d. Design §8.3, §9 (WebDAV "v2 讀 EPUB 的 OPF"); maintainer decision 7.

- [ ] **Step 1: `RemoteEPUBMetadataReader`.**
  - An internal entry on `PublicationSession`, around `retrievePackage(sourceURL:httpClient:)`. It reads `container.xml`, the OPF and the cover image over range requests, through `RemoteEPUBArchiveOpener` and 2d's own client (Wi-Fi only).
  - It never builds a session or writes `spine.json`.
  - About four requests a book: probe, ZIP tail, container, OPF, plus the cover.
  - **Per-book budget:** skip covers above a measured size, and stop a book that exceeds its byte budget.
- [ ] **Step 2: Store.**
  - Each record gains its identifiers (`ImportedMetadataCapture.classify`, with Calibre packages handled as in 1c's fixes) and `MetadataValue`s in `RemoteRecordStore`, from the same OPF parsing as 1b.
  - Covers go to `Caches/Works/covers/` (discardable, design §10.1), referenced as `CoverReference.copyFile`.
- [ ] **Step 3: Order and limits.**
  - The coordinator fills records by design §8.3's completeness score: cover, summary, author, tags, language and series, with constant weights. Most incomplete first.
  - It runs under the same lifecycle and Wi-Fi rules, after a connection's crawl completes or reaches its limit.
- [ ] **Step 4: Work index.** Identifiers from 2e enter the entries, so a WebDAV EPUB with an ISBN joins the same book from Calibre or the shelf at A-level.
- [ ] **Step 5: Tests.**
  - **`RemoteEPUBMetadataReaderTests`**, against a range-capable fixture (reuse `RemoteEPUBPublicationTests`' server if it fits): OPF fields and identifiers; cover extracted; byte budget enforced; a changed ETag mid-read fails as `contentChanged`; a non-EPUB is skipped.
  - **Completeness ordering:** the most incomplete record is filled first.
  - **`WorkIndexRemoteRecordsTests` extended:** a WebDAV EPUB's ISBN merges with a shelf copy's.
- [ ] **Step 6: Run and commit.** The §19 Phase 2 row, the new suites, and a measured per-book request count and byte total on the benchmark fixture.

**2e acceptance:**
- indexed EPUBs gain metadata and covers in completeness order, on Wi-Fi in the foreground, within the measured budgets;
- their identifiers merge works.

---

## Acceptance (Phase 2)

- [x] 2a: one browse path through providers; typed failures; Gutenberg special cases gone.
- [x] 2b: 設定 → 遠端書庫 manages every connection; book-source management pushed everywhere; bookshelf ＋ unchanged.
- [x] 2c: row status from a `SourceItemKey` lookup; no per-row scan.
- [x] 2d: WebDAV indexed per the maintainer's rules, with measured limits and visible status.
- [ ] 2e: OPF and covers for indexed EPUBs, most incomplete first.
- [ ] Every step: its own branch from `main` after the previous one merges; its tests and the §19 Phase 2 regression pass after its last edit; nothing pushed or merged without the maintainer's yes.
- [ ] Rollback:
  - 2a and 2c are code only.
  - Reverting 2b restores the iOS 18 sheet.
  - 2d and 2e: revert, then delete `Works/remote/` and `Caches/Works/covers/`. The `indexesBooks` field is ignored by older builds.

## Follow-ups found while planning

1. **`OPDSFeedRoute` opens different views in two stacks**: `OPDSFeedView` in `RemoteLibraryBrowserView`, `PublicLibraryFeedView` in `PublicLibraryHomeView` (`OPDSImportView.swift:81-89`; `PublicLibraryHomeView.swift:29`). Phase 5 must give Explore one destination per route.
2. **The OPDS 「範例目錄」 preset adds Gutenberg as an ordinary connection with no region check** (`OPDSImportView.swift:59-72`). 2a's registry hides the built-in one, but a preset-added copy is an ordinary OPDS connection. Decide with the maintainer whether the preset honours the gate.
3. **`OPDSFeedView`'s empty overlay does not check `didLoad`** (`OPDSImportView.swift:328`), so it can flash before the first load. `PublicLibraryFeedView` does check it.
4. **`FetchRetryPolicy.httpStatusCode(from:)` parses a localized string** (`FetchRetryPolicy.swift:183-195`) and cannot read `OPDSError.http`.
5. **Phase 0's plan still says "not merged"** in its "What landed", though every step is merged. Update it with the next docs change.
6. **The WebDAV route drops `etag` and `lastModified`** (`RemoteLibraryBookDetailView.swift:5-45`). 2d keeps them on records; the route may want them when Phase 5 opens indexed books.

## What landed

### 2a (2026-10-10)

Branch `unified-library/2a-registry`, on `6ad3b788`. Merged into `main` at `e2234bdd`; not pushed.

- **Pinned first.** `OPDSBrowseModelBehaviorTests` records what the model showed and requested before the change, and passed on the unchanged code:
  - a removed connection's message;
  - each failure's own text (OPDS 401, 500 and login page; `URLError`s);
  - Gutenberg's search URL;
  - 「此目錄不支援搜尋」 for a root without search, and a templated search;
  - a failed next page.

  These pins pass unchanged after the change. `WebDAVBrowseModelTests` (0c) already pinned the WebDAV model.
- **Types** (`SourceProvider.swift`): `SourceProvider`, `ProviderAvailability`, `CollectionBrowsing`, `CollectionCapabilities` (with `CollectionSearchSupport`), `CollectionLocation`, `CollectionCursor`, `CollectionPage`, `CollectionEntry`, `CoverReference`, and `WorkSummary`, which bounds its fields at init.
- **`SourceFailure`** carries the underlying error:
  - Its text is that error's own, so nothing on screen changes, and the models log the underlying error, so diagnostics keep domain and code.
  - Kinds: authentication, network, timeout, parse, rejected (with status), invalidAddress, connectionRemoved, unavailable, other.
  - Cancellation, `CancellationError` or `URLError.cancelled`, is rethrown unclassified.
- **Providers** (`Modules/Services/Works/Providers/`):
  - `OPDSProvider` (OPDS and Calibre) and `GutenbergProvider` conform to `OPDSFeedProviding`: `feed(_:isSearch:)`, `searchURL(query:search:)` and `makeRecord`. `browse` is built on `feed`, and its mapping (with `plainMetadata`) runs off the main actor.
  - Gutenberg's transport and search URL moved out of `OPDSBrowseModel`. Its navigation links to a book are items, keyed by ebook number.
  - `WebDAVProvider`: `list(_:)`, with `browse` built on it.
  - `AozoraProvider` and `ShelfProvider` have no caller in Phase 2. The Aozora one projects the same `AozoraCatalogStore` index the Aozora screens read; it is not a second loader.
- **`SourceProviderRegistry`** (`@MainActor`, `.shared`, also `AppDependencies.sourceProviders`):
  - Lookups resolve from the connection store at each call; nothing is cached, so a removed connection is gone at once.
  - Availability shapes only `browsableProviders(shelf:)`. A lookup still answers for Gutenberg in the China region.
  - The shelf is listed only when a store is passed.
- **One browse path:**
  - `OPDSBrowseModel` and `WebDAVBrowseModel` fetch through the providers. `GutenbergBookPageModel`'s default fetch goes through `GutenbergProvider` too.
  - Other client calls are not browses: `OPDSCatalogStore.testConnection` (a connection check), and the acquisition paths (`RemoteLibraryService` read and download, `CalibreProgressService`, `RemoteLibraryWritingService`).
- **Decisions made in the step:**
  - An OPDS entry with neither a navigation link nor an acquisition is left out of `browse`, as the feed views already leave it untappable.
  - `OPDSProvider.capabilities()` answers `search: .unknown`, since a feed advertises its search only once fetched, and `capabilities()` sends no request. It does not tell Calibre from Calibre-Web either; `libraryInfo()` would be a request. The model's own search decision is unchanged.
- **Follow-up fixes in the step:**
  - The registry resolves through `OPDSCatalogStore.connection(id:)`, the lookup the models made before. That lookup answers only `builtin.gutenberg` beyond the stored connections, so nothing changed.
  - `OPDSProvider` and `WebDAVProvider` build their client on first use. `browsableProviders()` therefore reads no keychain.
  - The provider tests' HTTP stub answers by host, so the OPDS and WebDAV suites cannot answer each other's requests if they run concurrently.
- **Constraint on Phase 5's caller:** `ShelfProvider.browse` calls `WorkIndexService.liveContext`, so it inherits 1c's constraint. `BookSourceStore.source(id:)` waits on the main thread until the source library is read. Browse the shelf only once that store has loaded.
- **Nothing on screen differs.** The UI tests below include the Gutenberg storefront with fixtures and the three remote library entries. There is no live OPDS or WebDAV server here, so those two were not browsed by hand.

```
✔ Test run with 93 tests in 17 suites passed after 0.737 seconds.
   (SourceFailureTests, OPDSProviderTests, WebDAVProviderTests, AozoraProviderTests, ShelfProviderTests,
    SourceProviderRegistryTests, OPDSBrowseModelBehaviorTests, WebDAVBrowseModelTests,
    PublicLibraryStorefrontTests, OPDSParserTests, OPDS2ParserTests, GutenbergOPDS2FixtureTests,
    PublicLibraryRegistryTests, PublicLibraryAvailabilityTests, RemoteLibraryBrowsePresentationTests,
    RemoteLibraryConnectionTests, RemoteLibraryHTTPTests)
§19 Phase 2 row, the remaining remote library suites:
✔ Test run with 58 tests in 7 suites passed (RemoteLibraryServiceTests, RemoteLibraryWritingTests,
   RemoteLibraryReadFailureTests, RemoteReadingRecordTests, RemoteEPUBPublicationTests,
   AozoraCatalogStoreTests, AozoraCatalogTests), plus XCTest RemotePDFReaderTests
✔ Test run with 14 tests in 2 suites passed (CalibreCFIMapperTests, CalibreProgressServiceTests)
UI: RemoteLibraryNavigationUITests (1), PublicLibraryStorefrontUITests (3),
    PublicLibraryExploreUITests (2): Executed 6 tests, with 0 failures
After the follow-up fixes:
✔ Test run with 43 tests in 10 suites passed (the six 2a suites, OPDSBrowseModelBehaviorTests,
   WebDAVBrowseModelTests, PublicLibraryStorefrontTests, RemoteLibraryConnectionTests)
```

### 2b (2026-10-11)

Branch `unified-library/2b-remote-library-settings`, on `e2234bdd`. Merged into `main` at `70300b3e`; not pushed.

- **設定 → 遠端書庫** (`RemoteLibrarySettingsView`, commit `2d6ffee6`):
  - A `DSSettingsRow` in 「來源配置管理」 pushes it through `navigationDestination(isPresented:)`, as that section's other pushed page does.
  - One section per kind, in the bookshelf ＋ order (WebDAV, OPDS, Calibre). Each section ends in a 新增伺服器 row (`SettingsRowLabel`, role `.action`).
  - Rows show the name and the full address, read by VoiceOver as one element; swipe deletes.
  - No new strings.
- **Deviations from the plan:**
  - **The editor is pushed, not a sheet.** The bookshelf's library list already pushes `RemoteLibraryConnectionEditor`, which has no close button of its own. Nothing on the page presents a modal, so the iOS 17 menu rule does not arise. The editor gained a `surface` parameter so it takes the page background of whichever screen pushed it.
  - **No `ContentUnavailableView`.** With no connections, the page already shows three sections, each with its add row. A separate empty view would only repeat them.
  - **The row shows the full address, not the host.** An unnamed connection is named after its host, and the screenshot showed the host twice.
- **Book-source management pushed on every version** (a separate commit):
  - `BookSourceManagementPresentationPolicy` is deleted, along with its tests (`DismissalSequencedPresentationTests`, `Tests/Contracts/DismissalSequencedPresentationContract.swift`).
  - `ProfileView` and `ExploreHomeView` push `BookSourceListView(embedsNavigationStack: false)` and keep no sheet path.
  - CLAUDE.md's bullet now reads 「Book-source management is pushed, never a sheet」. The technote records the change and when.
  - `PublicLibraryExploreUITests` leaves 書源管理 by back instead of 關閉.
  - iOS 17 behavior is unchanged (it was already pushed); only iOS 18+ changed.
  - `BookSourceImportPresentationPolicy` (the import sheet inside management, iOS 17) stays.
- **The bookshelf ＋ entries are unchanged.** `RemoteLibraryNavigationUITests` passes as it was.

```
✔ Test run with 8 tests in 1 suite passed (RemoteLibraryConnectionTests)
✔ Test run with 11 tests in 1 suite passed (DismissalSequencedPresentationTests)
UI: RemoteLibrarySettingsUITests (add rows for each kind, add, list, swipe-delete; screenshot checked),
    RemoteLibraryNavigationUITests, BookSourceManagementUITests, PublicLibraryExploreUITests:
    Executed 6 tests, with 1 test skipped and 0 failures.
    The skip is BookSourceManagementUITests.testLargeLibraryOpensScrollsAndSwitchesPages, opt-in through
    BOOK_SOURCE_UI_LIBRARY (a Legado source pack).
ruby scripts/check_localizations.rb: OK
```

### 2c (2026-10-11)

Branch `unified-library/2c-shelf-status`, on `70300b3e`. Merged into `main` at `9466ab8f`; not pushed.

- **`CopyLookup`** (`Modules/Services/LibraryStore/CopyLookup.swift`):
  - Maps `SourceItemKey` → copies, built from `readingBooks` with 1a's derivation and plain maps of the connections (no keychain).
  - Each copy's own key is included.
  - A second index by `(connection, entry id)` serves the per-format match.
  - `status(for:)` answers `.onShelf` or `.downloaded`, shown with the existing 已加入書架 and 已下載.
- **Memoized in `BookStore`** (`copyLookup(connections:)`, `copyLookupMemo`) on `mutationRevision` plus a fingerprint of the connections (id, kind, URL). It is rebuilt on the next read after either changes, never per row.
- **Book-source copies are left out of the key index.** Their key needs `BookSourceStore`, which waits on the main thread until the source library is read (1c's constraint), and nothing browses them through this lookup. Phase 4 or 5 adds them when a caller needs them, with that constraint in mind.
- **Callers:**
  - `RemoteLibraryService.book(for:format:store:)` goes through the entry index; its format-specific match is unchanged.
  - The remote detail page reads `isInBookshelf` from the copy. Its offline-file existence check runs in `.task(id:)` when the copy or its offline filename changes, instead of in every `body`.
  - Aozora's detail page and `AozoraLibraryDownloadService.addToShelf` find the copy by the work's key instead of scanning `store.books` by `catalogWorkID`.
- **Rows:**
  - OPDS feed rows and WebDAV folder rows add the status as a caption line.
  - Gutenberg and Aozora grid cards show it in place of 免費 (the price line), and it joins their VoiceOver value.
  - **Beyond the plan:** Aozora's list rows (`AozoraWorkRow`) also show it. They are Aozora's browse rows, as the grid cards are Gutenberg's.
- **已下載 means the copy records an offline file** (plan decision 5). Whether the file exists is checked on the detail page.
- **Measured:** 10,000 copies build in 29 ms (Debug `-Onone`, simulator); a memoized read takes 12 µs. Span: `library.copyLookup.build`.

```
✔ Test run with 53 tests in 6 suites passed (CopyLookupTests, RemoteLibraryServiceTests,
   RemoteReadingRecordTests, AozoraLibraryDownloadServiceTests, RemoteLibraryWritingTests,
   PublicLibraryStorefrontTests)
§19 Phase 2 regression (every name in Guardrails), plus 2a's suites, CopyLookupTests and
AozoraLibraryDownloadServiceTests:
✔ Test run with 173 tests in 28 suites passed after 1.805 seconds; XCTest RemotePDFReaderTests passed
UI: RemoteLibraryNavigationUITests, PublicLibraryStorefrontUITests (3), PublicLibraryExploreUITests (2),
    RemoteLibrarySettingsUITests: Executed 7 tests, with 0 failures
```

### 2d (2026-10-11)

Branch `unified-library/2d-webdav-index`, on `9466ab8f`. Merged by the maintainer's standing instruction of 2026-10-11 (merge each step that passes, do not push).

- **Strings:** the seven reviewed strings, in five languages. The maintainer kept 「在背景建立書籍索引」 and the proposed status wording.
- **`OPDSCatalog.indexesBooks: Bool?`** (decoded with `decodeIfPresent`). `OPDSCatalogStore.indexesBooks(_:)` resolves it:
  - Unset means on, except for the copy of the WebDAV backup account.
  - The migration now writes `false` for that copy.
  - A pre-2d copy is recognized by `isBackupAccountCopy`: the migration flag is set, and the URL and username match `webdav_url` / `webdav_username`. A library the reader added by hand with exactly the backup account's address and user is treated the same way, and they can turn it on.
- **`NetworkPathMonitor`** (`NWPathMonitor`): background work is allowed on a satisfied path over Wi-Fi or wired that is neither expensive nor constrained. The end-to-end test shows the simulator reports such a path.
- **`WebDAVIndexer`** crawls breadth-first with `PROPFIND Depth: 1`. Only importable book files become records (1a's derivation), with ETag, date and size.
  - It saves after each batch. Stop-after-batch is for the background; cancellation is for Wi-Fi lost, setting off, or connection removed.
  - Outcomes are typed. A failure keeps the frontier, so the next start resumes.
  - Per-folder `works.webdav.list` spans log only above 500 ms; one `works.webdav.crawl` span per run.
- **`RemoteRecordStore`** (`Works/remote/<connection id>.json`, owned by `BookStore` as `remoteRecords`):
  - Serial atomic writes and a revision.
  - A file that does not decode is discarded; an unreadable one is never written over.
  - A removed connection is retired, so a crawl's late save cannot bring its file back.
  - `visibleFiles` is the last complete crawl, updated by the crawl in progress. A file removed on the server leaves only when a crawl completes.
- **`WebDAVIndexCoordinator`** (`.shared`, attached at launch with the app's store; `setActive` from the scene phase):
  - It runs one connection at a time, keeps summaries in memory (files are read off main), and publishes `statuses` for 遠端書庫's rows.
  - **Its own client per run** (`liveLister`): `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` are off, and the password is read on main at start.
  - **Entering the background** sets stop-after-batch under a `BackgroundTaskHold`.
  - **An authentication failure** stops that connection until the connections change or the app launches again. Deviation: the plan said "until its credentials change", but a password edit leaves `catalogs` equal, so any edit counts.
  - **A network failure while off Wi-Fi** is recorded as a pause, not a failure.
- **UI:**
  - The editor shows the toggle for WebDAV, with its footer.
  - 遠端書庫's WebDAV rows add the status line, read with the row as one VoiceOver element.
  - A paused-in-background crawl still shows 正在建立索引, because it resumes on return.
  - `#Preview` "Row states" shows all five statuses.
- **Work index:**
  - `WorkIndexFile` schema 2 adds `remoteInputs`; version-1 files are discarded and rebuilt.
  - Remote records are entries keyed by their source item, reused when unchanged.
  - The remote store's revision joins the stale check.
  - A WebDAV record and the shelf copy of the same file join by `sameSourceItem` (tested).
- **Measured against a real WebDAV server** (the maintainer: 「你自己測試 webdav」), not the planned in-process `NWListener` fixture:
  - The server was macOS's own Apache with `mod_dav`/`mod_dav_fs` on `127.0.0.1:8088`, serving synthetic trees from the scratchpad. Nothing was downloaded.
  - Configuration: iPhone 18 Pro simulator, Debug with `SWIFT_OPTIMIZATION_LEVEL=-O`, final limits.

| Tree | Books / folders | Saves | Crawl | Index file | Load | Work index refresh |
|---|---|---|---|---|---|---|
| t1k | 1,000 / 40 | 1 | 81 ms | 340 KB | 7 ms | 85 ms |
| t5k | 4,953 / 127 | 2 | 393 ms | 1.8 MB | 34 ms | 317 ms |
| t20k | 20,470 / 2,047 | 21 | 3.5 s (1.7 ms a folder) | 8.5 MB | 146 ms | 1.33 s |

  PROPFIND of one folder took 1.3 ms with 10 children, 3.7 ms with 100, and 25.8 ms with 1,000. A real NAS adds its round trip to every folder.
  - **Limits** (`WebDAVIndexLimits.standard`), with the reason for each in its doc comment:
    - **Depth 10:** not measured.
    - **Batch 100 folders:** with 20, the 20k tree took about 100 whole-file rewrites; 100 takes 21. The batch finished on entering the background is about 3 s at ~30 ms a folder.
    - **20,000 files:** the work index refresh is 1.3 s at that size.
    - **Recrawl daily:** not measured.
  - **Phase 5 note:** a 20k-record refresh is 1.3 s off main. The first caller should refresh once per indexing completion, not per view.
- **End to end** (`RemoteLibrarySettingsUITests.testWebDAVLibraryIndexesItself`, opt-in by `TEST_RUNNER_YUEDU_WEBDAV_BENCHMARK_URL`):
  - Add a WebDAV library at `…/t1k/` in Settings. The toggle is on by default.
  - The row reaches 「Indexed (1000 books)」 on its own within about 20 s (screenshot checked).
- **Also on this branch:** `5a1baa9a` removes the close button from book-source management. 2b pushed it everywhere but left the xmark. The page now has no stack or close button of its own, and `PublicLibraryExploreUITests` asserts the close button is gone.

```
✔ Test run with 50 tests in 7 suites passed (WebDAVIndexerTests, RemoteRecordStoreTests,
   WebDAVIndexCoordinatorTests, WorkIndexRemoteRecordsTests, WorkIndexServiceTests, WorkIndexTests,
   RemoteLibraryConnectionTests)
§19 Phase 2 regression plus 2a–2d suites, WorkIndex*, BookStoreMetadataWriteBudgetTests,
ICloudSyncChangeDetectionTests, DismissalSequencedPresentationTests:
✔ Test run with 230 tests in 36 suites passed after 1.816 seconds; XCTest RemotePDFReaderTests passed
UI (with TEST_RUNNER_YUEDU_WEBDAV_BENCHMARK_URL): RemoteLibrarySettingsUITests (2, end to end included),
    RemoteLibraryNavigationUITests, PublicLibraryStorefrontUITests (3), PublicLibraryExploreUITests (2),
    BookSourceManagementUITests: Executed 10 tests, with 1 skipped (the opt-in source-pack test), 0 failures
ruby scripts/check_localizations.rb: OK
```
