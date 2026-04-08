# CoreText Stable Reading Position Design

## Summary

The CoreText reader currently treats `globalPage` as a stable identity for navigation and UI refresh. That assumption is false. Global page numbers are recalculated whenever chapter layouts are loaded or evicted, because unloaded chapters are temporarily estimated as one page each. As a result, the same integer page value can point to different content over time.

This design makes `(spineIndex, charOffset)` the stable reading position for the CoreText path. `globalPage` remains a derived value for presentation, animation, and compatibility with existing UI, but it is no longer the source of truth for navigation recovery.

## Problem

Two user-visible failures share the same root cause:

1. Opening or reading from the middle of a book can show the wrong content after more chapters load.
2. Going to the previous page at a chapter boundary can land on an estimated page instead of the true previous page.

Current behavior that causes this:

- `CoreTextPageEngine.rebuildPageOffsets()` assigns `1` page to every unloaded chapter.
- `CoreTextPageEngine.localPosition(for:)` resolves a `globalPage` using those shifting offsets.
- `CoreTextPageEngineView` refreshes visible UI using the previous `currentPage` integer after `.coreTextEngineChapterReady`.
- `ReaderView.Coordinator.pageViewControllerBefore` falls back to `globalPageIndex - 1` when the previous chapter is not loaded.

These are individually reasonable shortcuts, but together they make page identity unstable.

## Goals

- Keep visible reading content stable when chapter offsets are recomputed.
- Guarantee that cross-chapter backward navigation resolves to the true last page of the previous chapter.
- Preserve current save/restore semantics based on `CharOffsetStore`.
- Minimize changes outside the CoreText reader path.

## Non-Goals

- Replacing all `globalPage` usage in the app in this iteration.
- Changing the pagination algorithm itself.
- Redesigning bookmark, TTS, or progress models beyond what is necessary to keep navigation correct.

## Proposed Design

### 1. Introduce a stable CoreText reading position

Add a lightweight value type in the CoreText path:

- `ReadingPosition`
  - `spineIndex: Int`
  - `charOffset: Int`

This becomes the source of truth for the current visible location in the CoreText page controller layer.

### 2. Treat `globalPage` as derived, not authoritative

`globalPage` continues to exist because the current UI and animations depend on it, but its role changes:

- It is derived from `ReadingPosition` plus the latest loaded layouts.
- It may change when offsets are rebuilt.
- It is never trusted as the only identifier for “what page the user is on.”

### 3. Track the visible position in `CoreTextPageEngineView.Coordinator`

The coordinator will hold the last known stable position for the visible page.

Behavior:

- On initial setup, resolve the initial `globalPage` to `(spineIndex, charOffset)` and store it.
- After every successful page turn, update the stored `ReadingPosition` first, then update the bound `currentPage`.
- When `.coreTextEngineChapterReady` fires, re-resolve the visible target from the stored `ReadingPosition`, not from the old `currentPage` integer.

This ensures UI reloads remain attached to the same content even if offsets shifted.

### 4. Fix cross-chapter backward navigation

When `viewControllerBefore` is called for the first local page of a chapter:

- If the previous chapter is already loaded, navigate to `lastPageIndex(ofChapter:)`.
- If the previous chapter is not loaded, trigger preload and only resolve the target from the previous chapter’s real layout.
- Do not fall back to `globalPageIndex - 1` across chapter boundaries.

Within a loaded chapter, `globalPage - 1` remains acceptable because local page identity is stable inside a single layout.

### 5. Keep persistence behavior aligned with the stable model

`EPUBPageRenderer` already caches `savedSpineIndex` and `savedCharOffset` at page-turn time. This design keeps that model and aligns UI navigation with it, instead of adding a second competing truth.

### 6. Keep scope local to CoreText navigation

This iteration touches:

- `CoreTextPageEngine`
- `PageRenderingProvider`
- `CoreTextPageEngineView.Coordinator`
- Tests for offset remapping and cross-chapter previous-page behavior

This iteration does not rework the rest of `ReaderView` beyond what is required to keep its bound page index synchronized with the stable position.

## Data Flow

### Current

1. UI stores `currentPage`.
2. Engine loads or evicts chapters.
3. Offsets are rebuilt.
4. UI reuses the old `currentPage`.
5. The same integer may now resolve to different content.

### Proposed

1. UI stores `ReadingPosition`.
2. Engine loads or evicts chapters.
3. Offsets are rebuilt.
4. UI maps `ReadingPosition` back to the latest `globalPage`.
5. UI redraws the same content, even if the derived page number changed.

## Error Handling

- If a stored `charOffset` exceeds the loaded chapter length, clamp it to the chapter’s valid range before mapping to a page.
- If a cross-chapter previous-page request targets an unloaded chapter, show the existing placeholder only as a temporary loading state; final landing must come from the actual previous chapter layout.
- If a target chapter fails to preload, preserve current page rather than jumping to an estimated page.

## Testing Strategy

Add focused tests before implementation:

1. Offset remap stability
   - Given a visible `(spineIndex, charOffset)`, when additional chapters load and `spinePageOffsets` change, remapping still lands on the same chapter and character range.

2. Cross-chapter previous-page correctness
   - Given the first page of a loaded chapter and an unloaded previous chapter, backward navigation resolves to the true last page of the previous chapter after preload, not an estimated `globalPage - 1`.

3. Notification-driven refresh stability
   - When `.coreTextEngineChapterReady` triggers while the reader is visible, the refreshed page corresponds to the same stable reading position.

## Rollout

Implement in this order:

1. Add failing tests for stable remapping and chapter-boundary backward navigation.
2. Add `ReadingPosition` and expose the minimal mapping helpers needed by the coordinator.
3. Update coordinator state and notification refresh logic.
4. Remove the cross-chapter `globalPageIndex - 1` fallback.
5. Verify existing progress save/restore behavior still passes.

## Risks

- `ReaderView` currently assumes `currentPage` is the live identity of the visible content. The implementation must keep bound page values synchronized to avoid regressions in progress UI.
- Cover animation code also consumes `currentPage` and snapshots. It must use the derived page that corresponds to the current stable position.
- Because `ReaderView.swift` already has local uncommitted changes, implementation work must merge carefully instead of overwriting the file.

## Success Criteria

- Loading or evicting neighboring chapters does not change the visible content unexpectedly.
- Starting from the middle of a book no longer causes content disorder when more chapters become available.
- Previous-page navigation at chapter boundaries always lands on the true previous page.
- Save/restore still uses stable `(spineIndex, charOffset)` progress.
