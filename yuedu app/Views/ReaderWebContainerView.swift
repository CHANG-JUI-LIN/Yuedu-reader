/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import SwiftUI
import WebKit

struct ReaderWebContainerView: UIViewRepresentable {
    @ObservedObject var renderer: EPUBPageRenderer
    var pageTurnStyle: PageTurnStyle
    var onTapZone: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, pageTurnStyle: pageTurnStyle)
    }

    func makeUIView(context: Context) -> ReaderWebHostView {
        let view = ReaderWebHostView()
        context.coordinator.attach(to: view)
        renderer.onTapZone = onTapZone
        return view
    }

    func updateUIView(_ uiView: ReaderWebHostView, context: Context) {
        context.coordinator.renderer = renderer
        context.coordinator.pageTurnStyle = pageTurnStyle
        context.coordinator.attach(to: uiView)
        context.coordinator.updateGestureMode()
        renderer.onTapZone = onTapZone
    }

    static func dismantleUIView(_ uiView: ReaderWebHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: EPUBPageRenderer
        var pageTurnStyle: PageTurnStyle
        private weak var hostView: ReaderWebHostView?
        private var hostedWebView: WKWebView?
        private var activeTargetPage: Int?
        private lazy var panGesture: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            gesture.delegate = self
            gesture.cancelsTouchesInView = false
            gesture.maximumNumberOfTouches = 1
            return gesture
        }()

        init(renderer: EPUBPageRenderer, pageTurnStyle: PageTurnStyle) {
            self.renderer = renderer
            self.pageTurnStyle = pageTurnStyle
        }

        func attach(to hostView: ReaderWebHostView) {
            if self.hostView !== hostView {
                self.hostView?.removeGestureRecognizer(panGesture)
                self.hostView = hostView
                hostView.addGestureRecognizer(panGesture)
            }
            attachWebViewIfNeeded()
            updateGestureMode()
        }

        func detach() {
            hostView?.removeGestureRecognizer(panGesture)
            hostedWebView?.removeFromSuperview()
            hostedWebView = nil
            hostView = nil
        }

        func updateGestureMode() {
            panGesture.isEnabled = !renderer.isScrollModeEnabled
        }

        private func attachWebViewIfNeeded() {
            guard let hostView, let webView = renderer.liveWebView else { return }
            guard hostedWebView !== webView || webView.superview !== hostView else {
                webView.frame = hostView.bounds
                return
            }

            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.removeFromSuperview()
            webView.frame = hostView.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostView.insertSubview(webView, at: 0)
        }

        @objc
        private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !renderer.isScrollModeEnabled, renderer.totalPages > 0 else { return }
            guard let hostView else { return }

            let translationX = gesture.translation(in: hostView).x
            switch gesture.state {
            case .began:
                activeTargetPage = renderer.currentEpubPage
                let interruptedOffset = renderer.interruptAnimation()
                renderer.beginGestureInteraction(interruptedOffset: interruptedOffset)
                renderer.dragOffset(translationX)
                renderer.updateGestureInteraction()
            case .changed:
                renderer.dragOffset(translationX)
                renderer.updateGestureInteraction()
            case .ended, .cancelled, .failed:
                let velocityX = gesture.velocity(in: hostView).x
                let threshold = max(min(hostView.bounds.width * 0.18, 90), 48)
                var targetPage = renderer.currentEpubPage

                if (translationX <= -threshold || velocityX <= -520),
                   targetPage < renderer.totalPages - 1
                {
                    targetPage += 1
                } else if (translationX >= threshold || velocityX >= 520), targetPage > 0 {
                    targetPage -= 1
                }

                activeTargetPage = targetPage
                renderer.endGestureInteraction(targetPage: targetPage)
                renderer.resetDragBase()
                renderer.settleDrag(toGlobalPage: targetPage, style: pageTurnStyle)
                activeTargetPage = nil
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer,
                  let hostView
            else { return true }
            guard !renderer.isScrollModeEnabled else { return false }

            let velocity = panGesture.velocity(in: hostView)
            let isHorizontal = abs(velocity.x) > abs(velocity.y)
            let hasIntent = abs(velocity.x) > 30
            return isHorizontal && hasIntent
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

final class ReaderWebHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
*/
