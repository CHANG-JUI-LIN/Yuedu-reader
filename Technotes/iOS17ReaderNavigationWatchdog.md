# iOS 17 Detail-to-Reader Navigation Hang

## Reproduction

On iOS 17.5, push an online book from Explore or Search, then choose Read Now.
The reader stops responding during entry. The production report described a
loading indicator followed by termination; the simulator could finish painting
the first page before its main thread became stuck.

The same deterministic source and navigation tests passed on iOS 27. On iOS 17,
repeated process samples showed approximately 100% CPU and a main-thread loop
through UIKit layout, SwiftUI, AttributeGraph, and `ReaderView.body`.

Temporary SwiftUI body-change logging identified the repeating dependency:

```
OnlineBookView: _dismiss changed.
BookReaderView: _dismiss changed.
ReaderView: @self changed.
```

## Fix

In this navigation hierarchy, iOS 17 repeatedly invalidates the `DismissAction`
environment value in both outer views. Those invalidations rebuild the reader
and feed back into navigation layout. Both views now use the presentation-mode
binding already used by `ReaderView`, including when performing their close
actions. The same iOS 17 tests then complete normally.

Keep the native push, hidden reader navigation bar, and reserved back-swipe
region. Do not restore `@Environment(\.dismiss)` in these two views without
running the actual iOS 17 entry tests. Delaying navigation or retrying chapter
loading does not address this dependency cycle.

`FixedPageReaderView` (manga, PDF, fixed-layout EPUB) is the format reader
below `BookReaderView` for those books and follows the same two rules as
`ReaderView`: it reads `presentationMode`, never `@Environment(\.dismiss)`, and
it lets `ReaderNavigationContainer` decide whether it needs a NavigationStack of
its own. A missing `readerNavigator` does not mean modal: a detail-origin reader
is pushed onto the detail's stack with `readerUsesParentNavigationStack`. When
the fixed-page reader moved its controls into the native toolbar it wrapped
itself in a NavigationStack whenever it had no navigator, nesting a second
stack inside that destination, and manga stopped opening from a book detail
(reported 2026-09-28). `DetailReaderStackTests` pins both the pushed and the
modal case; the two manga methods under Regression open a real manga from a
detail.

Its two sheets, 閱讀設定 and 目錄, close through a closure from the view that
presents them, not `@Environment(\.dismiss)`. Feedback #132 (iOS 17.0): from the 搜索
tab, 閱讀模式 picks in 閱讀設定 did not take until the third or fourth try, and the
detail below ignored taps after the reader closed. The report's log shows 搜索 still
publishing its later pages under the open reader. With the fixture's pager source
(`fixture` as the search key) and 閱讀設定 left open and untouched on the iOS 17.0
simulator, the settings body re-ran on every one of those publications — its
DismissAction replaced each time — and on none of them once it stopped reading
`dismiss`. The simulator never reproduced the lost picks or the dead taps themselves.

## The search page

The search page sits under the same detail and reader, and it read
`@Environment(\.dismiss)` too — for a close button no caller ever showed. On
TestFlight build 5 an iOS 17 phone tapped a manga result on the 搜索 tab and
nothing opened. With that recipe (zh-Hans, manga result, its reader and back), the
iOS 17.5 simulator froze on the first tap: once the detail was pushed, one layout
pass never ended at 100% CPU, and body-change logging (`Self._logChanges()`)
reported `BookSearchView: _dismiss changed.` 2,248 times. Build 5 had also given
the page a second `navigationDestination(item:)` (最近閱讀's reader); with the
`dismiss` read gone but both destinations kept, the freeze went away and the
second round's manga reader would not open or would not leave on Back instead.
The page now reads no `DismissAction` and pushes everything through one item
destination (`SearchPagePush`); see `Technotes/iOS17SearchWatchdogPostmortem.md`,
guardrail 12.

Even with one destination, iOS 17.5 replaced the search page's `DismissAction`
about fourteen times per detail-and-reader round, re-running its body each time:
treat `dismiss` in any view under this push hierarchy as a hazard on iOS 17.

`AudiobookDetailView` still reads it, to close itself after 移除書架. Checked on
the iOS 17.5 simulator (2026-10-03) from 搜索 and from 探索, playing a chapter and
removing the book from the shelf: its `DismissAction` was replaced ten to fifteen
times per visit and never looped, and every round trip completed — nothing is
pushed above that page; its player is a full-screen cover. Check it again on
iOS 17 before anything is pushed from it.

This is separate from the synchronous publication during bookshelf probe
teardown, addressed by owner-scoped deferred navigation detachment.
The iOS 17 coordinator regression also exposed that UIKit can release an
externally removed reader before reconciliation. An idle, cleared weak
controller reference must release the session too; a staged push remains guarded.

## Regression

Prepare and serve `scripts/navigation_swipe_fixture.py` for the installed app.
Run these methods with `scripts/xctest.sh` on iOS 17:

- `DetailReaderBackSwipeUITests.testDetailReaderLoadsAndReturns`
- `DetailReaderBackSwipeUITests.testSearchDetailReaderLoadsAndReturns`
- `DetailReaderBackSwipeUITests.testDetailMangaReaderLoadsAndReturns`
- `DetailReaderBackSwipeUITests.testSearchDetailMangaReaderLoadsAndReturns`
- `DetailReaderBackSwipeUITests.testSearchTabMangaResultOpensEveryTime` (the 搜索 tab
  in zh-Hans, three rounds)

Each enters through the production UI and repeats entry. The text book requires
actual chapter text and swipes back to the same detail. The manga, from the same
fixture's image source, requires a page image on screen with the controls away,
raises them for the fixed-page reader's `Page 1 / 3`, and returns with the
reader's Back button. The tests use the repository's local StoreKit
configuration to avoid Apple ID dialogs on a new simulator.
