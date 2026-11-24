import Foundation

/// The reading position a page stands for once it is on screen.
///
/// A page's own position is where it starts. A turn the reader made lands on that: the place
/// they were is behind them. But most pages put on screen are the app re-placing the page the
/// reader is already on — the restore at the open, a chapter landing, a chapter laid out again
/// because a module's comments arrived — and the reader's position is then wherever on that page
/// it was, not where the page happens to start in this layout.
///
/// Taking the page start there loses the difference, and a layout that changes under the reader
/// turns it into a page. A book reopens before a module's comments are in, on the page of the
/// layout without them that holds the saved position; that page starts earlier than the saved
/// position, and once the comments arrive that earlier offset is on the page before (回饋中心
/// #247: 7/16 reopened as 6/16, the further into the chapter the likelier, as more comments
/// come before the place).
enum ReaderSettledPosition {
    /// - Parameters:
    ///   - pageStart: the position of the page now on screen.
    ///   - held: the position the reader was at before it was shown.
    ///   - readerDriven: the reader's own turn put the page there.
    ///   - pageCount: the pages shown from `pageStart` on: two for a spread.
    ///   - pageIndex: the page a position is on in the layout shown.
    static func resolve(
        pageStart: CoreTextReadingPosition?,
        held: CoreTextReadingPosition?,
        readerDriven: Bool,
        isPlaceholder: Bool,
        pageCount: Int = 1,
        pageIndex: (CoreTextReadingPosition) -> Int?
    ) -> CoreTextReadingPosition? {
        // `.max` stands for "the chapter's end", a target and never a place read: the page
        // start names the page it resolved to.
        guard let pageStart, let held, held != pageStart, !readerDriven, !isPlaceholder,
              held.spineIndex == pageStart.spineIndex, held.charOffset != .max,
              let page = pageIndex(pageStart), let heldPage = pageIndex(held),
              heldPage >= page, heldPage < page + max(1, pageCount)
        else { return pageStart }
        return held
    }
}
