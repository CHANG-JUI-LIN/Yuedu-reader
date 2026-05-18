<p align="center">
  <img src="docs/banner.svg" alt="Yuedu Reader" width="600">
</p>

# Yuedu Reader

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" alt="Yuedu Reader app icon" width="128">
</p>

<p align="center">
  <strong>A native iOS EPUB/TXT reader built with SwiftUI and CoreText.</strong><br>
  No WebView as the main reading surface. CJK-first, typography-heavy, and designed for long-form reading.
</p>

Yuedu Reader, named `閱讀` in Traditional Chinese and `阅读` in Simplified Chinese, is a native iOS reader for local books, online articles, RSS feeds, TTS playback, and WebDAV sync. Its main reading surface is rendered with CoreText instead of WebView, so pagination, continuous scrolling, EPUB CSS, CJK vertical writing, mixed CJK/Latin text, and reading-position restoration are handled by the app's own rendering pipeline.

> Status: CJK-first. Chinese reading, mixed CJK/Latin text, and long novel scenarios are the primary targets. English EPUB/TXT rendering is supported and includes EPUB typography features such as drop caps, publisher CSS, chapter layout, and table-of-contents navigation.

## Showcase

> Add screenshots here before promoting the repository. Recommended layout:
>
> - CJK vertical writing with inline commentary
> - English EPUB typography with drop cap
> - Table of contents
> - Reader settings / themes

| CJK Vertical Writing | English EPUB Typography | Table of Contents |
| :---: | :---: | :---: |
| <img src="docs/screenshots/cjk-vertical.png" width="220" alt="CJK vertical writing"> | <img src="docs/screenshots/english-epub.png" width="220" alt="English EPUB typography"> | <img src="docs/screenshots/toc.png" width="220" alt="Table of contents"> |

## Rendering Highlights

* **Native CoreText rendering**: paged reading and continuous scrolling without using WebView as the main reader.
* **CJK vertical writing**: vertical Traditional/Simplified Chinese layouts, CJK punctuation handling, mixed CJK/Latin text, and long-form novel reading.
* **Complex CJK EPUB handling**: tested against vertical Chinese EPUB structures with inline commentary, colored annotations, small-font notes, and large numbers of inline source markers.
* **English EPUB typography**: publisher CSS, chapter titles, paragraph indentation, `:first-letter` drop caps, nested block margins, dividers, font style cascade, and table-of-contents navigation.
* **Stable reading position**: reading progress is based on durable content coordinates instead of transient page numbers.

## Why CoreText?

Most EPUB readers can delegate layout to WebView. Yuedu Reader intentionally uses CoreText as the main reading surface so the app can control pagination, scroll layout, typography, themes, reading position, and CJK-specific behavior directly.

This makes the renderer harder to build, but it also makes the project useful as a native iOS reading-engine experiment, especially for CJK typography and long novel scenarios.

## What It Does

