# Per-chapter writing mode (2026-11-02)

Maintainer, 2026-11-02, after the MOBI/AZW3 verification (`2026-11-01-mobi-azw3-import.md`, step 6): keep
Calibre's generated inline table of contents in conversions and fix the root cause in the reader, as its own
plan. Nothing here works around it in the MOBI converter: `KF8ConverterTests` pins that page as the
conversion's last chapter.

**Precondition.** The MOBI work is uncommitted in this checkout and touches files this plan changes
(`ReaderView.swift`, `ReaderView+PageBuilding.swift`, `PublicationSession.swift`, and the new
`KF8ConverterTests.swift`). Implementation starts after that work is committed.

## Decisions (maintainer, 2026-11-02)

Asked as options with a recommendation each; the answers frame everything below.

1. **A chapter that declares no writing mode** (the Calibre TOC): 「看全書 CSS 決定」. When the book's CSS
   declares a writing mode anywhere, an undeclared chapter is horizontal, CSS's initial value, as WebKit, Readest
   and Apple Books lay it out. When the book's CSS declares none at all, the OPF decides as today
   (`primary-writing-mode`, else `page-progression-direction="rtl"` with a language that is not an RTL script ⇒
   vertical), so books that are vertical only by their OPF stay vertical.
2. **Paged mode, page order in a horizontal chapter of a vertical book**: 「跟整本書」. Page order, spine side,
   which tap zone is "next", swipe direction, curl and spreads follow the book's progression: the OPF's
   `page-progression-direction` when declared, otherwise the first leading spine document that declares a
   writing mode. Entering a horizontal chapter never reverses page turning; only the text inside it is laid
   out horizontally.
3. **Scroll mode**: 「交界處換軸」. Consecutive chapters of one writing mode form a *segment* with its own scroll
   axis (vertical-rl scrolls sideways right to left, horizontal-tb scrolls down). Crossing into a segment of
   the other mode tears the scroll view down and rebuilds it on the other axis; the screen visibly jumps, as
   in Readest.
4. **Crossing between segments**: 「捲到段尾自動換段」. Reaching a segment's end while scrolling forward opens
   the next segment; reaching its start backward opens the previous one. No overscroll threshold, no button.
5. **The frozen fidelity oracle**: 「你親手改 oracle」. `ORACLE.md` §改量法 allows only a person to change the
   measurement, in its own commit. This plan names exactly what has to change (see *Fidelity measurement*);
   the maintainer makes, locks and re-baselines it.
6. **自動閱讀 at the end of a horizontal segment** (scroll mode; it does not run on the vertical-rl axis today):
   「停下來」. It stops there, as at the end of the book; it does not skip the vertical segment and does not gain
   a right-to-left auto-scroll in this plan.

## The defect

The reader decides vertical-rl vs horizontal-tb **once per book** and lays every chapter out that way. A
horizontal document inside a vertical book is laid out vertically.

The concrete case: Calibre appends a generated inline TOC (`<body id="calibre_generated_inline_toc">`) to
every AZW3/MOBI with more than one TOC entry. In the converted `vertical-zh.azw3`, every content document
carries `<html class="calibre">` and links `flow0001.css` (`.calibre { writing-mode: vertical-rl }`); the TOC
document `OPS/text/c0004.xhtml` links only `flow0003.css`, which declares no writing mode. The OPF has
`<spine page-progression-direction="rtl">` and no `primary-writing-mode`.

Fidelity run `~/Library/Caches/YueduFidelity/runs/mobi-2026-11-02/report.md`, book `vertical-zh-azw3`:

| Spine | href | WebKit | Engine | Route | Score |
|---:|---|---|---|---|---:|
| 0 | `c0001.xhtml` (cover) | vertical-rl | vertical-rl | legacy (capability `vertical-writing-mode`) | 92.3 |
| 1 | `c0002.xhtml` | vertical-rl | vertical-rl | browser | 74.0 |
| 2 | `c0003.xhtml` | vertical-rl | vertical-rl | browser | 74.9 |
| 3 | `c0004.xhtml` (inline TOC) | **horizontal-tb** | **vertical-rl** | browser | **12.2** (44.7 lost on `writing-mode`) |

The same page in `vertical-zh-mobi` (MOBI 6 has no CSS, so the whole book is horizontal) scores 97.2.
Readest (per-section writing mode) and KOReader (no vertical text at all) lay the page out horizontally; what
Kindle does with it is unverified (see *How reference readers handle a mixed book*).

## Where writing mode is decided today

Three book-wide decisions, any of which turns the whole book vertical:

| # | Decision | Where | What it reads |
|---|---|---|---|
| D1 | OPF metadata | `PublicationSession.parseOPFMetadataXML` (`PublicationSession.swift:1336-1410`) → `session.epubWritingMode` | `<meta name="primary-writing-mode">`; else `page-progression-direction="rtl"` with a language that is not an RTL script **infers** `.verticalRL` (`:1378-1386`). This is what makes `vertical-zh-azw3` vertical before any CSS is read. |
| D2 | Tap-time preflight | `PublicationSession.inspectOpeningFlow` / `packageDeclaresVerticalWritingMode` (`:545-596`), regex `EPUBOpeningFlow.containsVerticalWritingModeDeclaration` | D1, or a vertical declaration in **any** stylesheet or the first three linear spine documents, whatever its selector. Chooses the opening animation only (`HomeView.swift:480-492`). |
| D3 | Renderer CSS detection | `HTMLAttributedStringBuilder.detectedVerticalWritingMode` (`:525`, `:608`, `scanCSSForVerticalWritingMode` `:704-708`) → sticky `EPUBAttributedStringBuilder.cssDetectedVerticalWritingMode` (`:47`, `:265-267`) → `EPUBPageRenderer.cssDetectedVerticalWritingMode` (`:390`) | The body's resolved style, **or any vertical declaration anywhere in the chapter's CSS**. Never reset. |

`ReaderView` folds them into one flag, `isVerticalEPUB` (`ReaderView.swift:697`): from D1 in `loadLocalEPUB`
(`ReaderView+PageBuilding.swift:191-193`) and from D3 when the first chapter is ready (`ReaderView.swift:3115-3126`,
which also turns the opening animation to `.rightSpine`). `effectiveWritingMode`
(`ReaderView+TXTVerticalScroll.swift:138-143`) is `.verticalRTL` when the flag is set, the user's 排版方向 for books
that allow it (TXT, online, Aozora: `ReadingBook.allowsVerticalWritingMode`, `Models.swift:1011`), and
`.horizontal` otherwise. It becomes `ReaderRenderSettings.writingMode` (`ReaderView+PageBuilding.swift:60`) and
every chapter is laid out with it. A CSS-only vertical book therefore opens horizontal, and is laid out a
second time when D3 fires.

D3 also turns a horizontal book vertical when any stylesheet has one vertical rule (a poem class, a sidebar).
That is the same defect as the inline TOC: a property of one element or one document, applied to the book. D1
is not a defect on its own: for a book whose CSS declares no writing mode, the OPF is the only signal there is,
and decision 1 keeps it. What goes wrong is D1 deciding for a book whose CSS does declare writing modes, and so
deciding `c0004`, which CSS would have left horizontal.


## The model: book direction and chapter writing mode

`isVerticalEPUB` answers two different questions with one bit. They separate:

- **Book direction**, a property of the *book*, fixed for the session:
  - `progression` (`rtl` / `ltr`): page order, spine side, which edge is "next", spread order, the
    opening and closing animation.
  - `principalMode` (`verticalRTL` / `horizontal`): what book-level UI that is not a page shows, such as the TOC
    sheet's column layout and the settings panel's flags.
- **Chapter writing mode**, a property of *one spine document*: its principal writing mode, which CSS Writing
  Modes 3 §8 defines as the root element's `writing-mode`, taken from `<body>` when there is one. WebKit does
  exactly this, and it is what the fidelity reference measured for `c0004`. It decides how that chapter is
  shaped, paginated, drawn, hit-tested and spoken, and, in scroll mode, which segment it belongs to.

Every consumer reads one or the other. `isVerticalEPUB`, `effectiveWritingMode`, D3 and
`cssDetectedVerticalWritingMode` are deleted.

