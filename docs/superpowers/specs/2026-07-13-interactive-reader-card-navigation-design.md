# Interactive Reader Card Navigation Design

## Goal

Replace modal reader presentation with a unified navigation transition that opens a book as an expanding card and closes it interactively as the user swipes back. The swipe distance must directly control the card's closing progress, including position, size, corner radius, shadow, backdrop, and book-opening treatment.

The result should feel native because it uses a real navigation push/pop and an interruptible UIKit transition, while retaining the existing SwiftUI reader implementations.

## Product Requirements

- Opening a book pushes a reader destination instead of presenting `BookReaderView` with `fullScreenCover`.
- The opening transition begins from the selected book cover when source geometry is available.
- The reader card expands over the existing screen with a rightward/full-screen covering motion rather than the default navigation slide.
- The visual treatment may unfold the cover/pages during opening and folds them back during closing.
- A back swipe is recognized only when its initial touch is within 10 points of the leading screen edge.
- Swipe progress continuously controls transition progress; releasing may finish or cancel based on distance and velocity.
- Taps in the 10-point edge area continue to reach reader content when the touch does not become a back pan.
- Interactive back navigation is disabled in scrolling reading mode.
- The system navigation bar and back button remain hidden in the reader.
- Programmatic close actions use the same closing animation when a valid source target exists.
- Reading position persistence remains `(spineIndex, charOffset)` and is not coupled to transition progress.
- The initial scope covers text/reflowable EPUB reading. Fixed-page, manga, and audiobook readers keep their existing presentation until they are explicitly migrated.

## Chosen Architecture

Use a UIKit navigation and transition layer around the existing SwiftUI feature screens:

1. A shared `ReaderNavigationCoordinator` owns reader push/pop requests and the source-card metadata for the active book.
2. The app's SwiftUI navigation roots expose their underlying navigation controller to the coordinator without moving reader rendering into UIKit.
3. `BookReaderView` remains SwiftUI content, but the coordinator creates and directly pushes its `UIHostingController`. UIKit therefore owns the push from before it begins; a SwiftUI `navigationDestination` must not race the navigation delegate or silently substitute the default slide.
4. A `ReaderCardTransitionAnimator` implements `UIViewControllerAnimatedTransitioning` for open and close animations.
5. A `ReaderCardInteractionController` uses `UIPercentDrivenInteractiveTransition` to map the leading-edge pan to transition progress.
6. A dedicated `UIScreenEdgePanGestureRecognizer` is configured for the leading edge, with an additional 10-point start-location gate. It does not use an invisible SwiftUI overlay, so ordinary taps are not swallowed.

This is preferred over SwiftUI's built-in `.navigationTransition(.zoom)` because the public SwiftUI transition API does not expose a custom progress value that can drive a multi-part book-opening effect. It is preferred over a custom `fullScreenCover` gesture because UIKit navigation provides correct push/pop ownership, cancellation, appearance callbacks, and interactive-transition semantics.

## Navigation Ownership

### Unified entry point

All migrated open-book actions call one semantic operation:

```swift
readerNavigator.open(bookID:source:)
```

`source` contains stable identity plus a geometry provider, not a captured `CGRect`. Geometry is resolved immediately before the transition so bookshelf scrolling, rotation, and layout changes do not leave stale coordinates.

The first migration covers both bookshelf grid and list entries. Other entry points continue using their current presentation until a later migration, but they must be recorded as explicit follow-up sites:

- online book detail
- in-app browser import/open flow
- global now-playing entry
- audiobook detail

### Reader close

Existing close commands route through the navigator. If the reader is the top navigation destination, the coordinator pops it. If its source card is no longer visible, it uses a deterministic fallback close animation rather than trying to animate toward invalid geometry.

## Transition Model

The transition has one normalized value, `progress`, from `0` to `1`:

- `0`: closed card at source-cover geometry
- `1`: full-screen reader

Opening runs from `0` to `1`; interactive closing runs from `1` toward `0`. UIKit's interactive pop percentage is converted to the same model so every visual property is derived from one source of truth.

### Visual interpolation

At minimum, the animator interpolates:

