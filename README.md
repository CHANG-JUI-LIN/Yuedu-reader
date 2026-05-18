# Yuedu Reader

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="120">
</p>

<p align="center">
  <strong>A native iOS reading engine built with CoreText instead of WebView.</strong><br>
  The best native iOS reading engine you'll find in open source. CoreText rendering, zero WebView.
</p>

## Showcase

<table width="100%">
  <tr style="border: none;">
    <td width="33.3%" align="center" style="border: none; vertical-align: top;">
      <br>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#6d28d9" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="Book icon"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"></path><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"></path></svg>
      <h3>CJK Vertical Writing</h3>
      <img src="docs/screenshots/cjk-vertical.png" width="220" style="border-radius: 8px; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1);" alt="Screenshot of CJK vertical writing">
      <p style="font-size: 0.9em; color: #666; margin-top: 10px;">Dream of the Red Chamber (脂評本): vertical text, inline commentary, and compact annotations.</p>
    </td>
    <td width="33.3%" align="center" style="border: none; vertical-align: top;">
      <br>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#15803d" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="Text icon"><path d="M3 5v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2z"></path><path d="M7 15l3-6 3 6"></path><path d="M8 13h4"></path></svg>
      <h3>English EPUB</h3>
      <img src="docs/screenshots/english-epub.png" width="220" style="border-radius: 8px; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1);" alt="Screenshot of English EPUB rendering">
      <p style="font-size: 0.9em; color: #666; margin-top: 10px;">Publisher CSS support: drop caps, nested margins, and typographic cascade.</p>
    </td>
    <td width="33.3%" align="center" style="border: none; vertical-align: top;">
      <br>
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#1d4ed8" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="List icon"><line x1="8" y1="6" x2="21" y2="6"></line><line x1="8" y1="12" x2="21" y2="12"></line><line x1="8" y1="18" x2="21" y2="18"></line><line x1="3" y1="6" x2="3.01" y2="6"></line><line x1="3" y1="12" x2="3.01" y2="12"></line><line x1="3" y1="18" x2="3.01" y2="18"></line></svg>
      <h3>Table of Contents</h3>
      <img src="docs/screenshots/toc.png" width="220" style="border-radius: 8px; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1);" alt="Screenshot of Table of Contents">
      <p style="font-size: 0.9em; color: #666; margin-top: 10px;">toc.ncx and nav.xhtml prioritized over spine-based chapter guessing.</p>
    </td>
  </tr>
</table>

## Why CoreText rendering is hard

Most iOS reading apps delegate layout to WebKit. This works well enough for simple EPUB files, but it means the app cannot directly control pagination, reading position, CJK-specific behavior, or how themes and font settings interact with publisher CSS.

Yuedu Reader uses CoreText as the primary rendering surface. This is harder to build in several concrete ways:

**CSS resolution by hand.** Publisher stylesheets cannot be passed to a layout engine — every property (`text-indent`, `font-size`, `:first-letter`, nested block margins, `@font-face`, `@import`) must be parsed, resolved into a cascade, and translated into `NSAttributedString` attributes. Shorthand properties, percentage-based values, and inherited properties all require explicit handling.

**Two rendering paths that must stay in sync.** The renderer has a legacy path (`HTMLAttributedStringBuilder`) and a newer renderable-node path (`HTMLStyledASTRenderableNodeConverter → NodeAttributedStringRenderer`). Both produce CoreText attributed strings from the same CSS resolution layer. Any CSS property change must be reflected in both paths.

**CJK vertical writing.** CoreText reuses its horizontal API in vertical mode, but the axis meanings change. `CTLineGetOffsetForStringIndex` becomes inline advance from column top, not x advance. `ascent` and `descent` become block-direction extents. Latin runs inside vertical CJK text must be selectively de-verticalized and re-centered on the column axis — otherwise strings like `BookDNA` or `PDF` sit off-center relative to surrounding CJK glyphs.

**Inline annotations in vertical mode.** Books like the 脂評 edition of 紅樓夢 contain dense inline commentary — small-font notes interleaved with the main text across every column. CoreText cannot place these automatically in vertical layout. The paginator reserves column-width placeholder runs; `CoreTextPageView` draws the annotation content manually after the CTFrame is rendered. Long annotations must be split across pages rather than becoming a single unbreakable run.

**Durable reading position.** Page numbers are transient — they shift when the user changes font size, rotates the device, or a chapter finishes loading. Reading position is stored as `(spineIndex, charOffset)` into the content, so progress survives any layout change.

## Technical Highlights

