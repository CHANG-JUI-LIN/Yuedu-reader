# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yuedu Reader — native iOS EPUB/TXT/RSS/web-novel reader. SwiftUI + CoreText, targeting iOS 17.0+, Swift 6.0, Xcode 16+. The reader renders via CoreText (not WebView) for precise pagination, CJK vertical writing, TTS sync, and text selection.

## Build & Test

Simulators on this machine are deleted and re-installed often, so **nothing in this repo hardcodes a device name, an OS version, or an Xcode path**. Resolve them at call time:

```bash
bash scripts/sim.sh doctor
```

`sim.sh` reads `simctl` and the installed Xcodes live. It picks the toolchain whose SDK can actually build to the installed runtimes, then the newest device on those runtimes (preferring Pro Max > Pro > plain), and prints a ready-made destination. Pass a name substring to steer the device (`sim.sh dest iPad`, `sim.sh dest "iPhone 17 Pro"`); `sim.sh list` shows what is buildable, `sim.sh xcodes` shows every toolchain. Re-run after any simulator or Xcode change — no file here needs editing.

```bash
# One toolchain + one destination for the whole session
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
SIM="$(bash scripts/sim.sh dest)"

# Build for simulator
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$SIM" build

# Run all unit tests
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$SIM"

# Run a single test class (no parallel — many tests depend on shared state)
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$SIM" -only-testing:'yuedu appTests/CoreTextWritingModeTests'

# Run a single test method
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "$SIM" -only-testing:'yuedu appTests/CoreTextWritingModeTests/testVerticalRTLPagination'
```

Use `-quiet` to suppress build output, but pair it with `-resultBundlePath` — `-quiet` swallows the failure messages. Tests are in `Tests/iOS/yuedu appTests/`. UI tests in `Tests/iOS-UI/`.

### Simulator gotchas

All of these were learned the hard way. The first three recur every time the simulator lineup or the installed Xcodes change — `sim.sh doctor` checks for all three at once.

