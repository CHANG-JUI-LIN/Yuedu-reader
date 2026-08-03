import SwiftUI
import UIKit

extension ReaderView {

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
            guard let layout = engine.layouts[spineIndex], !layout.pageRanges.isEmpty else {
                return ("", "0.00%")
            }
            let localPage = layout.pageIndex(for: charOffset) + 1
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset) * 100
            return ("\(localPage)/\(layout.displayPageCount)", String(format: "%.2f%%", pct))
        } else {
            guard !allPages.isEmpty, idx >= 0, idx < allPages.count else { return ("", "0.00%") }
            let page = allPages[idx]
            let total = allPages.filter { $0.chapterIndex == page.chapterIndex }.count
            let pct = Double(idx) / Double(max(allPages.count - 1, 1)) * 100
            return ("\(page.pageInChapter + 1)/\(total)", String(format: "%.2f%%", pct))
        }
    }

}
