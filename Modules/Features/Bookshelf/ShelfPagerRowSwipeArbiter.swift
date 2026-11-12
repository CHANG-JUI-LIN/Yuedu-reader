import SwiftUI
import UIKit

/// Lets a shelf row's swipe actions win over the group pager's paging pan (FB-184).
///
/// With groups, every list page sits in `HomeView.shelfPager`, a horizontal paging
/// `ScrollView`. Its pan and the list's swipe-action pan both want a horizontal drag, and the
/// pager took it: a leftward drag on a book row paged (or, on the last page, bounced) instead of
/// opening 置頂／刪除 — only a drag starting on the row's ••• (a control, whose touches the
/// pager does not take) opened them.
///
/// Attached to a book row, this makes the pager's pan wait for the failure of the pans its list
/// adds beside its own scroll pan — the swipe-action pan among them. A drag that opens the row's
/// actions keeps them; one they do not answer (rightward on a row with only trailing actions,
/// anywhere on a folder row or below the rows) fails them at once and pages as before.
///
/// Hooked when the row's cell enters the window, so every page the lazy pager lays out is
/// covered by its own rows; `require(toFail:)` keeps one entry per recognizer, so a row
/// coming back adds nothing. Only rows on the pager's pages carry it: a folder's pushed page
/// has no pager above its list. In 選取 the list's multi-select pan is among those waited on;
/// it does not hold paging up (`BookshelfRowSwipeUITests.testSwipesStillPageWhileSelecting`).
///
/// Measured 2026-11-12: without it the swipe fails on iOS 17.5 and on 27.2 alike. Delete it
/// once `BookshelfRowSwipeUITests` passes without it on every supported runtime — that is,
/// once SwiftUI lets a List's swipe actions win over an enclosing paging `ScrollView` itself.
struct ShelfPagerRowSwipeArbiter: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil,
                  let list = ancestor(of: self, ofType: UICollectionView.self),
                  let pager = ancestor(of: list, ofType: UIScrollView.self)
            else { return }
            for recognizer in list.gestureRecognizers ?? []
            where recognizer is UIPanGestureRecognizer && recognizer !== list.panGestureRecognizer {
                pager.panGestureRecognizer.require(toFail: recognizer)
            }
        }

        private func ancestor<T: UIView>(of view: UIView, ofType type: T.Type) -> T? {
            var candidate = view.superview
            while let current = candidate {
                if let match = current as? T { return match }
                candidate = current.superview
            }
            return nil
        }
    }
}
