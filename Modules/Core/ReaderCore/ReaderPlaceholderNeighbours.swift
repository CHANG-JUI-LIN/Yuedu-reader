import Foundation

/// The chapters `UIPageViewController` may be holding a 載入中 page for, off screen.
///
/// UIKit keeps the neighbours its data source vends and shows them on the next turn
/// without asking again. A 載入中 page vended for a chapter that has not laid out yet
/// therefore outlives the layout: the announcement takes `handleChapterReady`'s shortcut
/// for a chapter the reader is not looking at, the turn lands on the stale page, and
/// with nothing left to announce the reader stays on 載入中. Seen 2026-11-23 on the
/// simulator: two quick swipes onto a one-page chapter made UIKit ask for the page after
/// it at the landing, before the next chapter had laid out (17 ms later); when that next
/// chapter was the book's last, the turn into it never left 載入中. A 章節載入失敗 page
/// is always one page, so a failed chapter made this common. It sticks only when the
/// landing moves no later chapter's pages (the last chapter, or a page count equal to
/// its estimate): otherwise `rebuildPageOffsets` announces the whole book, and that
/// rewrites the stack anyway.
///
/// Vending a 載入中 page records its chapter; that chapter's layout landing then re-places
/// the stack, which makes UIKit ask for its neighbours again. A stack write replaces the
/// neighbours UIKit holds, so the record starts over. A completed turn does too, except
/// for the page it left, which UIKit keeps as the neighbour on that side without asking:
/// turning back off a 載入中 page keeps its chapter recorded.
struct ReaderPlaceholderNeighbours: Equatable {
    private(set) var chapters: Set<Int> = []

    /// The data source handed UIKit a page showing 載入中 for these chapters.
    mutating func vended(placeholderFor chapters: some Sequence<Int>) {
        self.chapters.formUnion(chapters)
    }

    /// UIKit's neighbours were replaced: the stack was written, or a turn landed.
    mutating func neighboursReplaced() {
        chapters.removeAll()
    }

    /// Whether the chapter that just laid out may have a stale 載入中 page in UIKit's
    /// hands, so its landing has to re-place the stack. Answers once per vend.
    mutating func layoutLanded(forChapter chapter: Int) -> Bool {
        chapters.remove(chapter) != nil
    }
}
