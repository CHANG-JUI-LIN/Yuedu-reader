# Yuedu Reader

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="112" alt="Yuedu Reader icon">
</p>

<p align="center">
  <strong>A native iOS reader powered by CoreText.</strong><br>
  EPUB / TXT / RSS / Manga / WebDAV / TTS / CJK vertical writing.
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/7hvbzYC1">
    <img src="https://img.shields.io/badge/TestFlight-Join%20Beta-0D96F6?logo=apple&logoColor=white" alt="Join the TestFlight beta">
  </a>
  <a href="https://t.me/+ZWmmgMwwJ3JiN2Rl">
    <img src="https://img.shields.io/badge/Telegram-Join%20Group-26A5E4?logo=telegram&logoColor=white" alt="Join the Telegram group">
  </a>
  <a href="https://iosdevweekly.com/issues/751">
    <img src="https://img.shields.io/badge/Featured%20in-iOS%20Dev%20Weekly%20%23751-FF6600" alt="Featured in iOS Dev Weekly #751">
  </a>
</p>

<p align="center">
  <a href="https://chang-jui-lin.github.io/Yuedu-reader/support.html">Support</a> ·
  <a href="https://chang-jui-lin.github.io/Yuedu-reader/privacy.html">Privacy Policy</a>
</p>

<p align="center">
  <img src="docs/demo/cjk-vertical-toc.gif" width="320" alt="Yuedu Reader CJK vertical reading demo">
</p>

Yuedu Reader is a native iOS reading app for serious long-form reading, focused on CJK typography, local EPUB/TXT libraries, manga, RSS, web article normalization, TTS, OPDS and WebDAV import/sync, and a reader UI that stays native instead of WebView-based.

