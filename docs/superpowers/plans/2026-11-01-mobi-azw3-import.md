# MOBI and AZW3 import (2026-11-01)

Maintainer, 2026-11-01: other formats come later, 「譬如說什麼 mobi 之類的」; asked for this plan first
(「先寫計畫」). Settled in the same conversation, and the frame for everything below:

- **CoreText stays the one reader.** A new format is converted at import into an EPUB and read by the EPUB
  path as it is. No second renderer, no WebView route for reflowable text.
- **Port foliate-js's `mobi.js` (MIT) to Swift.** Not libmobi: its C sources are LGPL-3.0 (risky in an App
  Store app whose own licence forbids modified builds), and it ships Kindle PID decryption (`encryption.c`).
  `awxkee/libmobi-swift` is labelled CC0 but vendors those same 19 LGPL C files.

## Scope

| In | Out |
|---|---|
| Mobipocket, "MOBI6" (`.mobi`, `.prc`, Mobipocket-era `.azw`) | Any file whose PalmDOC `encryption` field is not 0: refused with a message, never decrypted |
| KF8 (`.azw3`), and the KF8 half of a combo `.mobi` (EXTH boundary record, as foliate opens it) | KFX (`.kfx`, Amazon's current format; not a PalmDB file at all) and Topaz (`.azw1`, `.tpz`) |
| DRM-free files only | AZW4 Print Replica (a PDF inside), FB2, PalmDOC `TEXt` `.pdb`: see Decisions |
| Reflowable and fixed-layout KF8 (fixed layout becomes a pre-paginated EPUB and takes the existing fixed-layout route) | Writing MOBI/AZW3 back out |

What the reader gets is what an EPUB of the same book gets: every reading mode, TTS, highlights, search,
vertical CJK (KF8 carries `writing-mode` in its CSS and `page-progression-direction` in its RESC record).

## How it fits: the Aozora pattern, not a new one

The app already converts one foreign format at import: Aozora Bunko text → EPUB 3
(`AozoraEPUBWriter`, `AozoraBookImporter`, `AozoraBookRegenerator`, `docs/aozora/epub-text-contract.md`).
MOBI follows the same contract, and shares its machinery where the machinery is not Aozora-specific:

- **The original is kept** next to the EPUB in the book files' folder and travels with the book, as
  `AozoraBookSource.originalFilename` does. A later converter can then rebuild the EPUB from it.
- **The EPUB records what wrote it** (`OPS/yuedu-mobi.json`: `converterVersion`, `textVersion`, the original's
  SHA-256, each chapter's text length and SHA-256), inside the EPUB and not on the synced book record — the
  reason `AozoraEPUBManifest` gives: a synced field would tell another device its own copy was regenerated.
- **Text is the contract.** Reading positions are `(spineIndex, charOffset)` into the converted chapters'
  text, and highlights hang off the same offsets. A converter change that leaves every chapter's text as it
  was regenerates silently on open; one that changes text bumps `textVersion` and ships with a position
  migration, never alone — exactly `AozoraBookRegenerator`'s outcomes (`current`, `regenerated`, `newer`,
  `textChanged`, `olderTextVersion`, `originalMissing`, `inUse`).
- **One regenerator.** The version check, the "never downgrade", the in-use guard and the atomic swap move out
  of `AozoraBookRegenerator` into a converter-agnostic core that both formats call; each format supplies
  only "read the original, write the EPUB". No second copy of that logic.

**Positions across devices.** A local book is safe from version skew: its EPUB syncs and is never
downgraded (`newer`), so every device reads the same text. A remote book's converted EPUB does not sync,
so two devices on different `textVersion`s would hold different texts under the same synced positions.
The rule, from the first release: a synced reading position, bookmark or highlight of a converted book
records the `textVersion` it indexes. A device applies one only at its own `textVersion` and maps an older
one forward with the migration when one exists, and never applies one of another version (this device's
next save replaces it). Last writer wins between devices, as for any book: with both sides stamped, a newer build maps an older stamp
forward and a first-release device refuses a newer one, so neither needs to hold the other back. This costs
one optional field now; retrofitting it after a text change cannot recover which text old positions meant.
*As built in step 4:* a device's own version is the manifest's `textVersion` in the EPUB it actually reads
(a local book's `newer` EPUB can sync down and be read at a version this build did not write), read by
`ConvertedBookRegenerator` before the reader exists, since the reader stages its restore as it appears
(`ConvertedTextVersions`). A record without a stamp reads as version 1.

Book record: a new optional `mobi` source on `ReadingBook`, beside `aozora` (`Models.swift:306`), holding
`originalFilename` (nil for a remote book, whose remote file is the original) and the detected kind
(`mobi6` / `kf8`). Optional with no default value, so books that
lack it keep their sync hash (the `ReadingBook` new-field rule).

## The converter: a map of `mobi.js`

`mobi.js` is 1,238 lines (johnfactotum/foliate-js, last change 2026-04-03, `9a676796`). Its browser-only
pieces (`DOMParser`, `Blob`, `document`, `TextDecoder`) have direct replacements here: SwiftSoup (already a
dependency) parses and serialises the XHTML; `String(decoding:)` / CFStringEncoding handle cp1252 and UTF-8;
`GzipDecoder`'s raw-DEFLATE `inflate` (`Modules/Core/ReaderCore/Customization/GzipDecoder.swift`) is made
shared for KF8's zlib-compressed fonts instead of adding a second inflater.

New folder `Modules/Core/MOBI/` (joins the target by itself):

| `mobi.js` | Swift | Notes |
|---|---|---|
| `PDB`, `PALMDOC_HEADER`, `MOBI_HEADER`, `KF8_HEADER`, `EXTH_HEADER` | `MOBIFile` (headers, record table) | Magic check: PDB type/creator `BOOKMOBI` at offset 60, not the extension |
| `decompressPalmDOC` | `PalmDOCDecompressor` | Compression 2 |
| `huffcdic` | `HuffCDICDecompressor` | Compression 17480. Calibre never writes it, so it is untestable without a real DRM-free sample; see Verification |
| trailing-entry removal | `MOBIFile.textRecord(_:)` | Multibyte flag and the varlen trailers |
| `getIndexData`, `INDX`/`TAGX`/`CNCX` | `MOBIIndex` | Shared by the KF8 skeleton/fragment tables and the NCX |
| `getNCX` | `MOBIIndex.ncx` | KF8 table of contents |
| `getEXTH`, `getMetadata`, `getCover` | `MOBIMetadata` | Title, authors, publisher, language, ISBN, description, subjects, cover/thumbnail offsets → the book record and the EPUB's OPF |
| `MOBI6` | `MOBI6Converter` | Split at `<mbp:pagebreak>`; `filepos` byte offsets → element ids and `href="chN.xhtml#id"`; `recindex` images → files; the guide's TOC page → nav, with foliate's indentation heuristic for nesting |
| `KF8` | `KF8Converter` | Skeleton + fragments → one XHTML per skeleton; FDST flows → CSS/SVG files; `kindle:embed` / `kindle:flow` → manifest items; `kindle:pos:fid:…:off:…` → `href#id`; fonts de-obfuscated (XOR key) and inflated; RESC spine `properties` → page spreads; EXTH `fixed-layout`, `original-resolution`, `page-progression-direction` → OPF rendition properties |
| — | `MOBIEPUBWriter` | EPUB 3 via ReadiumZIPFoundation, `mimetype` first and stored, as `AozoraEPUBWriter` does |

Attribution: the port keeps foliate-js's MIT notice in each file derived from it and in the app's
acknowledgements.

Errors are typed and logged through `AppLogger`, never `try?`: `encrypted`, `notMOBI`, `unknownCompression`,
`truncatedRecord`, `missingIndex`. Only `encrypted` and `unknownCompression` have their own user-facing
message; the rest share 「無法讀取這個檔案」.

## Import routes

Inventory of 2026-11-01, spot-checked. **Every route that puts a local file on the shelf ends in
`LocalBookImportService.importBook`** (`Modules/Services/LibraryStore/LocalBookImportService.swift:21`, a
switch on the extension). **Remote libraries never import**: OPDS, the Calibre content server, WebDAV and
Gutenberg read in place through `RemoteLibraryService`. Drag and drop and LAN upload do not exist.

### First: one format list instead of seven

The readable formats are written out by hand in seven places today:

| Gate | Where |
|---|---|
| Local import | `LocalBookImportService.supportedExtensions` (`:8-11`), `supportedContentTypes` from it |
| Calibre wireless | `CalibreWirelessHandshake.supportedExtensions` (`CalibreWirelessProtocol.swift:130`) |
| Remote library item | `RemoteLibraryFormat.isSupported` (`RemoteLibraryItem.swift:17`) |
| OPDS acquisition | `OPDSAcquisition.importExtension` / `preference` (`OPDSClient.swift:10-35`), also used by OPDS 2 |
| WebDAV browse | `WebDAVBrowseClient.isImportableBook` (`WebDAVBrowseClient.swift:14`) |
| Remote detail | `RemoteLibraryBookDetailView.preferredFormat` / `mimeType(for:)` (`:54-69`) |
| Remote upload | `RemoteLibraryWritingService` (`:107`), `RemoteLibraryManagementView` importer (`:85-86`) |

Consumers that already read one of these and need no list of their own:
`VersionReadingCopy.swift:35, 69-77` (`format.isSupported`), `WorkVersions.isReadable` (acquisitions, from
`importExtension`), `SourceRecordDerivation.contentKind(forExtensions:)` (`:248-255`: anything not all-audio
or all-comic is `.text`, so AZW3 counts as text for search's kind filter as it is).

Adding `mobi` and `azw3` to seven lists is the duplicate-path pattern this project forbids. Step 4 first
moves them onto one `BookFileFormat` table (extension, MIME types, magic check, display name, reading
preference, whether it converts), with no behaviour change and the existing tests green; then adds the two
formats once. Remote upload stays EPUB/PDF/TXT/Markdown: nothing here writes MOBI to a server.

Reading preference when a book offers several formats: EPUB 3, EPUB, **AZW3, MOBI**, PDF, TXT, Markdown.
A converted reflowable book reads better than a PDF; an EPUB needs no conversion.

### Route by route

| Route | Today | Change |
|---|---|---|
| Files importer (`AddBookView.swift:109-111`) | `allowedContentTypes: supportedContentTypes` | Gets the new types from the table. They must be declared (below): `mobi`/`azw3` have no system type, only `dyn.` ones (checked on this Mac) |
| Open In (`Info.plist` `CFBundleDocumentTypes` `:11-42`, `.onOpenURL` → `SharedImportQueueDrainer.openFile`) | One "Readable documents" entry; no MOBI type | `UTImportedTypeDeclarations` for `mobi`/`prc`/`azw` and `azw3` (MIME `application/x-mobipocket-ebook`, `application/x-mobi8-ebook`, conforming to `public.data`), added to the existing document type. Identifiers chosen after checking what other iOS readers declare, so "Open in" stays consistent; never a `dyn.` type. *Step 4:* declared as Readest does, `org.mobipocket.mobi` (mobi, prc) and `com.amazon.azw` (azw, azw3; also `application/vnd.amazon.ebook`); the document type also lists KOReader's `com.amazon.mobi-ebook` and `com.amazon.mobi8-ebook`, so a file another app typed opens here too. `BookFileFormatTests.declaredType` pins every Kindle extension to a declared type |
| Shared-import classifier (`SharedImportQueueDrainer.swift:551-596`) | `directLocalBookExtensions` inherits the import list; unknown binary throws `unsupportedPayload` | Inherits the extensions; also recognises `BOOKMOBI` at offset 60 in its sniff, for a shared link whose URL has no extension |
| Share extension (`ShareExtension/Info.plist:24`) | Web URLs only; files never reach it | None |
| Calibre wireless (`CalibreWirelessProtocol.swift:130-168`) | Accepts epub/pdf/txt/md | Accepts `azw3` and `mobi` after `epub`. Which format Calibre sends when a book has both is checked with the Calibre on this Mac, not assumed. *Step 4: not yet observed* — it needs Send to device pressed in Calibre's window (`LiveCalibreWirelessTests` is operator-driven); carried to step 6. `CalibreWirelessService.swift:371-373` sends back the original for Aozora books; same for MOBI books |
| Aozora-style storage (`AozoraBookImporter.swift:56-73`) | EPUB as `<UUID>.epub`, original as `<UUID>.aozora.txt`; a failed copy deletes the book | MOBI books store `<UUID>.epub` and `<UUID>.mobi.<ext>`, same failure rule; deleting the book removes the original (`BookStore.swift:1561-1568` extended) |
| Remote read in place (`RemoteLibraryService.prepare` `:177-257`, `prepareLocal` `:265-280`) | `default: throw unsupportedFormat` | AZW3/MOBI download to the cache as today, then convert to `book.epub` beside it in the same cache folder; the reader opens that. The converted EPUB is a cache, never synced; each device converts its own and follows the regenerator's outcomes like a local book (a text-unchanged upgrade rebuilds it, a text change waits for the migration). See "Positions across devices" |
| Remote reader source (`RemoteLibraryService.readerSource` `:98-104`) | epub → `local_epub`, pdf → `local_pdf`, **anything else → `local`, the TXT pipeline** | `mobi`/`azw3` → `local_epub`, and the remote book record gets `ReadingBook.mobi` (kind, no local original: the remote file is the original) so the 格式 chip shows AZW3/MOBI. Left alone, a converted remote AZW3 would open as a text book |
| Remote offline copy (`downloadOffline` `:320-350`) | Validation `default:` checks **any** non-EPUB/PDF file as TXT | An explicit MOBI case (parse headers, refuse DRM) before marking the copy complete; the offline original is what syncs (`syncableContentFilename` already returns `offlineFilename`) |
| OPDS / Gutenberg / Calibre server lists, work detail, WebDAV browse | A MOBI/AZW3-only book is shown with 「此格式暫不支援閱讀」 (`OPDSImportView.swift:348`, `WorkDetailView.swift:816-829`, `RemoteImportViews.swift:108-120`) | Becomes readable through the table. Calibre acquisition URLs carry no extension (`/get/EPUB/42/…`), so the MIME mapping is what matters there |
| WebDAV indexer (`WebDAVIndexer.swift:81`) | Silently drops non-importable files | Keeps `mobi`/`azw3` through the table |
| iCloud (`ICloudSyncManager.swift:1533-1553`) | Syncs the content file and, for Aozora, the original | Same for MOBI: the EPUB and the original. A regenerated EPUB of the same size is not re-uploaded (the `recordName:size` marker, `:1571-1574`); this already affects Aozora, and the regenerator's check of the manifest on open is what makes it harmless |

Tests that pin MOBI/AZW3 as unsupported today and change with step 4:
`RemoteLibraryBrowsePresentationTests.swift:71-77`, `CalibreWirelessProtocolTests.swift:68-71`,
`OPDSParserTests.swift:43-46`, `OPDS2ParserTests.swift:69`, `WorkDetailVersionsTests.swift:93, 109`.

Format label: `displayFormatLabel` (`Models.swift:543-578`) is read only by the reader card's 格式 chip
(`ReaderModernBookCard.swift:88`); remote rows use `RemoteLibraryFormat.displayName`. See Decisions.

Strings that list formats: `AddBookView.swift:67-68, 77` and `CalibreWirelessView.swift:100` gain MOBI and
AZW3. The onboarding copy (`OnboardingContent.swift:94`, `OnboardingState.swift:102`) is a pitch, not a
list, and stays as it is.

Found while mapping, not in this plan's scope: `OPDSClient.download(_:)` and
`WebDAVBrowseClient.download(_:)` have no callers; `app.yuedu.log-file` is exported for `.txt`
(`Info.plist:133-143`).

## Verification

**Fixtures (committed, small, all text public domain or our own):**

1. Hand-made EPUBs in `Tests/iOS/yuedu appTests/Fixtures/MOBI/`, each exercising one feature (nested TOC,
   internal links across chapters, inline and full-page images, embedded font, CSS classes, a table,
   vertical `writing-mode` with `page-progression-direction: rtl`, fixed layout), converted with Calibre
   9.17 (`/Applications/calibre.app/Contents/MacOS/ebook-convert`, already on this Mac) to AZW3 and to old
   MOBI. Calibre's output carries no licence of its own. The generating script is committed next to them.
2. One Project Gutenberg book in its "Kindles (kf8)" and "Older Kindles" downloads, beside the EPUB3 from
   the same page (`/ebooks/<n>.kf8.images`, `.kindle.images`, `.epub3.images`). Step 1 found these are made
   by Calibre as well (9.5.0, EXTH 108): a second book, not a second producer. Every fixture is therefore
   Calibre-made; KindleGen/Amazon files (other index layouts, `SRCS` records), cp1252 text and HUFF/CDIC
   have no real sample. The census and the gaps are in `Fixtures/MOBI/mobi-fixtures.md`.

**Conversion oracle:** for every fixture made from an EPUB, our converted EPUB is compared with the source
EPUB: each chapter's text (whitespace-normalised) equal, TOC titles and nesting equal, every image present,
every internal link resolving. Calibre-made files rename and re-split, so the comparison is by text, not by
file name.

**Engine on converted books:** the converted fixtures join a fidelity corpus (`scripts/fidelity`), so the
CoreText engine is measured on what the converter writes. That measures the engine, not the conversion; the
oracle above measures the conversion.

**HUFF/CDIC:** step 1 reads the compression field of the Gutenberg files. Without any DRM-free HUFF/CDIC
sample, the decompressor is not shipped: such a file gets the `unknownCompression` message and a log line,
and support is added when a sample exists. Shipping a decompressor no test has run is not done.

**Speed:** an import span (`⏱ mobi.convert`, per book: parse, decompress, assemble, write) in Release
Console. Machine-local only, never committed: the large CJK EPUBs in `~/Desktop/Test document/EPUB Format`
converted with Calibre to AZW3, timed before the change is reported done. foliate-js's own README calls its
HUFF/CDIC path slow; the Swift port's speed is measured, not assumed.

## Steps

1. **Parser core.** `MOBIFile`, PalmDOC, trailing entries, EXTH metadata, encryption refusal, magic
   detection; the fixture script and the Gutenberg pair; the compression census. *Done 2026-11-01
   (`MOBIFileTests`); the script makes `features` and `vertical-zh` so far.*
2. **MOBI6 → EPUB.** Sections, `filepos` links, images, guide TOC, writer, manifest; oracle tests.
   *Done 2026-11-01 (`MOBI6ConverterTests`: every fixture's text equals its source EPUB's word for word,
   digests pinned, links and pictures resolve, the written EPUB opens). The MOBI 6 NCX index moves to
   step 3 with `MOBIIndex`.*
3. **KF8 → EPUB.** Index tables, skeleton/fragment assembly, flows, embeds, fonts, NCX, `kindle:pos` links,
   RESC, vertical and fixed layout; oracle tests; the combo-file case. The MOBI 6 NCX index as its table of
   contents. An engine-parity test (as `AozoraEngineParityTests`) that lays converted MOBI 6 chapters out
   through the CoreText path: the hanging indent (negative `text-indent` + `margin-left`) and `rem`
   headings against the reader's chosen font size are markup choices the text contract freezes at the
   first release, so they are confirmed in the engine before step 4 ships anything. *Done 2026-11-01
   (`KF8ConverterTests`: all six KF8 fixtures equal their source EPUB word for word, pictures and the
   font byte for byte, digests pinned, the written EPUB opens with the source's direction and table of
   contents; `MOBIEngineParityTests`). Fixed layout waits for a real sample (Decided in step 3). The fixture
   script now also makes `embedded-font` and `fixed-layout`, and converts only the books it is named. Reading
   the NCX for MOBI 6 showed step 1 read the index field at 0xF4 whenever record 0 was long enough; it, and
   the KF8 index fields (0xF8 and longer), are now read only from headers that hold them, as the extra-data
   flags already were. Vertical books are checked where the reader decides: the renderer's CSS detection
   turns the conversion vertical exactly when it turns the source vertical.*
4. **Library.** The `BookFileFormat` table first (no behaviour change), then `ReadingBook.mobi`, the shared
   regenerator core (Aozora moved onto it, its tests unchanged), every route in the table above, the
   document types, sync of the original, and the `textVersion` stamp on the synced positions, bookmarks
   and highlights of converted books (Positions across devices): it ships with the first release or it
   cannot be added later. *Done 2026-11-02 (`BookFileFormatTests`, `MOBIBookImportTests`,
   `ConvertedTextVersionTests`, the remote Kindle cases in `RemoteLibraryServiceTests`, the extensionless
   sniff in `SharedImportQueueDrainerTests`; the seven gates' tests and the Aozora suites unchanged but for
   the five that pinned MOBI as unreadable). Decided in step 4, below. Calibre's choice between formats is
   carried to step 6.*
5. **UI and localisation.** Refusal messages, format label, supported-format lists, in all five `.lproj`
   (plus `InfoPlist.strings` and `ShareExtension/*.lproj` where the document types show); VoiceOver read
   back on each new string. *Done 2026-11-02 (`ImportFailureReasonTests`; `SharedImportQueueDrainerTests`'
   two failing-outcome cases now carry their reason; `check_localizations.rb` green). The format label
   shipped with step 4. `ShareExtension/*.lproj` needed nothing: the share extension takes web URLs only and
   declares no document type. VoiceOver: the new alert and `AddBookView`/Calibre texts are plain elements
   the system reads; the greyed bookmark row (`.combine`, no hint) was checked in code only, and is read
   back once a real bookmark of another text version exists (none can before a `textVersion` bump).
   Nothing wraps `PublicationSessionError` into `ReaderError` before logging (`asReaderError` has no
   caller), so its `cause=` reaches every log line it is in. Known gap: on a remote Kindle book, the
   regenerator's validation open is not mapped, so a converter that wrote a bad EPUB would show Readium's
   generic text there. Decided in step 5, below.*
6. **Verification.** Oracle over all fixtures, fidelity corpus run, import timings, one XCUITest importing
   an AZW3 through Files and opening it. *Done 2026-11-02 but for Calibre's choice between formats, which
   needs the maintainer's hand on Send to device (Found in step 6, below). The seven MOBI suites together
   pass; timings and memory are measured on a Release build; `KindleImportUITests` and the
   `corpus-mobi.json` fidelity run are new.*

## Decisions

Maintainer, 2026-11-01 (AskUserQuestion, all three recommendations taken):

1. **Remote libraries are in scope.** A Calibre/OPDS/WebDAV book offered only as MOBI or AZW3 becomes
   readable in this plan, through `RemoteLibraryService.prepare` and the offline copy (Import routes). It
   stays read-in-place: the converted EPUB is a per-device cache.
2. **The format label shows the original: AZW3 or MOBI.** `displayFormatLabel` reads `ReadingBook.mobi`'s
   kind before the pipeline, so the 格式 chip says AZW3/MOBI while the book reads as an EPUB; remote rows
   already show the acquisition's own format.
3. **MOBI and AZW3 only.** FB2, AZW4 and PalmDOC `.pdb` are later plans, each a converter feeding the same
   regenerator core and the same `BookFileFormat` table.

Decided here and disclosed, for veto:

- The original is kept and synced (the Aozora rule), so a better converter can rebuild every book.
- Synced positions, bookmarks and highlights of converted books record the `textVersion` they index
  (Positions across devices).
- A DRM'd file is refused with its own message and never decrypted.
- HUFF/CDIC ships only once a DRM-free sample has run through a test.
- Reading preference puts AZW3 and MOBI after EPUB and before PDF.
- Calibre wireless keeps EPUB first in its accepted list.
- The onboarding copy keeps its format pitch unchanged.

Decided in step 1 (`Modules/Core/MOBI/`), where the port departs from foliate:

- **Header fields by header length, as Calibre reads them.** The extra-record-data flags only for header
  lengths 0xE4…500, the KF8 index fields only when version is 8 and the record holds them. foliate reads
  fixed offsets, which on an old short header are EXTH bytes.
- **A combo file is KF8 only with its `BOUNDARY` record** (Calibre's test). foliate's "KF8 part failed to
  open, read the MOBI 6 part instead" is not ported: a broken KF8 part throws, so a converter bug cannot hide
  behind the older rendition.
- **No guessing an encoding.** A code page other than 1252 or 65001 is refused (`unsupportedEncoding`);
  Calibre assumes cp1252 there and foliate UTF-8. A malformed EXTH block is refused too, where Calibre drops
  it. Both stay refusals until a real file shows otherwise.
- **The parser core does not log.** It throws typed errors; the importer (step 4) logs them with the file's
  context, so the core compiles and tests without the app.

Decided in step 2 (`MOBI6Converter`, `MOBIMarkupNormalizer`, `MOBIEPUBWriter`, `EPUBPackageArchive`):

- **Kindle markup becomes inline CSS.** MOBI 6 has no CSS; `height` on a block is margin-top, `width` the
  first-line indent (negative hangs), `<font size>` the legacy 1–7 table in `rem`, `<center>`/`<tt>`/`<u>`/
  `<strike>`/`<big>` spans or divs. The engine reads no presentational attribute but an image's size and
  makes unknown tags blocks, so leaving them would change the layout. `p` has no margins of its own
  (`style/mobi.css`), because the space above a paragraph is the file's `height`.
- **`<br></br>` is one break**, as a Kindle shows it; an HTML parser reads two.
- **A section is dropped only when it is empty in every sense**: no text, no picture, nothing linking into
  it (Calibre ends a book with one). Calibre's cover page, which it moves to just before its table of
  contents, stays where the file has it.
- **`filepos` targets become ids on the element they stand before** (or an anchor inside it when it has an
  id), not empty inline anchors between blocks.
- **The chapter digest covers markup**: SHA-256 of the stylesheet followed by the chapter's XHTML. What the
  engine lays out, and so what positions index, depends on both; any output change is a text change, and
  `MOBI6ConverterTests.pinnedText` fails on it (a SwiftSoup upgrade can trip it too). Before the first
  release with MOBI import, re-pinning is the fix; after it, `textVersion` moves with a migration.
  `length` is informational. Every chapter's `<title>` is the book's title, not a TOC entry's, so a better
  table of contents (step 3's NCX index, which all four MOBI 6 fixtures carry) is not a text change.
- **MOBI 6 is horizontal**: no `primary-writing-mode` or `page-progression-direction`, as foliate reads EXTH
  527 for KF8 only.
- **A file with no guide table of contents** gets a single navigation entry, its title, at the first
  chapter (a navigation document needs one; the Aozora writer does the same). The MOBI 6 NCX index
  (Calibre writes one too) waits for `MOBIIndex` in step 3. A table-of-contents link without text gives its place
  to its children.
- **Broken references are dropped with a warning**, never invented: an image whose `recindex` holds no
  image is removed, a link past the text loses its `href`. The warnings go to the importer's log (step 4).
- **One OCF packer.** `EPUBPackageArchive` (staging, `mimetype` first and stored, the container) is shared
  with `AozoraEPUBWriter`, whose output is unchanged.

Decided in step 3 (`KF8Converter`, `MOBIIndex`, `MOBINCXEntry.read`):

- **MOBI 6 table of contents: the guide's page first, the NCX without one.** Calibre's MOBI 6 NCX is flat
  where its page nests as the source did; both point at the same bytes. One NCX reader serves both
  formats; an NCX that cannot be read leaves the book without a table of contents, with a warning.
- **KF8 markup is edited as bytes and text, never re-serialised.** A chapter holds the file's XHTML,
  `aid` attributes, XML declaration and the source's own `<title>` included; only `kindle:` URLs change,
  and an `id` is added where a link target has none.
- **A `kindle:pos` target is foliate's**: the first element with an `id`, `name` or `aid` at or after the
  byte. foliate looks only to the end of the fragment; here the search runs to the end of the section. An
  element without an `id` gets one made from its `aid` (`aid-UGI1`) or `name`, the attribute itself kept.
- **SVG flows an `<img>` names are put back inline**, as the source had them (Calibre's cover wrapper draws
  a picture an SVG used as an image cannot load); any other reference to an SVG flow becomes
  `images/flowNNNN.svg`. Stylesheet flows become `style/flowNNNN.css`. Only flows and resources the book
  names are written.
- **Fonts**: a `FONT` record is de-obfuscated (XOR over 1040 bytes, 1024 with a 16-byte key) and
  zlib-inflated with its Adler-32 checked (`GzipDecoder.decompressZlib`). Calibre writes flags 3 with a
  20-byte key, so the real fixture covers both; a font that cannot be read is left out with a warning,
  the book still converts.
- **Broken references are reported, never invented**: a link whose target cannot be found loses its
  `href`; a table-of-contents entry likewise is dropped with its children; a `kindle:embed` or
  `kindle:flow` URL the file cannot back stays as it is. A skeleton without fragments (foliate makes it
  non-linear and never loads it) is left out, and a chapter that is not well-formed XML after assembly is
  kept as it is. Every one of these is a warning for the importer's log.
- **Page progression from EXTH 527, writing mode from the stylesheets.** EXTH 525 is not written: Calibre
  writes `horizontal-rl` for a vertical book, which an OPF `primary-writing-mode` would make authoritative.
- **The text contract is MOBI 6's**: the digest is every stylesheet followed by the chapter's XHTML, pinned
  in `KF8ConverterTests.pinnedText`.
- **Fixed layout waits for a real sample** (maintainer, 2026-11-01, AskUserQuestion, recommendation taken).
  Calibre's KF8 output carries no EXTH 122/126 and no RESC record, so no fixture can show what a
  fixed-layout KF8 file from Amazon's tools holds. Until one exists every KF8 book converts reflowable, as
  Calibre's own Kindle output does; `KF8ConverterTests.fixedLayoutFromCalibre` records the census. The
  viewport `<meta>` of the source stays in the XHTML.

Decided in step 4 (`BookFileFormat`, `ConvertedBookRegenerator`, `MOBIBookImporter`, `RemoteLibraryService`,
`ConvertedTextVersions`), disclosed for veto:

- **One behaviour change in the gates' move onto the table:** a remote item offering both `md` and
  `markdown` used to rank `markdown` last (absent from the old map); both now rank as Markdown.
- **The regenerator converts into a missing EPUB.** A remote library's Kindle book is converted on its first
  open into its cache folder (`converted.epub` beside the cached or offline original), so the in-use guard
  and the manifest read apply only once an EPUB exists. The remote path passes no reader to the guard: a
  session over that EPUB is opened only after the regenerator, and a converter version is fixed for the
  process, so only a process's first preparation can rebuild it.
- **A failed rebuild of a remote book opens the EPUB it has**, as a local book does (logged); only a first
  conversion's failure reaches the reader.
- **The regenerator's validation open keeps its spine cache in the work folder.** By file name it was every
  conversion's `spine_cache_book.json` in Caches, which the next conversion read back unchecked (Aozora's too).
- **A combination `.mobi` shows AZW3**: the chip names the rendition the book is read from.
- **Bookmarks of another text version** are not drawn, do not merge with new highlights, take no part in a
  page's bookmark toggle, and are not jumped to (logged); the bookmark list still shows them, greyed (step
  5). Only a book whose EPUB came from a later converter can have them.
- **A Firestore position write sets or deletes `textVersion` explicitly**: the write merges, and an
  unstamped position would otherwise keep the stamp of the one it replaced.
- **Saves made outside a reader** (a work's chapter jump, a shelf merge) before any reader opened the book in
  the process are unstamped, which reads as version 1.
- Not done here: the `mobi.convert` / `mobi.regenerate` spans are not added to `SourcePerfTrace`'s doc list,
  which does not list Aozora's either and holds another session's edit; Aozora books are not stamped yet
  (follow-up: their unstamped records must read as the Aozora text version current at that time).

Decided in step 5 (maintainer, 2026-11-02, AskUserQuestion):

- **Every import route says why a file failed, for every format** (maintainer's choice over the
  recommended Kindle-only). The Files importer always printed `error.localizedDescription`; Open In and the
  share sheet printed only 「N 個項目匯入失敗」. `SharedImportQueueDrainer.Outcome.failures` now carries
  `name: reason` per failure (every `recordFailure` site, the legacy book-source queues included), and the
  alert lists the first three under the count (`ContentView.sharedImportReasonLimit`).
- **The errors those routes meet speak to the reader**: `MOBIError` and `MOBIEPUBWriter.WriteError` (in
  `MOBIBookImporter.swift`, so the parser core stays free of the app), the Aozora importer's and writer's,
  `BookParserRegistryError`, the drainer's own `ImportError`, `BookSourceStore.ImportError` (its decoder
  detail kept: it names the key a source's author has to fix) and `PublicationSessionError`. Readium's errors
  become `PublicationSessionError.parsingFailed` where an import opens the EPUB
  (`BookStore.importEpub(requireValidPublication:)`), not in `PublicationSession.open`, which every reader
  shares. Comic, PDF, audio, TXT, OPML and replace-rule errors were already localized; OS errors (Cocoa,
  URL, JSON) are the system's own. `PublicationSessionError`'s new sentences also reach the reader's own
  open failures, which showed the English diagnostic before.
- **The log keeps what the sentence leaves out.** `DiagnosableError.diagnosticDescription`, written by
  `AppLogger` as `cause=` on the same line (os_log and 診斷與回報 alike): the old English text, or the case
  with its payload (`corruptIndex(record: 7)`).
- **A DRM'd file is named as protected, nothing more**: 「這個 Kindle 檔案有 DRM 保護，無法開啟」.
- **Bookmarks of another text version are listed greyed, with a line saying why, and cannot be tapped**
  (recommended option). In edit mode they select and delete like the rest; VoiceOver reads the row as one
  element with the reason and no 「點兩下跳至此頁」.
- **Format lists name AZW3 and MOBI** in the Files importer (its detail line: 「沒有 DRM 的 Kindle 電子書
  （.azw3 / .azw / .mobi / .prc）」) and Calibre wireless; new keys, the old ones left as the tables keep
  them.

Found in step 6 (2026-11-02):

- **Fixture oracle:** the seven MOBI suites together (`MOBIFileTests`, `MOBI6ConverterTests`,
  `KF8ConverterTests`, `MOBIEngineParityTests`, `MOBIBookImportTests`, `ConvertedTextVersionTests`,
  `ImportFailureReasonTests`): 77 tests, all passed.
- **Speed** (`⏱ mobi.convert`: read, parse, decompress, assemble, write). A Release build on an iPhone 18 Pro
  simulator (iOS 27.0) on this Mac, each file opened in the app through Open In
  (`xcrun simctl openurl <udid> file://…`, the route a device takes), twice. Calibre 9.17 made the AZW3s
  (KF8 only) and the MOBIs (MOBI 6 only) from the corpus EPUBs; "text" is the text length in record 0.

  | Book | Kind | File | Text | Run 1 | Run 2 |
  |---|---|---:|---:|---:|---:|
  | 紅樓夢＋大觀紅樓 | KF8 | 69 MiB | 9.4 MiB | 2400 ms | 2406 ms |
  | 三國演義注評 | KF8 | 140 MiB | 5.0 MiB | 2967 ms | 2957 ms |
  | 全職高手 3 | KF8 | 156 MiB | 21.1 MiB | 4723 ms | 4844 ms |
  | 劍來 (1) | KF8 | 155 MiB | 48.7 MiB | 5683 ms | 5592 ms |
  | 詭秘之主 4 | KF8 | 229 MiB | 19.7 MiB | 5654 ms | 5540 ms |
  | 詭秘之主 4 | MOBI 6 | 141 MiB | 23.1 MiB | 6496 ms | 6543 ms |
  | 劍來 (1) | MOBI 6 | 59 MiB | 57.8 MiB | 11017 ms | 10988 ms |

  The system's copy into `Documents/Inbox` comes before the span, and the import's EPUB open and persist
  after it (about 80 ms here). MOBI 6 is the slow one: 劍來's 58 MiB of text takes twice what its KF8 does.
  No sub-stage spans exist, so where the time goes inside the convert is not known yet.
- **Memory** (simulator RSS, from a fresh launch; not a device footprint): 詭秘之主 4 AZW3 558 → 1122 MB
  (+564 MB), 劍來 MOBI 6 549 → 1206 MB (+657 MB). `MOBIBookImporter.convert` reads the whole file with
  `Data(contentsOf:)` while the header sniff beside it maps the file; the converted pictures are copies of
  the original's records. Whether this fits a device's limit is not measured.
- **Fidelity** (`scripts/fidelity/corpus-mobi.json`, run `mobi-2026-11-02`, engine 0.11.0). The corpus is
  machine-local: each source EPUB beside the EPUBs the import made from its AZW3 and MOBI. The oracle
  compares our engine with WebKit on the *same* EPUB, so it measures how the reader lays out the converted
  markup; whether the conversion kept the text is what the fixture tests pin. 16 of 19 books reach 80.

  | Book | Source | AZW3 | MOBI 6 |
  |---|---:|---:|---:|
  | features | 82.7 | 90.4 | 93.4 (combo 90.4, uncompressed 93.4) |
  | gutenberg-11 | 72.9 | 87.7 | 84.4 |
  | vertical-zh | 79.6 | **63.4** | 97.3 (MOBI 6 is always horizontal) |
  | embedded-font | 94.6 | 99.7 | — |
  | 詭秘之主 (guimi) | 95.1 | 97.5 | — |
  | 全職高手 (quanzhi) | 97.3 | 97.3 | — |
  | 紅樓夢 (redchamber) | 91.3 | 91.9 | — |

  Every conversion scores at or above its source but one. The sources score lower where Calibre's output
  avoids a legacy fallback: nine gutenberg-11 chapters fall back on media queries, which Calibre's
  stylesheets do not carry over.

  vertical-zh's AZW3 loses its points on one page: the inline table of contents Calibre writes into every
  AZW3 (`calibre_generated_inline_toc`, `c0004.xhtml`), which the AZW3 carries and the conversion keeps.
  Its stylesheet sets no writing mode, so WebKit lays it out horizontally. The reader turns the whole book
  vertical once any chapter is (`cssDetectedVerticalWritingMode`, `ReaderView`), so the engine lays it out
  vertically: 12.2, with 44.7 points lost on writing mode alone. Any EPUB that mixes writing modes meets
  the same thing; the conversion does not change it. *Maintainer, 2026-11-02: keep the page, as Kindle,
  Readest and KOReader do; the reader deciding writing mode per chapter is a plan of its own.* The AZW3's
  two text chapters lay out as the source's do (layout 97–98 against 96–98) but lose about ten more paint
  points (48–49 against 37–39). Not looked into; Calibre's stylesheets add a 5 pt body margin, `@page`
  margins and explicit heading styles the source does not have.

  gutenberg-11's lowest chapter in both conversions (`c0003.xhtml`, 47.3 and 63.8) is its title page:
  two centred lines and an `<hr>`. The `<hr>` is the only thing painted there, and nearly all the lost
  points are its border paint (98 and 79). The source's title page is not in the sample, so there is no
  direct comparison.
- **UI test:** `KindleImportUITests` puts `features.azw3` in Files' On My iPhone, picks it in the
  document picker, waits for the shelf, opens it (the first chapter is one page turn past the cover), and
  deletes it. It passes on iOS 26.0 (iPhone 17 Pro, 58 s) and on iOS 17.5 (iPhone 15 Pro, 48 s), where
  Import from Files goes through the dismissal-sequenced chooser. The shelf has no long-press menu: a press opens
  the book, and deleting goes through the cell's ••• menu.
- **Calibre's choice between formats is still unobserved.** Computer use is refused for Calibre by policy,
  so Send to device needs the maintainer's hand. Ready for it: a scratch library at
  `~/Library/Caches/YueduMOBI/calibre-library` holding `features` as EPUB and AZW3 in one record (open it
  with `CALIBRE_CONFIG_DIRECTORY` pointed elsewhere, so the maintainer's own Calibre settings stay
  untouched), and `LiveCalibreWirelessTests` now prints the `lpath` it received, whose extension is the
  format Calibre chose. The run: `open -n -a calibre --env CALIBRE_CONFIG_DIRECTORY=…/calibre-config`;
  Connect/share › Start wireless device connection; find its port with `lsof -iTCP -sTCP:LISTEN` on the
  Calibre process; then the test with `TEST_RUNNER_YUEDU_LIVE_CALIBRE_WIRELESS_HOST=127.0.0.1` and `…_PORT`,
  and Send to device within 180 s of `READY_FOR_SEND`. Tried 2026-11-02: the wireless connection was never
  started, and the maintainer chose to commit first and observe later.
- **Found, not caused here:** nothing removed what Open In leaves in `Documents/Inbox`, so every book
  another app handed over (AirDrop, Mail, a chat app, `simctl openurl` of a Mac path) stayed there a second
  time, EPUBs as much as Kindle files. Files opened from the Files app are not copied: the built app has
  `LSSupportsOpeningDocumentsInPlace` (from `INFOPLIST_KEY_…` in the project). Fixed 2026-11-02: `openFile`
  deletes its own copy once the import is over, and a sweep as the app goes to the background takes
  earlier builds' leftovers.
