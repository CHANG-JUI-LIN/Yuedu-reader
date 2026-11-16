import SwiftUI
import UIKit

// 拼貼卡片 opens its page with a zoom out of the card (maintainer, 2026-11-16: 「探索頁拼貼卡片的
// 點擊轉場我要用zoom」).
// - iOS 18 and later: SwiftUI's own. The card is the source (`matchedTransitionSource`), and the
//   page its push appends zooms from it (`navigationTransition(.zoom)`), there and back, the
//   swipe back included.
// - iOS 17 has no zoom, SwiftUI's or UIKit's (nathantannar4/Transmission's `.zoom` is iOS 18 too;
//   maintainer, 2026-11-16: write the push ourselves). The push alone zooms, out of the card's
//   frame, through the stack's own UINavigationController (`ExploreZoomPushDriver`); the pop is
//   the stack's slide, which keeps the edge swipe a custom pop would need its own gesture for.
// One path per stack: the card asks for the zoom as it pushes (`prepare`), and the page reads it
// where its route is registered (`exploreZoomDestination`).

/// The zooms of one navigation stack: which card each page zooms out of.
@MainActor
final class ExploreZoomTransitions {
    /// The card a pushed value zooms out of, by that value (`ExplorePush.pathValue`). A value
    /// pushed again from the same card zooms again; from elsewhere it is not one of these.
    private var sources: [AnyHashable: String] = [:]
    /// Each card's frame in the window, for iOS 17's push.
    private var frames: [String: CGRect] = [:]
    let pushDriver = ExploreZoomPushDriver()

    /// The card `sourceID` pushes `push`: its page zooms out of it.
    func prepare(_ push: ExplorePush, from sourceID: String) {
        sources[push.pathValue] = sourceID
        if #unavailable(iOS 18), let frame = frames[sourceID] {
            pushDriver.arm(sourceFrame: frame)
        }
    }

    /// The card the page for `route` zooms out of, if a card pushed it.
    func source(for route: AnyHashable) -> String? {
        sources[route]
    }

    func record(frame: CGRect, of sourceID: String) {
        frames[sourceID] = frame
    }
}

/// A stack's zooms and the namespace its cards and pages share, as the environment gives them.
struct ExploreZoomContext: Equatable {
    let transitions: ExploreZoomTransitions
    let namespace: Namespace.ID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transitions === rhs.transitions && lhs.namespace == rhs.namespace
    }
}

extension EnvironmentValues {
    /// The zooms of the stack the view is on; nil where nothing zooms (a section's form).
    @Entry var exploreZoom: ExploreZoomContext? = nil
}

extension ExplorePush {
    /// The value `open(in:store:)` appends: what its page is registered for.
    var pathValue: AnyHashable {
        switch self {
        case .work(let route): AnyHashable(route)
        case .reader(let route): AnyHashable(route)
        case .explore(let route): AnyHashable(route)
        case .feed(let route): AnyHashable(route)
        case .folder(let route): AnyHashable(route)
        case .publicLibrary(let route): AnyHashable(route)
        case .article(let route): AnyHashable(route)
        case .list(let route): AnyHashable(route)
        case .series(let route): AnyHashable(route)
        }
    }
}

extension View {
    /// The card a page zooms out of, by `id`.
    func exploreZoomSource(id: String) -> some View {
        modifier(ExploreZoomSource(id: id))
    }

    /// A page registered for `route`: it zooms out of the card that pushed it, if one did.
    func exploreZoomDestination(_ route: some Hashable, zoom: ExploreZoomContext?) -> some View {
        modifier(ExploreZoomDestination(sourceID: zoom?.transitions.source(for: AnyHashable(route)), zoom: zoom))
    }
}

private struct ExploreZoomSource: ViewModifier {
    let id: String
    @Environment(\.exploreZoom) private var zoom

    func body(content: Content) -> some View {
        if let zoom {
            if #available(iOS 18, *) {
                content.matchedTransitionSource(id: id, in: zoom.namespace) { source in
                    source.clipShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
                }
            } else {
                content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    zoom.transitions.record(frame: frame, of: id)
                }
            }
        } else {
            content
        }
    }
}

private struct ExploreZoomDestination: ViewModifier {
    let sourceID: String?
    let zoom: ExploreZoomContext?

    func body(content: Content) -> some View {
        if #available(iOS 18, *), let sourceID, let zoom {
            content.navigationTransition(.zoom(sourceID: sourceID, in: zoom.namespace))
        } else {
            content
        }
    }
}

