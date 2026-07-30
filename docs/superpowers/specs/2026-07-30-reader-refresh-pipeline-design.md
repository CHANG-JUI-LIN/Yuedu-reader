# Reader Refresh Pipeline Refactor

## Context

Reader refresh behavior is currently coordinated across `ReaderConfig`,
`ReaderView`, `EPUBPageRenderer`, the paged and scroll engines, and their UIKit
hosts. A caller must know whether a change requires `invalidateLayout`,
`notifyChapterDataChanged`, `invalidateChapterDocument`, `reslice`, a SwiftUI
token change, or a visible-controller replacement.

That interface is nearly as complex as its implementation. It has caused
settings to update without immediately replacing visible content:

- scroll mode originally missed chapter refreshes;
- scroll-mode bold changes lagged behind font-size changes;
- custom reader-font changes were routed only to the paged engine;
- manual refresh loading state could finish before the visible scroll content
  was replaced.

The current architecture also constructs `ReaderRenderSettings` through two
separate functions, one for paged mode and one for scroll mode. Their geometry
and appearance rules have already diverged.

## Scope

This refactor covers the path from reader setting or chapter-content changes to
the visible paged page or scroll chunk replacement.

It includes:

- layout, appearance, chapter-content, and mode-activation refreshes;
- paged and scroll engine routing;
- chapter document invalidation;
- latest-wins cancellation;
- stable reading-position restoration;
- refresh completion and failure reporting;
- a single render-settings snapshot builder;
- chapter-title style refresh coverage.

It does not:

- split the complete `ReaderView`;
- change online fetch or parsing behavior;
- introduce another cache or retry path;
- override publisher-authored EPUB heading CSS with every app-defined
  chapter-title option;
- change the visual design of reader settings.

## Architectural Decision

`EPUBPageRenderer` becomes the single deep Module that owns reader refresh
coordination. It already owns the paged engine, scroll engine, and shared
`ChapterDocumentStore`, so this deepens an existing Module instead of adding a
one-adapter seam.

Callers submit one refresh request:

```swift
await epubRenderer.refresh(request)
```

The interface hides:

- which engine must rebuild;
- which document or layout cache must be invalidated;
- how the active reading position is restored;
- how overlapping work is cancelled;
- when the visible output has actually been replaced.

`ReaderView` remains responsible for translating UI events into refresh intent
and displaying the returned completion or failure state. It no longer
orchestrates engine methods.

## Refresh Requests

The refresh request is a value carrying:

- the refresh intent;
- the active reading mode;
- the latest immutable `ReaderRenderSettings`;
- the stable position `(spineIndex, charOffset)`;
- the target viewport geometry when layout size changed;
- a chapter index for chapter-content changes.

The renderer assigns the monotonically increasing transaction identifier.
Callers do not generate or compare transaction identifiers.

The supported intents are:

### Layout

Used for any change that can alter line breaks, page ranges, chunk ranges, or
title geometry:

- reader font and font size;
- bold;
- line height, letter spacing, and paragraph spacing;
- page and footer spacing;
- writing mode and spread geometry;
- chapter-title style;
- render-affecting decorations.

The active engine rebuilds. The inactive engine records the new settings
revision and rebuilds only if later activated, preventing both stale
mode-switch output and unnecessary duplicate pagination.

### Appearance

Used for changes that do not alter text geometry:

- theme;
- text and background colors;
- reader background image when it can be applied without reflow.

If a supposedly appearance-only change affects document output or geometry, it
must be promoted to a layout request rather than adding a hidden secondary
path.

### Chapter Content

Used after an online chapter becomes ready, a manual chapter refresh completes,
or cached chapter content is explicitly replaced.

The renderer invalidates the target chapter in the shared
`ChapterDocumentStore`, rebuilds that chapter in the active engine, and restores
the supplied stable position. Inactive-engine derived layouts are marked
stale, but the underlying content invalidation occurs exactly once.

### Mode Activation

Used when entering paged or scroll mode. The renderer compares the target
engine's applied settings/content revisions with the current revisions. It
rebuilds only when stale, then restores the stable position.

## Render Settings Snapshot

The current `currentRenderSettings` and `buildRenderSettings` implementations
are replaced by one snapshot builder with an explicit paged-or-scroll geometry
input.

The builder owns the rules for:

- effective text and background appearance;
- body font, bold, and font metrics;
- margins and safe-area reservations;
- paged overlay reservations;
- scroll footer reservations;
- writing mode;
- chapter-title style;
- reader background image;
- dialogue and decoration settings.

Mode differences remain explicit data, not separate implementations. Every
refresh request and initial engine load uses this same builder.

## Transaction Lifecycle

Each refresh is a transaction with one terminal result:

- `completed`;
- `superseded`;
- `failed(error)`.

The renderer keeps the current render revision and transaction identifier.

1. The request captures the latest settings and stable position.
2. Settings and content revisions are recorded before asynchronous work begins.
3. The renderer cancels obsolete render work.
4. The active engine rebuilds using the captured revisions.
5. The engine commits its new layout or chunks.
6. The active UIKit host replaces its visible page or reloads its chunks and
   restores the stable position.
7. Only then does the transaction complete.

No loading state may be cleared merely because a setting value changed or an
engine task started.

## Concurrency Rules

- Repeated layout and appearance requests are latest-wins.
- A superseded transaction cannot complete or clear state owned by a newer
  transaction.
- Chapter-content invalidation is recorded before cancellable layout work, so a
  later settings request cannot lose newly fetched content.
- A later transaction rebuilds with both the latest content revision and latest
  settings revision.
- No delay, automatic retry, or alternate loader is introduced.
- Paged and scroll engines keep their existing internal generation guards; the
  renderer transaction is the cross-engine owner.

