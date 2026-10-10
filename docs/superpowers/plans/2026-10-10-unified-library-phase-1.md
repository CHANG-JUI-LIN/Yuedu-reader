# Unified Library, Phase 1 — Implementation Plan

> **For the implementer.** Read [AGENTS.md](../../../AGENTS.md) and [CLAUDE.md](../../../CLAUDE.md) first, then the design sections each task cites. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> - Design: [Technotes/UnifiedLibrary-2026-10-08-design.md](../../../Technotes/UnifiedLibrary-2026-10-08-design.md) — §3 (D1–D6), §4–§8, §10, §15 (Phase 1 and 交接), §16 item 9, §17 items 1–3, §19.
> - Audit: [Technotes/UnifiedLibrary-2026-10-08-audit.md](../../../Technotes/UnifiedLibrary-2026-10-08-audit.md) — §4–§7, §8.3, §16 items 2 and 5, appendix A.
> - Previous plan: [2026-10-10-unified-library-phase-0.md](2026-10-10-unified-library-phase-0.md). Its guardrails apply here too.
>
> Line numbers are from `main` at `f394ab40`. Re-read each file before editing; other sessions commit to `main` all day.

**Goal:** the data model the later phases stand on, without changing what readers see or what syncs:
- **1a:** derive a source record from every kind of book and remote item, and fix the 書籍資訊 「來源」 row;
- **1b:** keep the identifiers and metadata that imports throw away today, in a sidecar, never in `ReadingBook`;
- **1c:** a work index rebuilt from those records, merging on shared identifiers (A-level) and on title + author (B-level, labeled and splittable);
- **1d:** a store for the reader's decisions, a resolver for each field's effective value, and lock checks on the three paths that overwrite a copy's title.

**Today:**
- A book's origin is one `source` string, which doubles as a format tag. The 「來源」 row recognizes only `"local"`, so every EPUB, PDF, comic, audiobook and remote book reads 「網頁匯入」 (audit §16 item 2; `HomeView.swift:1481`).
- EPUB OPF identifiers, languages, descriptions and subjects are read and dropped. So are OPDS languages and summaries, Calibre's ISBN and uuid on the book itself, and Aozora's catalog fields (audit §5.3, §7.3).
- Nothing links two copies of the same book.
- Three paths overwrite a copy's title: online refresh, Calibre write-back and WebDAV rename. Nothing records where a title came from, and the reader cannot lock one (audit §7.2).

---

## Scope

**In:**
- 1a, 1b, 1d;
- 1c with A-level merging (shared identifiers or the same source item) and B-level merging (title + author). The maintainer settled §17 item 1 on 2026-10-10: yes, labeled and splittable.

**Out:**
- **Any screen beyond the 「來源」 row.** There is no work page, unified search or lock UI yet. Phase 1 ships dormant: nothing in production builds the index or sets a lock.
- **Syncing decisions** (Phase S2, §17 item 2), and a portable key for remote connections (§17 item 3). Decisions anchored on remote connections stay device-local until then.
- **Changing `ReadingBook`.** No field is added (D1).

---

## Decisions

### Made while planning

Each comes with its reason; the maintainer can overturn any of them.

1. **The plan is in English,** like Phase 0's.
2. **Order: 1a → 1b → 1c → 1d, one branch each, each cut from `main` after the previous one merges.** This is stricter than the design's 交接 table:
   - **1c needs 1b.** A-level merging of a local EPUB needs its OPF ISBN, which only 1b captures. Without it, 《三體》 EPUB versus Calibre cannot merge.
   - **1c defines `WorkDecision`,** as a pure input to the index, so its "split stays split" fixture can run. 1d adds the store that persists decisions.
   - Branches: `unified-library/1a-source-records`, `1b-imported-metadata`, `1c-work-index`, `1d-decisions-and-locks`.
3. **One URL normalizer.** `BookStore.onlineBookURLKey` (`BookStore.swift:3046`, private) backs the "already on shelf" lookup (`onlineBook(sourceId:bookInfoURL:)`, `:1058`). 1a moves it unchanged into a shared `OnlineBookURLKey.normalize(_:)`, used by both the lookup and the source record. It does not write a second normalizer.
4. **Every copy has two keys.**
   - Its **copy key**, `SourceItemKey(.library, "local", ReadingBook.id)`. It syncs with the book, so it is portable.
   - Its **current source key**, for example `bookSource/<bookSourceUrl>/<normalized detail URL>`.
   - Locks and overrides on a copy's own display fields (title, author) anchor to the copy key. The current source key changes on 換源, and a lock anchored there would vanish (design §8.2, D3).
5. **The 「來源」 row uses existing localized keys, plus one new one.** The full mapping is in Task 1a and is for review: the maintainer's rule is that names never change silently. A remote copy whose connection was removed has no existing string, so 遠端書庫 is added (zh-Hans 远程书库, en Remote Library, ja リモートライブラリ, ko 원격 서재; maintainer, 2026-10-10).
6. **1b stores `MetadataValue`s, keyed by copy.**
   - One file per copy: `Application Support/Works/metadata/<ReadingBook.id>.json`. Inside: `schemaVersion`, the copy's source key, `[ExternalIdentifier]` and `[MetadataValue]`.
   - That is design §10.1's `Works/metadata/`, sharded per copy, the unit imports know.
   - The values carry provider and source item, so 1d's resolver reads them as they are.
7. **One OPF reader.**
   - Readium's `Metadata` keeps only the unique identifier. 1b first checks `otherMetadata` for the remaining `dc:identifier`s.
   - If they are not there, it extends the existing `parseOPFMetadataXML` (`PublicationSession.swift:633`) to collect every `dc:identifier` with its scheme, instead of adding a second parser.
   - Languages, description and subjects come from Readium `Metadata`.
8. **No background scans.** Existing books get their sidecar from an on-demand API that a later work page calls. Phase 1 adds the API and no trigger.
9. **The index is built on demand,** from a snapshot taken on the main actor and computed off it. The result is applied only if `BookStore.mutationRevision` is unchanged, as `snapshotForSync` does (`BookStore.swift:2396-2448`). Nothing polls the revision, which would be a timing wait. Incremental updates compare per-copy fingerprints of identity fields, since the revision is a global counter (`:87`).
10. **`works.*` spans are measured, not asserted.**
    - An environment-gated benchmark (`YUEDU_WORKS_BENCHMARK=1`) builds and searches 2,000 copies plus 5,000 remote records, and prints the three spans.
    - §10.4's 200 ms and 16 ms thresholds are suggestions for the maintainer, and Debug `-Onone` numbers would not judge them fairly.
    - The numbers go into this plan's "What landed".
