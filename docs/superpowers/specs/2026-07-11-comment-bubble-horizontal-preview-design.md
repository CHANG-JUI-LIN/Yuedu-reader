# Comment Bubble Horizontal Preview Design

## Goal

Change the comment-bubble style picker from a multi-column grid to a compact, single-row horizontal scroller.

## Design

- Keep the existing `ReaderCommentBubbleSettingsView` section and all selection behavior.
- Replace `LazyVGrid` with a horizontal `ScrollView` containing a `LazyHStack`.
- Hide the horizontal scroll indicator.
- Reduce the visible preview tile by one design-token size step.
- Preserve a minimum 44-point interactive area even though the visible card becomes smaller.
- Preserve the existing preview image, title, selected border, accessibility label, and selected trait.

## Scope

Only the comment-bubble style preview layout and its sizing token are changed. Import, export, editing, deletion, rendering, persistence, and localization behavior remain unchanged.

## Verification

- Parse the touched Swift files.
- Run `ruby scripts/check_localizations.rb`.
- Run `git diff --check`.
- Do not run a long `xcodebuild`; provide the targeted test command if stronger verification is wanted.