## Visible Output Completion

Engine readiness and visible-output replacement are separate facts. The
completion contract requires both.

The existing paged and scroll UIKit hosts are the two adapters at a private
visible-commit seam. Engine refresh events carry the renderer-assigned
transaction identifier. Each host acknowledges that identifier only after it
has applied the replacement. `ReaderView` does not participate in this seam.

Paged mode completes after:

- the relevant chapter layout has been rebuilt;
- the current stable position resolves against the new layout;
- the page host has replaced its visible view controller.

Scroll mode completes after:

- the relevant chapter document has been rebuilt when required;
- the current chapter has been resliced;
- the collection host has consumed the reset event, reloaded chunks, and
  restored the stable offset.

The existing `scrollResliceToken`, scattered `onResliceCompleted` callbacks,
and caller-owned completion clearing are removed once their responsibilities
are covered by the transaction.

## Failure Handling

Layout or appearance failure preserves the previous visible content and
returns `failed(error)`.

Chapter-content failure preserves the chapter load failure state and existing
manual retry interface. It does not automatically retry.

A mode-activation failure does not silently show a stale target mode. It
returns an explicit failure so the existing reader failure surface can remain
visible.

Cancellation caused by a newer request returns `superseded`, not `failed`.

## Chapter Title Style Coverage

`ChapterTitleStyle` is carried as one value in `ReaderRenderSettings`. A change
to any of its fourteen fields changes the settings revision:

1. `visible`
2. `size`
3. `topSpacing`
4. `bottomSpacing`
5. `weight`
6. `alignment`
7. `followsBodyFont`
8. `splitEnabled`
9. `numberRelativeSize`
10. `numberFontPostScript`
11. `nameFontPostScript`
12. `advancedCSSEnabled`
13. `lightTemplate`
14. `darkTemplate`

Direct edits, built-in or custom preset application, file import, and restoring
the official default all reach the same settings-change path. Deleting a font
that is referenced by `numberFontPostScript` or `nameFontPostScript` clears
those references as part of the deletion mutation, producing a new settings
snapshot. UI actions no longer pair a state write with a manual
`refresh.send()` call.

Rendering support remains format-aware:

| Path | Supported behavior |
| --- | --- |
| TXT and online plain title | Full plain-style fields |
| Advanced CSS title | Visibility, size, outer spacing, and light/dark templates; template CSS owns weight, alignment, and decoration |
| EPUB authored heading | Visibility, size, top spacing, and body spacing; publisher CSS continues to own the other heading styles |

This refactor guarantees immediate refresh for every field in the paths where
that field is meaningful. It does not expand app styling to override EPUB
authored CSS.

## Migration Sequence

1. Add tests for refresh routing, transaction completion, cancellation, and
   settings identity before changing production behavior.
2. Consolidate render-settings snapshot construction.
3. Add the renderer-owned refresh transaction interface.
4. Route layout and appearance refreshes through it.
5. Route chapter-content and manual refreshes through it.
6. Route mode activation through it.
7. Replace scroll token and scattered completion callbacks.
8. Remove obsolete manual `refresh.send()` calls and duplicate observers.
9. Run the complete relevant regression set and app build.

Each migration step keeps paged and scroll reading functional. Old paths are
removed when their responsibility moves; they are not retained as fallbacks.

## Test Strategy

### Render Settings

- One snapshot builder serves paged and scroll modes.
- Explicit geometry inputs produce the intended mode-specific insets.
- Each of the fourteen chapter-title fields changes settings identity.
- Preset, import, reset, and referenced-font deletion produce a new snapshot.

### Renderer Transactions

- Layout requests route to the active engine.
- The inactive engine is marked stale and refreshes on activation.
- Appearance requests do not reflow when geometry is unchanged.
- Chapter-content requests invalidate exactly one chapter document.
- Rapid requests complete only the newest transaction.
- A content revision survives a superseding layout request.
- Failures preserve old visible output.

### Paged Integration

- Font size, bold, custom reader font, and chapter-title changes rebuild and
  replace the visible page.
- Chapter refresh rebuilds the target document and visible page.
- Stable `(spineIndex, charOffset)` survives re-pagination.
- Switching from scroll to paged mode never displays the prior settings
  revision.

### Scroll Integration

- The same setting changes rebuild and replace visible chunks.
- Chapter refresh rebuilds the target document before reslicing.
- Collection reset occurs once per committed transaction.
- Stable `(spineIndex, charOffset)` survives reslicing.
- Switching from paged to scroll mode never displays the prior settings
  revision.

### Existing Regression Suites

Run the related test classes without parallel execution:

- `ChapterDocumentStoreTests`
- `CoreTextScrollTests`
- `CoreTextScrollOnlineCacheTests`
- `UserFontSettingsTests`
- `ChapterTitleAttributedBuilderTests`
- `OnlineChapterTitleDeduplicatorTests`
- `OnlineReaderPipelineUnificationTests`
- reader session, navigation, and chapter presentation tests touched by the
  final diff

Then run the application build. Any additional related suite exposed by the
final dependency diff is added to the regression run.

## Acceptance Criteria

- Every reader layout setting immediately replaces visible content in both
  paged and scroll modes.
- Manual chapter refresh keeps loading state until visible replacement
  completes or fails.
- No stale settings appear after switching reading modes.
- Reading position remains stable across every refresh type.
- Overlapping refreshes are deterministic and latest-wins.
- `ReaderView` no longer calls paged/scroll invalidation or reslicing methods
  directly for refresh orchestration.
- There is one render-settings snapshot builder.
- No token, delay, retry, or alternate cache masks a failed primary path.
- All specified regressions and the app build pass.
