import Foundation

struct ReaderBarVisibility: Equatable, Sendable {
    var showsHeader: Bool
    var showsFooter: Bool
}

enum ReaderOverlayPresentationPolicy {

    /// Whether each bar is drawn — and, by the same call, whether the paginator
    /// reserves space for it.
    ///
    /// **There is deliberately no `isScrolling` parameter.** The bars used to be
    /// free-positioned components that only paged mode drew, which is why scroll
    /// mode had no header or footer at all. Bars are structural: the text area is
    /// inset by their height in both modes, exactly as legado's
    /// `view_book_page.xml` constrains its `ContentTextView` between the two
    /// dividers and then scrolls only the content.
    ///
    /// Both the renderer and `ReaderLayoutMetrics` must ask this one function. If
    /// they ever disagree, the text either slides under a bar or leaves a blank
    /// strip where one was reserved but never drawn.
    static func visibility(
        layout: ReaderBarLayout,
        headerEnabled: Bool,
        footerEnabled: Bool,
        isChapterOpeningPage: Bool
    ) -> ReaderBarVisibility {
        ReaderBarVisibility(
            showsHeader: headerEnabled
                && layout.hasContent(in: .header)
                && !(isChapterOpeningPage && layout.hidesHeaderOnChapterOpening),
            showsFooter: footerEnabled && layout.hasContent(in: .footer)
        )
    }

    static func hidesStatusBar(
        showsReaderChrome: Bool,
        isEditing: Bool
    ) -> Bool {
        isEditing || !showsReaderChrome
    }

    /// The home indicator follows the status bar: both are system chrome that has
    /// to clear out of the immersive reading page and come back together with the
    /// reader's own bars. It gets its own entry point (rather than the call site
    /// reusing `hidesStatusBar`) so the two can diverge later without the reader
    /// reading a status-bar rule to decide a home-indicator question.
    static func hidesHomeIndicator(
        showsReaderChrome: Bool,
        isEditing: Bool
    ) -> Bool {
        hidesStatusBar(showsReaderChrome: showsReaderChrome, isEditing: isEditing)
    }
}
