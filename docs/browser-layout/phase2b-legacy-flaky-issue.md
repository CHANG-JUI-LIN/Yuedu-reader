# Issue: Two Deterministic EPUBRenderingTests Failures (Resolved on feature/browser-layout-engine)

**Status:** RESOLVED on `feature/browser-layout-engine`. Both failures were real
legacy-renderer defects — NOT fixed on `main` (verified after merging latest
main: the same 2 of 57 still failed post-merge, and the tests/implementation
files were byte-identical to `main`).

## Symptom

Running the `EPUBRenderingTests` class (class-level `-only-testing`) on
`feature/browser-layout-engine` failed exactly 2 of 57 tests, every time:

```
FAILED: longTableRasterPagesKeepEveryAuthoredRow()
  EPUBRenderingTests.swift:391: Expectation failed: (pages.count → 1) > 1
FAILED: chatBubbleWrapperKeepsAuthoredMarginsWithoutBlankParagraphs()
  EPUBRenderingTests.swift:1013: Expectation failed: (nameStyle.paragraphSpacingBefore → 21.0) <= 5.0
```

## Why it looked flaky / "already fixed on main"

- `xcodebuild ... -only-testing:"yuedu appTests/EPUBRenderingTests/<method>"` on
  this environment executes **0 tests** (xcresult `totalTestCount: 0`) for these
  Swift-Testing methods, so "individual runs pass" was a vacuum. The tests only
  run in class-level executions, where they fail deterministically.
- The earlier hypothesis that `main` had fixed them was **wrong**: after merging
  latest `main` (`e84f4e7`), both tests still failed. `git diff` showed
  `HTMLTableSupport.swift` and `EPUBRenderingTests.swift` identical between
  `main` and the branch, and the tests were introduced by `34aff04` which IS an
  ancestor of `main` — they never passed on `main` either.

## Root causes & fixes (both on this branch, `e84f4e7` + 1)

1. **longTableRasterPagesKeepEveryAuthoredRow**
   `HTMLTableRasterizer.renderPages` (`Modules/Core/ReaderCore/CoreText/HTMLTableSupport.swift:822`)
   defaults `maxPageHeight` to `.greatestFiniteMagnitude`, so all 37 rows land
   on a single raster page. The reader always passes a real content height
   (`config.renderHeight`, see `NodeAttributedStringRenderer.swift:1474`); the
   test omitted it and expected > 1 page. **Fix:** the test now passes
   `maxPageHeight: 200` to exercise the pagination path it is named for.

2. **chatBubbleWrapperKeepsAuthoredMarginsWithoutBlankParagraphs**
   Root cause: `HTMLStyledASTRenderableNodeConverter.convert` flattens `body`
   children into top-level nodes, so `renderBlock`'s per-block
   `collapseAdjacentParagraphSpacing` only ever saw a single block's own
   children. The `.tk` div's `margin: 1em 1em` was reserved (by
   `reserveContainerInsets`) into its first child's `paragraphSpacingBefore`
   (17.5pt margin + 4.5pt padding/border = 21pt) and never collapsed against the
   preceding narration paragraph. **Fix:** `NodeAttributedStringRenderer.render`
   now runs one whole-chapter `collapseAdjacentParagraphSpacing(...,
   honorStructuralInsets: true)` after the per-block passes (gated off for
   vertical writing mode). Structural insets (padding+border) are preserved so
   box borders never overlap neighbouring lines.

## Repro

Standalone repro class `Phase2BStaleLegacyReproTests` (run as a CLASS):

```bash
xcodebuild -project "Yuedu-Reader.xcodeproj" -scheme "Yuedu-Reader" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  -only-testing:"yuedu appTests/Phase2BStaleLegacyReproTests" test
```

## Resolution

Both tests pass on this branch; full `EPUBRenderingTests` (57/57),
`CoreTextPipelineTests`, `EPUBPipelineParityTests`, and
`CoreTextWritingModeTests` (23/23) all green. This clears the Phase 3
precondition that the full legacy suite is green before starting Phase 3A/3B.
