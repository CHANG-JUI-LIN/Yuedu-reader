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
yuedu app/
├── Models/
│   ├── App/          # GlobalSettings, DesignTokens, AppDependencies
│   ├── Book/         # ReadingBook, Bookmark, BookStore, BookChapter
│   ├── BookSource/   # Book source definitions and fetch pipeline
│   ├── LocalBook/    # EPUB/TXT/Markdown parsers and ingestors
│   ├── Online/       # Online reading pipeline and chapter fetching
│   ├── RSS/          # RSS models, feed parser, Legado rule engine
│   ├── Reader/       # CoreText layout engine, page rendering, EPUB renderer
│   ├── RuleEngine/   # CSS/XPath/Regex/JSON extraction rules
│   ├── TTS/          # Text-to-speech coordination and HTTP TTS
│   ├── Network/      # HTTP fetching, WebView fetcher
│   ├── Sync/         # WebDAV sync manager
│   ├── Migration/    # Legado data migration
│   └── Extensions/   # Color, String extensions
├── Views/
│   ├── Reader/       # Reader UI, controls, settings, scroll views
│   ├── Bookshelf/    # Home bookshelf and book management
│   ├── BookSource/   # Book source list, debug, and login views
│   ├── RSS/          # RSS subscription list, feed view, article reader
│   ├── Settings/     # Global settings, profile, WebDAV, TTS, migration
│   ├── Online/       # Browser view, web novel discovery
│   ├── Search/       # Book search interface
│   ├── Book/         # Add book views
│   ├── Common/       # Shared UI components
│   └── ...           # TTS, Stats, Download, Login, Replace
├── ViewModels/       # ObservableObject view models
├── Assets/           # Asset catalog and book source engine JS
├── en.lproj/         # English localization
├── zh-Hans.lproj/    # Simplified Chinese localization
└── zh-Hant.lproj/    # Traditional Chinese localization
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