- card frame: source cover/card frame to full-screen bounds
- corner radius: source card radius to zero
- shadow: shelf-card shadow to no outer shadow
- backdrop: transparent to the reader surface/background
- reader content opacity: delayed fade-in during the latter part of opening
- source cover opacity: hidden only while the transition snapshot represents it

The book-opening layer is isolated behind `ReaderBookOpeningEffect`. Its first implementation uses lightweight snapshot layers for the front cover, inside cover, page block, spine crease, and reader surface; it must not reparent the live CoreText or SwiftUI reader view. This keeps layout and reading state independent from animation.

The selected physical model is a single-cover 3D hinge, not a flat card rotation or a two-page spread:

- left-spine books hinge on the left edge and rotate the front cover outward in the negative Y direction;
- right-spine books mirror the same geometry around the right edge and rotate in the positive Y direction;
- the front cover lives outside the clipped page block, so it can visibly swing beyond the book bounds instead of being cut off;
- front and inside-cover faces remain visually distinct through the edge-on point;
- the page block expands from the physical spine while the whole book grows from the shelf cover to the full reader frame;
- a narrow spine crease and moving contact shadow preserve the hinge during slow drags;
- after the cover passes roughly 90 degrees, the reader snapshot progressively replaces the page block; near the final state the off-screen cover fades so the live reader can occupy the full display.

Closing evaluates the exact same geometry in reverse. An interactive pop therefore scrubs the cover angle, page-block width, crease, frame, corner radius, and reader reveal from one normalized progress value without switching animations.

The animation follows these phases, all driven by the same continuous progress:

1. `0.00...0.25`: lift the card, strengthen shadow, and begin horizontal expansion.
2. `0.15...0.70`: unfold the cover/page treatment and expand toward the destination frame.
3. `0.55...1.00`: reveal live reader content and remove card rounding/shadow.

These are mapping ranges, not separate queued animations, so reversing or cancelling the gesture remains visually continuous.

### Source unavailable fallback

If the source book is off-screen, deleted, filtered, or belongs to a non-migrated entry point, use a centered card-scale transition with the same corner-radius and backdrop behavior. Never force-scroll the shelf merely to recover the source.

## Gesture Rules

- Attach the edge-pan recognizer only while a migrated reader is the top navigation destination.
- Begin only when the first touch is within 10 points of the leading safe screen edge and horizontal intent is toward the trailing edge.
- Fail early for predominantly vertical movement.
- Set touch-cancellation behavior so a stationary touch or failed pan does not prevent link taps, text selection, reader tap zones, or toolbar controls.
- Disable the recognizer whenever `effectiveScrollMode` is true.
- Do not change page-turn recognizers outside the 10-point edge start zone.
- Finish when progress crosses the tuned completion threshold or release velocity clearly indicates closing; otherwise cancel and restore the reader.
- During an active interactive pop, temporarily suspend competing reader page-turn pans, then restore them on finish or cancellation.

Right-to-left publication page progression does not move the app-navigation edge. App-level back remains the leading screen edge according to interface layout direction; book page-turn direction continues to be handled by the reader engine.

## State and Lifecycle

- Opening the reader must not start duplicate load work if an interactive close is cancelled.
- A cancelled pop leaves the same `ReaderView`, engine, current position, TTS state, and overlays mounted.
- A completed pop triggers the existing close/persistence path exactly once.
- Source-card visibility is restored on both transition completion and cancellation.
- Rotation during an active interaction cancels safely, resolves new geometry, and leaves the reader open.
- Backgrounding during an active interaction cancels rather than committing a partially completed close.
- The transition coordinator holds no strong reference cycle among the navigation controller, hosting controller, source view, or animator.

## Compatibility

- Minimum deployment remains iOS 17.
- UIKit custom transitions provide the full behavior on iOS 17 and later.
- iOS 18 `matchedTransitionSource` may remain for unrelated system transitions but is not the driver of this feature.
- iPhone is the first supported form factor. On iPad, the reader keeps its current presentation until source/destination behavior is defined for regular-width and multi-column layouts.
- Accessibility Reduce Motion replaces unfolding and perspective effects with a short cross-fade/card-scale transition. Navigation and the edge gesture remain functional.

## Components

