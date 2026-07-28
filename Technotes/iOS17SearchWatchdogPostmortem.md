# iOS 17 Search Navigation Watchdog Postmortem

## Status

Resolved by `639175d Freeze search detail navigation state`.

Two original users who could reliably reproduce the issue confirmed the fix. The pre-fix Build 48 IPS reports covered iOS 17.0 and iOS 17.7.2 on different device generations.

## Symptom

On iOS 17, book-source search could freeze while displaying results or after selecting a result. Later iterations restored scrolling and selection animation, but navigation into the detail screen still stalled. iOS 18 and later did not reproduce the issue.

The final pre-fix IPS reports placed the main thread entirely in system UI frameworks:

- iOS 17.7.2: SwiftUI → AttributeGraph → `HostingScrollView` → UIKit layout.
- iOS 17.0: SwiftUI → trait propagation → scene activation state → UIKit layout.

These stacks identify the failing subsystem, not the originating app dependency. A report captured after app switching can show scene deactivation work that happened after the initial tap.

## Root Cause

The search navigation route previously carried only a result id. Its destination builder was an instance method on `BookSearchView` and resolved the full result by reading the live `SearchAggregator.results` array.

That kept the pushed detail hierarchy connected to the streaming search dependency graph. Navigation, trait, scene, or layout updates could re-evaluate the destination through its parent while the detail hierarchy was being created.

The detail hierarchy also accepted source-controlled introduction metadata. Some source rules return an entire HTML document as `intro`. The old path normalized that raw value from view-facing computed properties and used a vertically fixed-size `Text` inside the detail scroll view. This amplified iOS 17 layout work.

The failure was therefore a compound trigger:

1. A navigation destination retained a dependency on a live, repeatedly published result collection.
2. Destination creation crossed the iOS 17 UIKit table / SwiftUI navigation boundary.
3. Unbounded source metadata entered SwiftUI text measurement.
4. iOS 17's SwiftUI, AttributeGraph, and UIKit update implementation entered a stable failure mode that does not reproduce on later systems.

Apple has not published a note identifying this exact private-framework failure. Treat the OS explanation as a high-confidence inference from two symbolicated IPS reports, version-specific reproduction, and the verified fix.

## Final Design

### Frozen Navigation Snapshot

`SearchResultRoute<Snapshot>` carries both a stable id and the exact `SearchBook` snapshot selected by the user. Equality and hashing use only the id; destination data comes from the retained snapshot.

Do not replace this with an id-only route that re-reads `SearchAggregator`.

### Detached Destination

`SearchResultDestination` is a separate `View`. It receives only the route and required environment data. It must not capture `BookSearchView` or its `@StateObject SearchAggregator`.

### Bounded Detail Presentation

`OnlineBookDetailPresentationPolicy` bounds source-controlled introduction metadata before SwiftUI sees it:

- Raw normalization input: at most 32,000 characters.
- Final display introduction: at most 4,000 characters plus an ellipsis.

Search origin presentation precomputes `detailIntro`. Detail fetch results are sanitized before entering view state. `OnlineBookView` and `AudiobookDetailView` must not normalize raw HTML from `body`.

### iOS 17 Compatibility Renderer

iOS 17 search results remain in `IOS17SearchResultTable`, a native UIKit table backed by bounded value rows. iOS 18 and later use the SwiftUI list path.

Delete the UIKit renderer only when:

1. The deployment target is iOS 18 or later.
2. The item-based navigation branch is removed at the same time.
3. Search, selection, detail navigation, and large-intro sources have been regression tested.

## Investigation Timeline

Several earlier changes removed real costs but did not sever the final dependency:

1. Value-based navigation replaced eager per-row destination construction.
2. Search row presentation snapshots moved content inference and intro cleanup out of row bodies.
3. Result publication gating reduced streaming invalidations.
4. Cover URL and metadata bounds reduced untrusted input costs.
5. A UIKit result table restored stable iOS 17 scrolling.
6. Selection routing restored tap animation.
7. Stable detail identities reduced state replacement.
8. The final route snapshot, detached destination, and bounded detail intro removed the remaining freeze.

User feedback changing from "the whole search page freezes" to "scrolling works" to "tap animation works but detail does not open" was evidence that each earlier layer improved while a downstream navigation problem remained.