- **`xcode-select` and the runtimes drift apart, and only the command line notices.** With a release Xcode and an Xcode-beta both installed, development happens in the beta (its GUI uses its own toolchain) while `xcode-select` still points at the release. `xcodebuild` then has an older SDK than every installed runtime and reports **no eligible simulator destination at all** — listing only ineligible *physical device* entries, with an error naming an OS version that is not the real problem. Nothing is missing and nothing needs downloading; the toolchain is just wrong. `sim.sh` picks the right one and announces it; `export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"` fixes it per-command without a password, and `sudo xcode-select -s …` fixes it permanently.
- **Never match a destination by name.** `-destination 'platform=iOS Simulator,name=…'` picks silently among matches, and there is no way to make it prefer the one you meant — renaming the device does *not* change the choice. Deleting a runtime leaves its devices behind as "unavailable" **under the same name as the live one**, so a stale iPhone 17 Pro Max can shadow the current iPhone 17 Pro Max indefinitely. Always resolve to `-destination "id=<UDID>"` via `sim.sh dest`.
- **A runtime newer than the active SDK boots but cannot be built to.** `simctl` reports it `isAvailable`, it launches fine, and only `xcodebuild` disagrees. `sim.sh` filters these out; `sim.sh doctor` lists them under "Bootable but NOT buildable". Reach for `xcodebuild -downloadPlatform iOS` only after confirming no installed Xcode already covers them.
- **Clear orphans after deleting a runtime.** `sim.sh doctor` reports devices stranded by a removed runtime and duplicate names across runtimes. `xcrun simctl delete unavailable` removes them (destructive — it also erases those devices' app data, so read the list first).
- **`RequestDenied` is CoreSimulator state, not configuration.** `xcodebuild test` can die in a retry loop on `FBSOpenApplicationServiceErrorDomain Code=1 RequestDenied` while launching the UI-test runner, before a single unit test executes — and then pass afterwards with no config change at all. `xcrun simctl shutdown all` (plus deleting stale `Clone N of …` devices) clears it. While diagnosing, ignore `IDELaunchParametersSnapshot: no debugger version`; it appears in passing runs too. `RequestDenied` is the only meaningful signal.

Do **not** pass `-derivedDataPath` to work around any of this — it abandons the incremental cache and rebuilds from scratch every run. `xcodebuild -showBuildSettings … | grep BUILT_PRODUCTS_DIR` resolves where the app actually landed.

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
- **Section Footers**: All section-level explanatory notes, hints, or limits must use native `Section { ... } footer: { Text(...) }` with `.dsSectionFooter()` (Apple HIG standard 13pt Footnote + `DSColor.textSecondary`), never placed as rows inside Section.
- **UI design**: All views must follow `docs/design.md` (HIG-native, not web UI). Title rule: only the four tab roots (`HomeView`, `ExploreHomeView`, `RSSListView`, `SettingsView`) use `.inlineLarge`, and only via `toolbarTitleDisplayModeInlineLargeOrInline()`; every pushed page and modal sheet uses `.inline` (never `.automatic`/`.large`/a bare `.inlineLarge`). The `yuedu-ios-design` skill enforces this when touching UI.
- **Accessibility**: A view isn't done until VoiceOver reads it correctly — this app has blind users, and every VoiceOver defect so far reached them because the label was never checked, not because it was hard. `docs/design.md` §7 is the checklist; §7.1 lists the SwiftUI traps that have already shipped bugs. The three that recur: accessibility modifiers on a **container** propagate to every child (label each `Button`, never the enclosing `HStack`); decorative `Image(systemName:)` is focusable and speaks its raw symbol name, so it needs `.accessibilityHidden(true)`; `Slider` has no label and announces a fraction of its range, so give it `.accessibilityLabel` + `.accessibilityValue` sharing the on-screen value's computed property.
- **Dependency injection**: `AppDependencies` + `@Environment` for services. Singletons only for caches and shared managers.
- **CSS properties**: Adding to `ResolvedStyle` requires mirroring in `RenderStyle`, updating `RenderStyle.from`, and handling both rendering paths.
- **Vertical CJK**: Vertical writing uses right-to-left page flow. `String+VerticalNormalization` and `VerticalLayoutConfig` handle coordinate transforms. Run `CoreTextWritingModeTests` before touching vertical layout code.
- **SwiftUI previews**: Add `#Preview` when creating or changing view code.

## Engineering Discipline

This project is past "make it work" and into systems engineering. Locally-reasonable patches accumulate into duplicate paths, unowned state, and death-by-a-thousand-fallbacks. These rules override the default instinct to add a recovery layer:

- **Root cause before fallback.** An empty or failed result is a diagnostic signal, not a retry trigger. First distinguish "legitimately empty" from "parse/request failed", then fix the primary path. A fallback is justified only for genuinely external, unavoidable failures (site outage, anti-bot wall) — never to paper over a bug in our own code.
- **Every fallback must be documented and disclosed.** Precise trigger condition (not bare `if result.isEmpty`), a comment stating the real-world case it guards and the condition under which it can be deleted, and an explicit mention in your summary so the user can veto it. When editing near an existing fallback, check whether its reason still holds; if obsolete, propose deleting it.
- **No timing-based waits.** Never `Task.sleep` / `asyncAfter` "to let state settle" and retry. Await the actual signal (async value, callback, notification). A delay that fixes a race is hiding the race.
- **Sequence iOS 17 menu-launched modals by dismissal.** On iOS 17, a SwiftUI `Menu` action can lose an immediate `.sheet`, `.fileImporter`, or photo-picker presentation while the menu's UIKit controller is still dismissing. Use the direct `DismissalSequencedActionChooser` compatibility entry and launch the destination only from its real `onDismiss`; keep the native `Menu` on iOS 18+. Do not restore an `asyncAfter` workaround. Read `Technotes/iOS17MenuModalPresentation.md` before adding or changing import actions inside a menu.
- **Do not nest the book-source importer under a sheet on iOS 17.** A direct empty-state import button also failed when `BookSourceListView` was already presented as a sheet, proving the problem is broader than menu dismissal. `BookSourceManagementPresentationPolicy` pushes book-source management from Settings and Explore on iOS 17 so its importers have a first-level presenter; iOS 18 keeps the sheet presentation. Preserve this ownership boundary until the deployment target reaches iOS 18.
- **One path per concern.** Don't add a second cache, parser route, or loader where one exists. All online parsing goes through `BookSourceSession.session(for:)` (one reused JS bridge per source — bypassing it recreates the JSContext-per-call regression). When fixing a data-flow bug, enumerate every route that flow traverses (cache hit / network / fallback / pagination) and confirm the fix covers each, or state why not.
- **Views don't orchestrate.** A view calls one service-level use case; the service owns caching, concurrency, dedup, and degradation. No fetch→parse→cache→store chains inside SwiftUI code.
- **Measure, then optimize.** Performance claims need numbers. Instrument with `SourcePerfTrace` spans (⏱ lines, visible in Release Console; add a span if the stage isn't covered) and report before/after milliseconds. Never guess the bottleneck from reading code.
- **Don't swallow errors.** In parsing/network pipelines, `try?` that discards the error is banned unless an empty result is truly equivalent; log through `AppLogger` (never wrapped in `#if DEBUG` — os_log is how on-device issues get diagnosed).
- **Vague perf tasks get a contract first.** For "optimize X" requests, state the measurable goal, the constraints (no source-compat behavior change, no new cache layer, no wider WebView use), and the acceptance evidence before writing code.
- **Freeze data at search navigation boundaries.** The iOS 17 search watchdog was resolved only after the selected `SearchBook` snapshot moved into the route and the destination stopped reading live `SearchAggregator.results`. Never regress to an id-only route that re-resolves from the source screen. Keep source-controlled detail text bounded and sanitized before SwiftUI layout. Read `Technotes/iOS17SearchWatchdogPostmortem.md` before changing search result rendering, routing, or online detail intro presentation.

## Dependencies

Detailed package versions and their transitive dependencies are recorded in [Dependencies.md](file:///Users/zhangruilin/Desktop/Yuedu-reader/Technotes/Dependencies.md).

- **Readium** (BSD) — EPUB parsing (ReadiumShared, ReadiumStreamer, ReadiumZIPFoundation, ReadiumFuzi)
- **SwiftSoup** (MIT) — HTML parsing for RSS and rule engine
- **GoogleSignIn** (Apache 2.0) — Optional Google sign-in
- **CryptoSwift**, **SQLite.swift**, **Zip**, **DifferenceKit**, **GCDWebServer**


## Key Documentation

- `Technotes/Architecture.md` — full architecture
- `Technotes/iOS17SearchWatchdogPostmortem.md` — verified iOS 17 search freeze root cause, failed approaches, and non-regression guardrails
- `Technotes/iOS17MenuModalPresentation.md` — iOS 17 menu-to-sheet/importer presentation race and compatibility contract
- `docs/coretext/README.md` — CoreText code map and contributor notes
- `docs/coretext/rendering-pipeline.md` — content → pages flow
- `docs/coretext/vertical-writing.md` — vertical-rl layout rules
- `CONTRIBUTING.md` — conventions and PR process