> 📝 Featured in [iOS Dev Weekly #751](https://iosdevweekly.com/issues/751) — [*From WebView to CoreText: Building a Native EPUB Reader for iOS*](https://chang-jui-lin.github.io/Yuedu-reader/2026/05/20/from-webview-to-coretext/).

## CJK Vertical Reading

Yuedu Reader is built for serious CJK reading, not just basic EPUB display.

It supports vertical writing, right-to-left reading flow, CJK punctuation, inline commentary, vertical table of contents, and CoreText-based pagination.

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="280" alt="CJK vertical writing">
</p>

Highlights:

- Vertical CJK text rendering
- Right-to-left table of contents for vertical books
- CJK punctuation handling
- Inline commentary and annotation-heavy EPUB testing
- CoreText pagination instead of WebView-based display

## English EPUB Works Too

Yuedu is not limited to CJK books. Standard English EPUB rendering is also supported, including publisher CSS, chapter navigation, images, links, and pagination.

<p align="center">
  <img src="docs/screenshots/english-epub.png" width="260" alt="English EPUB rendering">
  <img src="docs/screenshots/toc.png" width="260" alt="English EPUB table of contents">
</p>

Supported EPUB features include:

- Reflowable EPUB
- Publisher CSS cascade
- Drop caps and paragraph styling
- Images and SVG rasterization
- `toc.ncx` and `nav.xhtml` navigation
- Highlights, bookmarks, and TTS

## Reading Workflows

Yuedu Reader is not only a local EPUB reader. It also includes RSS reading and web article normalization for online reading workflows.

- **RSS Reader**: RSS / Atom feeds, article extraction, and reading inside the native reader.
- **Web Article Normalization**: convert web pages into clean long-form reading content.
- **Book Source Reading**: Legado-compatible book sources for online web novels — search, browse chapters, and read in the native CoreText reader.
- **Manga Reading**: read manga from compatible book sources or import local manga (`.cbz` / `.zip`), viewed in a dedicated image reader.
- **Library Import**: add books straight from OPDS catalogs and WebDAV servers via the bookshelf add-book menu.

<p align="center">
  <img src="docs/demo/book-source-reading.gif" width="320" alt="Online book-source web-novel reading demo">
</p>

## Features

- SwiftUI + CoreText native iOS reader
- EPUB / TXT / Markdown local reading
- CJK vertical writing and right-to-left reading UI
- Paged and scroll reading modes
- Highlights, bookmarks, annotations
- TTS and auto-reading
- Manga reading via a dedicated image reader (book sources + local `.cbz` / `.zip` import)
- OPDS catalog import
- WebDAV import and sync
- RSS / web article reading
- Legado-compatible source rules
- EPUB regression samples for rendering compatibility

## Roadmap

### Now

- Improve EPUB rendering compatibility
- Polish CJK vertical reading and TOC behavior
- Add EPUB rendering bug templates and regression samples
- Improve RSS loading error handling

### Next

- Better web article normalization
- Richer manga sources and reader gestures
- Fixed-layout EPUB prototype

### Later

- App Store release
- TestFlight feedback loop
- More accessibility work
- More automated rendering regression tests

See open issues labeled `help wanted` or `good first issue` if you want to contribute.

## Why CoreText?

Most EPUB readers use WebView. Yuedu uses CoreText for the main reader so it can control pagination, text ranges, highlights, TTS synchronization, and CJK vertical rendering more precisely.

This makes it possible to build:

- stable reading positions based on `(spineIndex, charOffset)`
- precise page rendering
- native text selection and highlighting
- TTS progress synchronization
- custom CJK vertical layout behavior

## Rendering Pipeline

Yuedu has two EPUB rendering paths that share the same CSS resolution and CoreText drawing layer:

- Legacy HTML attributed-string builder
- RenderableNode IR pipeline

Most contributors do not need to understand the full engine before working on UI, docs, localization, EPUB testing, WebDAV, or source-rule features.

For details, see:

- [CoreText contributor notes](docs/coretext/README.md)
- [Architecture notes](Technotes/Architecture.md)

## EPUB Compatibility

Yuedu includes a small EPUB regression corpus and compatibility checklist for testing rendering behavior.

- [EPUB compatibility checklist](docs/epub-compatibility-checklist.md)
- [EPUB regression samples](docs/epub-regression/README.md)

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

Select the `Yuedu-Reader` scheme and build for a simulator or device. Or run:

```bash
./scripts/build.sh
```

## Project Boundary

Yuedu Reader is a reader engine and app shell. It does not include, host, recommend, or distribute copyrighted content sources.

Users are responsible for making sure imported files, RSS feeds, websites, custom rules, cookies, accounts, and generated content comply with applicable laws, copyright requirements, and website terms.

The project will not accept contributions for built-in piracy sources, DRM circumvention, paywall bypassing, private-token sharing, cookie harvesting, or anti-bot bypass logic.

Legado compatibility is a source-rule format compatibility target only. Yuedu Reader does not bundle third-party source rules and is not affiliated with the [Legado](https://github.com/gedoor/legado) project.

## AI-Assisted Development

This repository is developed with heavy AI-assisted collaboration, including code generation, refactoring, documentation, and review support. Human review and project ownership remain part of the workflow.

If you strongly prefer strictly human-authored code or are uncomfortable with AI-assisted development, please review the project with that expectation in mind. Your understanding is appreciated.

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

## Development

- Use `localized()` for user-facing strings; update all three `.lproj` files.
- Keep reading position based on content coordinates, not page indexes.
- Style UI with design-token APIs: `DSColor`, `DSFont`, `DSSpacing`.
- Add a compiling SwiftUI preview (`#Preview` or `PreviewProvider`) when creating or changing view code wherever practical.
- CSS properties added to `ResolvedStyle` must mirror in `RenderStyle`, update `RenderStyle.from`, and handle both rendering paths.
- Nested block CSS margins accumulate through `inheritedBlockMarginLeft`.
- Keep source/rule-engine work limited to legal, user-provided content workflows.

See [CONTRIBUTING.md](CONTRIBUTING.md). Demo media workflow: [docs/demo/README.md](docs/demo/README.md).

## License

[MIT](https://opensource.org/license/mit). See [LICENSE](LICENSE). This project links against [Readium](https://github.com/readium) components, which are BSD-licensed.