// MARK: - iOS 17

/// Finds the navigation controller of the stack it is placed on, for iOS 17's push.
struct ExploreZoomNavigationProbe: UIViewRepresentable {
    let driver: ExploreZoomPushDriver

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.driver = driver
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.driver = driver
        uiView.resolve()
    }

    final class ProbeView: UIView {
        weak var driver: ExploreZoomPushDriver?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        /// The nearest navigation controller up the responder chain: this stack's, not another
        /// tab's.
        func resolve() {
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let navigationController = next as? UINavigationController {
                    driver?.navigationController = navigationController
                    return
                }
                responder = next
            }
        }
    }
}

/// iOS 17's zoom: for the one push a card arms, the stack's delegate is this, which hands UIKit
/// the zoom and forwards everything else to SwiftUI's delegate; it gives the delegate back once
/// the page shows. Not while another delegate animates the stack (the reader's card).
@MainActor
final class ExploreZoomPushDriver: NSObject, UINavigationControllerDelegate {
    weak var navigationController: UINavigationController?
    private weak var forwarded: UINavigationControllerDelegate?
    /// The card's frame in the window, until the push takes it.
    private var sourceFrame: CGRect?

    func arm(sourceFrame frame: CGRect) {
        guard let navigationController, navigationController.transitionCoordinator == nil else { return }
        if navigationController.delegate !== self {
            guard !(navigationController.delegate is ReaderNavigationTransitionDriver) else { return }
            forwarded = navigationController.delegate
            navigationController.delegate = self
        }
        sourceFrame = frame
    }

    private func release(_ navigationController: UINavigationController) {
        guard sourceFrame == nil, navigationController.delegate === self else { return }
        navigationController.delegate = forwarded
        forwarded = nil
    }

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        if operation == .push, let frame = sourceFrame {
            sourceFrame = nil
            return ExploreZoomPushAnimator(sourceFrame: frame)
        }
        // Anything else disarms it: the card's push did not happen as asked.
        sourceFrame = nil
        return forwarded?.navigationController?(navigationController, animationControllerFor: operation, from: fromVC, to: toVC)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        if animationController is ExploreZoomPushAnimator { return nil }
        return forwarded?.navigationController?(navigationController, interactionControllerFor: animationController)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController,
                              animated: Bool) {
        forwarded?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController,
                              animated: Bool) {
        let forwarded = forwarded
        release(navigationController)
        forwarded?.navigationController?(navigationController, didShow: viewController, animated: animated)
    }
}

/// The page grows out of the card: from the card's frame, its corners the card's, to the whole
/// screen, on a spring; with Reduce Motion, it fades in where it ends.
@MainActor
final class ExploreZoomPushAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let sourceFrame: CGRect

    init(sourceFrame: CGRect) {
        self.sourceFrame = sourceFrame
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        DSAnimation.zoomPushDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toViewController = transitionContext.viewController(forKey: .to),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        let container = transitionContext.containerView
        let finalFrame = transitionContext.finalFrame(for: toViewController)
        toView.frame = finalFrame
        container.addSubview(toView)

        let source = container.convert(sourceFrame, from: nil)
        guard !UIAccessibility.isReduceMotionEnabled, source.width > 0, finalFrame.width > 0 else {
            toView.alpha = 0
            UIView.animate(withDuration: DSAnimation.zoomFadeDuration) {
                toView.alpha = 1
            } completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
            return
        }

        // The page scaled to the card's width and centred on it, cut to the card's height and
        // corners; then the whole page, square-cornered.
        let scale = source.width / finalFrame.width
        let mask = UIView(frame: CGRect(x: 0, y: (finalFrame.height - source.height / scale) / 2,
                                        width: finalFrame.width, height: source.height / scale))
        mask.backgroundColor = .black
        mask.layer.cornerRadius = DSRadius.xxl / scale
        mask.layer.cornerCurve = .continuous
        toView.mask = mask
        toView.transform = CGAffineTransform(translationX: source.midX - finalFrame.midX, y: source.midY - finalFrame.midY)
            .scaledBy(x: scale, y: scale)

        UIView.animate(springDuration: DSAnimation.zoomPushDuration, bounce: 0) {
            toView.transform = .identity
            mask.frame = toView.bounds
            mask.layer.cornerRadius = 0
        } completion: { _ in
            toView.mask = nil
            toView.transform = .identity
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
    }
}
