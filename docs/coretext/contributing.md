# Contributing to CoreText Reader Code

## Before Editing

1. Identify the path: EPUB, TXT, online HTML, or scroll chunks.
2. Check whether the change affects both HTML paths:
   `HTMLAttributedStringBuilder` and `NodeAttributedStringRenderer`.
3. Check whether vertical writing needs a separate coordinate conversion.
4. Add or update focused tests before broad refactors.

## Common Change Checklist

| Change | Also check |
| --- | --- |
| CSS property | `CSSPropertyApplier`, `ResolvedStyle`, `RenderStyle`, both renderers |
| Layout metric | `CoreTextPaginator.CacheKey`, page ranges, snapshot rendering |
| Inline image | `RunDelegateProvider`, image extraction, image tap metadata |
| Vertical punctuation | `String+VerticalNormalization`, `VerticalLayoutConfig`, writing-mode tests |
| Link behavior | `CoreTextPageView`, `CoreTextPageEngine.resolveInternalLink`, reader navigation callback |
| Selection/underline | `TextSelectionManager`, `InteractionOverlayView`, page and chunk geometry |
| Bookmark/position | `CoreTextReadingPosition`, `ReaderView`, `CharOffsetStore` |

## Test Commands

Focused vertical layout and interaction:

> Resolve the simulator instead of naming one: `-destination "$(bash scripts/sim.sh dest)"`.
> This machine's simulators are deleted and re-installed often, and name matching picks
> silently among duplicates. `bash scripts/sim.sh doctor` diagnoses a broken lineup.

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination "$(bash scripts/sim.sh dest)" \
  -only-testing:'yuedu appTests/CoreTextWritingModeTests' \
  -parallel-testing-enabled NO
```

CoreText pipeline regressions:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination "$(bash scripts/sim.sh dest)" \
  -only-testing:'yuedu appTests/CoreTextPipelineTests' \
  -parallel-testing-enabled NO
```

Run `git diff --check` before committing.
