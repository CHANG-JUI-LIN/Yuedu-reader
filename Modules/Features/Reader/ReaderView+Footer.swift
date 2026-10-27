import SwiftUI
import UIKit

/// Progress changes invalidate only this fixed overlay, not ReaderView's whole
/// navigation/representable tree. The session remains the single position owner.
struct ReaderSessionProgressView<Content: View>: View {
    @ObservedObject var session: ReaderSessionStore
    @ViewBuilder var content: (ReaderLocation) -> Content

    var body: some View {
        content(session.state.location)
    }
}

extension ReaderView {

    @ViewBuilder
    var readerChapterStatusOverlays: some View {
        // These chapter-dependent surfaces follow session progress without
        // rebuilding the navigation tree or replacing the scroll container.
        if manuallyRefreshingChapterIndex == currentChapterIndex {
            readerSurfaceBackground
                .overlay { ProgressView(localized("載入中…")) }
                .readerLoadingChromeTap { toggleReaderChrome() }
                .transition(.opacity)
        }
        if case .failed(let message) = currentChapterOverlayState {
            chapterLoadFailureOverlay(message: message)
        }
    }

    // MARK: - Header / Footer Bars

    var readerHeaderBarOffset: CGFloat {
        ReaderLayoutMetrics.headerBarTopOffset(
            safeTop: effectiveReaderSafeTop,
            headerTopPadding: readerConfig.readerHeaderTopPadding,
            edgeDistance: settings.readerBarLayout.edgeDistances.header
        )
    }

    var readerFooterBarOffset: CGFloat {
        ReaderLayoutMetrics.footerBarBottomOffset(
            safeBottom: effectiveReaderSafeBottom,
            footerBottomPadding: readerConfig.footerBottomPadding,
            edgeDistance: settings.readerBarLayout.edgeDistances.footer
        )
    }

    /// The band each bar occupies, taken out of the text area in *both* reading
    /// modes.
    ///
    /// Reserve the union of body and opening-page content. Geometry must not
    /// depend on the currently visible page, or a chapter boundary could change
    /// pagination while the reader is displaying it.
    var readerBarContentInsets: (top: CGFloat, bottom: CGFloat) {
        let layout = settings.readerBarLayout
        let visibility = ReaderBarVisibility(
            showsHeader: readerConfig.readerHeaderVisible && layout.reservesSpace(in: .header),
            showsFooter: readerConfig.readerFooterVisible && layout.reservesSpace(in: .footer)
        )
        return ReaderLayoutMetrics.barContentInsets(
            safeTop: effectiveReaderSafeTop,
            safeBottom: effectiveReaderSafeBottom,
            showsHeader: visibility.showsHeader,
            showsFooter: visibility.showsFooter,
            verticalMargin: readerConfig.pageMarginV,
            headerTopPadding: readerConfig.readerHeaderTopPadding,
            footerBottomPadding: readerConfig.footerBottomPadding,
            headerExtent: readerBarExtents.header,
            footerExtent: readerBarExtents.footer,
            edgeDistances: layout.edgeDistances,
            topMargin: readerConfig.pageMarginTop,
            bottomMargin: readerConfig.pageMarginBottom,
            headerInnerMargin: CGFloat(layout.headerMargins.inner),
            footerInnerMargin: CGFloat(layout.footerMargins.inner)
        )
    }

    /// How tall each band is. Follows the bar's own font and divider rather than
    /// the flat 16pt the bars used to assume — a 16pt bar font did not fit in a
    /// 16pt band and its descenders were clipped.
    var readerBarExtents: (header: CGFloat, footer: CGFloat) {
        let layout = settings.readerBarLayout
        let fontSize = CGFloat(layout.style.normalized.fontSize)
        return (
            header: ReaderBarRenderer.extent(
                fontSize: fontSize,
                showsDivider: layout.showsHeaderDivider
            ),
            footer: ReaderBarRenderer.extent(
                fontSize: fontSize,
                showsDivider: layout.showsFooterDivider
            )
        )
    }

    /// Scroll mode's share of `readerBarContentInsets`, split into the part that is
    /// clipped away (the bands the bars sit in) and the part that stays as ordinary
    /// padding (上下邊距).
    ///
    /// The two always add back up to `readerBarContentInsets`, which is also what
    /// the paginator is told, so the bar, the hole reserved for it and the text's
    /// resting position cannot disagree. Scroll mode used to take its vertical
    /// inset straight from `pageMarginV` and never consult the bars at all — which
    /// is why the text started underneath the header.
    var readerScrollBarInsets: ReaderScrollBarInsets {
        let layout = settings.readerBarLayout
        let visibility = ReaderBarVisibility(
            showsHeader: readerConfig.readerHeaderVisible && layout.reservesSpace(in: .header),
            showsFooter: readerConfig.readerFooterVisible && layout.reservesSpace(in: .footer)
        )
        let extents = readerBarExtents
        let total = readerBarContentInsets

        let topBand = visibility.showsHeader
            ? readerHeaderBarOffset + extents.header + CGFloat(layout.headerMargins.inner)
            : 0
        let bottomBand = visibility.showsFooter
            ? readerFooterBarOffset + extents.footer + CGFloat(layout.footerMargins.inner)
            : 0

        return ReaderScrollBarInsets(
            topBand: topBand,
            bottomBand: bottomBand,
            topMargin: max(0, total.top - topBand),
            bottomMargin: max(0, total.bottom - bottomBand)
        )
    }

