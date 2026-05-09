# yuedu

An iOS EPUB/TXT/web-novel reader built with SwiftUI and CoreText.  
Read, bookmark, annotate, and listen — all in one app.

## Features

- **EPUB & TXT reading** — CoreText-based paged and vertical-scroll rendering
- **Web novel support** — Rule-engine book sources with CSS/XPath/Regex/JSON extraction
- **RSS subscriptions** — Standard RSS/Atom feeds plus Legado-format rule-based sources
- **TTS (Text-to-Speech)** — AVSpeechSynthesizer and HTTP-based custom TTS backends
- **Bookmarks & annotations** — Paragraph-level underline annotation persistence
- **Vertical writing mode** — CJK vertical right-to-left text
- **OPML & Legado JSON import/export** — Migrate subscriptions easily
- **WebDAV sync** — Backup and restore reading progress
- **Google Sign-In** — Account sync (optional)

## Requirements

- iOS 18.0+
- Xcode 16.0+
- Swift 6

## Getting Started

```bash
git clone https://github.com/yuedu-reader/yuedu-app.git
cd yuedu-app
open "yuedu app.xcodeproj"
```

Select the `yuedu app` scheme and build to a simulator or device.

## Project Structure

```
yuedu app/
├── Models/               # Data models, stores, engines
│   ├── App/              # Global settings, design tokens, DI
│   ├── Book/             # Book model, BookStore, bookmarks
│   ├── BookSource/       # Book source fetch pipeline
│   ├── LocalBook/        # EPUB/TXT/Markdown parsers
│   ├── Online/           # Online reading pipeline
│   ├── RSS/              # RSS models, fetcher, parser
│   ├── Reader/CoreText/  # CoreText layout engine
│   ├── RuleEngine/       # CSS/XPath/Regex/JSON rule extraction
│   ├── TTS/              # Text-to-speech coordination
│   └── ...               # Comic, Migration, Network, Sync, Server
├── Views/                # SwiftUI views
│   ├── Reader/           # Reader UI and controls
│   ├── Bookshelf/        # Home bookshelf
│   ├── BookSource/       # Book source management
│   ├── RSS/              # RSS subscription views
│   ├── Settings/         # App settings
│   └── ...               # Search, Stats, TTS, etc.
├── ViewModels/           # ObservableObject view models
├── Assets/               # Assets catalog and book source engine JS
└── *.lproj/              # Localization (zh-Hant, zh-Hans, en)
```

## Architecture

- **Reader**: `EPUBPageRenderer` dispatches to `CoreTextPageEngine` (paged) or `CoreTextScrollEngine` (scroll). Each page is rendered by `CoreTextPageView` via CoreText `CTFrame` drawing.
- **Book sources**: `BookSourceFetcher` → `OnlineReadingPipeline` → rule engine extracts chapters and content.
- **RSS**: `RSSFetcher` handles standard XML feeds and Legado rule-based HTML scraping.
- **Dependency injection**: `AppDependencies` + `@Environment` for services; singletons for caches and managers.

## Localization

All UI strings must use `localized()`. Do not hardcode strings.

When adding keys, update all three files:
- `zh-Hant.lproj/Localizable.strings`
- `zh-Hans.lproj/Localizable.strings`
- `en.lproj/Localizable.strings`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — See [LICENSE](LICENSE).

**Note:** This project links against [Readium](https://github.com/readium) components which are BSD-licensed. The Readium name and logo are trademarks of the Readium Foundation.