11. **Privacy in logs.** `AppLogger` writes `.public`. Works spans and logs carry counts and kinds only, never titles or authors; Calibre and WebDAV titles are the reader's private library (design §10.3).
12. **Names.** Code comments say "unified library 1b". `AozoraBookImporter` already uses "Phase 1b, route C" for an unrelated plan.

### Settled by the maintainer (2026-10-10)

1. **§17 item 1, B-level auto-merge: yes.** Merges are labeled 「依書名與作者判斷」 and can be split; a split is permanent. 1c.4 is built in Phase 1, on by default.
2. **No flag for Phase 1.** Rollback means reverting the step's merge and deleting `Application Support/Works/`. This deviates from design §15, which assumes a flag "like `ReaderFeatureFlags`". That type is dead code (follow-up 1), and Phase 1 ships dormant except for the 「來源」 row.
3. **Calibre write-back on a locked title:** the server edit goes through, but a copy whose title is locked keeps it, and one `AppLogger` line notes the skip.

### The questions as they were asked

1. **§17 item 1, B-level auto-merge.** Should two copies whose titles match after `WorkMatchKey` normalization, and whose authors are both present and compatible, merge automatically, labeled 「依書名與作者判斷」 and splittable? The design recommends yes; the MVP needs it. This decides whether 1c.4 is built now.
2. **A flag for Phase 1.** The design says screen-affecting steps sit behind a UserDefaults flag "like `ReaderFeatureFlags`". But `ReaderFeatureFlags` (`Models.swift:1086`) is never read on `main`, and Phase 1 changes one label. Phase 1's rollback text in §15 assumes a flag.
   - (a) No flag. Rollback means reverting the step and deleting `Works/`. This is a deviation from the design, stated here.
   - (b) A small `UnifiedLibraryFlags` gating the new 「來源」 label and 1b's sidecar writes.
3. **Calibre write-back on a locked title.** Calibre write-back is an explicit edit the reader makes in this app.
   - (a) The server edit goes through, but a copy whose title is locked keeps it, and one `AppLogger` line notes the skip.
   - (b) The lock steps aside for this path.
   The design checks locks on all three paths, which is (a).

---

## Context

### Copies and their origins (1a)

- **`ReadingBook`** (`Models.swift:208`) has:
  - `title` 210, `author` 211, `source` 212, `contentPipelineKind` 214 (`epub | txt | html | manga | fixedPage | audio`; `resolvedPipelineKind` 468);
  - `isInBookshelf` 220, `remoteSource: RemoteBookReference?` 221, `isOnline` 224, `bookSourceId: UUID?` 225, `bookInfoURL` 226, `aozora: AozoraBookSource?` 305.
  - It has no language, identifier or kind flag.
  - `strippedForSync()` is at 191; the hash is `ICloudSyncManager.stableHash` (`ICloudSyncManager.swift:855`).
- **Values of `source`:**
  - `"local"`: TXT and Markdown (`BookStore.swift:359`, `:647`), `.json` imports (`LocalBookImportService.swift:35`), and remote non-EPUB/PDF files (`RemoteLibraryService.swift:79`);
  - `"local_epub"`: `BookStore.swift:760` and remote EPUB `:77`. Aozora books are here too, through `importEpub`;
  - `"local_pdf"`: `:524` and remote `:78`;
  - `"local_manga"`: `:450`;
  - `"local_audio"`: `:618`;
  - a detail URL for book-source books (`addOnlineBook`, `:1431`, `isOnline = true`, `bookSourceId` set);
  - a page URL for browser imports (`addWebBrowsedBook`, `:1674`, `bookSourceId = nil`, `isOnline = true`), and for `importWeb`/`saveBook` (`:799`, `:2299`, `isOnline = false`).
- **Remote copies** keep a `local*` source; their identity is `remoteSource` (`RemoteBookReference`: `connectionID`, `entryID`, `format`… `RemoteLibraryItem.swift:34`). Gutenberg copies are remote copies with `connectionID == "builtin.gutenberg"`.
- **Calibre wireless copies** look like local files. Their uuid lives only in `calibre-wireless-device.json` (`CalibreDeviceRegistry`, keyed by `bookID` = `ReadingBook.id`, `CalibreWirelessService.swift:320-321`).
- **Remote items** before they become copies:
  - `OPDSEntry` (`OPDSClient.swift:43`): `id`, `title`, `author`, `authorNames`, `summary`, `acquisitions`, `isBook`;
  - `RemoteLibraryItem` (`RemoteLibraryItem.swift:21`);
  - `WebDAVBrowseClient.Entry`: `id` = absolute URL. The root is `webDAVClient(for:).rootURL`, which has a trailing `/`. There is no relative-path helper;
  - `OnlineBook` (`BookSource.swift:404`), with `OnlineBookContentKind` `text | audio | manga` (`:420`);
  - `AozoraWork` (`AozoraCatalog.swift:34`);
  - `GutenbergBook` / `PublicLibraryBook` (`PublicLibraryBookPresentation.swift:5`, `:48`).
- **Book sources:** `BookSourceStore.shared.source(id:)` (`BookSourceStore.swift:95`) returns `bookSourceUrl` (`BookSource.swift:249`).
- **The 「來源」 row** (`HomeView.swift:1477-1483`): `book.source == "local" ? localized("本機文件") : localized("網頁匯入")`. Existing keys: 本機文件, 網頁匯入, 網路書籍, 來源配置, Project Gutenberg, 青空文庫, and `RemoteLibraryKind.libraryTitle` (OPDS 書庫, WebDAV 書庫, Calibre 書庫; `OPDSImportView.swift:427`).

### Imports (1b)

- **`BookStore.importEpub`** (`:666`) opens a `PublicationSession` (`:723`/`:725`), builds the book at `:757`, and persists at `:779-780`.
  - `session.publication.metadata` has `identifier` (unique only), `languages`, `description`, `subjects`, `publishers` and `published`.
  - `session.language` is the first `dc:language` from our own parser.
- **`LocalBookImportService.importBook`** (`:18`) dispatches by extension, then applies the caller's title/author and saves again (`:53-57`).
- **`RemoteLibraryService.record`** (`:45`) builds the copy from `RemoteLibraryItem` at `:62` and drops `summary`.
  - `RemoteLibraryBookRoute.init(entry:)` (`RemoteLibraryBookDetailView.swift:10-24`) drops `authorNames` before that.
  - The OPDS 1 parser reads no language or identifier besides `<id>` (`OPDSFeedParserDelegate`, `:244`).
  - OPDS 2 decodes `language` and drops it (`OPDS2FeedParser.swift:245-258`).