## Rejected Shortcuts

- Reducing search concurrency did not solve the issue.
- One enabled source could still reproduce it.
- Publication throttling alone did not solve detail navigation.
- UIKit rows alone did not solve the SwiftUI destination dependency.
- Stable `OnlineBook` ids alone did not detach the destination.
- Scene deactivation frames are not evidence that backgrounding caused the original bug.
- Do not add sleeps, delayed navigation, retries, or alternate destination loaders.

## Rejected Diagnoses

Three conclusions reached during the investigation were wrong. They are recorded
because each looked well supported at the time and can be re-derived from the
same evidence.

- **"Main thread CPU utilization was 16%, so it was waiting rather than
  computing."** A watchdog report dilutes utilization across its sampling
  window. The same report showed 9.74 CPU seconds against the 10-second
  scene-update budget, which is a saturated main thread. Compare CPU seconds to
  the time budget and disregard the percentage.

- **"The root cause is `BookSourceRuntimeStateStore.queue.sync` blocked by
  source JS writing UserDefaults."** This came from reading the leaf frames of a
  symbolicated stack, and a macOS bench produced supporting numbers (42.9 ms per
  layout pass under 12 concurrent writers). The leaf frame was a consequence of
  excessive body evaluation, not its cause. The store rewrite derived from this
  conclusion (`873f49c`) corrupted aggregate-source parsing and was reverted in
  `d03cf14`.

- **"iOS 17 specificity is disproved because 17.5 and 26.5 evaluate the same
  number of bodies."** A SwiftUI harness reported identical counts on both
  systems, but it omitted per-row `@ObservedObject`, result re-sorting, spring
  animation, `.searchable`, and the streaming progress publisher. A harness that
  does not reproduce the failing conditions is not a disproof. This conclusion
  steered the investigation away from version-specific behavior, which was the
  correct direction.

## Required Guardrails

When editing search or online detail presentation:

1. Freeze selected presentation data at the navigation boundary.
2. Do not resolve an active destination from a live collection owned by the source screen.
3. Keep destination builders independent from the parent feature model.
4. Bound and sanitize source-controlled strings before declarative UI layout.
5. Do not parse full-page HTML in row or detail `body` evaluation.
6. Avoid forcing full intrinsic height for unbounded text in a scroll container.
7. Preserve the route snapshot and bounded-intro tests in `IOS17SearchResultTableTests`.
8. Symbolicate new reports only with an archive/dSYM whose UUID matches the IPS slice.
9. Treat a system-only stack as the end of the causal chain; trace app data dependencies backward.
10. Require iOS 17 regression evidence before simplifying this compatibility path.
11. Any parent feature that embeds `SearchView` must use a heterogeneous `NavigationPath`; a
    typed parent path rejects `SearchResultRoute` and makes result taps fail on every iOS version.

## Relevant Files

- `Modules/Features/Search/BookSearchView.swift`
- `Modules/Features/Search/SearchResultRoute.swift`
- `Modules/Features/Explore/ExploreHomeView.swift`
- `Modules/Features/Explore/ExploreNavigationPath.swift`
- `Modules/Features/Search/IOS17SearchResultTable.swift`
- `Modules/Features/Search/SearchResultDetailIdentity.swift`
- `Modules/Services/Online/SearchAggregator.swift`
- `Modules/Services/Online/SearchResultPresentation.swift`
- `Modules/Services/Online/OnlineBookDetailPresentation.swift`
- `Modules/Features/BookDetail/OnlineBookView.swift`
- `Modules/Features/BookDetail/AudiobookDetailView.swift`
- `Tests/iOS/yuedu appTests/IOS17SearchResultTableTests.swift`
- `Tests/iOS/yuedu appTests/AudiobookDetectionTests.swift`

## Verification Evidence

Before commit:

- Swift parser checks passed for all changed Swift and test files.
- `git diff --check` passed.
- Localization validation passed for all three localization files (1510 keys).
- Lightweight route and presentation-policy contracts passed.
- Long-running `xcodebuild` was intentionally not run under repository instructions.

Production evidence:

- Both original reporters confirmed the final behavior was normal.
