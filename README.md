# yuedu

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md)

A highly customizable native iOS reader built with SwiftUI and CoreText.

yuedu focuses on CJK long-form reading, custom typography, large-book performance, EPUB/TXT import, RSS, TTS, WebDAV, and user-defined web content normalization.

> Status: CJK-first. Chinese reading, mixed CJK/Latin text, and long-form novel scenarios are the primary targets. English EPUB/TXT rendering is supported at a basic level but has not been fully tested as a primary use case.

## Highlights

- **CJK-first typography** — optimized for Chinese long-form reading, punctuation handling, paragraph spacing, indentation, and vertical writing.
- **Custom CoreText renderer** — paged and vertical-scroll rendering without relying on a WebView-based reading surface.
- **EPUB & TXT import** — local book import, parsing, caching, and reading-position restoration.
- **Large-book handling** — tested with 14M-character TXT files and 8M-character EPUB files.
- **TTS reading** — AVSpeechSynthesizer and HTTP-based custom TTS backends.
- **RSS subscriptions** — standard RSS/Atom feeds and rule-based feed extraction.
- **WebDAV support** — backup, restore, and library/progress synchronization workflows.
- **Web content normalization** — convert user-provided web articles or novel pages into the reader format.
- **Bookmarks & annotations** — paragraph-level bookmark and underline annotation persistence.
- **Customizable reading UI** — fonts, font size, line spacing, margins, themes, page/scroll modes, and vertical writing mode.

## Scope

yuedu is a reading engine and app shell. It does not include, host, or recommend copyrighted content sources.

Users are responsible for ensuring that imported files, web content, RSS feeds, and custom rules comply with applicable laws, copyright requirements, and website terms.

Requests or contributions for built-in piracy sources, DRM circumvention, paywall bypassing, private tokens, cookies, or anti-bot bypass logic will not be accepted.

## Requirements

- iOS 18.0+
- Xcode 16.0+
- Swift 6

## Getting Started

```bash
git clone https://github.com/yuedu-reader/yuedu.git
cd yuedu
open Yuedu-Reader.xcodeproj
```

Select the `Yuedu-Reader` scheme and build to a simulator or device.

## Project Structure

```text
iOS/
├── Models/               # Data models, stores, engines
│   ├── App/              # Global settings, design tokens, dependency injection
│   ├── Book/             # Book model, BookStore, bookmarks
│   ├── BookSource/       # User-defined source fetch pipeline
│   ├── LocalBook/        # EPUB/TXT/Markdown parsers
│   ├── Online/           # Online reading and web normalization pipeline
│   ├── RSS/              # RSS models, fetcher, parser
│   ├── Reader/CoreText/  # CoreText layout and pagination engine
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON rule extraction
│   ├── TTS/              # Text-to-speech coordination
│   └── ...               # Comic, Migration, Network, Sync, Server
├── Views/                # SwiftUI views
│   ├── Reader/           # Reader UI and controls
│   ├── Bookshelf/        # Home bookshelf
│   ├── BookSource/       # Source management
│   ├── RSS/              # RSS subscription views
│   ├── Settings/         # App settings
│   └── ...               # Search, Stats, TTS, etc.
├── ViewModels/           # ObservableObject view models
├── Assets/               # Assets catalog and rule-engine resources
└── *.lproj/              # Localization (zh-Hant, zh-Hans, en)
```

## Architecture

- **EPUB parsing**: Readium components are used for EPUB package parsing and resource management.
- **Rendering**: `EPUBPageRenderer` dispatches to `CoreTextPageEngine` for paged reading or `CoreTextScrollEngine` for vertical scrolling. Pages are drawn by `CoreTextPageView` using CoreText `CTFrame` rendering.
- **CJK layout**: The renderer is designed around Chinese long-form reading, including CJK punctuation, paragraph indentation, mixed CJK/Latin text, and vertical right-to-left layout.
- **Book sources**: `BookSourceFetcher` → `OnlineReadingPipeline` → `RuleEngine` extracts chapters and normalized content from user-defined rules.
- **RSS**: `RSSFetcher` handles standard XML feeds and rule-based HTML extraction.
- **TTS**: The TTS coordinator maps readable text blocks to playback state and reader position.
- **Sync**: WebDAV and account-related services handle backup, restore, and progress synchronization.
- **Dependency injection**: `AppDependencies` and `@Environment` provide services; caches and managers are centralized where necessary.

## Localization

All UI strings must use `localized()`. Do not hardcode user-facing strings.

When adding localization keys, update all three files:

- `zh-Hant.lproj/Localizable.strings`
- `zh-Hans.lproj/Localizable.strings`
- `en.lproj/Localizable.strings`

## Recommended README Assets

For a public GitHub release, add the following assets:

- Bookshelf screenshot
- Reading page screenshot
- Typography/settings screenshot
- Page-turning animation GIF
- TTS playback GIF or short video
- Import benchmark table
- Architecture diagram

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

Contributions should focus on the reader engine, UI, localization, EPUB/TXT handling, RSS, WebDAV, accessibility, tests, and legal user-provided content workflows.

## License

MIT — See [LICENSE](LICENSE).

This project links against [Readium](https://github.com/readium) components, which are BSD-licensed. The Readium name and logo are trademarks of the Readium Foundation.