- **Calibre wireless:** `receiveBook` (`CalibreWirelessService.swift:269`). The whole metadata dictionary is in `incoming.metadata` (uuid, isbn and the rest), and it imports through `LocalBookImportService` at `:313`.
- **Aozora:** `AozoraLibraryDownloadService.addToShelf(work:store:)` (`:34`) has the whole `AozoraWork` in memory (`id`, `yomi`, `ndc`, `kanaStyle`, `credits`…) and keeps only `title` and `catalogWorkID` (`:69-71`).
- **Sidecar precedents:**
  - `BookChapterStore`: one file per book (`books_meta.chapters/<id>.json`), flushed on `BookStore.persistQueue`. Removal is gated by `recordsLoadedCompletely` (`BookStore.swift:2452`).
  - `BookReaderSettingsStore`: version field, `writesBlocked`, keep-aside of corrupt files.
- **Hash precedent:** `ICloudSyncChangeDetectionTests.hash(_:)` = `stableHash(book.strippedForSync())` (`:39-41`).

### Work index and decisions (1c, 1d)

- **`BookStore`:**
  - `mutationRevision` (`:87`) is a global `UInt64`, bumped on every `records` write. It is not published.
  - `readingBooks` (`:129`) holds every copy, shelf or not. `books` (`:113`) holds the shelf only.
- **Normalization to reuse:**
  - `AIBM25Index.searchText` (`AIBM25Index.swift:92-95`): NFKC plus Traditional→Simplified plus lowercase;
  - `AozoraCatalog.normalized` (`:119`): kana folding.
  - No shared punctuation-stripping helper exists.
- **Store templates:**
  - `BookReaderSettingsStore`: version, `writesBlocked`, keep-aside, sorted-keys atomic writes;
  - `BookSourceStore`: a serial `persistQueue` with newest-snapshot coalescing (`:976-1050`);
  - `OfflineDownloadModels.swift:201-270`: tolerant decoding with `schemaVersion`.
  - `StorageLocations.directory(_:)` (`:216-220`) creates folders.
- **The three overwrite paths:**
  - **Online refresh:** `commitRefreshedList` (`BookStore.swift:2150-2199`). The title/author write is at `:2171-2179`, and it runs only when `infoPackage` is non-nil, that is `forceInfoRefresh || tocURL.isEmpty` (`:1930`). It writes `records[index]` directly. **No test asserts this overwrite today.**
  - **Calibre write-back:** `RemoteLibraryWritingService.updateMetadata` (`:154-191`, writes at `:177-188` through `saveReadingBook`).
  - **WebDAV rename:** `reconcileMove` (`:222-235`, title at `:232`).
- **Concurrency:** the app target is Swift 5 mode with no approachable concurrency (`project.pbxproj` `:862`, `:916`). The test target has `SWIFT_APPROACHABLE_CONCURRENCY = YES`. `BookStore` methods are individually `@MainActor`, and background work uses `Task.detached` and serial queues.

---

## Guardrails

Phase 0's guardrails apply in full. In particular:

- `bash scripts/xctest.sh -- -collect-test-diagnostics never -only-testing:'yuedu appTests/<StructName>'`, and check the suite count in the verdict.
- No `-derivedDataPath`. Delete your own `.xcresult`s.
- The checkout is shared. Never switch the main checkout's branch while another session works there; ask before a worktree, since it means about 5 GB of DerivedData.
- Commit only your own files.

Phase 1 adds:

- **`ReadingBook` does not change** (D1). No field, no new write. A test pins its `CodingKeys` set (1b).
- **`Works/` files** follow design §10.1: top-level `schemaVersion`, tolerant decoding, refuse writes after a failed read (keep a corrupt file aside first, as 0d does), and serial atomic writes. `index.json` is discarded and rebuilt on a schema change; `decisions.json` changes need an explicit migration and test.
- **Pure first.** Derivation, matching, merging and resolving are pure functions on value types (`Sendable`, `Hashable`, `Codable`), tested without singletons. Stores and services wrap them.
- **No new localized strings** unless a step says so. If one appears, all five languages and `ruby scripts/check_localizations.rb`.
- **UI** (1a only): invoke `yuedu-ios-design`; the row reads the same way in VoiceOver, now with the right value.

---

## File map

**Create**
- `Modules/Services/Works/SourceRecord.swift` (1a): `ProviderType`, `SourceInstanceKey`, `SourceItemKey`, `ExternalIdentifier` (with normalization), `ContentKind`, `AcquisitionOption`, `SourceRecord`.
- `Modules/Services/Works/SourceRecordDerivation.swift` (1a): pure derivations, `OnlineBookURLKey`, the WebDAV relative path.
- `Modules/Services/Works/MetadataValue.swift` (1b): `MetadataField`, `MetadataPayload`, `MetadataValue`.
- `Modules/Services/Works/ImportedMetadataStore.swift` (1b).
- `Modules/Services/Works/ImportedMetadataCapture.swift` (1b): per-import extraction.
- `Modules/Services/Works/WorkMatchKey.swift` (1c).
- `Modules/Services/Works/WorkIndex.swift` (1c): `Work`, `Edition`, the union-find, `WorkDecision`.
- `Modules/Services/Works/WorkIndexService.swift` (1c): snapshot, build and apply, `index.json`, spans.
- `Modules/Services/Works/WorkDecisionsStore.swift` (1d).
- `Modules/Services/Works/MetadataResolver.swift` (1d).
- Tests:
  - `SourceRecordDerivationTests` (1a);
  - `ImportedMetadataCaptureTests` and `ImportedMetadataStoreTests` (1b);
  - `WorkMatchKeyTests`, `WorkIndexTests` and `WorkIndexServiceTests` (1c);
  - `WorkDecisionsStoreTests`, `MetadataResolverTests` and `TitleOverwriteLockTests` (1d);
  - `WorkIndexBenchmarkTests`, env-gated (1c).

**Modify**
- `Modules/Features/Bookshelf/HomeView.swift` (1a): the 「來源」 row only.
- `Modules/Services/LibraryStore/BookStore.swift`:
  - 1a: `onlineBookURLKey` moves out, with identical behavior;
  - 1b: one capture call in `importEpub` and the other `import*` functions, plus sidecar removal in `delete` and in `removeChapters(notIn:)`'s sibling;
  - 1d: a lock check in `commitRefreshedList`.
