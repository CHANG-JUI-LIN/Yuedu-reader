# iOS 17 Menu-to-Modal Presentation Compatibility

## Symptom

On iOS 17.7, tapping an import action can leave the current screen unchanged
without presenting the requested sheet, document picker, or photo picker.
There are three presentation boundaries:

1. A SwiftUI `Menu` can still be dismissing when its action requests a modal.
2. Book-source management was itself a sheet and tried to present its import
   UI as a nested sheet.
3. Reader settings was itself a sheet and tried to present its font document
   picker from that nested presenter.

The empty-book-source button is a direct `Button`, not a `Menu`, and it also
failed. That evidence disproved the original menu-only diagnosis.

## Root Cause

SwiftUI implements both menus and sheets through UIKit presentation
controllers. On iOS 17, the active presenter can remain occupied or be resolved
incorrectly across these boundaries. The next binding still changes, but the
requested presentation can be dropped:

- while the menu's private controller is dismissing; or
- while book-source management is already the presented sheet and asks SwiftUI
  to find a presenter for a second sheet; or
- while reader settings asks its already-presented sheet host to resolve the
  document picker's presenter.

iOS 18 changed menu dismissal and gesture behavior, so the native menu path is
retained there.

## Compatibility Contract

`MenuModalPresentationPolicy` selects the compatibility path only before iOS
18. A direct button presents `DismissalSequencedActionChooser`; the chosen route
is retained in `DismissalSequencedPresentation`, and the real destination is
presented only from the chooser sheet's `onDismiss` callback.

`BookSourceManagementPresentationPolicy` separately pushes book-source
management from Settings and Explore on iOS 17. Its import, add, edit, login,
and validation destinations therefore become first-level presentations. iOS
18 retains the original book-source management sheet.

`ReaderSettingsPresentationPolicy` dismisses reader settings before font
import on iOS 17. `ReaderView` retains the pending font-import route and opens
the document picker only from the settings sheet's real `onDismiss` callback,
so the picker is owned by the reader's first-level presenter. iOS 18 keeps the
font importer inside reader settings.

Both sequenced flows use an event boundary, not a guessed duration:

1. Store the selected route.
2. Dismiss the current menu chooser or reader-settings sheet.
3. Consume and present the route from that presenter's `onDismiss`.

Never replace this sequence with `DispatchQueue.main.asyncAfter`, `Task.sleep`,
or a retry. Timing values vary by device, accessibility settings, animation
state, and OS patch version.

## Coverage

The compatibility path covers menu-launched imports in:

- Book sources: local and network import
- Bookshelf: local files, WebDAV, and OPDS
- RSS: source/folder creation, OPML, and JSON
- TTS sources: local and network import
- Replacement rules: add and JSON import
- Reader font import (first-level presenter after settings dismissal on iOS 17)
- Appearance background images: Photos and Files
- Bottom-tab custom icons

Direct import buttons remain unchanged unless their owner is book-source
management or reader settings. Book-source management changes navigation
ownership on iOS 17; reader settings dismisses before handing font import to
the reader's first-level presenter.

## Removal Condition

Delete the compatibility policy, chooser routes, and contract tests only when
the app's minimum deployment target reaches iOS 18. Until then, new modal or
document-picker actions must not be launched directly from a SwiftUI `Menu` on
iOS 17, book-source management must not be changed back to a sheet there, and
reader font import must keep its first-level presenter handoff.

## Regression Checks

- `Tests/Contracts/DismissalSequencedPresentationContract.swift` verifies the
  OS policy and pending-route lifecycle without requiring an iOS runtime.
- `Tests/iOS/yuedu appTests/DismissalSequencedPresentationTests.swift` mirrors
  the behavior in the iOS test target.
- Parse all affected Swift files after changing presentation routing.
