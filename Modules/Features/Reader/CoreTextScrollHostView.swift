import SwiftUI
import UIKit

/// Lets 自動閱讀 drive the scroll view, and the reader's bars read its pages,
/// without the reader holding a UIKit controller. The host fills it in;
/// `AutoReadController` calls through it once a frame.
@MainActor
final class ReaderAutoScrollHandle {
    /// Advance by this many points. `false` once the content cannot move further.
    var scrollBy: ((CGFloat) -> Bool)?
    /// The visible text band's height — already the clipped one, not the screen.
    var viewportHeight: (() -> CGFloat)?
    /// The live viewport anchor, sampled synchronously before lifecycle flushes.
    var positionForPersistence: (() -> CoreTextReadingPosition?)?
    /// A chapter's page at the top of the band, one band per page
    /// (`CoreTextCollectionScrollViewController.screenPagination`).
    var screenPagination: ((Int) -> ChapterPagination?)?
}

/// Wraps CoreTextCollectionScrollViewController as a SwiftUI representable, forwarding engine, insets, and theme.
struct CoreTextScrollHostView: UIViewControllerRepresentable {

    @ObservedObject var engine: CoreTextScrollEngine
    let axis: CoreTextScrollAxis
    /// The page's left and right margins, safe area included (`ReaderView.effectivePageMargins`).
    let sideInsets: ReaderSideInsets
    let verticalInset: CGFloat
    let bottomMargin: CGFloat
    /// Vertical axis only: how much of the top and bottom is taken by the two
    /// fixed bars, and the 上下邊距 inside what is left.
    var barInsets: ReaderScrollBarInsets = .zero
    var autoScrollHandle: ReaderAutoScrollHandle?
    let backgroundColor: UIColor
    let initialChapter: Int
    let initialCharOffset: Int
    let navigationRequest: ReaderScrollNavigationRequest?
    let playbackHighlight: ReaderPlaybackHighlight?
    let textAnnotations: [CoreTextTextAnnotation]
    var visibleRefreshCommit: ReaderVisibleRefreshCommit?
    var onVisibleRefreshFinished: (UInt64, ReaderVisibleRefreshOutcome) -> Void = { _, _ in }
    var onTap: () -> Void = {}
    var onUserScrollBegan: () -> Void = {}
    var onProgressCommit: (CoreTextReadingPosition) -> Void = { _ in }
    var onInternalLinkTap: (String) -> Void = { _ in }
    var onChapterContentRequired: (Int) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: axis,
            sideInsets: sideInsets,
            verticalInset: verticalInset,
            backgroundColor: backgroundColor
        )
        vc.onTap = onTap
        vc.onUserScrollBegan = onUserScrollBegan
        vc.onProgressCommit = onProgressCommit
        vc.onInternalLinkTap = onInternalLinkTap
        engine.onChapterContentRequired = onChapterContentRequired
        vc.setInitialPosition(chapter: initialChapter, charOffset: initialCharOffset)
        vc.setTextAnnotations(textAnnotations)
        vc.setPlaybackHighlight(playbackHighlight)
        vc.bottomMargin = bottomMargin
        // Before the view loads, so `viewDidLoad` builds the collection view's
        // constraints already inset — no first-frame flash of full-bleed text
        // under the bars.
        vc.setInitialBarInsets(axis == .vertical ? barInsets : .zero)
        bindAutoScroll(to: vc)
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard let collectionVC = vc as? CoreTextCollectionScrollViewController else { return }
        collectionVC.onTap = onTap
        collectionVC.onUserScrollBegan = onUserScrollBegan
        collectionVC.onProgressCommit = onProgressCommit
        collectionVC.onInternalLinkTap = onInternalLinkTap
        engine.onChapterContentRequired = onChapterContentRequired
        collectionVC.setTextAnnotations(textAnnotations)
        collectionVC.setPlaybackHighlight(playbackHighlight)
        collectionVC.update(
            axis: axis,
            sides: sideInsets,
            vertical: verticalInset,
            bottomMargin: bottomMargin,
            barInsets: barInsets
        )
        collectionVC.updateBackgroundColor(backgroundColor)
        bindAutoScroll(to: collectionVC)
        if let navigationRequest,
           context.coordinator.lastNavigationVersion != navigationRequest.version {
            context.coordinator.lastNavigationVersion = navigationRequest.version
            collectionVC.requestReslice(
                at: navigationRequest.position.spineIndex,
                charOffset: navigationRequest.position.charOffset
            )
        }
        if let commit = visibleRefreshCommit,
           commit.mode == .scroll,
           context.coordinator.lastRefreshTransactionID != commit.transactionID {
            context.coordinator.lastRefreshTransactionID = commit.transactionID
            // Same hazard as the paged host: `applyVisibleRefresh`'s viewport-unavailable
            // branch acknowledges synchronously, and this runs inside SwiftUI's view
            // update, where clearing the renderer's `@Published pendingVisibleRefreshCommit`
            // trips "Publishing changes from within view updates". Defer the ack by one
            // main-queue turn; the reslice path already completes from a `Task`.
            let finish = onVisibleRefreshFinished
            collectionVC.applyVisibleRefresh(commit) { transactionID, outcome in
                DispatchQueue.main.async { finish(transactionID, outcome) }
            }
        }
    }

    private func bindAutoScroll(to vc: CoreTextCollectionScrollViewController) {
        guard let autoScrollHandle else { return }
        autoScrollHandle.scrollBy = { [weak vc] points in
            vc?.autoScroll(by: points) ?? false
        }
        autoScrollHandle.viewportHeight = { [weak vc] in
            vc?.autoScrollViewportHeight ?? 0
        }
        autoScrollHandle.positionForPersistence = { [weak vc] in
            vc?.positionForPersistence()
        }
        autoScrollHandle.screenPagination = { [weak vc] spine in
            vc?.screenPagination(forChapter: spine)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastNavigationVersion: UInt64 = 0
        var lastRefreshTransactionID: UInt64 = 0
    }
}