- `Modules/Services/RemoteLibrary/RemoteLibraryService.swift` (1b): capture in `record`.
- `Modules/Features/Bookshelf/RemoteLibraryBookDetailView.swift` (1b): `RemoteLibraryItem` keeps `authorNames` and language.
- `Modules/Services/OPDS/OPDSClient.swift`, `OPDSFeedParser…`, `OPDS2FeedParser.swift` (1b): `OPDSEntry` gains optional `language` and `identifiers`.
- `Modules/Services/Calibre/CalibreWirelessService.swift`, `Modules/Services/PublicLibrary/AozoraLibraryDownloadService.swift` (1b): capture.
- `Modules/Core/EPUB/PublicationSession.swift` (1b, only if `otherMetadata` lacks the identifiers): `parseOPFMetadataXML` collects all `dc:identifier`s.
- `Modules/Services/RemoteLibrary/RemoteLibraryWritingService.swift` (1d): lock checks.
- `Modules/Services/LibraryStore/StorageLocations.swift` (1b): `works`.
- This plan: "What landed" after each step.

---

## Task 1a: Source records, and the 「來源」 row

**Branch:** `unified-library/1a-source-records`. Design §5, §6; audit §16 item 2.

- [ ] **Step 1: Types.** In `SourceRecord.swift`, add the design §5 types listed in the file map, as value types.
  - `ExternalIdentifier.normalized(scheme:value:)`:
    - ISBN-10 → ISBN-13, without hyphens or spaces, check digit verified, invalid rejected;
    - uuid lowercased without `urn:uuid:`;
    - Gutenberg number from `urn:gutenberg:N[:edition]` or `…/ebooks/N`;
    - the Aozora work id as is.
- [ ] **Step 2: Move the URL key.** Move `BookStore.onlineBookURLKey` to `OnlineBookURLKey.normalize(_:)`, unchanged: trim, drop the fragment, lowercase. `onlineBook(sourceId:bookInfoURL:)` calls it.
  - Test first: a table of URLs (fragment, case, whitespace, nil) keeps today's output, and the shelf lookup still finds a book added with a differently cased URL.
- [ ] **Step 3: Derivations**, each a pure function with a table-driven test in `SourceRecordDerivationTests`:

  | Input | Instance | Item | Identifiers | Kind |
  |---|---|---|---|---|
  | `ReadingBook`, local file (`local*`, no `remoteSource`, no `aozora`) | `library/local` | `ReadingBook.id` | — (1b adds OPF) | from `resolvedPipelineKind`: `manga` → comic, `audio` → audio, else text |
  | `ReadingBook` with `aozora` | `aozora/builtin.aozora` | `catalogWorkID`; if nil, falls back to `library/local/<id>` | `aozoraWork` | text |
  | `ReadingBook` with `remoteSource`, connection kind OPDS / WebDAV / Calibre | `opds\|webDAV\|calibre/<connectionID>` | OPDS/Calibre: `entryID`; WebDAV: path relative to the root | Calibre: `calibreUUID` from `urn:uuid:`; OPDS: `isbn13` from `urn:isbn:` | from the format extension and pipeline kind |
  | `ReadingBook` with `remoteSource.connectionID == builtin.gutenberg` | `gutenberg/builtin.gutenberg` | the ebook number | `gutenberg` | text |
  | `ReadingBook`, book source (`isOnline`, `bookSourceId`) | `bookSource/<bookSourceUrl>` | `OnlineBookURLKey.normalize(bookInfoURL ?? source)` | — | from `contentPipelineKind` |
  | same, source deleted | `bookSource/missing:<uuid>` | same | — | same |
  | `ReadingBook`, browser import (`bookSourceId == nil`, URL source) | `library/local` | `ReadingBook.id` | — | text |
  | `OPDSEntry` + connection | per connection kind | `entry.id` | as above | from acquisitions |
  | `WebDAVBrowseClient.Entry` + root | `webDAV/<connectionID>` | relative path | — | from extension |
  | `OnlineBook` + `BookSource` | `bookSource/<bookSourceUrl>` | normalized `bookUrl` | — | `OnlineBookContentKind` |
  | `AozoraWork` | `aozora/builtin.aozora` | `work.id` | `aozoraWork` | text |
  | `GutenbergBook` | `gutenberg/builtin.gutenberg` | ebook number | `gutenberg` | text |

  - Every `ReadingBook` record also carries its copy key `library/local/<id>` and `copyID` (decision 4).
  - The WebDAV relative path is the percent-encoded path after the root path. Test with CJK and spaces, and with an entry outside the root, which is rejected and logged.
  - Calibre wireless copies derive as local files here. Their uuid joins in 1b from the device registry.
- [ ] **Step 4: The 「來源」 row.** It shows `SourceLabel.text(for: book, record:)`, a pure function with a table test:

  | Copy | Shows (existing key) |
  |---|---|
  | local file, any format | 本機文件 |
  | browser import or `importWeb` | 網頁匯入 |
  | book source | 網路書籍 |
  | OPDS / WebDAV / Calibre copy | that kind's `libraryTitle`: OPDS 書庫 / WebDAV 書庫 / Calibre 書庫 |
  | Gutenberg | Project Gutenberg |
  | Aozora | 青空文庫 |
  | remote copy whose connection was removed | 遠端書庫 (new) |

  - Only the value text changes; the row's layout, label and accessibility do not.
  - Invoke `yuedu-ios-design`, and add a `#Preview` of the 書籍資訊 section with one copy of each kind if the section has none.
