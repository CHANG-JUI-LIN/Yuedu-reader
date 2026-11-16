import SwiftUI
import UIKit

extension View {
    /// Closes the full-screen cover this reader is in on a swipe in from the leading edge.
    ///
    /// A reader pushed in a tab leaves on that swipe with the system's back gesture
    /// (`reservingNavigationBackSwipe()`, the shelf's card pop). A cover has no navigation
    /// controller to go back in, so the swipe did nothing there (FB-206: iPad, a comic opened
    /// from 書架). Every reader outside a tab's stack is in one — the iPad shelf's, an import's,
    /// an online book's, 搜尋's recent books, the browser's, the now-playing artwork's — and
    /// `BookReaderView` gives all of them this. The cover closes with its own animation once
    /// the swipe ends; it does not follow the finger.
    ///
    /// An overlay, never a background: a UIKit view in a page's background reorders its
    /// accessibility elements by position (`reservingNavigationBackSwipe()`).
    func closesCoverOnLeadingEdgeSwipe(perform close: @escaping () -> Void) -> some View {
        overlay(ReaderCoverEdgeSwipeProbe(close: close).frame(width: 0, height: 0))
    }
}

// MARK: - Probe

private struct ReaderCoverEdgeSwipeProbe: UIViewRepresentable {
    let close: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.close = close
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.close = close
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.uninstall()
    }

    /// Puts the edge pan on the cover's root view once it is in a window, and takes it off
    /// with the reader. On the cover's own view, not the window: a sheet over the reader (目錄,
    /// 設置) is presented in a container of its own, so a swipe there never reaches it.
    @MainActor
    final class ProbeView: UIView, UIGestureRecognizerDelegate {
        // `gestureRecognizerShouldBegin(_:)` is UIView's too, hence `override`: this view is the
        // pan's delegate, and has no recognizer of its own for UIView's version to answer.
        var close: (() -> Void)?
        private weak var host: UIView?
        private var pan: NavigationBackEdgePanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            install()
        }

        private func install() {
            guard let cover = presentedRoot() else {
                AppLogger.error("ReaderCoverEdgeSwipe: the reader is not in a presented controller; no edge swipe")
                return
            }
            guard host !== cover.view else { return }
            uninstall()
            let pan = NavigationBackEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.edges = .left
            pan.delegate = self
            cover.view.addGestureRecognizer(pan)
            self.pan = pan
            host = cover.view
        }

        func uninstall() {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            pan = nil
            host = nil
        }

        /// The controller the cover presented: the first one up the responder chain that has
        /// no parent and was presented.
        private func presentedRoot() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController,
                   controller.parent == nil,
                   controller.presentingViewController != nil {
                    return controller
                }
                responder = next
            }
            return nil
        }

        private static func hasPushedPage(in controller: UIViewController) -> Bool {
            if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 {
                return true
            }
            return controller.children.contains { hasPushedPage(in: $0) }
        }

        @objc private func handle(_ pan: NavigationBackEdgePanGestureRecognizer) {
            guard pan.state == .ended, let view = pan.view else { return }
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            guard NavigationBackSwipePolicy.completesClose(
                translation: translation, velocity: velocity, containerWidth: view.bounds.width
            ) else { return }
            close?()
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? NavigationBackEdgePanGestureRecognizer,
                  let view = pan.view,
                  let cover = presentedRoot(),
                  // Something presented over the reader owns the screen.
                  cover.presentedViewController == nil,
                  // A page pushed inside the cover goes back on this swipe, as it always did.
                  !Self.hasPushedPage(in: cover) else { return false }
            return NavigationBackSwipePolicy.shouldBegin(
                initialX: pan.initialLocation.x, translation: pan.translation(in: view),
                containerWidth: view.bounds.width
            )
        }
    }
}

#Preview {
    Text(localized("閱讀"))
        .closesCoverOnLeadingEdgeSwipe {}
}
