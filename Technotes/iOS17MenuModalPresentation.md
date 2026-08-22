# iOS 17 Menu-to-Modal Presentation Compatibility

## Symptom

On iOS 17.7, tapping an import action can leave the current screen unchanged
without presenting the requested sheet, document picker, or photo picker.
There are four presentation boundaries:

1. A SwiftUI `Menu` can still be dismissing when its action requests a modal.
2. Book-source management was itself a sheet and tried to present its import
   UI as a nested sheet.
3. Reader settings was itself a sheet and tried to present its font document
   picker from that nested presenter.
4. A `ShareLink` inside a `Menu` still asks for a share sheet while the menu
   controller is dismissing; UIKit ownership does not remove that boundary.
   Confirmed again on iOS 17.7 by 匯出書源, which was simply dead: the book-source
   export links had been written as in-menu `ShareLink`s precisely because the
   author believed UIKit ownership avoided the race.

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
- while book-source management's import sheet asks for a document picker; or
- while reader settings asks its already-presented sheet host to resolve the
  document picker's presenter; or
- while a toolbar menu is dismissing and its `ShareLink` requests the share sheet.

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

`BookSourceImportPresentationPolicy` covers the remaining nested boundary inside
book-source management. On iOS 17, choosing a JSON file first dismisses the import
sheet, retains the document route, and opens the picker only from that sheet's real
`onDismiss` callback. The picker and pasted-JSON routes still converge on the same
`doImportData` / store import path. iOS 18 keeps the picker inside the import sheet.

`BookInfoEditPresentationPolicy` pushes 書籍資訊 (book info / cover editing) from
the bookshelf on iOS 17 for the same reason: it owns the 選擇圖片 photo and file
pickers, which as a sheet would be nested presentations. Its 封面搜索 destination
is a `NavigationLink` in both variants — internal navigation inside a sheet never
crosses a presentation boundary. iOS 18 keeps the sheet.

`ReaderSettingsPresentationPolicy` dismisses reader settings before font
import on iOS 17. `ReaderView` retains the pending font-import route and opens
the document picker only from the settings sheet's real `onDismiss` callback,
so the picker is owned by the reader's first-level presenter. iOS 18 keeps the
font importer inside reader settings.

The same policy now covers every document picker reader settings owns. 匯入閱讀
設定, 匯入正則高亮 and 章節標題樣式's 從檔案匯入樣式 all call
`ReaderSettingsView.requestStyleImporter`, which either sets the local
`styleImportRoute` (iOS 18+) or hands a `ReaderStyleImportRoute` to `ReaderView`
via `onOpenStyleImporter` (iOS 17). Either presenter attaches the one
`readerStyleImportPresentation` modifier, so there is a single picker, a single
parse route (`ReaderSettingsImportService`), and a single apply.

`ShareLink` avoids the document-picker path used by `.fileExporter`, but it is
only presentation-safe when the link itself is a direct page or sheet control.
It must not be launched from a still-dismissing `Menu` on iOS 17. 診斷與回報 and
書源除錯大師 therefore keep their export links directly in the Form and leave only
non-presenting actions in the toolbar menu; 主題 keeps per-theme export in the theme
editor rather than the grid's context menu.

`MenuShareLinkPresentationPolicy` covers the shares that have to stay in a menu
because the menu is the row's only affordance. Before iOS 18 the menu row becomes a
plain `Button` that hands a `PendingShareExport` to the screen, and the screen shows
`ShareExportSheet` — where the `ShareLink` is a direct sheet control — from its own
first-level presenter. iOS 18 keeps the native in-menu `ShareLink`, which needs no
extra tap. The payload is built in a closure, so before iOS 18 it is only produced on
tap rather than on every layout pass of the eagerly-built menu.

Pick by who owns the menu: a screen that is itself a page (書源管理 is pushed before
iOS 18, RSS 文章 is a `navigationDestination`) shows the hand-off sheet as a
first-level presentation. A screen that is already a sheet moves the link out of the
menu entirely instead of nesting another sheet under it — that is why 書源除錯大師's
匯出紀錄 became a Form row.

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
- Book-source JSON file selection: first-level picker after the import sheet dismisses
- Bookshelf: local files, WebDAV, and OPDS
- RSS: source/folder creation, OPML, and JSON
- TTS sources: local and network import
- Replacement rules: add and JSON import
- Reader font import (first-level presenter after settings dismissal on iOS 17)
- 閱讀設定 import: 閱讀設定備份, 正則高亮 rules, 章節標題樣式 (same handoff)
- Appearance background images: Photos and Files
- Bottom-tab custom icons
- 書籍資訊 cover images (pushed from the bookshelf on iOS 17)
- Diagnostics export (direct Form `ShareLink`, never toolbar Menu → share sheet)
- 書源除錯大師 匯出紀錄 (direct Form `ShareLink`, moved out of the toolbar menu)
- 書源匯出: 匯出全部／匯出選中／匯出書源檔案／匯出該分組 (hand-off to
  `BookSourceListView`'s first-level `ShareExportSheet`)
- RSS 文章 分享 and 電量 SVG 分享 SVG (same hand-off, own screen's presenter)

Direct import buttons remain unchanged unless their owner is book-source
management or reader settings. Book-source management changes navigation
ownership and dismisses its local-import sheet before the file picker on iOS 17;
reader settings dismisses before handing font import to the reader's first-level
presenter.

## Removal Condition

Delete the compatibility policy, chooser routes, and contract tests only when
the app's minimum deployment target reaches iOS 18. Until then, new modal or
document-picker actions must not be launched directly from a SwiftUI `Menu` on
iOS 17, book-source management and 書籍資訊 must not be changed back to sheets
there, and reader font import and the 閱讀設定 style importers must keep their
first-level presenter handoff. Presentation-producing `ShareLink`s must also stay
out of SwiftUI `Menu`s on iOS 17: either move the link to a direct page or sheet
control, or route it through `MenuShareLinkPresentationPolicy`'s hand-off. Never
re-argue that UIKit owning the share sheet removes the boundary — that belief is
what shipped the 匯出書源 bug.

## Regression Checks

- `Tests/Contracts/DismissalSequencedPresentationContract.swift` verifies the
  OS policy and pending-route lifecycle without requiring an iOS runtime.
- `Tests/iOS/yuedu appTests/DismissalSequencedPresentationTests.swift` mirrors
  the behavior in the iOS test target.
- Parse all affected Swift files after changing presentation routing.