- [ ] **Step 5: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/SourceRecordDerivationTests' \
    -only-testing:'yuedu appTests/RemoteReadingRecordTests' \
    -only-testing:'yuedu appTests/RemoteLibraryBrowsePresentationTests' \
    -only-testing:'yuedu appTests/LocalBookImportServiceTests' \
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests'
  ruby scripts/check_localizations.rb
  ```

**1a acceptance:**
- every entry type has a table-driven derivation test;
- the shelf lookup's behavior is unchanged with the moved normalizer;
- the 「來源」 row shows the table above;
- no `ReadingBook` change.

---

## Task 1b: Keep imported metadata in a sidecar

**Branch:** `unified-library/1b-imported-metadata`, from `main` after 1a. Design §8.2, D1.

- [ ] **Step 1: Pin `ReadingBook`** before touching an import. A test lists `ReadingBook.CodingKeys` (golden set from `main`) and fails on any change. A second test imports an EPUB fixture, then checks two things:
  - `stableHash(book.strippedForSync())` of the returned book equals the hash of the same book after `BookStore` reloads from disk;
  - the store's `mutationRevision` advanced only by the import's own writes.
- [ ] **Step 2: Types and store.**
  - `MetadataField`, `MetadataPayload` (text, texts, number, date, cover reference) and `MetadataValue` follow design §5.
  - `ImportedMetadataStore` owns `Works/metadata/<copyID>.json`, containing `{schemaVersion: 1, copyID, sourceItem, identifiers, values}`.
  - Writes go through one serial queue with atomic replace, coalescing per copy.
  - A file that fails to read is kept aside (`…corrupt-<mtime>.json`) before it is ever rewritten; one that cannot be read or copied blocks writes for that copy (0d's rule).
  - `remove(copyID:)` and `remove(notIn:)`. The latter runs only when `BookStore.recordsLoadedCompletely`, as `removeChapters(notIn:)` does (`BookStore.swift:2452`).
  - Tests in `ImportedMetadataStoreTests`: round trip, a corrupt file kept aside, an unreadable file never written over, removal gated on a complete load.
- [ ] **Step 3: Extraction,** as pure functions in `ImportedMetadataCapture` (`ImportedMetadataCaptureTests`):
  - **EPUB:**
    - all `dc:identifier`s, typed: ISBN normalized to `isbn13`, `urn:uuid:` to `epubUniqueIdentifier`, and other values kept as `epubUniqueIdentifier` (compared only within that scheme);
    - `languages`, `description` (plain text, at most 300 characters for the summary value, full text kept), `subjects`, `publishers`, `published`.
    - First check whether Readium's `otherMetadata` holds the non-unique identifiers. If not, extend `parseOPFMetadataXML` (decision 7).
    - Fixtures: an OPF with an ISBN-10, an ISBN-13 and a uuid; one with several languages; one with none of these.
  - **OPDS 1 and 2:**
    - `OPDSEntry` gains optional `language` and `identifiers`, parsed from `dc:language` and `dc:identifier` (OPDS 1) and from `metadata.language` and `identifier` (OPDS 2).
    - `RemoteLibraryItem` keeps `authorNames`, `language` and `identifiers`, which `RemoteLibraryBookRoute.init` stops dropping.
    - Update `OPDSParserTests`, `OPDS2ParserTests` and `GutenbergOPDS2FixtureTests` for the new fields.
  - **Calibre wireless:** from `incoming.metadata`: `uuid` → `calibreUUID`; `isbn` and `identifiers.isbn` → `isbn13`; `languages`, `tags`, `comments`, `series`, `series_index`, `publisher`, `pubdate`.
  - **Aozora:** `aozoraWork` from `work.id`; language `ja`; `yomi`, `ndc` and `kanaStyle` as tags; credits as author names when the index is available.
- [ ] **Step 4: Capture at import.** One call per entry point, after the copy is built and before or alongside its first persist, without changing the copy. Every call passes values only:
  - `importEpub` (`:757-780`; the session is still open);
  - `importLocalManga`, `importLocalPDF`, `importLocalAudiobook`, `importTxt` (identity only: no OPF);
  - `RemoteLibraryService.record` (`:62`, from the `RemoteLibraryItem`);
  - `CalibreWirelessService.receiveBook` (`:313-321`, after `LocalBookImportService` returns the copy);
  - `AozoraLibraryDownloadService.addToShelf` (`:69-71`);
  - `BookStore.addOnlineBook` (`:1421`, identity and kind only).
  - `LocalBookImportService`'s title-override re-save (`:53-57`) neither needs nor triggers a second capture.
- [ ] **Step 5: On demand for existing books.** `ImportedMetadataCapture.captureIfMissing(copy:)` reads what it can from the copy's file or registry and writes the sidecar. Test it on a copy imported before this step. No trigger calls it in Phase 1 (decision 8).
- [ ] **Step 6: Deletion.** `BookStore.delete` removes the copy's sidecar, and the post-sync cleanup calls `remove(notIn:)` under the same gate as the table of contents. Test both, including that an incomplete load removes nothing.
- [ ] **Step 7: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/ImportedMetadataCaptureTests' \
    -only-testing:'yuedu appTests/ImportedMetadataStoreTests' \
    -only-testing:'yuedu appTests/ICloudSyncChangeDetectionTests' \
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests' \
    -only-testing:'yuedu appTests/RemoteReadingRecordTests' \
    -only-testing:'yuedu appTests/LocalBookImportServiceTests' \
    -only-testing:'yuedu appTests/ICloudAudioSyncExclusionTests' \
    -only-testing:'yuedu appTests/AozoraLibraryDownloadServiceTests' \
    -only-testing:'yuedu appTests/OPDSParserTests' \
    -only-testing:'yuedu appTests/OPDS2ParserTests' \
    -only-testing:'yuedu appTests/GutenbergOPDS2FixtureTests' \
    -only-testing:'yuedu appTests/CalibreWirelessReceiverTests'
  ```

  `ICloudAudioSyncExclusionTests` lives in `LocalAudiobookArchiveTests.swift:177`.

**1b acceptance:**
- the `ReadingBook` key set and hashes are unchanged;
- each import kind leaves a sidecar with its identifiers and metadata;
- existing books get one only on demand;
- deleting a copy removes its sidecar.

---

## Task 1c: The work index

**Branch:** `unified-library/1c-work-index`, from `main` after 1b. Design §7, §10.2, §10.4.

- [ ] **Step 1: `WorkMatchKey`** (design §7.1). It is pure; `WorkMatchKeyTests` covers:
  - title: NFKC, lowercase, Traditional → Simplified (reusing the transform `AIBM25Index.searchText` uses, `AIBM25Index.swift:92-95`), kana folding (as `AozoraCatalog.normalized`), and removal of Unicode P\* and S\* characters including 《》「」【】.
  - Digits and bracketed text are kept: 三體 ≠ 三體II, 斗罗大陆 ≠ 斗罗大陆3.
  - Display text is never normalized.
  - Authors use the containment rule with at least 2 characters (`SearchAggregator.swift:125-131`).
  - Nothing else is stripped until real data is measured.
- [ ] **Step 2: Types.** `Work`, `Edition` (language or script plus content kind; Calibre formats of one book share an edition), `MatchEvidence` (`.identifier(ExternalIdentifier)`, `.sameSourceItem`, later `.titleAuthor`) and `WorkDecision` (design §5, all referring to `SourceItemKey`s).
- [ ] **Step 3: The union-find** (design §7.3), deterministic: the same records and decisions always give the same works, editions and ordering. `WorkIndexTests` covers:
  - **《三體》** zh-Hans EPUB (OPF ISBN X) + Calibre EPUB and PDF (uuid U, ISBN X) + OPDS zh-Hant (ISBN X) → one work, two editions (zh-Hans with three records, zh-Hant with one), evidence `identifier(isbn13 X)`;
  - 《三體》 and 《三體II》 with different ISBNs → two works;
  - same title, incompatible authors, no shared identifier → two works (B-level needs compatible authors);
  - a comic adaptation sharing a title → two works (content kind differs; A-level does not even try);
  - a translation (en) → its own work;
  - Calibre EPUB and PDF of one uuid → one edition;
  - a `differentWorks` decision between two records sharing an ISBN → two works, whatever else matches ("rejection always wins");
  - a `sameWork` decision → one work;
  - two copies of the same source item, for example two shelf entries of one OPDS entry → one work.
