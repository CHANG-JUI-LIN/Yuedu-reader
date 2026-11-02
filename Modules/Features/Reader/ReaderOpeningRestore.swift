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

    var target: (chapterIndex: Int, charOffset: Int)?

    /// A page settled on screen. Returns whether it delivered the restore.
    @discardableResult
    func pageSettled(_ page: Int, pageIndex: (CoreTextReadingPosition) -> Int?) -> Bool {
        // A 載入中 page has no index for the target, and the page shown before the restored
        // chapter arrived has another: neither delivers it.
        guard let target,
              ReaderProgressRestoreResolver.resolvePage(
                  chapterIndex: target.chapterIndex,
                  charOffset: target.charOffset,
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
        let position = CoreTextReadingPosition(spineIndex: spineIndex, charOffset: max(0, target.charOffset))
        guard let page = ReaderProgressRestoreResolver.resolvePage(
            chapterIndex: position.spineIndex,
            charOffset: position.charOffset,
            resolver: pageIndex
        ) else { return .unresolved }
        return .restore(position, page: page)
    }
}