- **Native CoreText reader**: paged reading and continuous scroll rendering without using WebView as the main reading surface.
- **EPUB CSS rendering**: publisher CSS support including `:first-letter` drop caps, nested block margins, `<hr>` dividers with `width`/`margin`/`alignment`, `text-indent` (including negative hanging indent), `font-size`/`font-weight`/`font-style` cascade, and percentage-based margin/padding/width resolution.
- **CJK typography**: paragraph indentation, punctuation handling, line spacing, margins, mixed CJK/Latin text, and vertical writing support.
- **Local library**: import EPUB, TXT, and Markdown-like text files with parsing, caching, covers, bookmarks, annotations, and reading-position restore.
- **Large-book handling**: validated with long TXT and EPUB books, including multi-million-character reading flows.
- **Online reading pipeline**: normalize user-provided web pages and rule-based book sources into the same reader format.
- **Legado-compatible source rules**: import and run user-provided custom source rules compatible with the [Legado](https://github.com/gedoor/legado) rule format.
- **RSS reader**: RSS/Atom feeds, rule-based extraction, OPML-style workflows, and article rendering.
- **TTS**: local `AVSpeechSynthesizer` playback and HTTP-based custom TTS providers.
- **Sync and backup**: WebDAV-oriented backup, restore, library sync, and progress sync flows.
- **Reader customization**: fonts, font size, line height, paragraph spacing, margins, themes, page/scroll mode, and vertical writing mode.

## Project Boundary

Yuedu Reader is a reader engine and app shell. It does not include, host, recommend, or distribute copyrighted content sources.

Users are responsible for making sure imported files, RSS feeds, websites, custom rules, cookies, accounts, and generated content comply with applicable laws, copyright requirements, and website terms.

The project will not accept contributions for built-in piracy sources, DRM circumvention, paywall bypassing, private-token sharing, cookie harvesting, or anti-bot bypass logic.

Legado compatibility is a source-rule format compatibility target only. Yuedu Reader does not bundle third-party source rules and is not affiliated with the Legado project.

## AI-Assisted Development

This repository is developed with heavy AI-assisted collaboration, including code generation, refactoring, documentation, and review support. Human review and project ownership remain part of the workflow, but AI-assisted code is intentionally present throughout the project.

If you strongly prefer strictly human-authored code or are uncomfortable with AI-assisted development, please review the project with that expectation in mind. Your understanding is appreciated.

## Requirements

- iOS 18.0+
- Xcode 16+
- Swift 5 language mode in the Xcode project

## Getting Started

```bash
git clone https://github.com/CHANG-JUI-LIN/Yuedu-reader.git
cd Yuedu-reader
open Yuedu-Reader.xcodeproj
```

Select the `Yuedu-Reader` scheme and build for an iOS simulator or device.

You can also run the app-target build script:

```bash
./scripts/build.sh
```

Equivalent command:

```bash
xcodebuild \
  -project "Yuedu-Reader.xcodeproj" \
  -scheme "Yuedu-Reader" \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build
```

## Repository Layout

```text
iOS/
├── Models/               # Data models, stores, services, renderers, parsers
│   ├── App/              # Global settings, design tokens, dependency injection
│   ├── Book/             # Book model, BookStore, bookmarks, metadata
│   ├── BookSource/       # User-defined source fetching
│   ├── LocalBook/        # EPUB/TXT/Markdown ingestion
│   ├── Online/           # Online reading and web normalization pipeline
│   ├── RSS/              # RSS models, feed fetcher, parser, article utilities
│   ├── Reader/CoreText/  # CoreText pagination, scroll layout, drawing, CSS resolution
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON extraction
│   ├── Sync/             # WebDAV and sync logic
│   └── TTS/              # Speech playback coordination
├── Views/                # SwiftUI screens and reusable UI
│   ├── Reader/           # Reader surface, controls, settings, overlays
│   ├── Bookshelf/        # Home bookshelf and book management
│   ├── BookSource/       # Book-source management and diagnostics
│   ├── Online/           # Browser/import flows
│   ├── RSS/              # RSS subscription and article views
│   └── Settings/         # App settings, profile, sync, TTS, migration
├── ViewModels/           # ObservableObject view models
├── Assets/               # Asset catalogs and rule-engine resources
└── *.lproj/              # Localization: zh-Hant, zh-Hans, en

ShareExtension/           # iOS share extension
Widget/                   # Home screen widget
Tests/                    # Unit and UI test targets
Technotes/                # Architecture notes
scripts/                  # Local automation scripts
xcconfig/                 # Shared Xcode configuration
```

## Architecture Notes

- **EPUB**: Readium components handle EPUB package parsing and resource access. CSS from the publication (including `@import`, `@font-face`, and linked stylesheets) is loaded, processed, and resolved per chapter.
- **Rendering pipeline**: Two parallel paths both produce CoreText-attributed strings:
  - Legacy path: `HTMLAttributedStringBuilder.build()` → direct `NSAttributedString`
  - RenderableNode path: `HTMLStyledASTRenderableNodeConverter` → `RenderableNode` IR → `NodeAttributedStringRenderer`
  - Both share `CSSParser`, CSS resolution, `ResolvedStyle`, and `CoreTextPageView.drawLines`. Any CSS property change must update both paths.
- **Paged vs scroll**: `EPUBPageRenderer` routes content to `CoreTextPageEngine` for paged reading or `CoreTextScrollEngine` for continuous scroll. `CoreTextPageView` and chunk cells draw the final CoreText frames.
- **EPUB TOC**: The reader TOC panel prioritizes `toc.ncx`/`nav.xhtml` entries over the spine chapter list. Spine-only items (continued contents pages, split back matter) are excluded. Spine fallback includes deduplication for consecutive identically-titled entries.
- **Reading position**: durable positions are based on `(spineIndex, charOffset)` instead of page number, because page indexes can shift after chapter loading or layout changes.
- **Online content**: `BookSourceFetcher`, `OnlineReadingPipeline`, `ModernRuleEngine`, and web fetchers convert user-provided sources into normalized chapter content.
- **RSS**: feed XML parsing and rule-based article extraction share the same sanitization and reader-rendering principles as online reading.
- **TTS**: playback state is coordinated separately from rendering so reader highlighting and system media controls can follow the active text segment.
- **Dependency injection**: `AppDependencies` and SwiftUI environment values provide app services; shared managers are centralized where persistence or cache ownership is required.

More detail: [Technotes/Architecture.md](Technotes/Architecture.md).

## Development Rules

- Use `localized()` for user-facing strings and update all three localization files:
  - `iOS/zh-Hant.lproj/Localizable.strings`
  - `iOS/zh-Hans.lproj/Localizable.strings`
  - `iOS/en.lproj/Localizable.strings`
- Keep reader identity based on stable content coordinates, not transient page indexes.
- Use the app's design-token APIs for UI styling: `DSColor`, `DSFont`, and `DSSpacing` in `Models/App/DesignTokens.swift`.
- Add a compiling SwiftUI preview (`#Preview` or `PreviewProvider`) when creating or changing view code wherever practical, so screens and components can be inspected quickly in Xcode.
- Keep source/rule-engine work limited to legal, user-provided content workflows.
- When adding CSS properties to `ResolvedStyle`, mirror the fields in `RenderStyle`, update the converter (`RenderStyle.from`), and handle both rendering paths.
- Nested block CSS margins must accumulate via `inheritedBlockMarginLeft` — CoreText uses a single frame, so parent margins don't automatically compound into child paragraph indents.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution conventions.

## License

MIT. See [LICENSE](LICENSE).

This project links against [Readium](https://github.com/readium) components, which are BSD-licensed. The Readium name and logo are trademarks of the Readium Foundation.
dium name and logo are trademarks of the Readium Foundation.