- [ ] **Step 4: B-level** (settled 2026-10-10: yes). Merging on equal `WorkMatchKey` titles plus present, compatible authors plus same content kind plus compatible language, with evidence `.titleAuthor`. zh-Hans and zh-Hant are compatible but separate editions.
  - `WorkIndexPolicy.titleAuthorMerging` defaults to `true`. It is a policy value for tests and a later "split" UI, not a feature flag.
  - Fixtures: 《三體》 without ISBNs merges; with one author missing it does not (C-level, suggestion only); with a `differentWorks` decision it does not.
- [ ] **Step 5: `WorkIndexService`.**
  - It snapshots `readingBooks` plus the source URL map on the main actor, builds off it, and applies only if `mutationRevision` is unchanged (decision 9).
  - It persists `Works/index.json` with `schemaVersion`, discarded on mismatch.
  - Incremental: per-copy fingerprints of identity fields decide which records to re-derive.
  - Spans: `works.index.build`, `works.index.load`, `works.search.local`, with counts only (decision 11).
  - `WorkIndexServiceTests`: a stale snapshot is dropped; an incremental update after adding or removing a copy equals a full rebuild; a corrupt `index.json` is discarded and rebuilt; nothing is built until asked.
- [ ] **Step 6: Benchmark.** `WorkIndexBenchmarkTests`, enabled with `YUEDU_WORKS_BENCHMARK=1`: 2,000 synthetic copies plus 5,000 remote records. It prints build, load and one local search in milliseconds. The numbers go to "What landed" for the maintainer's §10.4 decision.
- [ ] **Step 7: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/WorkMatchKeyTests' \
    -only-testing:'yuedu appTests/WorkIndexTests' \
    -only-testing:'yuedu appTests/WorkIndexServiceTests' \
    -only-testing:'yuedu appTests/SourceRecordDerivationTests' \
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests'
  TEST_RUNNER_YUEDU_WORKS_BENCHMARK=1 bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/WorkIndexBenchmarkTests'
  ```

**1c acceptance:**
- the fixtures above pass, B-level included;
- the index is deterministic, built only on demand, and rebuildable from nothing;
- benchmark numbers are recorded.

---

## Task 1d: Decisions, the resolver, and title locks

**Branch:** `unified-library/1d-decisions-and-locks`, from `main` after 1c. Design §8, D2, D3, D6.

- [ ] **Step 1: Characterize the three overwrite paths, unlocked,** before any change. `TitleOverwriteLockTests` covers:
  - online refresh with `forceInfoRefresh: true` and a fake fetcher whose `BookInfoPackage` names a different title and author → today the copy takes them (`BookStore.swift:2171-2179`);
  - Calibre write-back → every local format of that Calibre book takes the new title and authors (`RemoteLibraryWritingService.swift:177-188`; reuse `RemoteLibraryWritingTests`' fixtures);
  - WebDAV rename → the copy's title becomes the new file name (`:232`).
- [ ] **Step 2: `WorkDecisionsStore`.**
  - It owns `Works/decisions.json`, authoritative: `{schemaVersion: 1, decisions: [WorkDecision]}`.
  - Writes are serial and atomic, with keep-aside-then-write for corrupt files and blocked writes for unreadable ones.
  - Queries: `isLocked(field:anchor:)`, `override(field:anchor:)`, `decisions(involving:)`.
  - `WorkDecisionsStoreTests`: round trip, a corrupt file kept aside, an unreadable file never written over, a future `schemaVersion` refused for writing.
- [ ] **Step 3: `MetadataResolver`** (design §8.1), pure. The precedence is user override > lock (the value frozen when the lock was set) > chosen candidate > field priority > the copy's own value.
  - Each result carries its provenance.
  - Fields follow §8.1's table. Title and author never fill in automatically.
  - `MetadataResolverTests` is table-driven per rule, including that a lock freezes the value at lock time while newer values arrive.
- [ ] **Step 4: Lock checks.** Before writing `title` or `author`, each path asks the store about the copy key (decision 4). When locked, it keeps the copy's value and logs one `AppLogger` line with the copy id and path, not the title.
  - **Online refresh:** in `commitRefreshedList`. The other refreshed fields (`tocURL`, `runtimeVariables`, chapters) still update.
  - **Calibre write-back** (settled: the server edit goes through): only the locked copies' local title is skipped.
  - **WebDAV rename:** `remoteSource` follows the new path, and the locked title stays.
  - Extend `TitleOverwriteLockTests`: with a lock, each path keeps the title; without one, Step 1's expectations hold unchanged.
- [ ] **Step 5: Run and commit.**

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/TitleOverwriteLockTests' \
    -only-testing:'yuedu appTests/WorkDecisionsStoreTests' \
    -only-testing:'yuedu appTests/MetadataResolverTests' \
    -only-testing:'yuedu appTests/RemoteLibraryWritingTests' \
    -only-testing:'yuedu appTests/BookStoreBackgroundPublishTests' \
    -only-testing:'yuedu appTests/LibraryRefreshScaleTests' \
    -only-testing:'yuedu appTests/BookStoreMetadataWriteBudgetTests' \
    -only-testing:'yuedu appTests/ICloudSyncChangeDetectionTests'
  ```

  Also run the two online-refresh tests in `yuedu_appTests.swift`, struct `yuedu_appTests`. Swift Testing functions need `()` in `-only-testing`:

  ```bash
  bash scripts/xctest.sh -- -collect-test-diagnostics never \
    -only-testing:'yuedu appTests/yuedu_appTests/refreshOnlineBookMetadataRepairsLegacyShelfEntry()' \
    -only-testing:'yuedu appTests/yuedu_appTests/refreshOnlineBookMetadataPersistsFirstTOCPageBeforeFullFetchCompletes()'
  ```

**1d acceptance:**
- without a lock, all three paths behave exactly as Step 1 recorded;
- with one, the title stays and one log line says why;
- decisions survive a relaunch and a corrupt file.

---

## Acceptance (Phase 1)

