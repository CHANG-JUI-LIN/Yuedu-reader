import Foundation

/// The saved position a book opened at, owed to the reader until it is on screen.
///
/// Opening sets it (`ReaderView.refreshInitialRestoreState`); the paged executor places the
/// reader there through the external target, and once the chapter is fully laid out
/// `resolve` names the precise page so `ReaderView` can settle its own state on it.
///
/// It is owed once. Whichever shows it first — the executor settling on its page, or
/// `resolve` — discharges it, and nothing applies it after that. `ReaderView` runs `resolve`
/// again on every chapter-count change while it is owed, and an online chapter that is not
/// cached has no layout at the open; left owed after the executor had shown it, a table-of-
/// contents refresh, or the layout finishing after the reader's first turn, applied it over
/// every turn made since (feedback #112).
@MainActor
final class ReaderOpeningRestore {
    enum Resolution: Equatable {
        /// Nothing is owed.
        case nothingOwed
        /// The chapter has no layout yet (an online chapter not fetched); still owed.
        case unresolved
        /// The restore is on `page`.
        case restore(CoreTextReadingPosition, page: Int)
    }

    /// `translationOffset` as the saved position has it (`CoreTextReadingPosition`): a page
    /// of a translation, or of nothing but comment cards, shares its offset with the page
    /// after it and is found by this.
    var target: (chapterIndex: Int, charOffset: Int, translationOffset: Int?)?

    /// A restore to a place inside what is added to a chapter (a page of a module's comment
    /// cards), and the page it was shown on. The additions arrive after the chapter's first
    /// layout, so at the open their page is not there yet and the restore lands on the page of
    /// the chapter's own text at that offset. Once they arrive it is owed again
    /// (`additionsArrived`), unless the reader has settled anywhere else meanwhile
    /// (`readerSettled`): a turn made since is never undone (feedback #112).
    private(set) var awaitingAdditions: (position: CoreTextReadingPosition, shownAs: CoreTextReadingPosition)?

    /// The restore is on screen: `position` is what was saved, `shownAs` the position of the
    /// page showing it.
    func restoreShown(at position: CoreTextReadingPosition, shownAs: CoreTextReadingPosition?) {
        guard position.translationOffset != nil, let shownAs, shownAs != position else {
            awaitingAdditions = nil
            return
        }
        awaitingAdditions = (position, shownAs)
    }

    /// A page settled at `position`. Any page but the one the restore was shown on is the
    /// reader's own move.
    func readerSettled(at position: CoreTextReadingPosition) {
        if let waiting = awaitingAdditions, waiting.shownAs != position { awaitingAdditions = nil }
    }

    /// What was added to `spine` is laid out. Returns the saved position when it now has a page
    /// of its own; `pagePosition` is the position of the page a position is on.
    func additionsArrived(
        spine: Int,
        pagePosition: (CoreTextReadingPosition) -> CoreTextReadingPosition?
    ) -> CoreTextReadingPosition? {
        guard let waiting = awaitingAdditions, waiting.position.spineIndex == spine,
              let now = pagePosition(waiting.position), now != waiting.shownAs
        else { return nil }
        awaitingAdditions = nil
        return waiting.position
    }

    /// A page settled on screen. Returns whether it delivered the restore.
    @discardableResult
    func pageSettled(_ page: Int, pageIndex: (CoreTextReadingPosition) -> Int?) -> Bool {
        // A 載入中 page has no index for the target, and the page shown before the restored
        // chapter arrived has another: neither delivers it.
        guard let target,
              ReaderProgressRestoreResolver.resolvePage(
                  chapterIndex: target.chapterIndex,
                  charOffset: target.charOffset,
                  translationOffset: target.translationOffset,
                  resolver: pageIndex
              ) == page
        else { return false }
        self.target = nil
        return true
    }

    /// Lays out the restored chapter and names the page the restore is on. `chapterCount` counts
    /// spine items, as positions do; an EPUB's TOC can have fewer entries.
    func resolve(
        chapterCount: Int,
        preload: (Int) async -> Void,
        pageIndex: (CoreTextReadingPosition) -> Int?
    ) async -> Resolution {
        guard let target else { return .nothingOwed }
        let spineIndex = max(0, min(target.chapterIndex, max(0, chapterCount - 1)))
        await preload(spineIndex)
        // The executor can show the restore while its chapter lays out, and the reader turn on
        // from there; it was delivered then, and applying it now would undo those turns.
        guard let owed = self.target, owed == target else { return .nothingOwed }
        let position = CoreTextReadingPosition(spineIndex: spineIndex, charOffset: max(0, target.charOffset),
                                               translationOffset: target.translationOffset)
        guard let page = ReaderProgressRestoreResolver.resolvePage(
            chapterIndex: position.spineIndex,
            charOffset: position.charOffset,
            translationOffset: position.translationOffset,
            resolver: pageIndex
        ) else { return .unresolved }
        return .restore(position, page: page)
    }
}