**Books whose layout the user chooses** (排版方向: TXT, online, Aozora; `ReadingBook.allowsVerticalWritingMode`,
`Models.swift:1011`) are untouched: every chapter's mode is the setting, `progression` and `principalMode`
follow it, exactly as today. The user cannot set a mode for a publisher EPUB today (the picker is hidden and
`ReaderView.swift:2642-2654` returns early), and this plan does not add one.

### The rules

For a publisher EPUB, computed once per book and deterministic: a pure function of the book's files, never of
which chapters happen to have been laid out.

1. **The book declares a writing mode in CSS** when any `writing-mode` / `-webkit-writing-mode` /
   `-epub-writing-mode` declaration (any value, any selector, comments stripped) appears in a manifest
   stylesheet or in the first three linear spine documents. This is the scope the tap-time preflight already
   reads (`PublicationSession.swift:572-596`), widened from "vertical" to "any value".
2. **Book default** (the mode of an undeclared chapter): `horizontal` when rule 1 holds (decision 1); otherwise
   the OPF's (`primary-writing-mode`, else the `rtl` + non-RTL-script inference,
   `PublicationSession.swift:1378-1386`); otherwise `horizontal`.
3. **Chapter writing mode** = the chapter's declared principal mode, else the book default.
4. **`principalMode`** = the chapter writing mode of the first of the first three linear spine documents that
   declares one, else the book default.
5. **`progression`** = the OPF's `page-progression-direction` when it is `rtl` or `ltr`; otherwise `rtl` when
   `principalMode` is vertical, `ltr` when not (decision 2).

For the converted `vertical-zh.azw3`: rule 1 holds (`flow0001.css`), so the book default is horizontal;
`c0001`–`c0003` declare vertical-rl through `html.calibre`; `c0004` declares nothing ⇒ **horizontal**;
`principalMode` vertical (from `c0001`); `progression` `rtl` (OPF). For the CSS-free `ja` fixture pinned by
`EPUBRenderingTests.cjkRTLPageProgressionDefaultsToVerticalWriting`: rule 1 fails, so the OPF inference makes
every chapter vertical, as today.

Behaviour changes, all intended: a horizontal book whose only vertical rule is on a non-root element (a poem
class, a sidebar) stops turning entirely vertical and right-to-left (D3 did that); a CSS-only vertical book is
laid out vertical from its first layout instead of horizontal-then-relaid-out, and its paged view gets the right
direction from the start (see *Paged mode*).

### One resolver

`BookWritingModes` (app, `Modules/Core/ReaderCore/`) answers, for every caller, "this book's direction" and "spine
*n*'s writing mode": both engines (BrowserAuto and its legacy delegate), paged and scroll, the shelf's opening
animation, `ReaderView`, and the fidelity oracle. One answer per `(book, spine)`, cached for the session. It
depends on no reader setting, so a font or margin change never recomputes it. For books in the user's mode it
returns the setting for every spine.

- **Where the CSS answer comes from.** The package's CSS frontend, which BrowserAuto already runs on every
  chapter (`BrowserChapterDocument.parse`). Today the package never derives a writing mode from CSS: the host
  passes one (`BrowserChapterEvaluation.swift:50-78`), the cascade maps logical properties with it, and the
  scanner sends a chapter to legacy whenever the CSS disagrees with it (`BrowserLayoutCapabilityScanner.swift:
  136-151, 221-225`). **YueduCoreText 0.12** adds a read-only `BrowserChapterDocument.principalWritingMode`:
  `<body>`'s computed `writing-mode`, inherited from `<html>`, or `nil` when no declaration reaches either. It
  reads only the cascade for those two elements, so it does not depend on the configuration.
- **The resolver reuses the admission parse.** BrowserAuto parses each chapter once in `decideEngine`
  (`BrowserLayoutPageEngine.swift:680-709`) and evaluates it with a writing mode; the resolver reads
  `principalWritingMode` from that same parse and the evaluation is given its answer. The vertical scroll path
  skips admission today (`:2067-2075`); it gains the parse. Both measured (`⏱ chapter.writingMode`, beside the
  existing `browser.admission`).
- **The legacy builder stops deciding.** Its `detectedVerticalWritingMode` / `scanCSSForVerticalWritingMode`
  (`HTMLAttributedStringBuilder.swift:525, 608-610, 704-708`) go. They were unreliable anyway: the regex matched
  any rule in any sheet, the body flag is only ever set (`CSSPropertyApplier.swift:364-406` never clears it for
  `horizontal-tb`), and the body resolves from `makeRootStyle`, not from `<html>`
  (`HTMLBuilderPipelines.swift:179-199`), so `html.calibre` never reached it.
- **The shelf uses it too.** `PublicationSession.inspectOpeningFlow` (`:545-566`) and its regex
  `EPUBOpeningFlow.containsVerticalWritingModeDeclaration` become `BookWritingModes`'s direction computed from
  package resources (container, OPF, the declaration scan, and the package parse of up to three leading spine
  documents). Today's cost is in the `⟐ resolveOpeningDirection EPUB done elapsedMs=` log
  (`HomeView.swift:490`); the new one is reported beside it.
- **Failure.** A chapter the package cannot parse already falls to legacy (`chapterParse`,
  `BrowserLayoutPageEngine.swift:697-705`); its writing mode is then the book default, logged through
  `AppLogger` with the spine and the parse error. This is a fallback for a genuinely unparseable document, not
  a retry: it can be removed if the package ever parses every document.

## Consumers

Inventory of 2026-11-02. Each consumer reads the **book direction** (B), **the chapter's writing mode** (C), or,
in scroll mode, **the segment's axis** (S). Paths are under `Modules/` unless given in full.

### Already per page or per chunk: no change