- [x] 1a: source records for every entry type; the 「來源」 row fixed; one URL normalizer.
- [x] 1b: sidecar metadata for every import; `ReadingBook` keys and hashes unchanged.
- [x] 1c: deterministic index, A-level and B-level, with the design's fixtures; benchmark numbers recorded.
- [ ] 1d: decisions store, resolver, locks on three paths, unlocked behavior unchanged.
- [ ] Every step: its own branch from `main` after the previous one merges; its tests and the §19 Phase 1 regression pass after its last edit; nothing pushed or merged without the maintainer's yes.
- [ ] Rollback: revert the step's merge and delete `Application Support/Works/`. No `ReadingBook` or sync content changed (design §15).

## Follow-ups found while planning

1. **`ReaderFeatureFlags` is dead code** (`Models.swift:1086`): never read on `main`. Phase 1 adds no flag (settled 2); deleting the type is a separate cleanup.
2. **`BookStore.delete` leaves files behind** (audit §16 item 5). 1b removes its own sidecar but none of the rest.
3. **`DiscoverKindsCache.key` joins its inputs with an unescaped `|`** (found in Phase 0a). It can collide; it is unrelated to Phase 1.

## What landed

_Fill in per step: commit, test verdict lines, surprises, and anything left undone._

### 1a (2026-10-10)

Branch `unified-library/1a-source-records`, on `f394ab40`. Two commits: `28791650` (records, derivations, shared URL key, the row) and `233f02ca` (遠端書庫). Not merged, not pushed.

- **Types** are in `Modules/Services/Works/SourceRecord.swift`. `ExternalIdentifier.normalized` turns ISBN-10 into ISBN-13 with both check digits verified, and lowercases Calibre uuids without `urn:uuid:`. A Gutenberg number may be given bare, as `urn:gutenberg:N`, or as a `…/ebooks/N` URL; an Aozora work id is kept as it is.
- **Derivations** are in `SourceRecordDerivation.swift`. A `SourceRecordContext` answers source URLs, connection kinds and WebDAV roots: `live()` reads the stores, and tests pass dictionaries.
  - The WebDAV item key is the percent-*decoded* path below the root, so two spellings of one path give one key. The plan said percent-encoded; decoded is what landed.
  - A copy whose connection was removed keeps its copy key.
- **`OnlineBookURLKey.normalize`** replaced `BookStore.onlineBookURLKey`, with identical body. Both lookup call sites use it.
- **The 「來源」 row** reads `SourceLabel.text(for:record:)`, with the table in Task 1a plus 遠端書庫. The existing 「書籍資訊 – 封面區」 `#Preview` covers the section.
- **Surprise found by the tests:** `normalized(.gutenberg, "1342")` returned nil, because it only accepted urns and URLs, so every derived Gutenberg record had no identifier. It is fixed, and a test covers the bare number.
- **Evidence:**

```
✔ Test run with 42 tests in 5 suites passed after 0.431 seconds.
   (SourceRecordDerivationTests, RemoteReadingRecordTests, RemoteLibraryBrowsePresentationTests,
    LocalBookImportServiceTests, BookStoreMetadataWriteBudgetTests; on 28791650)
✔ Test run with 17 tests in 1 suite passed after 0.018 seconds.   (SourceRecordDerivationTests, on 233f02ca)
check_localizations: OK, 3329 keys
```

### 1b (2026-10-10)

Branch `unified-library/1b-imported-metadata`, on `346327dd`. Merged into `main` at `3accf360`; not pushed.

- **Types:** `MetadataField`, `MetadataPayload` (text, texts, number, date), `MetadataValue` and `ImportedMetadata` (`schemaVersion`, copy id, source item, identifiers, values), in `Modules/Services/Works/MetadataValue.swift`.
- **`ImportedMetadataStore`** keeps `<shelf folder>/Works/metadata/<copy id>.json` (production: `Application Support/Works/metadata`). It writes on one serial queue with atomic replace.
  - **Writes merge:** identifiers are unioned, and a value replaces one of the same field from the same place. An Aozora book first records its generated OPF, then its catalog work, and both survive.
  - **Damaged files:** an undecodable file is kept aside (`<id>.corrupt-<mtime>.json`); an unreadable one is never written over.
  - **Removal:** `BookStore.delete` removes the copy's sidecar. `remove(notIn:)` runs only after a complete load and after a sync is applied, beside `removeChapters(notIn:)`. Corrupt backups are kept.
- **OPF identifiers:** Readium drops every `dc:identifier` except the unique one (its `otherMetadata` excludes them all), so `PublicationSession.opfIdentifiers` reads them from the OPF with their `opf:scheme`. Languages, description, subjects, publishers and date come from Readium `Metadata`.
  - Classification: ISBN by scheme, `urn:isbn:`, or a valid ISBN shape; anything else as `epubUniqueIdentifier`. 1b read Calibre's `opf:scheme="calibre"` as the Calibre uuid. That identifier is Calibre's application id, so 1c corrected it (`7a52d0a5`): the uuid is the `opf:scheme="uuid"` identifier of a package that also carries Calibre's own.
- **OPDS:** `OPDSEntry` gained `language` and `identifiers`, read from `dc:language` and `dc:identifier` in OPDS 1 (local names, since the parser processes namespaces) and from `metadata.language` and `identifier` in OPDS 2. `RemoteLibraryItem` keeps `authorNames`, `language` and `identifiers`, which `RemoteLibraryBookRoute.init(entry:)` passes on.
- **Capture points:**
  - `importEpub`, after the copy is persisted;
  - `RemoteLibraryService.record`, both for a new copy and when an existing one is opened again. That is a reader's action, not a scan;
  - Calibre wireless `receiveBook`, after the registry is saved (uuid, ISBN, languages, tags, comments, series, series index, publisher, date). The copy stays a local copy, but its values are attributed to the sending library, `calibre/wireless:<library id>`. They sit beside the OPF values from the EPUB import rather than replacing them, so 1c can tell which source said what;
  - Aozora `importWork`, merged with the OPF.
- **Deviation from the plan:** TXT, PDF, comic, audiobook and book-source copies get no sidecar. They have nothing beyond what `SourceRecord` already derives, and an empty file would only be noise.
- **On demand:** `ImportedMetadataCapture.captureIfMissing(copy:store:)` reads a local EPUB copy's OPF. Nothing calls it in Phase 1.
- **One shape per field:** `language` is always `.texts`. The remote capture first wrote `.text`, and this was fixed before merge.
- **Removal is gated like chapter lists:** a shelf file that exists but does not decode removes no sidecar (tested). No production path deletes the shelf file.
- **`ReadingBook` is unchanged.** `ImportedMetadataImportTests` checks that the imported book's encoded keys are a subset of `CodingKeys` as of `346327dd`, and that its `stableHash(strippedForSync())` equals the hash of the copy reloaded from disk.