### `ReaderNavigationCoordinator`

Owns semantic open/close operations, active reader metadata, navigation-controller integration, source resolution, and mode-dependent gesture enablement.

### `ReaderTransitionSource`

Describes book identity, source view/geometry lookup, source corner radius, and optional cover snapshot. It does not own bookshelf state.

### `ReaderCardTransitionAnimator`

Builds interruptible UIKit property animations for push and pop. It is responsible only for transition visuals and cleanup.

### `ReaderCardInteractionController`

Translates edge-pan distance and velocity into `update`, `finish`, or `cancel` operations. It exposes no reader-domain state.

### `ReaderBookOpeningEffect`

Maps normalized progress to cover/page snapshot transforms. This component is replaceable so visual tuning does not disturb navigation correctness.

### SwiftUI bridge

Provides the reader destination factory, current scroll-mode state, and close action to the coordinator. The coordinator queues an open until the shelf navigation controller is attached, then directly performs the UIKit push. It must never publish a SwiftUI presentation flag first and attach the transition driver afterward.

## Error Handling and Cleanup

- If no navigation controller can be resolved, log a transition diagnostic and use the existing modal presentation temporarily rather than making open-book actions fail.
- If snapshot creation fails, continue with a plain card-frame transition.
- If source geometry becomes invalid mid-transition, finish using the fallback destination geometry.
- Always remove temporary snapshots, restore source visibility, and restore reader gesture states in a single idempotent cleanup path.
- Telemetry should distinguish open, interactive-close-finished, interactive-close-cancelled, fallback-transition, and transition-error events without recording book content.

## Testing Strategy

### Unit tests

- progress clamping and conversion between pop percentage and open-state progress
- completion/cancellation decisions across distance and velocity boundaries
- 10-point start-region acceptance and rejection
- scroll-mode gesture enablement policy
- phase interpolation for frame, radius, opacity, and book-opening values
- cleanup idempotence and source fallback selection

### Integration tests

- bookshelf grid and list entries push the correct `BookReaderView`
- reader close pops to the originating shelf state
- cancelled interactive pop preserves the same reader session and position
- completed pop persists position once
- source disappearance during reading uses fallback close
- tap zones, links, selection, and toolbar taps still work at the leading edge
- page-turn gestures outside the edge region remain unchanged
- switching to scroll mode disables interactive back immediately

### Manual verification

- slow drag, reverse drag, cancel, fast flick, and repeated open/close
- source book near every screen edge and partially visible
- bookshelf scrolled or filtered while the reader is open
- light/dark reader themes and custom backgrounds
- Reduce Motion, larger text, VoiceOver, and device rotation
- iOS 17 and the current iOS simulator/runtime

Per repository instructions, long `xcodebuild` runs are provided to the user rather than executed automatically.

## Delivery Sequence

1. Introduce navigation coordinator, transition contracts, and unit-tested progress math without changing presentation.
2. Migrate bookshelf grid/list open and close paths to real push/pop using a plain transition.
3. Add source geometry and the non-interactive card opening/closing animator.
4. Add the 10-point interactive edge-pop controller and cancellation behavior.
5. Connect scroll-mode gating and reader page-turn gesture arbitration.
6. Add and tune the replaceable book-opening visual effect.
7. Verify accessibility and fallbacks, then plan separate migrations for non-bookshelf entry points and iPad.

## Out of Scope

- Rewriting CoreText rendering or reader state management
- Changing reading-position identity
- Migrating fixed-page, manga, audiobook, browser, and online-detail presentation in the first delivery
- Reproducing another app's artwork or animation assets exactly
- Full 3D page simulation or physically accurate page curling
- Changing scroll-mode navigation behavior beyond disabling this edge-back gesture

## Acceptance Criteria

The first delivery is complete when a text/EPUB book opened from either bookshelf layout uses a real navigation push, visually expands from its book source as a card, and can be interactively closed from a 10-point leading-edge swipe whose progress continuously reverses the card animation. Cancelling restores the unchanged live reader; completing returns to the same shelf state and persists reading position exactly once. Taps remain functional, page turns outside the edge region remain unchanged, and scroll mode does not begin the back gesture.