Drawing, hit testing, selection, highlights, annotations, note markers, regex highlights and the TTS wash all
read the layout's own mode (`ChapterLayout.writingMode`, `CoreTextChunk.writingMode`, `ReaderScrollItem.writingMode`,
a browser paint fragment's `writingMode`): `CoreTextPageView.swift:62-83, 803-845, 1886-1935, 2123-2184,
2400-2499`; `CoreTextAnnotationRenderer.swift:40-156`; `NoteMarkerOverlayView.swift:18-20`;
`RegexHighlightDecorationRenderer` via `CoreTextPageView.swift:831-839`; `CoreTextChunkCell.swift:135-221,
569-670`; `BrowserScrollTileCell.swift:104-197`. The package's `TextSelectionManager` works in offsets only.
TTS (`ReaderPlaybackHighlight`, `Core/TTS`, `Features/Reader/TTS`) has no writing-mode dependence; its page-follow
crosses chapters through `jumpToChapter` (`ReaderView+SourceChange.swift:656-781`).

### Engines (paged and scroll)

The chapter's mode must be known **before** its build: the legacy builder needs it up front, admission needs it
up front, and a placeholder page has none. It travels as its own field, never inside per-chapter
`ReaderRenderSettings`: `BrowserLayoutPageEngine.makeScrollChapter` calls `updateRenderSettings` whenever the
settings differ (`:2020`), which cancels every spine's in-flight preparation and clears every cached scroll
chapter (`:1393`, `:445-451`), and a settings `writingMode` change is a `.layout` refresh that invalidates every
chapter (`ReaderRenderRefresh.swift:147-164`, `BrowserLayoutPageEngine.swift:1071-1115`).
`ReaderRenderSettings.writingMode` (`Models.swift:950`) keeps meaning the user's 排版方向 and is read by layout
only for books in the user's mode.

| Today (`settings.writingMode`) | Where | Becomes |
|---|---|---|
| Legacy build config | `EPUBAttributedStringBuilder.makeConfig` (`:464-486`, `:484`) → `NodeAttributedStringRenderer.Config` (`:144`) | C, through a new `ChapterDocumentRequest.writingMode` (`ChapterDocument.swift:48-53`; the store's key includes it, `:91-95`) |
| Pagination request | `CoreTextPageEngine.swift:1187` → paginator (its `CacheKey` already includes the mode, `CoreTextPaginator.swift:614-630, 768-781`; `ChapterLayout.writingMode` `:252`) | C |
| Browser config and admission | `BrowserLayoutConfigInputs.makeConfiguration` (`BrowserLayoutPageEngine.swift:285-315`, `:310`), `decideEngine` (`:691`, `:709`), `chapterEvaluation` (`:988-995`) | C; `evaluate(_:configuration:writingMode:)` already takes it per call |
| Scroll chapter preparation | `prepareScrollChapter` (`:2067-2145`), `preloadChapter` (`:555`) | C |
| Scroll engine layout (geometry extent ENG:135-148, vertical prep ENG:411-421/592-606, browser size swap ENG:545-549, tile cap ENG:556/1046-1048, slicer ENG:653/665-673, placeholder ENG:757-762, image-only chunk ENG:894-942; ENG = `Core/ReaderCore/CoreText/CoreTextScrollEngine.swift`) | ENG | C (= S inside a segment) |
| `usesViewportScrolling = continuousScrolling && !settings.writingMode.isVertical` | `EPUBPageRenderer.swift:258, 491`; `BrowserLayoutPageEngine.swift:555` | S |

`EPUBPageRenderer` owns the session's `BookWritingModes` and hands both engines and the scroll engine a
`writingMode(forSpine:)` provider. The provider is a defaulted parameter whose default answers
`settings.writingMode` for every spine, which is also what `BookWritingModes` answers for a book in the user's
mode, so it is one path, not two. **This keeps the frozen oracle compiling and measuring as today:**
`RenderFidelityOracleTests.FidelityEngineCapture` (`:420-447`) builds `CoreTextPageEngine`,
`BrowserLayoutPageEngine` and `CoreTextScrollEngine` itself, with `settings` only, and reads
`PublicationSession.epubWritingMode` (`:55`). Steps 1–4 keep every symbol it calls source-compatible
(`epubWritingMode` stays: it is D1, an input of rule 2), and each step's test run proves it by building the
test target.

**Scanner consequence.** With the chapter's own root mode requested, a vertical chapter with no other-mode
declarations is no longer rejected for its writing mode (today the converted book's `c0001` falls to legacy with
`vertical-writing-mode`). A chapter with an *inner* element in the other mode still goes to legacy, which lays the
whole chapter out in the chapter's mode (`BrowserLayoutCapabilityScanner.swift:138-141`): mixed modes *inside*
one document stay out of scope, unchanged from today.

### Paged mode

The page view controller's direction is fixed when it is built: spine location (`CoreTextPagedView.swift:59`,
`ReaderCoverPageMotion.swift:186-189`; UIKit cannot move a spine), `semanticContentAttribute`
(`CoreTextPagedView.swift:81-87`), the coordinator's `let isRTL` (`:392`, `:428`), the before/after swap
(`:1916`, `:1929`) and the curl's virtual indices (`:955`). Decision 2 needs exactly that: one direction per book.

| Consumer | Where | Today | Becomes |
|---|---|---|---|
| Page view `isRTL` | `ReaderView.swift:1956` | `pageProgressionDirection == .rtl \|\| effectiveWritingMode.isVertical` | B (`progression == .rtl`) |
| Touch-zone editor `isRTL` | `ReaderView.swift:2187` | same | B |
| Turn commands, external target and chapter-ready placement, links, instant and cover pans | `CoreTextPagedView.swift:313-318, 1411-1417, 1522-1526, 2277-2399, 2497` | coordinator / live `isRTL` | B (unchanged code) |
| Tap zones | `TouchZoneConfig.effective(isProActive:isRTL:)`, `TouchZoneConfig.swift:74-128` | B | B |
| VoiceOver page order | `CoreTextPagedView.swift:1174, 1180` → `CoreTextPageView.swift:403-405` | B | B |
| Spreads (pair order, snapshot, mid-spine curl) | `iPad/ReaderSpreadPageViewController.swift:47-49`; `CoreTextPagedView.swift:851-853, 1229-1244, 1341-1342` | B | B. A spread may hold the last vertical page and the first horizontal page; it is ordered by the book, as Readest orders an LTR colophon in a Japanese book |
| Page stepping across a chapter boundary | `positionAfter`/`positionBefore`, `CoreTextPagedView.swift:1995, 2025` | position walk, mode-agnostic | unchanged |
| Page view identity | `ReaderView.readerPageViewIdentity` (`:660-668`) | style + spread + size | adds `progression`, so a direction change rebuilds the controller |
| The mid-session flip | `ReaderView.swift:3115-3126` (and `ReaderView+PageBuilding.swift:191-193`) | sets `isVerticalEPUB`, turns the animation `.rightSpine` | deleted: the direction is known before the first layout |

**A defect this removes (found while mapping, not run on a device).** The paged view is built on the same
`isCoreTextReady` transition that sets `isVerticalEPUB` (`ReaderView.swift:1947-1985` vs `:3115-3126`). Its
coordinator keeps the `isRTL` it was created with, and the identity does not include the direction, so a CSS-only
vertical EPUB without `page-progression-direction="rtl"` very likely turns its pages left-to-right. TXT's 排版方向
toggle has the same shape (`ReaderView.swift:2642-2654`: a layout refresh, no rebuild). Deciding the direction
before the view exists, and putting it in the identity, covers both; Step 3 adds the test.

### Scroll mode: axis segments

A **segment** is a maximal run of consecutive spine items with the same chapter writing mode. The scroll host
shows one segment at a time on that mode's axis (`verticalRTL` → `.horizontalRTL`, `horizontal` → `.vertical`).
Inside a segment every item matches the axis, so today's save, restore, anchor, prefetch and insertion code
works as it is. That is the reason one `UICollectionView` never holds two axes: it has one
`contentOffset`/`contentSize`, one scroll direction (`CoreTextScrollAxis.swift:25-32`), one
`semanticContentAttribute` (the RTL mirror is `.forceRightToLeft` plus `flipsHorizontallyInOppositeLayoutDirection`,
`CoreTextScrollAxis.swift:34-41`, VC:227, VC:724, VC:2326-2328; no transform anywhere), one `contentInset`
(VC:917-934) and one frame set by the bar constraints (VC:985-1005). VC =
`Features/Reader/CoreTextCollectionScrollViewController.swift`.

Today a horizontal chapter simply given `.horizontal` inside an RTL scroll would break on every path: its line
width becomes the column height and its chunks grow up to 2000 pt tall in a cell `bounds.height` high
(`sizeForItemAt` VC:2069-2083); saving returns nil and logs `commit.unresolved` (VC:2301-2320), so progress is
never saved there; restoring lands on the chunk edge (`rightOffset` is nil for horizontal chunks,
`CoreTextChunk.swift:262`); a browser chapter takes the viewport path whose viewport is never requested off the
vertical axis, so only its first screen is ever laid out.

| Today (book-wide) | Where | Becomes |
|---|---|---|
| `scrollAxis = effectiveWritingMode.isVertical ? .horizontalRTL : .vertical` | `ReaderView+TXTVerticalScroll.swift:149-151` | S: the axis of the segment on screen, published by the scroll host |
| Layout chosen from the axis; an axis change replaces it and reslices **at offset 0** | VC:204-214, 694-760 (`requestReslice(at: restoreChapter)` VC:750-753) | S; the reslice takes a target position (a chapter start, a chapter end, or a saved position) instead of dropping the in-chapter offset |
| Insets, bar bands, text band | VC:917-934, 985-1005; `ReaderView+TXTVerticalScroll.swift:22-26`; `ReaderView.swift:572-580` | S |
| Prefetch: vertical loads past the ends within 1.5 screens, RTL loads ±1 around the visible chapter | VC:2143-2157; engine `ensureChapterAhead/Behind` ENG:277-295 | S, and **stops at the segment boundary**: the engine resolves spine *n*±1's mode before loading it and does not load across a change |
| Opening restore: RTL goes through the paged engine | `ReaderView.swift:3311, 3329-3358` | S of the restore chapter's segment |
| Chapter gap 24 / 72 pt | VC:2001-2005 | S |
| TTS follow, 自動閱讀, `screenPagination`: vertical axis only | VC:803-839, 973-982, 1884-1895 | S. A horizontal segment of a vertical book gains them; a vertical segment has none, as a vertical book has none today |
| Calibre progress `isVertical` | `ReaderView+Logic.swift:578-581` (dedupe only, never sent: `CalibreProgressService.swift:51-58, 179-180`) | C of the position's chapter |

**Crossing** (decisions 3 and 4):

- A **user-driven** scroll, a drag or the deceleration it started, that reaches the segment's end edge in the
  reading direction opens the next segment at its first chapter's start. Reaching the start edge backward opens
  the previous segment at its last chapter's **end** (a new restore target: the last line, or in vertical-rl the
  last column, at the trailing edge).
- **Nothing programmatic crosses**: layout, insertion, restore and reslice change offsets without crossing. Only
  `isDragging || isDecelerating` with the offset at the edge triggers it, at most once per gesture, and the new
  segment opens at rest.
- **A segment shorter than the viewport** (the Calibre TOC is one screen) sits at both edges at once. It crosses
  on a drag toward either edge, never on its own; the test covers the bounce.
- **Commands cross directly**, building the target's segment at the target: tap-zone page turns at a segment
  edge, 上一章／下一章, the TOC, bookmarks, links, search results and TTS follow.
- **自動閱讀** scrolls only on the vertical axis today (VC:973-982), so it runs only in a horizontal segment, and
  the next segment is always vertical-rl. At the segment's end it **stops**, as it stops at the end of the book
  (decision 6).
- Cost: a crossing is today's axis change (`update(axis:)` → `engine.reslice` → `.reset`), measured with a
  `⏱ scroll.segmentCross` span.

### Book-level UI

| Consumer | Where | Becomes |
|---|---|---|
| Opening / closing animation | `ReaderBookOpeningDirection.resolve` (`ReaderBookOpeningDirection.swift:23-29`); shelf `HomeView.swift:480-492`; reader `ReaderView+PageBuilding.swift:127-135` | B (`progression == .rtl` ⇒ `.rightSpine`), the same function at the shelf and in the reader |
| TOC sheet layout | `ReaderView.swift:2843`, `TOCLayoutMode.from(writingMode:)` (`Models.swift:1003-1005`) | B (`principalMode`) |
| Settings panel `isVerticalWritingMode` (hides 底部對齊) | `ReaderView.swift:2725`; `ReaderSettingsView.swift:524-526` | B (`principalMode`) |
| Quick theme panel 右往左 label | `ReaderView.swift:2749`; `ReaderQuickThemePanelView.swift:486` | B (`principalMode`) |
| `ReaderPresentationState.direction` | `ReaderView.swift:952, 1018` (written, read only by `ReaderPresentationContractTests.swift:305`) | B |
| Fixed layout | `FixedPageReaderView.swift:184`, `ReaderView.swift:1880` | unchanged (page progression only) |

## Reading positions

`(spineIndex, charOffset)` carries no writing mode, and nothing that stores or maps it consults one:
`CoreTextReadingPosition` (`CoreTextReadingPosition.swift:3-50`), `ReaderLocation`, `ReaderProgressRestoreResolver`,
`ReadingPositionStore`, `CharOffsetStore`, `spinePageOffsets` (`CoreTextPageEngine.swift:1718-1759`), reading
stats (`ReaderView+Logic.swift:365-400`). No reference reader's position format depends on writing mode
either. There are no persisted layout caches to invalidate: the paginator's and the document store's caches
are in memory and already keyed by mode.

**But the text an offset counts in can depend on the mode**, so positions move for a chapter whose mode changes:

1. **Legacy vertical collapses an inline-annotation span into one U+FFFC** (`NodeAttributedStringRenderer.swift:
   578-585`, `:2442-2466`; `RunDelegateProvider.swift:230-268`). Horizontal keeps the span's text.
2. **The paginator's vertical preparation splits an oversized placeholder into several**
   (`CoreTextPaginator.swift:2030-2077`; `replacement.length > range.length` at `:2066`). The prepared string is
   the layout's (`:1014`, `:1322`), with no back-map.
3. **The route can change.** Admission keys on the requested mode, so a chapter whose mode changes can move
   between BrowserAuto and legacy, whose texts are not guaranteed identical
   (`BrowserLayoutPageEngine.swift:1766-1789`).

Two consequences:

- **From this plan on, every chapter's text is stable across sessions**, because its mode is a pure function of
  the book's files. Today it is not quite: D3 is a sticky flag that can flip mid-session, and the 0.11 picture
  migration (`ReaderView+PageBuilding.swift:225-242` → `EPUBPageRenderer.savedPositionPictures` `:515-533`) runs
  before `isVerticalEPUB` is set, so it judges a CSS-only vertical book's chapters as horizontal. After this plan
  it asks `BookWritingModes` like everything else.
- **One-time shift for the chapters whose mode this plan changes**: undeclared chapters of CSS-declaring vertical
  books (the Calibre TOC), documents that declare horizontal inside vertical books, and every chapter of a book
  D3 turned vertical through a non-root rule. Saved positions, bookmarks and highlights in those chapters were
  counted in the old text.

**Gate, not a speculative migration.** Step 2 ends with it, before any engine changes, because the old decision
(D1, D3) still exists then and today's engines already take one mode through `settings.writingMode`: for every
chapter of `scripts/fidelity/corpus.json`, `corpus-mobi.json` and the machine-local
`~/Desktop/Test document/EPUB Format` books whose mode differs between the old book-wide decision and the new
rules (the same list as risk 2), compare `chapterText(forSpine:)` built both ways. Equal text (the
expected result for the Calibre TOC, which has no annotation spans) means no migration and the plan says so. Any
difference stops the step and goes to the maintainer with the list, and with a migration modelled on
`PictureOffsetMigration` (stamped once per book; positions, bookmark excerpts, highlights) as the proposal.

## How reference readers handle a mixed book

Research of 2026-11-02, every link pinned to the commit read that day. "Unverified" = no primary source found.

| Reader | Writing mode decided | Paged: which way is "next" in a horizontal chapter of an RTL book | Scroll: axis at a mode change | Position |
|---|---|---|---|---|
| foliate-js (`78914aef`) | Per section, `getDirection(doc)` reads `body`'s computed `writingMode`/`direction` ([paginator.js#L178-L187](https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/paginator.js#L178-L187)); AZW3 `book.dir` from EXTH 527 only ([mobi.js#L1047](https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/mobi.js#L1047)) | Inconsistent: buttons and arrow keys follow the book ([view.js#L519-L524](https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/view.js#L519-L524)), swipes follow the section ([paginator.js#L793-L821](https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/paginator.js#L793-L821)) | Switches per section (one section mounted at a time; [#L714-L719](https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/paginator.js#L714-L719)) | CFI, independent of mode |
| Readest (foliate fork `0c7a0edc`, app `f88b7451`) | Per section; per-book override (`auto`/`horizontal-tb`/`horizontal-rl`/`vertical-rl`) forces every section, TOC included ([style.ts#L503-L505](https://github.com/readest/readest/blob/f88b7451fb47748a1d0a5c0b7d115a8b4a7078b8/apps/readest-app/src/utils/style.ts#L503-L505)) | **The book.** [#95 / 444be907](https://github.com/readest/foliate-js/commit/444be90731186a905afe808e05a96e000be81195) pins `#rtl` to page-progression-direction; its comment: an LTR colophon in a Japanese book still pages right-to-left | **Switches**: continuous scroll stops preloading at a writing-mode boundary and rebuilds every view when crossing it ([befe16d4 / #13](https://github.com/readest/foliate-js/commit/befe16d47c1b21f80a7eb67c16134eb44305e1c8)) | CFI |
| Readium swift-toolkit (`e20d5cfc`) + Readium CSS | Book-wide: CJK language + RTL progression ⇒ vertical, injected into **every** resource ([EPUBSettings.swift#L114-L131](https://github.com/readium/swift-toolkit/blob/e20d5cfc847c2cfa02aaf7be409848b504bd46ca/Sources/Navigator/EPUB/Preferences/EPUBSettings.swift#L114-L131), [CSSLayout.swift#L78-L96](https://github.com/readium/swift-toolkit/blob/e20d5cfc847c2cfa02aaf7be409848b504bd46ca/Sources/Navigator/EPUB/CSS/CSSLayout.swift#L78-L96)) — so the Calibre TOC would come out vertical (inferred, not run) | n/a: vertical forces scroll mode ([#L136-L141](https://github.com/readium/swift-toolkit/blob/e20d5cfc847c2cfa02aaf7be409848b504bd46ca/Sources/Navigator/EPUB/Preferences/EPUBSettings.swift#L136-L141)) | Book-wide ([EPUBNavigatorViewController.swift#L688-L696](https://github.com/readium/swift-toolkit/blob/e20d5cfc847c2cfa02aaf7be409848b504bd46ca/Sources/Navigator/EPUB/EPUBNavigatorViewController.swift#L688-L696)) | Locator (href + progression) |
| Apple Books (Asset Guide) | Per document: `writing-mode` on `html`/`body`, one value per document; horizontal and vertical text **must be split into separate content documents** — exactly this case ([Text Directions](https://help.apple.com/itc/booksassetguide/en.lproj/itc7e9ec52f7.html)) | **The book**: page-progression-direction "is a global attribute" that "defines the pagination flow of the book as a whole" ([Page Progression Direction](https://help.apple.com/itc/booksassetguide/en.lproj/itc078b6673e.html)) | Documented book-wide (CJK books scroll horizontally, `ibooks:scroll-axis` overrides, [Scrolling](https://help.apple.com/itc/booksassetguide/en.lproj/itccf6b30e09.html)); what it does at a horizontal document: unverified | unverified |
| KOReader (crengine) | No vertical text at all ("we won't support vertical text", [#11469](https://github.com/koreader/koreader/issues/11469#issuecomment-1967992448)) — the TOC is horizontal because everything is | User toggle `inverse_reading_order`, not read from the OPF | n/a | xpointer + percent |
| Kindle (KPG v2026.3) | `primary-writing-mode` "defines page rendering order, reading mode, and reader navigation"; per-document modes not mentioned. Calibre writes EXTH 525 and 527 and its inline-TOC template has no `writing-mode` ([toc.py#L20-L38](https://github.com/kovidgoyal/calibre/blob/27ddbc72b251637bcfae658fa503ab2d78666914/src/calibre/ebooks/mobi/writer8/toc.py#L20-L38)) | unverified | unverified | unverified |

Agreement: **page order follows the book** wherever it is documented or coded (Apple, Readest #95, Readium,
foliate's buttons). **No reader's position format depends on writing mode.** The scroll axis splits: foliate and
Readest switch at the boundary (Readest by tearing the continuous scroll down and rebuilding it); Readium and
Apple document one axis per book.

## Fidelity measurement (the maintainer's change)

`RenderFidelityOracleTests.swift` is frozen by `scripts/fidelity/oracle.lock`. Today it decides "vertical" for the
whole book from the OPF alone and uses that bit for the engine settings, the viewport, the engine's dump label
(which the scorer reads to pick its axis, `fidelity.py:439`) and the WebKit reference's viewport. So even a
correct engine would be laid out, labelled and scored vertical at `c0004`. Per decision 5, the maintainer makes
this change, in its own commit, by `ORACLE.md` §改量法:

| Line | Today | Change |
|---|---|---|
| `:55` | `let vertical = session.epubWritingMode == .verticalRL`, once per book | Per chapter, inside the chapter loop: `BookWritingModes`' answer for `chapter.spine` |
| `:56`, `:67` | `FidelityWebReference(viewport: FidelityProfile.viewport(vertical: vertical))`, created lazily once per book | The reference viewport follows the chapter's mode (a new `FidelityWebReference` when it changes); the two viewports differ (`:192-195`: full width and height minus margins, or width minus margins and full height) |
| `:192`, `:205`, `:425-426`, `:444-446` | `viewport(vertical:)`, `settings(vertical:)`, the scroll engine's `contentWidth` / `viewportExtent` | Follow from the per-chapter bit; no edit beyond passing it |
| `:454` | the dump's `"writingMode"` label | Follows from the per-chapter bit |
| `:183` | `extractorVersion = 2` | 3: `c0004`'s WebKit reference was captured at the vertical viewport and must be re-captured; `refKey` (`:227-233`) does not see the viewport choice |

Then `python3 scripts/fidelity/test_fidelity.py`, `python3 scripts/fidelity/fidelity.py lock --write`, a new
baseline, and the old-vs-new difference written to `docs/browser-layout/fidelity-loop/reports/`.

The oracle builds its engines once per chapter (`FidelityEngineCapture.capture`), with `settings` and no
provider, so the engines lay that chapter out in `settings.writingMode` (see *Engines*): passing the per-chapter
bit into `settings(vertical:)` (`:205`) is the whole engine-side change. In scroll mode a horizontal chapter is a
vertical-axis segment, which is exactly the oracle's horizontal capture.

**Between Step 3 and Step 5** the oracle still lays out, labels and scores every chapter in the book-wide mode,
so `c0004` stays at 12.2 in any run made in that window. That is the unchanged oracle, not a regression signal;
the acceptance evidence before Step 5 is `KF8ConverterTests` and the engine tests.

**Acceptance**: `scripts/fidelity/measure.sh --corpus scripts/fidelity/corpus-mobi.json`, compared with
`fidelity.py compare` against the maintainer's new baseline. `vertical-zh-azw3` spine 3 (`c0004`) at or above
80 (the same page scores 97.2 in `vertical-zh-mobi`), engine and reference both `horizontal-tb`; the book at or
above 80 (63.4 today); no other book in `corpus-mobi.json` or `corpus.json` lower than its baseline.

## Risks

1. **Positions in chapters whose mode changes**: see *Reading positions*. Gated by a measurement.
2. **Books that change direction for existing readers.** A horizontal book that D3 turned vertical because of one
   non-root vertical rule becomes horizontal, left-to-right, mid-reading. It is the fix, but it is visible;
   positions survive (risk 1 aside). The opposite case is the one rule 1 can get wrong: a book that is vertical
   only by its OPF and whose CSS declares `writing-mode` solely on inner elements (a `.yoko` horizontal inset,
   no root declaration) now counts as "declares a writing mode in CSS", so its undeclared chapters, which is all
   of them, become horizontal. Apple Books, which reads only CSS, lays such a book out horizontally too; today we
   lay it out vertically. Step 2 therefore ends with a list: every book in `corpus.json`, `corpus-mobi.json` and
   `~/Desktop/Test document/EPUB Format` whose chapter modes or direction differ from today's book-wide answer,
   with the reason per book. The maintainer reviews that list before Step 3; a book of this kind on it is the
   signal to narrow rule 1 to root-reaching declarations.
3. **Crossing loops in scroll mode.** A segment shorter than the viewport is at both edges at once; a crossing
   triggered by anything but the user's own gesture would bounce between segments. The crossing rule admits
   only `isDragging || isDecelerating`, once per gesture; a test opens straight into the one-screen TOC.
4. **Books that alternate modes** (a translator's horizontal note after every vertical chapter) cross often, and
   each crossing is a full reslice. Accepted with decision 3; `⏱ scroll.segmentCross` says what it costs.
5. **Cache thrash** if the chapter's mode ever rides in `ReaderRenderSettings` (see *Engines*). Design rule: it is
   its own field.
6. **Cost of knowing the mode first.** A parse is added on the vertical scroll path and at the shelf. Measured,
   with before/after numbers in the step's report; no budget is invented here.
7. **Cross-repo ordering.** The app cannot build against a package tag that exists only on this Mac; other
   sessions share the checkout. The 0.12 tag is pushed before the app's package reference moves.
8. **iOS 17 and 27.** The axis swap and the paged identity change are UIKit behaviour; the scroll and paged tests
   run on both runtimes (`sim.sh dest`, and an iOS 17.5 destination).
9. **Odd but intended**: an iPad spread that pairs the last vertical page with the first horizontal page, ordered
   right to left; a horizontal TOC whose pages advance right to left. Both are what Apple's and Readest's rules
   give.
10. **Out of scope, unchanged**: an element inside a document in the other mode (a vertical poem block in a
    horizontal chapter) still sends the chapter to legacy, laid out in the chapter's mode. Fixed-layout books
    keep their own direction handling. TXT, online and Aozora books keep the user's mode for every chapter.

## Test strategy

The smallest relevant classes after each step (`scripts/xctest.sh`, `-parallel-testing-enabled NO`), never the
whole suite unless a step's scope requires it.

**New**

- YueduCoreText 0.12: `principalWritingMode` for `html.class`, `body.class`, inline `style` on each, `!important`,
  `-webkit-` / `-epub-` prefixes, `horizontal-tb` declared explicitly, a vertical rule on a *non-root* element
  (must be `nil`), and no declaration (`nil`).
- `BookWritingModesTests`:
  - converted `vertical-zh.azw3` (`Fixtures/MOBI`) → chapters `[v, v, v, h]`, `principalMode` v, `progression` rtl;
  - converted `features.azw3` → all h, ltr;
  - the CSS-free `ja` book of `cjkRTLPageProgressionDefaultsToVerticalWriting` → all v (OPF inference), rtl;
  - a horizontal book with `.poem { writing-mode: vertical-rl }` on a `<div>` → all h, ltr;
  - a vertical book with one `body { writing-mode: horizontal-tb }` chapter → that chapter h, rtl;
  - Hebrew with `rtl` → all h, rtl;
  - no `page-progression-direction` and CSS-only vertical → rtl;
  - the shelf's and the reader's answers are the same value for each fixture.
- Engines: the converted `vertical-zh.azw3` laid out by `CoreTextPageEngine` alone and by BrowserAuto →
  `ChapterLayout.writingMode` of spine 3 `.horizontal`, of spine 1 `.verticalRTL`; the paged data source steps from
  the last page of spine 2 to the first page of spine 3 with `isRTL` true.
- Paged view: a CSS-only vertical EPUB without `page-progression-direction` builds its page view RTL from the
  first layout (the frozen-coordinator defect); a TXT 排版方向 change rebuilds the controller.
- `ScrollWritingModeSegmentTests`, on the converted book in scroll mode:
  - opening in spine 3 builds a vertical-axis segment;
  - a drag past the RTL segment's end opens spine 3 at offset 0;
  - a drag back from spine 3's top opens spine 2 at its end, with the last column at the trailing edge;
  - open → save → reopen inside spine 3 lands on the same line;
  - restore, insertion and reslice never cross;
  - opening into the one-screen TOC does not bounce;
  - a TOC jump and TTS follow cross directly.
- The position gate of Step 2 (a test-only tool comparing chapter text under the old and new decisions).

**Changed**

- `KF8ConverterTests.verticalInReader` (`:309-327`) asserts `renderer.cssDetectedVerticalWritingMode`, which is
  deleted. It becomes: `vertical-zh.azw3` and its source EPUB give the same direction and the same mode for every
  spine they share, and the conversion's extra last spine (the TOC) is horizontal. This is the cheapest acceptance
  check for `c0004` and does not depend on the oracle. `KF8ConverterTests.opening` (`:296-307`) moves to the new
  direction API. These are the MOBI work's files, so this happens only after it is committed.

**Must stay green**

`CoreTextWritingModeTests` (the whole class), `VerticalTypographyAcceptanceTests`, `BrowserVerticalReaderRouteTests`,
`JapaneseVerticalRubyTests`, `LegacyTateChuYokoTests`, `CoreTextScrollTests`, `ContinuousScrollRestoreTests`,
`ReaderOpeningRestoreTests`, `EPUBRenderingTests` (its direction tests, including
`cjkRTLPageProgressionDefaultsToVerticalWriting`), `ReaderCardTransitionMathTests`,
`ReaderTouchZoneEditorModelTests`, `ReaderPresentationContractTests`, `PictureOffsetMigrationTests`,
`KF8ConverterTests`, `MOBIEngineParityTests`.

**On the simulator**: the converted `vertical-zh` book opened by Open In (`simctl openurl`), one screenshot of
`c0004` in paged mode and one in scroll mode after crossing into it. VoiceOver reads the TOC page's links in
order. Tests green plus those screenshots, then stop.

## Steps

0. **Precondition**: the MOBI work is committed.
1. **YueduCoreText 0.12.** `BrowserChapterDocument.principalWritingMode` and its package tests; changelog; tag
   pushed. The app moves its package reference in the same step and builds; nothing reads the API yet.
2. **`BookWritingModes`.** The rules, the declaration scan, the reuse of the admission parse, `⏱ chapter.writingMode`;
   the shelf switches to it (`HomeView.swift:480-492`, `inspectOpeningFlow` and its regex deleted). Report the
   tap-time cost before and after. Tests: `BookWritingModesTests`, `ReaderCardTransitionMathTests`,
   `EPUBRenderingTests`. Ends with **one gate**, reviewed by the maintainer before Step 3: the list of books whose
   answer changes (risk 2) and, for each changed chapter, whether its text is equal under the old and new modes
   (*Reading positions*). A difference brings the migration proposal with it.
3. **Engines and paged mode.** The chapter's mode into `ChapterDocumentRequest`, `PaginationRequest`, the browser
   config and admission; `isVerticalEPUB`, `effectiveWritingMode`, D3 and `cssDetectedVerticalWritingMode`
   deleted; every consumer in *Paged mode* and *Book-level UI* moved to B; `readerPageViewIdentity` gains the
   direction; `KF8ConverterTests` updated; the oracle untouched and still building. Tests: the engine and
   paged-view tests above, plus *Must stay green*.
4. **Scroll segments.** Segment discovery and boundary-bounded prefetch in the engine; the host publishes the
   segment axis; reslice to a target position (start, end, saved); crossing; `⏱ scroll.segmentCross`. Tests:
   `ScrollWritingModeSegmentTests`, `CoreTextScrollTests`, `ContinuousScrollRestoreTests`,
   `BrowserVerticalReaderRouteTests`, `ReaderOpeningRestoreTests`, on iOS 17.5 and the current runtime.
5. **Oracle (maintainer)**, its own commit: the table in *Fidelity measurement*, `extractorVersion` 3,
   `test_fidelity.py`, `lock --write`, a new baseline and its report.
6. **Acceptance.** The fidelity run on `corpus-mobi.json` and `corpus.json` compared with the new baseline; the
   two simulator screenshots; the plan's steps marked done with their numbers.

Steps 1–4 are engine and reader changes; step 5 is the measurement and is never in the same commit as any of them.

## Found while mapping, not in this plan

- `BrowserTextInteractionController.swift:135, 145` hard-codes `isVertical: false` for note badges and annotation
  underlines, so a vertical chapter laid out by BrowserAuto draws horizontal-style underlines and badges. Not
  caused by this plan, but a vertical `c0001`-like chapter admitted to BrowserAuto after Step 3 would show it more
  often.
- `TXTPageEngine.swift` has no constructor call anywhere; TXT goes through `CoreTextPageEngine`
  (`EPUBPageRenderer.loadTXT`, `:552-608`).
- Readest offers a per-book writing-mode override for EPUB (`auto` / `horizontal-tb` / `horizontal-rl` /
  `vertical-rl`). Nothing here adds one; noted only because it is the obvious next request.

## Implementation log

**Step 1, done 2026-11-02.** YueduCoreText 0.12.0 published (tag `0.12.0`, commit `a438cc4`, GitHub release):
`BrowserChapterDocument.principalWritingMode` (`Engine/PrincipalWritingMode.swift`, 17 tests in
`PrincipalWritingModeTests`). It reads `<html>`/`<body>` declarations through the cascade's order; SVG spellings
(`tb-rl`, `lr-tb`) read; values the engine cannot lay out (`vertical-lr`, `sideways-lr`) ignored as an
unsupported declaration; dark-media rules ignored. The app requires 0.12.0.

**Decisions taken while implementing** (they refine the sections above; where they differ, these win):

- **Scroll mode carries the segment's mode in the engine-bound settings.** Inside a segment every chapter has the
  segment's mode, so the copy of `ReaderRenderSettings` handed to `CoreTextScrollEngine` and the browser engine
  in scroll mode has `writingMode` = the segment's mode, and a crossing is today's axis change (settings change →
  reslice → reset). Risk 5 does not apply: the value is constant within a segment. It is written only on that
  engine-bound copy, never into the persisted settings or the field that means the user's 排版方向 (TXT, online
  and Aozora read that field).
- **Paged mode uses a per-spine provider** `writingMode(forSpine:)`, a defaulted parameter whose default answers
  `settings.writingMode` for every spine (which keeps `RenderFidelityOracleTests` building and measuring as today).
  Every `BrowserLayoutConfig` built for a chapter uses that chapter's mode (`makeConfiguration`, `decideEngine`,
  `chapterEvaluation`, `layoutBrowserChapter`): `CascadeInputs` includes the writing mode, and a mismatch makes
  `accepts` / `rebound(to:)` fail.
- **Resolver API.** `BookWritingModes` (`@MainActor`), created at book open: `direction` (`progression`,
  `principalMode`) known after open; `writingMode(forSpine:) async` resolved lazily, cached per spine, in-flight
  requests deduplicated; `cachedWritingMode(forSpine:)` for synchronous readers. The parse and the
  `principalWritingMode` read run in one `nonisolated` async helper (the property walks the DOM). No open-time
  pass over every chapter. Its own parse, not shared with admission until `⏱ chapter.writingMode` says it matters.
- **Shelf.** A `BookResourceProvider` over `EPUBPackageResources` feeds the existing `EPUBStylesheetIngestion`
  (one ingestion path). It parses only when `page-progression-direction` is undeclared.
- **"Old decision" for the Step 2 gate** = D1 OR D3 over any chapter (D3 is sticky, so its union over the book).

**Step 2, done 2026-11-02** (`04ef254f`, then the early-outs below). `BookWritingModes` and the shelf's
`PublicationSession.inspectDirectionIsRTL`; `EPUBOpeningFlow` deleted. Measured on the iPhone 18 Pro Max simulator
with a test-only tool (`WritingModeGateTool`, env-gated, not committed; kept outside the repo).

- **Gate.** 40 books: `corpus.json`'s 19, `corpus-mobi.json`'s 19, the two fixed-layout fixtures. 38 unchanged.
  No book changes direction. Two chapters change mode, each compared under both modes by the paged engines and by
  `CoreTextScrollEngine`:
  - `红楼梦脂评汇校本` spine 0 `titlepage.xhtml`, a Calibre SVG cover that links none of the book's stylesheets:
    vertical → horizontal, route legacy (`vertical-writing-mode`) → browser, text 1 → 2 UTF-16 in both engines. A
    position saved there is 0 or 1, both inside the new text: no migration.
  - `vertical-zh-azw3` spine 3 `c0004.xhtml` (the inline TOC): vertical → horizontal, browser → browser, text equal
    (29 UTF-16) in both engines.
  No book of risk 2's narrowing kind (vertical by OPF, writing modes declared only on inner elements) is in the
  corpus.
- **Early-outs, all exact** (no mode changed when they landed): a document none of whose parse texts (markup and
  `productionStylesheetTexts`, `@import` already inlined) mention `writing-mode` is not parsed; the leading
  documents are not parsed when rule 1's scan found no declaration; the shelf returns a declared progression before
  reading any stylesheet; the resolver reuses ingestion the adapter already holds.
- **Cost, per chapter, after the ingestion admission shares** (median; before = Step 2 as first committed, which
  read the chapter again and parsed whenever any manifest stylesheet named the property): `mahabharata` (2,014
  chapters, no declaration) 20.4 → **0.7 ms**; `kusamakura` (declares, so parses) 11.0 → **8.2 ms**, which Step 3
  removes by reading the mode from admission's own parse. Ingestion itself, unchanged and shared with admission:
  80 ms (`mahabharata`), 133 ms (`全职高手3`); the first gate run timed it together with the mode (82 ms).
- **Cost at the shelf.** Declared progression: 1.4–6.3 ms (no stylesheet read). No declaration: the old preflight's
  reads (package, OPF, every stylesheet, three leading documents' text), `mahabharata` 144 → 119 ms, `全职高手3`
  338 → 196 ms, `redchamber-azw3` 121 → 51 ms (before = Step 2 as first committed; the old preflight did the same
  reads and was not measured separately). A CSS-declaring book with no progression adds three leading parses; none
  is in the corpus.
- **Found, not in this plan:** `PublicationSession`'s spine cache is keyed by file name alone
  (`getCacheURL`, `spine_cache_<name>.json`), so two books with the same file name share one cached spine. The
  test EPUBs, all named `book.epub`, read each other's spines until they were given unique names.

**Step 3, done 2026-11-02.** Both paged engines lay each chapter of a publisher EPUB out in its own mode, and
everything that reads the book's direction reads `BookDirection`. `isVerticalEPUB`, `effectiveWritingMode`, D3
(`detectedVerticalWritingMode`, `cssDetectedVerticalWritingMode` and their regex scans in both builders) and the
mid-session flip that set the opening direction from D3 are deleted.

- **Engines.** `CoreTextPageEngine.writingModes` and `BrowserLayoutPageEngine.writingModes` (the browser engine
  hands the same instance to its legacy delegate). `nil` lays every chapter out in `settings.writingMode`, which is
  what the oracle and every other caller that does not set it get. The legacy engine awaits the chapter's mode, then
  checks its generation again, and carries it in the settings copy each `ChapterDocumentRequest` and
  `PaginationRequest` is built from (no new request field). The browser engine reads it once per chapter and passes
  it to the config, the evaluation and `layoutBrowserChapter`; scroll preparation keeps the scroll settings' mode.
- **Admission reads its own parse.** `decideEngine` asks `writingModeWithoutParse(forSpine:input:)` (already
  resolved, or a document none of whose texts name the property) and otherwise reads
  `BrowserChapterDocument.principalWritingMode` from the document it has just parsed
  (`writingMode(forSpine:declared:)`, `⏱ chapter.writingMode source=admission`). No chapter is parsed a second
  time for its mode; `testStaleAdmissionSpines` stays empty on the converted book (an evaluation built in one mode
  and reused in another would show there).
- **Reader.** `loadLocalEPUB` resolves the modes after the session opens, before the picture migration and the
  engines (`resolveWritingModes(for:)`, `⏱ reader.open.writingModes`); `load` hands them only to the session they
  were resolved for, so a book another session resolved never lends its modes. `bookDirection` is published from
  then on, so the page view is built in the book's direction from its first layout; TXT, online and Aozora books
  have none and follow 排版方向. `readerPageViewIdentity` includes the direction. Fixed-layout books get their
  direction too (opening and closing animation, as before).
- **Cost** (iPhone 18 Pro Max simulator, a test-only timing tool, not committed). Admission's read of its own parse,
  per chapter that names the property: `kusamakura` median **0.09 ms** (Step 2's separate parse: 8.2 ms),
  `红楼梦脂评汇校本` 0.16 ms; the parse it reads costs 6.5 / 1.7 ms and admission does it anyway. Opening a book now
  adds `resolveWritingModes` before the engines start (warm runs): 12 ms `mahabharata`, 17 ms `全职高手3` (rule 1's
  stylesheet scan; no declaration, so no parse), 15 ms `红楼梦脂评汇校本`, 50–54 ms `kusamakura` (three leading
  documents ingested, which admission then reuses, and parsed, which it does not).
- **Interim until Step 4.** Scroll mode still lays a whole book out in its principal mode, so in scroll mode
  admission (per chapter) and `prepareScrollChapter` (the scroll settings) can disagree on a chapter like `c0004`,
  which is then evaluated again. Step 4 makes the scroll settings' mode the segment's, equal to the chapter's.
- **Tests.** New `ChapterWritingModeEngineTests` (legacy alone; BrowserAuto with no stale admission; stepping from
  the last vertical page into the TOC still right to left; direction before the first layout; another session's
  and TXT's direction; the identity). `KF8ConverterTests.verticalInReader` asks the renderer: the source marks its
  cover `linear="no"`, so the conversion's documents are compared per book (`[v, v]` → `[v, v, v, h]`), not by
  index. Must-stay-green plus `EPUBAutoRoutingTests` and `BrowserLayoutPageEngineTests`: 262 tests in 19 suites
  pass on the iOS 27.2 simulator.

**Step 4, done 2026-11-02, except the opening-restore row.** Scroll mode shows a publisher EPUB one segment at a
time, on the segment's axis.

- **Engine.** `CoreTextScrollEngine.writingModes` (the instance the paged engines ask). `loadChapter` awaits a
  chapter's mode before building it and refuses one of another mode than `renderSettings.writingMode`, recording it
  as a boundary; `ensureChapterAhead/Behind` never ask for a boundary chapter, so prefetch stops there.
  `segmentBoundary(after:)` / `(before:)` tell the host where the segment ends. An engine started on a chapter
  outside its segment shows nothing and logs an error: the one way to reach another mode is to enter its segment.
- **One entry point.** `EPUBPageRenderer.enterScrollSegment(containing:)` resolves the chapter's mode and, when it
  differs from the segment on screen, writes it into the scroll engine's settings, sets the browser engine's
  viewport scrolling, and publishes `scrollSegmentMode` (latest call wins). ReaderView's scroll settings and axis
  read it (`scrollWritingMode`), so the change submits a `.layout` refresh at the session's position: one reslice,
  at the target. Scroll mode does not build its host before the opening chapter's segment is known, so the host is
  never built on the book's axis and turned. A refresh built before the segment was entered (entering scroll mode
  submits one at once) keeps the segment's mode: `updateRenderSettings` and `prepareScroll` read it from the scroll
  engine. Leaving scroll mode clears it.
- **Navigation.** `requestScrollNavigation` enters the target's segment first; every scroll jump goes through it
  (目錄, bookmarks, links, search, 上一章／下一章 and now the chapter slider, which used to reslice the engine
  directly and left the host restoring its old position).
- **Crossing.** The host checks the edge in `scrollViewDidScroll`, only while `isDragging || isDecelerating`, once
  per gesture: forward at the end opens the next segment's first chapter at its start; backward at the start opens
  the previous one's last chapter at its end (`scrollToContentEnd`, the last column at the trailing edge, then a
  layout pass so the landing is read back from the cells and committed). While a crossing is on its way no position
  is persisted from the segment being left. `update(axis:)` no longer reslices on an axis change (the refresh does,
  at the reading position). From the axis change to that reslice's reset the host shows nothing and reads no offset
  (`awaitsAxisReset`): the engine's chunks are still the old axis's, and in the simulator they showed the segment
  being left, cover first, on the new axis. The axis change also puts the offset at the content's start on both
  axes, which stops a deceleration still running: the old axis's offset had carried over and pushed the TOC's text
  off the side of the screen. A failed reslice still sends its reset; the one path that leaves the flag set is a
  refresh with no viewport (`scrollViewportUnavailable`), which an axis change, made on a laid-out host, does not
  reach. A segment shorter than the screen bounces on its axis, so a drag can leave it. 自動閱讀 stops at the
  segment's end.
- **Cost** (`⏱ scroll.segmentCross`, iPhone 17 Pro simulator, iOS 26.5, the converted book). Warm crossings:
  forward into the TOC 53–56 ms, backward to spine 2's end 98 ms. The first backward crossing after launch took
  590 ms, of which a 416 ms main-thread block with no instrumented span ran alongside Metal shader compiles (the
  first draw of the reader's glass bar in that process). The screen is blank for ~85 ms between the axis change and
  the reset.
- **Simulator.** Forward: the TOC opens at its top, its lines' starts on screen (1/1 · 96.9%). Backward: spine 2's
  last column at the trailing edge (第 240 夜, 91.9%), saved as (2, 1809); the refresh's own apply and spine 1's
  insertion behind it keep it there (sentry delta 0 each). Paged mode lays c0004 out horizontally (1/1 · 96.9%).
- **Not done: the opening restore** (*Scroll mode* table, `ReaderView.swift:3311`). `applyInitialProgressIfNeeded`
  still picks its branch by the book's axis, because it runs before the segment is entered. It cannot be moved to
  the restore chapter's segment yet: both branches clamp the saved spine to `chapters.count - 1`, and `chapters`
  is the EPUB's TOC entries, not its spine (`ReaderView+PageBuilding.swift:138`; the paged branch through
  `ReaderOpeningRestore.resolve(chapterCount:)`). The converted book has 2 TOC entries and 4 spine items, so a save
  at (3, 0) resolves to (1, 0): in scroll mode the header reads 第一章 and the footer 3.2% over the TOC (the save
  stays (3, 0)); in paged mode the book reopens on 第一章's first page. Older than this plan; it hits every EPUB
  whose spine is longer than its TOC.
- **Tests.** New `ScrollWritingModeSegmentTests` (a vertical segment stops at the TOC; entering the TOC's segment;
  entering is idempotent; a stale refresh keeps the segment's mode; a start outside the segment; only the reader's
  drag crosses; save and reopen inside the TOC; a one-screen segment; an axis turn shows nothing until the reslice
  and starts the new axis square). With `ChapterWritingModeEngineTests`, `CoreTextScrollTests`,
  `ContinuousScrollRestoreTests`, `BrowserVerticalReaderRouteTests`, `ReaderOpeningRestoreTests` and
  `ReaderPresentationContractTests`: 81 tests in 7 suites pass on iOS 17.5, 26.5 and 27.2.
- **Known limitations, left as they were.** A chapter inserted on the RTL axis puts the reader back at the
  committed position; only the vertical axis keeps the live cell's place (`applyChunkInsertion`), so a chapter
  arriving mid-drag in a vertical-rl segment can pull the reader back. A change of extent alone (bars, insets)
  reslices at the chapter's start, dropping the place inside it (`update(axis:)`). `BrowserTextInteractionController`
  draws note badges and highlights with `isVertical: false`. (Spine indices bounded by the TOC's
  `chapters.count` were listed here; fixed in their own commit, below.)

**Opening restore, done 2026-11-02 (its own commit, after Step 4).** Both clamps count the spine
(`spineChapters.count`), not the TOC. In scroll mode `applyInitialProgressIfNeeded` waits while the opening
chapter's segment is pending and runs again once `scrollBody` has entered it, so its branch follows the axis of
the restore chapter's segment: a horizontal segment restores in the scroll host, a vertical-rl one still goes
through the paged engine, as a vertical book always has. Simulator (iOS 26.5, the converted book): paged mode
reopens at the TOC on c0004 (1/1 · 96.9%; it opened 第一章 page 1/11 before); scroll mode reopens there with
header 第二章 潮汐 and 96.9% (第一章 and 3.2% before); a save at (2, 1809) in scroll mode resolves to spine 2,
spine 2's last column at the trailing edge, 91.9% (spine 1 before). `ReaderView` has no unit-test host for the
opening restore; the same seven suites pass on iOS 17.5, 26.5 and 27.2.

**Spine indices, done 2026-11-02 (its own commit).** Every reader site that bounded a spine index by the TOC's
`chapters.count`, or read a TOC entry by a spine index, now counts `spineChapters`: `canGoNextChapter`, the
next-chapter warm-up, neighbour preload, the scroll slider (`scrollSliderSpine(forProgress:spineCount:)` /
`scrollSliderProgress(forSpine:spineCount:)`, shared by the thumb, the release and the scrub caption), 聽書's
chapter chain (`narratableChapter(from:direction:spineCount:isSeparator:)`) and text, notes and highlights,
translation prefetch. Titles by spine go through `chapterTitle(forSpineIndex:)` (the TOC entry the item starts
in). 聽書's panel takes its 下一章 state from the reader and its chapter list picks TOC entries
(`startTTSChapter(atTOCEntry:)`). The 進度 chip counts TOC entries (0 before the first). The paged slider no
longer sits at 0 for a one-entry TOC. New `ReaderSpineIndexTests`; with `ReaderOpeningRestoreTests`,
`ScrollWritingModeSegmentTests` and four more, 57 tests in 7 suites pass on iOS 17.5, 26.5 and 27.2. Simulator
(iOS 26.5, scroll mode, a throwaway UI test): the slider at its end lands on the Calibre TOC (spine 3, 書末頁
disabled); 上一章 twice reaches 第一章 with 下一章 enabled; 下一章 goes to 第二章 and then the TOC; the slider at
its start reaches the cover, and a drag to two thirds 第二章.