```
✔ Test run with 119 tests in 15 suites passed after 1.561 seconds.
   (ImportedMetadataCaptureTests, ImportedMetadataStoreTests, ImportedMetadataImportTests,
    ICloudSyncChangeDetectionTests, BookStoreMetadataWriteBudgetTests, RemoteReadingRecordTests,
    RemoteLibraryServiceTests,
    LocalBookImportServiceTests, ICloudAudioSyncExclusionTests, AozoraLibraryDownloadServiceTests,
    OPDSParserTests, OPDS2ParserTests, GutenbergOPDS2FixtureTests, CalibreWirelessReceiverTests,
    SourceRecordDerivationTests)
```

### 1c (2026-10-10)

Branch `unified-library/1c-work-index`, on `3accf360`. Not merged, not pushed.

- **`WorkMatchKey`** (`WorkMatchKey.swift`):
  - Folding: NFKC, lowercase, Traditional → Simplified, katakana → hiragana, then without Z\*, P\* and S\* characters and controls. Digits and bracketed text stay.
  - Authors use the containment rule at 2 characters or more, with an author required on both sides.
  - **`LanguageTag`** parses a tag's own subtags. `Locale.Language` fills in likely scripts: `zh` and `zho` become Hans, and `und` becomes Latn. A script therefore comes only from an explicit subtag or from a written region (`zh-TW` → Hant). ISO 639-2/B codes (`chi` …) map to their /T codes.
- **`WorkIndex.build`** (`WorkIndex.swift`) is a pure, deterministic union-find:
  - A-level joins on the same source item, then on each shared identifier among isbn13, calibreUUID, gutenberg, aozoraWork, openLibraryWork, openLibraryEdition and wikidata.
  - **`epubUniqueIdentifier` never merges**, because templates reuse package ids. It stays in the data.
  - B-level joins within a `WorkMatchKey` title bucket when authors are compatible (`WorkIndexPolicy.titleAuthorMerging`, default on). Such a work reports `isMergedByTitleAndAuthor`.
  - **Rejections are checked on the whole group at each join**, not pair by pair. Evidence never joins groups whose content kinds or known base languages differ, so zh ~ unknown ~ en cannot chain.
  - **Decisions:** `differentWorks` always wins. `sameWork` overrides the kind and language rules but never a `differentWorks`. A decision matches a record by its copy key or by its source key.
  - Every result is sorted; no `Set` or `Dictionary` order reaches the output. A test builds from the original, reversed and two seeded shuffles, and compares both the values and the sorted-keys JSON of the works.
  - **Editions** are language or script plus content kind:
    - A script-less tag joins the only edition of its language that has a script (`en` beside `en-US`), otherwise its own edition.
    - A copy with no language joins the only edition of its kind, otherwise `und`.
    - Neither guess ever splits a work.
  - `WorkDecision` has all five cases of design §5; only `sameWork` and `differentWorks` are read in 1c.
- **`WorkIndexService`** (`WorkIndexService.swift`, `Works/index.json`):
  - Nothing is built until `refresh()`; Phase 1 has no caller.
  - Records are derived on the main actor from plain maps. The WebDAV root is computed as `rootURL` does, without building a client, which would read the keychain per copy.
  - Sidecars are read and the index built in a detached task. The result is applied only if `mutationRevision` is unchanged; otherwise the call returns false.
  - **Incremental:** each copy keeps its record and its sidecar's stamp (modification date and size, from one listing of the folder). An unchanged copy keeps its entry; the union-find always reruns over all entries, since a removal can split a work. A sidecar written after its copy is saved changes no revision, and the stamp catches it (tested).
  - **Spans:** `works.index.snapshot`, `works.index.build`, `works.index.load` and `works.search.local`, with counts only.
  - **File rules:** another `schemaVersion`, or a file that does not decode, is discarded and rebuilt. A file that cannot be read is never written over, and the index then lives in memory. Dates use the default `Double` encoding, because ISO 8601 drops the sub-second part of a stamp and every copy would look changed on the next launch.
- **Each entry stores its folded title and author keys.** The first benchmark showed folding costs about 52 µs a string, nearly all of it in ICU's Traditional-Simplified transform, and the build folded the same strings several times. Caching the keys took the 7,000-entry pure build from 2,099 to 152 ms (Debug `-Onone`). Listing the sidecar folder once took a warm refresh from 209 to 77 ms.
- **Deviations from the plan and design:**
  - The only input in Phase 1 is copies. Design §7.3 also lists remote records the reader acted on, but nothing stores those yet. Acting on one (reading, adding) already makes it a copy.
  - The benchmark's 5,000 remote records go to the pure builder for the same reason.
  - The `works.index.snapshot` span is extra.

```
✔ Test run with 33 tests in 4 suites passed after 2.440 seconds.
   (WorkMatchKeyTests, WorkIndexTests, WorkIndexServiceTests, WorkIndexBenchmarkTests)
✔ Test run with 110 tests in 12 suites passed after 0.825 seconds, after the last edit.
   (WorkMatchKeyTests, WorkIndexTests, WorkIndexServiceTests, ImportedMetadataCaptureTests,
    ImportedMetadataStoreTests, ImportedMetadataImportTests, SourceRecordDerivationTests,
    BookStoreMetadataWriteBudgetTests, ICloudSyncChangeDetectionTests, RemoteLibraryServiceTests,
    CalibreWirelessReceiverTests, AozoraLibraryDownloadServiceTests)
```

Benchmark, iPhone 18 Pro simulator, 2,000 copies (1,400 titles, 40% with a sidecar ISBN) plus 5,000 remote records:

| Measure | Debug `-Onone` | Debug `-O` |
|---|---|---|
| `WorkMatchKey.title` × 7,000 | 386 ms | 355 ms |
| Service cold refresh (snapshot, sidecar reads, build) | 442 ms | 346 ms |
| Service warm refresh (load, stat, no rebuild) | 77 ms | 61 ms |
| `works.index.load` (decode 2.4 MB `index.json`) | 49 ms | 43 ms |
| `works.search.local`, 2,000 copies | 1.7 ms | 1.3 ms |
| Pure build, 7,000 entries (keys already folded) | 152 ms | 56 ms |
| Pure search, 7,000 entries | 2.7 ms | 2.1 ms |

`-O` is `SWIFT_OPTIMIZATION_LEVEL=-O` on the Debug configuration (Release would upload dSYMs). Folding barely changes with `-O`, since its cost is inside ICU. Against §10.4's suggested thresholds (load 200 ms, search 16 ms), both are well under, so no SQLite. That decision stays with the maintainer.