    /// Draws the two bars over the reading surface, at exactly the offsets
    /// `readerBarContentInsets` reserved for them, and keeps the reader's clock.
    ///
    /// Mounted in every mode, drawing in only some: paged CoreText bakes its bars
    /// into the page instead, but the clock behind them still has to tick, so the
    /// layer stays and `drawsFixedBars` decides whether anything is painted.
    func readerBars(visibility: ReaderBarVisibility, drawsFixedBars: Bool) -> some View {
        ReaderPageBarsLayer(
            visibility: visibility,
            drawsFixedBars: drawsFixedBars && !showsBookOpenFailure,
            headerTopOffset: readerHeaderBarOffset,
            footerBottomOffset: readerFooterBarOffset,
            // Captures `ReaderView`. Its `@State` and `@ObservedObject` read through
            // shared storage, so the captured copy still sees live values — the same
            // contract `refreshPageBars` documents.
            model: { bar, clock in readerBarModel(for: bar, clock: clock) },
            onClockTick: { clock in applyClockTick(clock) }
        )
    }

    /// The top safe area of the reader's own window — not the key window's, which can be
    /// another window on another screen.
    var windowSafeTop: CGFloat {
        readerWindow.window?.safeAreaInsets.top ?? readerSafeAreaTop
    }

    func updateFixedLayoutOrientationPreference() {
        guard usesFixedLayoutRenderer else {
            restoreFixedLayoutOrientationPreference()
            return
        }

        let orientation = epubRenderer.fixedLayoutOrientation
        guard orientation != .auto else {
            restoreFixedLayoutOrientationPreference()
            return
        }

        guard activeFixedLayoutOrientationRequest != orientation else { return }
        activeFixedLayoutOrientationRequest = orientation
        ReaderOrientationController.shared.request(orientation, in: readerWindow.windowScene)
    }

    func restoreFixedLayoutOrientationPreference() {
        guard activeFixedLayoutOrientationRequest != nil else { return }
        activeFixedLayoutOrientationRequest = nil
        ReaderOrientationController.shared.restoreDefault(in: readerWindow.windowScene)
    }

    /// The reader's own window's bottom safe area inset (used for manual compensation in full-screen reading).
    var windowSafeBottom: CGFloat {
        readerWindow.window?.safeAreaInsets.bottom ?? 0
    }

    /// Reads only tracked state — never `windowSafeTop`. Every caller of this runs during
    /// body evaluation (the render-settings snapshot, `scrollBody`, the header, TXT
    /// vertical scroll), and `windowSafeTop` reaches into
    /// `UIApplication.shared.connectedScenes` for the key window's safe area. Querying
    /// UIKit window geometry from inside a SwiftUI update is what froze the shelf entry:
    /// the reader is evaluated while the card push is still laying the window out, and
    /// the hosting controller then stopped producing any further body evaluations.
    ///
    /// The window value is not lost. `onPreferenceChange(ReaderSafeAreaTopKey)` already
    /// folds it in with `max($0, windowSafeTop)` before storing — an event handler, which
    /// is the correct place to consult UIKit — so this returns the same number.
    var effectiveReaderSafeTop: CGFloat {
        readerSafeAreaTop
    }

    /// Clears the footer bar the panel is anchored to, so the two do not overlap.
    var readerAutoReadPanelBottomInset: CGFloat {
        readerBarContentInsets.bottom + DSSpacing.sm
    }

    /// Same contract as `effectiveReaderSafeTop`: tracked state only.
    ///
    /// `readerBarContentInsets` is read by the render-settings snapshot, which is
    /// exactly the caller the note above warns about — pointing it at
    /// `windowSafeBottom` stalled the hosting controller and left books stuck on
    /// 載入中.
    var effectiveReaderSafeBottom: CGFloat {
        readerSafeAreaBottom
    }

    // The inline (curl) footer and `pageFooterInfo(forPage:)` lived here. The
    // comment on them claimed the footer was "baked into the page texture" — it
    // never was; neither had a call site. Both are now real, and singular:
    // `ReaderView+PageBars.pageBarsContent(forGlobalPage:)` computes what a bar
    // says on any page, and `CoreTextPageView.renderPage` bakes it in.
}