- **Native CoreText rendering**: paged and continuous scroll without WebView as the main reader.
- **CJK vertical writing**: Traditional/Simplified Chinese vertical layouts, CJK punctuation, mixed CJK/Latin text, tested against complex vertical Chinese EPUB structures with inline commentary and colored annotations.
- **EPUB CSS resolution**: publisher CSS support including `:first-letter` drop caps, nested block margin accumulation, `<hr>` with width/margin/alignment, `text-indent` (including negative hanging indent), font cascade, and percentage-based margin/padding/width resolution.
- **Stable reading position**: progress stored as `(spineIndex, charOffset)` instead of transient page numbers, which shift after chapter loading or layout changes.
- **Large-book handling**: validated with multi-million-character TXT and EPUB files.
- **Legado-compatible source rules**: import and run user-provided rules compatible with the [Legado](https://github.com/gedoor/legado) rule format.
- **Online reading pipeline**: normalizes web pages and rule-based sources into the reader format.

## Rendering Pipeline

<p align="center">
  <img src="docs/banner.svg" alt="Rendering pipeline architecture" width="680">
</p>

Two parallel paths both produce CoreText attributed strings:

```
Legacy path:     HTMLAttributedStringBuilder.build() → NSAttributedString
                     ↓                            ↓
RenderableNode:  HTMLStyledASTRenderableNodeConverter → RenderableNode IR → NodeAttributedStringRenderer
                     ↓                            ↓
               Shared: CSSParser → ResolvedStyle → CoreTextPageView.drawLines()
```

Any CSS property change must update both paths. The shared layer handles CSS resolution, `ResolvedStyle`, and frame drawing in `CoreTextPageView`.

**Paged vs scroll**: `EPUBPageRenderer` routes content to `CoreTextPageEngine` (paged) or `CoreTextScrollEngine` (continuous scroll). `CoreTextPageView` and chunk cells draw the final CoreText frames.

**EPUB TOC**: reader prioritizes `toc.ncx` / `nav.xhtml` entries over the spine chapter list. Spine-only items (continued contents pages, split back matter) are excluded. Spine fallback deduplicates consecutive identical titles.

## Feature Overview

- CoreText paged and scroll reader
- EPUB CSS rendering (publisher stylesheets, font cascade, drop caps, margins)
- CJK typography: vertical writing, punctuation, paragraph indentation
- Local library: EPUB, TXT, Markdown import with caching, covers, bookmarks, annotations
- Online reading: web page normalization, rule-based source fetching
- RSS reader: RSS/Atom feeds, rule-based extraction, OPML import
- TTS: AVSpeechSynthesizer and HTTP custom TTS providers
- WebDAV sync: backup, restore, library and progress sync
- Reader customization: fonts, size, line height, spacing, margins, themes, page/scroll mode, vertical writing

## Requirements

- iOS 18.0+, Xcode 16+, Swift 5

## Getting Started

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

Select the `Yuedu-Reader` scheme and build for simulator or device. Or run:

```bash
./scripts/build.sh
```

## Repository Layout

```text
iOS/
├── Models/
│   ├── App/              # Global settings, DesignTokens, AppDependencies
│   ├── Book/             # ReadingBook, Bookmark, BookStore
│   ├── BookSource/       # Book source definitions and fetch pipeline
│   ├── LocalBook/        # EPUB/TXT/Markdown parsers
│   ├── Online/           # Online reading and web normalization
│   ├── RSS/              # RSS models, feed parser
│   ├── Reader/CoreText/  # CoreText page engine, scroll engine, CSS parser, rendering
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON extraction rules
│   ├── Sync/             # WebDAV sync manager
│   └── TTS/              # Text-to-speech coordination
├── Views/                # SwiftUI screens
├── ViewModels/           # ObservableObject view models
├── Assets/               # Asset catalogs and rule engine resources
└── *.lproj/              # Localization: zh-Hant, zh-Hans, en
```

## Development Rules

- Use `localized()` for user-facing strings; update all three `.lproj` files.
- Reading position based on content coordinates, not page indexes.
- UI styling via design-token APIs: `DSColor`, `DSFont`, `DSSpacing`.
- Add `#Preview` when creating or changing views.
- CSS properties added to `ResolvedStyle` must mirror in `RenderStyle`, update `RenderStyle.from`, and handle both rendering paths.
- Nested block CSS margins accumulate via `inheritedBlockMarginLeft`.

See [CONTRIBUTING.md](CONTRIBUTING.md). Architecture notes: [Technotes/Architecture.md](Technotes/Architecture.md).

## License

MIT. See [LICENSE](LICENSE). Links against [Readium](https://github.com/readium) components (BSD-licensed).
