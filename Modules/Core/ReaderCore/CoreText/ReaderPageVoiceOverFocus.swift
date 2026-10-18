import UIKit

/// Whether a page that has just come on screen takes VoiceOver's focus.
///
/// A page turn has to move VoiceOver to the new page (`.screenChanged`); otherwise focus stays on
/// the page that just left and nothing is read. But every page controller used to post it from its
/// own `viewDidAppear`, and a page also appears when nobody turned anything: a chapter arriving, a
/// relayout or the placeholder giving way to its page re-place the page the reader is already on.
/// With the reading menu open, that pulled VoiceOver off the menu the user had just opened and back
/// onto the page — the top bar, next to the page in swipe order, could still be reached, while the
/// bottom bar (目錄、書籤、深色、設置、閱讀進度) never could (feedback #15, opened with 立即閱讀,
/// where the book's chapters are still arriving).
///
/// One instance per paged reader, owned by `CoreTextPageEngineView`'s coordinator, which hands it
/// to every page through its VoiceOver funnel; the pages report here instead of posting.
@MainActor
final class ReaderPageVoiceOverFocus {
    /// Whether the reading menu, or a surface opened from it, is over the page
    /// (`ReaderView.pageIsCoveredBySurface`).
    var isPageCovered = false

    /// A page as far as VoiceOver focus is concerned: the position it shows, and whether it is the
    /// 載入中 placeholder standing in for that position's text.
    struct Page: Equatable, Sendable {
        let position: CoreTextReadingPosition?
        let isPlaceholder: Bool
    }

    /// The page VoiceOver was last moved to; nil before the first.
    private var focused: Page?

    /// The rule, apart from UIKit so it can be tested.
    ///
    /// - Nothing while VoiceOver is off, or while a surface covers the page: VoiceOver is on that
    ///   surface, and taking it back is the bug.
    /// - Nothing when the page put on screen shows the position VoiceOver is already on: that is
    ///   the same page placed again (a chapter arriving, a relayout), not a turn — unless it is the
    ///   text replacing the 載入中 placeholder VoiceOver was on.
    /// - Otherwise the page takes focus: the first page, and a turn or a jump to another position.
    nonisolated static func movesFocus(
        to appeared: Page,
        from focused: Page?,
        voiceOverRunning: Bool,
        pageIsCovered: Bool
    ) -> Bool {
        guard voiceOverRunning, !pageIsCovered else { return false }
        guard let focused else { return true }
        if appeared.position != focused.position { return true }
        return focused.isPlaceholder && !appeared.isPlaceholder
    }

    /// Called by a page from its `viewDidAppear` with the element VoiceOver should land on.
    func pageDidAppear(_ element: UIView, at position: CoreTextReadingPosition?, isPlaceholder: Bool = false) {
        let page = Page(position: position, isPlaceholder: isPlaceholder)
        guard Self.movesFocus(
            to: page,
            from: focused,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
            pageIsCovered: isPageCovered
        ) else { return }
        focused = page
        UIAccessibility.post(notification: .screenChanged, argument: element)
    }
}
