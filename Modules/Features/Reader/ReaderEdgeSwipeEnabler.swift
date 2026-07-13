import SwiftUI
import UIKit

// MARK: - ReaderEdgeSwipeEnabler

/// A zero-sized probe mounted at the bookshelf navigation root. It resolves
/// the *outer* `UINavigationController` before a reader is pushed, allowing
/// the coordinator to supply both the opening animator and the later
/// percent-driven edge pop. The gesture itself lives on the navigation
/// controller, so this probe never participates in hit testing and taps in
/// the leading-edge strip continue to reach reader content.
struct ReaderEdgeSwipeEnabler: UIViewRepresentable {
    let navigator: ReaderNavigationCoordinator

    func makeUIView(context: Context) -> NavigationProbeView {
        let view = NavigationProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onHierarchyChanged = { [weak coordinator = context.coordinator] probe in
            coordinator?.resolveNavigationController(from: probe)
        }
        context.coordinator.navigator = navigator
        return view
    }

    func updateUIView(_ uiView: NavigationProbeView, context: Context) {
        context.coordinator.navigator = navigator
        context.coordinator.resolveNavigationController(from: uiView)
    }

    static func dismantleUIView(_ uiView: NavigationProbeView, coordinator: Coordinator) {
        coordinator.navigator?.detachNavigationController()
        uiView.onHierarchyChanged = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var navigator: ReaderNavigationCoordinator?
        private weak var attachedNavigationController: UINavigationController?
        private var remainingResolutionAttempts = 8

        func resolveNavigationController(from view: UIView) {
            guard view.window != nil else { return }
            guard let navigationController = findNavigationController(from: view) else {
                guard remainingResolutionAttempts > 0 else { return }
                remainingResolutionAttempts -= 1
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.resolveNavigationController(from: view)
                }
                return
            }
            remainingResolutionAttempts = 8
            guard attachedNavigationController !== navigationController else { return }
            attachedNavigationController = navigationController
            navigator?.attach(to: navigationController)
        }

        private func findNavigationController(from view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let next = responder?.next {
                if let navigationController = next as? UINavigationController {
                    return navigationController
                }
                responder = next
            }
            // A TabView may own several sibling NavigationStacks. Choosing the
            // first navigation controller under the window can attach the
            // reader gesture to the wrong tab, so unresolved ancestry simply
            // retries when SwiftUI updates or reparents this probe.
            return nil
        }
    }

    final class NavigationProbeView: UIView {
        var onHierarchyChanged: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onHierarchyChanged?(self)
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onHierarchyChanged?(self)
        }
    }
}
