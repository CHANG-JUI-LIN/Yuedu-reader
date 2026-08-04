# Issue: Two Deterministic EPUBRenderingTests Failures on feature/browser-layout-engine

**Status:** NOT flaky — deterministic failures on this branch. Not caused by the browser-layout work; the branch base (`aefbf82`) predates the main-side fixes.

## Symptom

Running the `EPUBRenderingTests` class (class-level `-only-testing`) on
`feature/browser-layout-engine` fails exactly 2 of 57 tests, every time:

```
FAILED: longTableRasterPagesKeepEveryAuthoredRow()
  EPUBRenderingTests.swift:391: Expectation failed: (pages.count → 1) > 1
FAILED: chatBubbleWrapperKeepsAuthoredMarginsWithoutBlankParagraphs()
  EPUBRenderingTests.swift:1013: Expectation failed: (nameStyle.paragraphSpacingBefore → 21.0) <= 5.0
```

Verified identical at the Phase 1.5 tip (`0b46d28`, a temporary worktree run:
55 passed / 2 failed) and at HEAD — the failures are branch-wide, pre-existing,
and independent of all browser-layout code.

## Why it looked flaky

`xcodebuild ... -only-testing:"yuedu appTests/EPUBRenderingTests/<method>"` on
this environment executes **0 tests** (xcresult `totalTestCount: 0`) for these
two Swift-Testing methods, so "individual runs pass" was a vacuum. The tests
only run in class-level executions, where they fail deterministically. This
also makes bisection by method filter impossible on this machine.

## Root causes

1. **longTableRasterPagesKeepEveryAuthoredRow**
   `HTMLTableRasterizer.renderPages` (`Modules/Core/ReaderCore/CoreText/HTMLTableSupport.swift:822`)
   defaults `maxPageHeight` to `.greatestFiniteMagnitude`, so all 37 rows land
   on a single raster page. The reader always passes a real content height
   (that's why it works in-app); the test calls without it and expects > 1.
   The main branch's newer version presumably supplies a page budget in the
   test (see the `renderHeight` note in `NodeAttributedStringRenderer.Config`).

2. **chatBubbleWrapperKeepsAuthoredMarginsWithoutBlankParagraphs**
   The `.tk` div's `margin: 1em 1em` collapses to 21.0pt `paragraphSpacingBefore`
   instead of ≤ 5pt. This is the margin-collapse / blank-paragraph handling that
   `main`'s commit `9e84b80` / `197dc07` era work touched; the branch base
   `aefbf82` predates those fixes.

## Repro

Standalone repro class (run as a CLASS, method filters run 0 tests here):

```bash
xcodebuild -project "Yuedu-Reader.xcodeproj" -scheme "Yuedu-Reader" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:"yuedu appTests/Phase2BStaleLegacyReproTests" test
```

Both tests in the repro class fail with the same messages.

## Resolution path

- These are fixed by merging the newer `main` history (the branch is behind
  `main` by `9e84b80`, `197dc07`, …) — **do not fix on this branch**; the
  browser-layout work must not smuggle legacy-renderer changes.
- Tracked for Phase 2B acceptance as a documented pre-existing condition with
  a reproducible test, per the Phase 2B spec's fallback clause.
