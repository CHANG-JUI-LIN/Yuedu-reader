# Yuedu Reader

<p align="center">
  <img src="iOS/Assets.xcassets/AppIcon.appiconset/ios_app_icon_novel_reader_1024_no_alpha.png" width="112" alt="Yuedu Reader icon">
</p>

<p align="center">
  <strong>A native iOS reader powered by CoreText.</strong><br>
  EPUB / TXT / RSS / WebDAV / TTS / CJK vertical writing.
</p>

<p align="center">
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="docs/demo/cjk-vertical-toc.gif" width="320" alt="Yuedu Reader CJK vertical reading demo">
</p>

Yuedu Reader, named `閱讀` in Traditional Chinese and `阅读` in Simplified Chinese, is a native iOS reading app built for serious long-form reading. It focuses on CJK typography, local EPUB/TXT libraries, online article normalization, RSS, TTS, WebDAV sync, and a reader UI that stays native instead of WebView-based.

## CJK Vertical Reading

Yuedu Reader is built for serious CJK reading, not just basic EPUB display.

It supports vertical writing, right-to-left reading flow, CJK punctuation, inline commentary, vertical table of contents, and CoreText-based pagination.

<p align="center">
  <img src="docs/screenshots/cjk-vertical.png" width="260" alt="CJK vertical writing">
  <img src="docs/screenshots/toc.png" width="260" alt="CJK vertical table of contents">
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
  <img src="docs/screenshots/english-epub.png" width="280" alt="English EPUB rendering">
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

Short workflow GIFs should live in `docs/demo/rss-reading.gif` and `docs/demo/web-normalization.gif`. They are intentionally kept out of the first screen so the README loads quickly and stays focused.

## Features

- SwiftUI + CoreText native iOS reader
- EPUB / TXT / Markdown local reading
- CJK vertical writing and right-to-left reading UI
- Paged and scroll reading modes
- Highlights, bookmarks, annotations
- TTS and auto-reading
- WebDAV sync
- RSS / web article reading
- Legado-compatible source rules
- EPUB regression samples for rendering compatibility

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

This repository is developed with heavy AI-assisted collaboration, including code generation, refactoring, documentation, and review support. Human review and project ownership remain part of the workflow, but AI-assisted code is intentionally present throughout the project.

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

MIT. See [LICENSE](LICENSE). This project links against [Readium](https://github.com/readium) components, which are BSD-licensed.
