import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Header / Footer Bars

    /// The band each bar occupies, taken out of the text area in *both* reading
    /// modes.
    ///
    /// Deliberately asks the policy with `isChapterOpeningPage: false` — the
    /// maximal case. Page geometry must not depend on which page you are looking
    /// at: reserving the header band only on non-opening pages would give the
    /// chapter's first page a taller text area than the rest, and pagination would
    /// disagree with itself every time a chapter boundary moved.
    /// `hidesHeaderOnChapterOpening` is therefore a *drawing* decision only.
    var readerBarContentInsets: (top: CGFloat, bottom: CGFloat) {
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: settings.readerBarLayout,
            headerEnabled: readerConfig.readerHeaderVisible,
            footerEnabled: readerConfig.readerFooterVisible,
            isChapterOpeningPage: false
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
            footerExtent: readerBarExtents.footer
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
        let visibility = ReaderOverlayPresentationPolicy.visibility(
            layout: settings.readerBarLayout,
            headerEnabled: readerConfig.readerHeaderVisible,
            footerEnabled: readerConfig.readerFooterVisible,
            isChapterOpeningPage: false
        )
        let extents = readerBarExtents
        let total = readerBarContentInsets

        let topBand = visibility.showsHeader
            ? ReaderLayoutMetrics.headerBarTopOffset(
                safeTop: effectiveReaderSafeTop,
                headerTopPadding: readerConfig.readerHeaderTopPadding
              ) + extents.header
            : 0
        let bottomBand = visibility.showsFooter
            ? ReaderLayoutMetrics.footerBarBottomOffset(
                safeBottom: effectiveReaderSafeBottom,
                footerBottomPadding: readerConfig.footerBottomPadding
              ) + extents.footer
            : 0

        return ReaderScrollBarInsets(
            topBand: topBand,
            bottomBand: bottomBand,
            topMargin: max(0, total.top - topBand),
            bottomMargin: max(0, total.bottom - bottomBand)
        )
    }

    /// Draws the two bars over the reading surface, at exactly the offsets
    /// `readerBarContentInsets` reserved for them.
    @ViewBuilder
    func readerBars(
        content: ReaderOverlayContentSnapshot,
        visibility: ReaderBarVisibility
    ) -> some View {
        VStack(spacing: 0) {
            if visibility.showsHeader {
                ReaderBarView(model: readerBarModel(for: .header, content: content))
                    .padding(
                        .top,
                        ReaderLayoutMetrics.headerBarTopOffset(
                            safeTop: effectiveReaderSafeTop,
                            headerTopPadding: readerConfig.readerHeaderTopPadding
                        )
                    )
            }
            Spacer(minLength: 0)
            if visibility.showsFooter {
                ReaderBarView(model: readerBarModel(for: .footer, content: content))
                    .padding(
                        .bottom,
                        ReaderLayoutMetrics.footerBarBottomOffset(
                            safeBottom: effectiveReaderSafeBottom,
                            footerBottomPadding: readerConfig.footerBottomPadding
                        )
                    )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Bottom Footer (overlay for slide/cover/tab modes)
    var bottomFooter: some View {
        ReaderOverlayFooter(
            pageInfo: chapterPageInfo,
            progress: totalProgressPercent,
            textColor: readerTheme.textColor,
            footerPadding: readerConfig.footerBottomPadding,
            horizontalPadding: readerConfig.readerFooterHorizontalPadding
        )
    }

    var windowSafeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top) ?? readerSafeAreaTop
    }

    var keyWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { scene in
                scene.activationState == .foregroundActive &&
                    scene.windows.contains(where: \.isKeyWindow)
            }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.windows.contains(where: \.isKeyWindow) }
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
        ReaderOrientationController.shared.request(orientation, in: keyWindowScene)
    }

    func restoreFixedLayoutOrientationPreference() {
        guard activeFixedLayoutOrientationRequest != nil else { return }
        activeFixedLayoutOrientationRequest = nil
        ReaderOrientationController.shared.restoreDefault(in: keyWindowScene)
    }

    /// Returns the key window's bottom safe area inset (used for manual compensation in full-screen reading).
    var windowSafeBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom) ?? 0
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

    // MARK: - Inline Footer (curl mode: baked into page texture, moves with the page)
    func inlineFooter(forPage idx: Int) -> some View {
        let info = pageFooterInfo(forPage: idx)
        return ReaderInlineFooter(
            pageInfo: info.pageInfo,
            progress: info.progress,
            textColor: readerTheme.textColor,
            footerPadding: readerConfig.footerBottomPadding,
            horizontalPadding: readerConfig.readerFooterHorizontalPadding
        )
    }

    /// Computes footer info (chapter page + progress percentage) for the given page.
    func pageFooterInfo(forPage idx: Int) -> (pageInfo: String, progress: String) {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let (spineIndex, charOffset) = engine.charOffset(forPage: idx)
            guard let pagination = engine.chapterPagination(
                forSpine: spineIndex,
                charOffset: charOffset
            ) else {
                return ("", "0.00%")
            }
            let localPage = pagination.localPageIndex + 1
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset) * 100
            return ("\(localPage)/\(pagination.displayPageCount)", String(format: "%.2f%%", pct))
        } else {
            guard !allPages.isEmpty, idx >= 0, idx < allPages.count else { return ("", "0.00%") }
            let page = allPages[idx]
            let total = allPages.filter { $0.chapterIndex == page.chapterIndex }.count
            let pct = Double(idx) / Double(max(allPages.count - 1, 1)) * 100
            return ("\(page.pageInChapter + 1)/\(total)", String(format: "%.2f%%", pct))
        }
    }

}
