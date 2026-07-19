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
| `Resources/` | Resources only: `Assets.xcassets`, `*.lproj`, entitlements |

## Key Architecture

### Reader Pipeline

Two rendering modes, both backed by CoreText:

**Paged mode:** `EPUBPageRenderer` → `CoreTextPageEngine` → `UIPageViewController` → `CoreTextPageView` (each page drawn via `CTFrameDraw`)

**Scroll mode:** `EPUBPageRenderer` → `CoreTextScrollEngine` → `UICollectionView` (`CoreTextCollectionScrollViewController`) → `CoreTextChunkCollectionCell` (~2000pt chunks via `CoreTextChunkSlicer`)

EPUB HTML → `HTMLAttributedStringBuilder` → `NSAttributedString` → paginator → pages. A parallel path via `RenderableNode` IR exists for CSS-rich content. Both paths share CSS resolution through `ResolvedStyle` / `RenderStyle`.

### Online Reading Pipeline

`BookSourceFetcher.searchBooks()` → `AnalyzeUrl` (template URL construction) → `WebFetcher` (HTTP) → `ModernRuleEngine` (CSS/XPath/Regex/JSON extraction) → `OnlineReadingPipeline` (chapter fetch + content) → CoreText layout

### RSS Pipeline

Standard feeds: `RSSFetcher` → `RSSXMLParser` → `RSSStore`
Legado rule-based: `RSSFetcher` → `LegadoRSSScraper` (SwiftSoup + CSS rules) → `RSSStore`
Import/Export: OPML 2.0 and Legado JSON formats

## Critical Conventions

- **Reading position**: `(spineIndex, charOffset)`, never global page index. Pages shift when chapters load.
- **Localization**: Every user-facing string via `localized("Key")`. Keys must exist in all three `.lproj` files under `Resources/`: `zh-Hant`, `zh-Hans`, `en`.
- **Design tokens**: Use `DSColor`, `DSFont`, `DSSpacing` for all UI styling. Never hardcode colors or fonts.
- **UI design**: All views must follow `docs/design.md` (HIG-native, not web UI). Title rule: pushed pages with a nav title use `.toolbarTitleDisplayMode(.inlineLarge)`; modal sheets use `.inline` (never `.inlineLarge`/`.large`). The `yuedu-ios-design` skill enforces this when touching UI.
- **Dependency injection**: `AppDependencies` + `@Environment` for services. Singletons only for caches and shared managers.
- **CSS properties**: Adding to `ResolvedStyle` requires mirroring in `RenderStyle`, updating `RenderStyle.from`, and handling both rendering paths.
- **Vertical CJK**: Vertical writing uses right-to-left page flow. `String+VerticalNormalization` and `VerticalLayoutConfig` handle coordinate transforms. Run `CoreTextWritingModeTests` before touching vertical layout code.
- **SwiftUI previews**: Add `#Preview` when creating or changing view code.

## Engineering Discipline

This project is past "make it work" and into systems engineering. Locally-reasonable patches accumulate into duplicate paths, unowned state, and death-by-a-thousand-fallbacks. These rules override the default instinct to add a recovery layer:

- **Root cause before fallback.** An empty or failed result is a diagnostic signal, not a retry trigger. First distinguish "legitimately empty" from "parse/request failed", then fix the primary path. A fallback is justified only for genuinely external, unavoidable failures (site outage, anti-bot wall) — never to paper over a bug in our own code.
- **Every fallback must be documented and disclosed.** Precise trigger condition (not bare `if result.isEmpty`), a comment stating the real-world case it guards and the condition under which it can be deleted, and an explicit mention in your summary so the user can veto it. When editing near an existing fallback, check whether its reason still holds; if obsolete, propose deleting it.
- **No timing-based waits.** Never `Task.sleep` / `asyncAfter` "to let state settle" and retry. Await the actual signal (async value, callback, notification). A delay that fixes a race is hiding the race.
- **One path per concern.** Don't add a second cache, parser route, or loader where one exists. All online parsing goes through `BookSourceSession.session(for:)` (one reused JS bridge per source — bypassing it recreates the JSContext-per-call regression). When fixing a data-flow bug, enumerate every route that flow traverses (cache hit / network / fallback / pagination) and confirm the fix covers each, or state why not.
- **Views don't orchestrate.** A view calls one service-level use case; the service owns caching, concurrency, dedup, and degradation. No fetch→parse→cache→store chains inside SwiftUI code.
- **Measure, then optimize.** Performance claims need numbers. Instrument with `SourcePerfTrace` spans (⏱ lines, visible in Release Console; add a span if the stage isn't covered) and report before/after milliseconds. Never guess the bottleneck from reading code.
- **Don't swallow errors.** In parsing/network pipelines, `try?` that discards the error is banned unless an empty result is truly equivalent; log through `AppLogger` (never wrapped in `#if DEBUG` — os_log is how on-device issues get diagnosed).
- **Vague perf tasks get a contract first.** For "optimize X" requests, state the measurable goal, the constraints (no source-compat behavior change, no new cache layer, no wider WebView use), and the acceptance evidence before writing code.

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
