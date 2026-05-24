# Yuedu Reader CoreText Refactor Roadmap

## Baseline

- Baseline commit: `45a5bdb Refactor reader navigation and curl paging`
- Scope through P2: preserve existing SwiftUI/CoreText reader behavior while moving reader state, navigation, and engine contracts onto explicit seams.
- Current completed foundation at baseline: `ReaderNavigator`, `ReaderPresentationState`, curl double-sided paging, WeChat theme, and focused transition tests.

## Required Local Gates

Run these before committing any phase:

```bash
git diff --check
xcodebuild build -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -configuration Debug
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:"yuedu appTests/ReaderPresentationContractTests" -only-testing:"yuedu appTests/ReaderEngineContractTests" -only-testing:"yuedu appTests/ProgrammaticPageTransitionPerformerTests" -only-testing:"yuedu appTests/ReaderPageTransitionQueueTests" -only-testing:"yuedu appTests/CoreTextCFIProgressTests"
find iOS -name Localizable.strings -print0 | xargs -0 plutil -lint
```

## P0: Baseline and Gates

- Add this roadmap as the phase tracker and command source of truth.
- Add minimal GitHub Actions coverage for build, focused CoreText/transition tests, localization plist lint, and whitespace checks.
- Keep formatter/linter rewrites out of P0 so gates do not create broad formatting churn.

## P1: ReaderSessionCoordinator

- `ReaderSessionCoordinator` owns the live `ReaderNavigator`.
- Position-changing actions are routed as `ReaderAction` values and return explicit `ReaderEffect` values.
- Programmatic page-transition queueing is owned by `ReaderSessionCoordinator`; the SwiftUI/UIPageViewController bridge requests transitions through coordinator effects.
- `ReaderView` remains the SwiftUI host for menus, sheets, controls, and concrete view-controller presentation.

## P2: Capability-Based Engine Contracts

- `PageRenderingProvider` is now the paged composite alias:
  - `LayoutLifecycle`
  - `StablePositionResolving`
  - `ProgressResolving`
  - `InternalLinkResolving`
  - `ThemeUpdatable`
  - `AnnotationApplying`
  - `SnapshotRenderable`
  - `PageViewControllerVending`
- `PagedReaderEngine` and `ScrollReaderEngine` make caller requirements explicit at compile time.
- Unsafe `PageLayoutEngine` default `nil/no-op` fallbacks have been removed; engine-specific unsupported behavior must now be explicit on that engine.
- Snapshot generation remains an optional capability with a safe default fallback.

## Deferred Phases

- P3 splits `CoreTextPageEngine` into services.
- P4 consolidates HTML rendering behind the renderable-node path.
- P5 adds a resource repository and render scheduler.
- P6 adds paged/scroll parity for positions and annotations.
- P7 adds structured errors, resource/navigation policy, and accessibility coverage.
- P8 expands CI, performance baselines, and release hardening.
