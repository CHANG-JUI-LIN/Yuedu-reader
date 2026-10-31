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
        restore.target = (chapterIndex: 2, charOffset: 249)
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
        restore.target = (chapterIndex: 2, charOffset: 249)
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
        restore.target = (chapterIndex: 2, charOffset: 249)
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
}
