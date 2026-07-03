# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yuedu Reader — native iOS EPUB/TXT/RSS/web-novel reader. SwiftUI + CoreText, targeting iOS 17.0+, Swift 6.0, Xcode 16+. The reader renders via CoreText (not WebView) for precise pagination, CJK vertical writing, TTS sync, and text selection.

## Build & Test

```bash
# Build for simulator
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run all unit tests
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'

# Run a single test class (no parallel — many tests depend on shared state)
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/CoreTextWritingModeTests'

# Run a single test method
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/CoreTextWritingModeTests/testVerticalRTLPagination'
```

Use `-quiet` to suppress build output. Tests are in `Tests/iOS/yuedu appTests/`. UI tests in `Tests/iOS-UI/`.

## Targets

| Target | Purpose |
|--------|---------|
| `yuedu app` | Main iOS app |
| `yuedu appTests` | Unit/integration tests |
| `yuedu appUITests` | UI tests |
| `Yuedu-Reader Widget` | Home screen widget |
| `yuedu app ShareExtension` | Share sheet extension |

## Source Layout

Swift sources live under `Modules/` and `Targets/` (Xcode 16 file-system-synchronized groups — drop a file into the folder and it joins the target, no `.pbxproj` edit). Everything compiles into the `yuedu app` target.

| Folder | Contents |
|--------|----------|
| `Modules/Core/` | Domain logic: `ReaderCore` (CoreText engine/paginator), `EPUB`/`TXT`/`Markdown`/`Comic` parsing, `BookSource`, `RuleEngine`, `Replace`, `TTS` |
| `Modules/Services/` | `Network`, `RSS`, `OPDS`, `Online`, `LibraryStore`, `iCloud`/`WebDAV`/`Account`, `LanServer`, `Stats`, `Migration` |
| `Modules/Features/` | SwiftUI screens: `Bookshelf`, `Reader` (+`iPad`/`Manga`/`TTS`), `BookDetail`, `Explore`, `WebBrowser`, `Search`, `RSS`, `Settings`, `BookSource`, `Stats` |
| `Modules/SharedUI/` | `DesignSystem` (`DesignTokens.swift`), `Adaptive`, `Components`, `Extensions` |
| `Targets/Yuedu/SharedApp/` | App entry (`yuedu_appApp.swift`, `ContentView.swift`), DI, `GlobalSettings`, app config |
| `Targets/Yuedu/iPad/` | iPad-specific shell (e.g. `IPadAdaptiveRootTabStyle.swift`) |
| `iOS/` | Resources only: `Assets.xcassets`, `*.lproj`, bridging header, entitlements |

## Key Architecture

### Reader Pipeline

Two rendering modes, both backed by CoreText:

**Paged mode:** `EPUBPageRenderer` → `CoreTextPageEngine` → `UIPageViewController` → `CoreTextPageView` (each page drawn via `CTFrameDraw`)

**Scroll mode:** `EPUBPageRenderer` → `CoreTextScrollEngine` → `UITableView` → `CoreTextChunkCell` (~2000pt chunks via `CoreTextChunkSlicer`)

EPUB HTML → `HTMLAttributedStringBuilder` → `NSAttributedString` → paginator → pages. A parallel path via `RenderableNode` IR exists for CSS-rich content. Both paths share CSS resolution through `ResolvedStyle` / `RenderStyle`.

### Online Reading Pipeline

`BookSourceFetcher.searchBooks()` → `AnalyzeUrl` (template URL construction) → `WebFetcher` (HTTP) → `ModernRuleEngine` (CSS/XPath/Regex/JSON extraction) → `OnlineReadingPipeline` (chapter fetch + content) → CoreText layout

### RSS Pipeline

Standard feeds: `RSSFetcher` → `RSSXMLParser` → `RSSStore`
Legado rule-based: `RSSFetcher` → `LegadoRSSScraper` (SwiftSoup + CSS rules) → `RSSStore`
Import/Export: OPML 2.0 and Legado JSON formats

## Critical Conventions

- **Reading position**: `(spineIndex, charOffset)`, never global page index. Pages shift when chapters load.
- **Localization**: Every user-facing string via `localized("Key")`. Keys must exist in all three `.lproj` files: `zh-Hant`, `zh-Hans`, `en`.
- **Design tokens**: Use `DSColor`, `DSFont`, `DSSpacing` for all UI styling. Never hardcode colors or fonts.
- **UI design**: All views must follow `docs/design.md` (HIG-native, not web UI). Hard rule: any page with a top toolbar / nav title uses `.toolbarTitleDisplayMode(.inlineLarge)`. The `yuedu-ios-design` skill enforces this when touching UI.
- **Dependency injection**: `AppDependencies` + `@Environment` for services. Singletons only for caches and shared managers.
- **CSS properties**: Adding to `ResolvedStyle` requires mirroring in `RenderStyle`, updating `RenderStyle.from`, and handling both rendering paths.
- **Vertical CJK**: Vertical writing uses right-to-left page flow. `String+VerticalNormalization` and `VerticalLayoutConfig` handle coordinate transforms. Run `CoreTextWritingModeTests` before touching vertical layout code.
- **SwiftUI previews**: Add `#Preview` when creating or changing view code.

## Dependencies

Detailed package versions and their transitive dependencies are recorded in [Dependencies.md](file:///Users/zhangruilin/Desktop/Yuedu-reader/Technotes/Dependencies.md).

- **Readium** (BSD) — EPUB parsing (ReadiumShared, ReadiumStreamer, ReadiumZIPFoundation, ReadiumFuzi)
- **SwiftSoup** (MIT) — HTML parsing for RSS and rule engine
- **GoogleSignIn** (Apache 2.0) — Optional Google sign-in
- **CryptoSwift**, **SQLite.swift**, **Zip**, **DifferenceKit**, **GCDWebServer**


## Key Documentation

- `Technotes/Architecture.md` — full architecture
- `docs/coretext/README.md` — CoreText code map and contributor notes
- `docs/coretext/rendering-pipeline.md` — content → pages flow
- `docs/coretext/vertical-writing.md` — vertical-rl layout rules
- `CONTRIBUTING.md` — conventions and PR process
