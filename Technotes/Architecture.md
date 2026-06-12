# Yuedu-reader Architecture

## Overview

Yuedu-reader is an iOS EPUB/TXT/web-novel reader built with SwiftUI and CoreText.  
The app supports paged and scroll reading, bookmark annotation, TTS, RSS subscriptions, and rule-engine-based web novel sources.

## Target Structure

| Target | Description |
|--------|-------------|
| `yuedu app` | Main iOS application |
| `yuedu app Widget` | Home screen widget |
| `yuedu app ShareExtension` | Share sheet extension |
| `yuedu appTests` | Unit and integration tests |
| `yuedu appUITests` | UI tests |

## Source Layout

```
Modules/
├── Core/                  # EPUB/TXT/MD parsers, CoreText engine, BookSource, RuleEngine, TTS, Comic, Replace
├── Features/              # SwiftUI screens: Bookshelf, Reader, RSS, BookSource, Settings, Search, WebBrowser...
├── Services/              # LibraryStore, Online, WebDAV, iCloud, OPDS, Network, Account, RSS, Migration...
└── SharedUI/              # DesignSystem (DSColor, DSFont, DSSpacing), Components, Extensions, Utilities, Adaptive layout
Resources/                 # Assets.xcassets, Assets/ (book source engine JS), en.lproj, zh-Hans.lproj, zh-Hant.lproj
Targets/Yuedu/             # SharedApp, iPhone/, iPad/ entry points
```

## Reader Pipeline

The reader has two rendering modes, both backed by CoreText:

### Paged Mode
```
EPUBPageRenderer → CoreTextPageEngine → UIPageViewController → CoreTextPageView
```
- `CoreTextPaginator` handles margin flow, CJK typography, and frame-based pagination
- `CoreTextPageView` draws each page via `CTFrameDraw` with line-by-line rendering
- `HTMLAttributedStringBuilder` converts EPUB HTML chapters to NSAttributedString

### Scroll Mode
```
EPUBPageRenderer → CoreTextScrollEngine → UITableView → CoreTextChunkCell
```
- Vertical continuous scroll with dynamic chunk slicing
- `CoreTextChunkSlicer` divides content into ~2000pt viewport chunks

## Online Reading Pipeline

```
BookSourceFetcher.searchBooks()
  → AnalyzeUrl (URL construction with template variables)
  → WebFetcher (HTTP request)
  → ModernRuleEngine (CSS/XPath/Regex/JSON extraction)
  → OnlineReadingPipeline (chapter fetch + content extraction)
  → CoreText layout
```

## RSS Pipeline

- **Standard RSS/Atom**: `RSSFetcher` → `RSSXMLParser` → `RSSStore`
- **Legado rule-based**: `RSSFetcher` → `LegadoRSSScraper` (HTML scraping via SwiftSoup + CSS rules) → `RSSStore`
- **Import/Export**: OPML 2.0 and Legado JSON formats

## Key Design Decisions

- **Reading position identity**: Use `(spineIndex, charOffset)` not `globalPage`. Pages shift when chapters load.
- **Margin flow**: `GlobalSettings.pageMarginH/V` → `currentContentInsets()` → `CoreTextPaginator.paginate(contentInsets:)` → `ChapterLayout.contentInsets` → `CoreTextPageView.draw()`
- **Dependency injection**: `AppDependencies` + `@Environment` for services; singletons for caches
- **Localization**: All UI strings via `localized()`; keys in zh-Hant, zh-Hans, en

## Dependencies

- **Readium** (BSD) — EPUB parsing via ReadiumShared, ReadiumStreamer, ReadiumZIPFoundation
- **SwiftSoup** (MIT) — HTML parsing for RSS and rule engine
- **GoogleSignIn** (Apache 2.0) — Optional Google account sign-in
- **Fuzi** — XPath XML querying (via ReadiumFuzi)
