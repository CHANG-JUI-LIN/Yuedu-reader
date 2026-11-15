import Testing
@testable import yuedu_app

/// The saved position a book opens at is owed once, until the reader is shown it.
///
/// `ReaderView` resolves it in a `Task` that first lays the chapter out, and runs again on
/// every chapter-count change while it is owed. An online chapter that is not cached has
/// no layout at the open, so the restore stayed owed after the executor had shown it; a
/// table-of-contents refresh with new chapters, or the layout simply finishing after the
/// reader's first turn, then applied it over the turns made since (feedback #112).
@Suite("The opening restore is owed until it is on screen")
@MainActor
struct ReaderOpeningRestoreTests {
    /// Chapter 2 starts at global page 10 and has a page every 240 characters.
    private static func page(of position: CoreTextReadingPosition) -> Int? {
        position.spineIndex == 2 ? 10 + position.charOffset / 240 : nil
    }

    @Test("a turn made while the restored chapter lays out is not undone")
    func turnDuringLayoutIsKept() async {
        let restore = ReaderOpeningRestore()
        restore.target = (chapterIndex: 2, charOffset: 249, translationOffset: nil)
        let resolution = await restore.resolve(
            chapterCount: 4,
            preload: { _ in
                // While the chapter lays out, the executor shows the restore on page 11
                // and the reader turns to page 12.
                restore.pageSettled(11, pageIndex: Self.page(of:))
                restore.pageSettled(12, pageIndex: Self.page(of:))
            },
            pageIndex: Self.page(of:)
        )
        #expect(resolution == .nothingOwed, "the restore was applied again after the reader turned to page 12")
        #expect(restore.target == nil)
    }

    @Test("a restore the reader was shown is not applied again by a later run")
    func shownRestoreIsNotReapplied() async {
        let restore = ReaderOpeningRestore()
        restore.target = (chapterIndex: 2, charOffset: 249, translationOffset: nil)
        var laidOut = false
        let pageIndex = { (position: CoreTextReadingPosition) -> Int? in
            laidOut ? Self.page(of: position) : nil
        }
        // The open: the chapter has not been fetched, so it has no page and stays owed.
        #expect(await restore.resolve(chapterCount: 4, preload: { _ in }, pageIndex: pageIndex) == .unresolved)
        // The fetch lays the chapter out and the executor shows the restore; the reader turns on.
        laidOut = true
        #expect(restore.pageSettled(11, pageIndex: pageIndex))
        restore.pageSettled(12, pageIndex: pageIndex)
        // A table-of-contents refresh with new chapters runs the restore again.
        let rerun = await restore.resolve(chapterCount: 5, preload: { _ in }, pageIndex: pageIndex)
        #expect(rerun == .nothingOwed, "the restore was applied again after the reader turned to page 12")
    }

    @Test("a page that is not the restore's leaves it owed")
    func otherPagesLeaveRestoreOwed() async {
        let restore = ReaderOpeningRestore()
        restore.target = (chapterIndex: 2, charOffset: 249, translationOffset: nil)
        var laidOut = false
        let pageIndex = { (position: CoreTextReadingPosition) -> Int? in
            laidOut ? Self.page(of: position) : nil
        }
        // A 載入中 page: the chapter has no layout, so no page can be the restore's.
        #expect(!restore.pageSettled(11, pageIndex: pageIndex))
        laidOut = true
        // The first page shown before the restored chapter arrived.
        #expect(!restore.pageSettled(0, pageIndex: pageIndex))
        #expect(restore.target != nil)
        let resolution = await restore.resolve(chapterCount: 4, preload: { _ in }, pageIndex: pageIndex)
        #expect(resolution == .restore(CoreTextReadingPosition(spineIndex: 2, charOffset: 249), page: 11))
    }

    /// A page of a translation, or of nothing but comment cards, shares its offset with the page
    /// after it: the saved position says which it is (`translationOffset`), and the restore
    /// asks for the page by all of it. Asked by offset alone it named the page after.
    @Test("a saved position inside what was added at an offset restores to its own page")
    func addedContentPositionRestoresToItsPage() async {
        let restore = ReaderOpeningRestore()
        restore.target = (chapterIndex: 2, charOffset: 96, translationOffset: 1)
        let pageIndex = { (position: CoreTextReadingPosition) -> Int? in
            guard position.spineIndex == 2, position.charOffset == 96 else { return nil }
            // Page 7 is the cards before offset 96, page 8 the text at it.
            return position.translationOffset == 1 ? 7 : 8
        }
        #expect(!restore.pageSettled(8, pageIndex: pageIndex))
        let resolution = await restore.resolve(chapterCount: 4, preload: { _ in }, pageIndex: pageIndex)
        #expect(resolution == .restore(CoreTextReadingPosition(spineIndex: 2, charOffset: 96, translationOffset: 1), page: 7))
        #expect(restore.pageSettled(7, pageIndex: pageIndex))
        #expect(restore.target == nil)
    }

    /// A module's comments arrive after the chapter's first layout: at the open the page of
    /// cards the reader left is not there, and the restore lands on the text page at that
    /// offset. The saved place is owed again once the cards are laid out.
    @Test("a restore to a page of cards is placed there once the cards arrive")
    func restoreWaitsForAdditions() {
        let restore = ReaderOpeningRestore()
        let saved = CoreTextReadingPosition(spineIndex: 2, charOffset: 96, translationOffset: 1)
        let textPage = CoreTextReadingPosition(spineIndex: 2, charOffset: 0)
        restore.restoreShown(at: saved, shownAs: textPage)
        // The relayout re-places the page on screen: not the reader's move.
        restore.readerSettled(at: textPage)
        // The comments of another chapter, then this one's before they change anything.
        #expect(restore.additionsArrived(spine: 1, pagePosition: { _ in saved }) == nil)
        #expect(restore.additionsArrived(spine: 2, pagePosition: { _ in textPage }) == nil)
        #expect(restore.additionsArrived(spine: 2, pagePosition: { _ in saved }) == saved)
        #expect(restore.additionsArrived(spine: 2, pagePosition: { _ in saved }) == nil, "placed once")
    }

    @Test("a turn the reader made before the cards arrived is not undone")
    func readerTurnDropsAwaitedAdditions() {
        let restore = ReaderOpeningRestore()
        let saved = CoreTextReadingPosition(spineIndex: 2, charOffset: 96, translationOffset: 1)
        restore.restoreShown(at: saved, shownAs: CoreTextReadingPosition(spineIndex: 2, charOffset: 0))
        restore.readerSettled(at: CoreTextReadingPosition(spineIndex: 3, charOffset: 0))
        #expect(restore.additionsArrived(spine: 2, pagePosition: { _ in saved }) == nil)
    }

    @Test("a restore shown on its own page, or to the book's own text, waits for nothing")
    func ordinaryRestoreAwaitsNothing() {
        let restore = ReaderOpeningRestore()
        let saved = CoreTextReadingPosition(spineIndex: 2, charOffset: 96, translationOffset: 1)
        restore.restoreShown(at: saved, shownAs: saved)
        #expect(restore.awaitingAdditions == nil)
        restore.restoreShown(at: CoreTextReadingPosition(spineIndex: 2, charOffset: 249),
                             shownAs: CoreTextReadingPosition(spineIndex: 2, charOffset: 200))
        #expect(restore.awaitingAdditions == nil)
    }
}
