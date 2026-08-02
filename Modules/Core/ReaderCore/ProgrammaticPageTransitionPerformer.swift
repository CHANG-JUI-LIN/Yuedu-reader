import UIKit

protocol ProgrammaticPageTransitionControlling: AnyObject {
    var dataSource: UIPageViewControllerDataSource? { get set }
    var viewControllers: [UIViewController]? { get }

    func setViewControllers(
        _ viewControllers: [UIViewController]?,
        direction: UIPageViewController.NavigationDirection,
        animated: Bool,
        completion: ((Bool) -> Void)?
    )

    func layoutIfNeeded()
}

extension UIPageViewController: ProgrammaticPageTransitionControlling {
    func layoutIfNeeded() {
        view.layoutIfNeeded()
    }
}

struct ProgrammaticPageTransitionPerformer {
    let pageTurnStyle: PageTurnStyle

    func perform(
        on controller: ProgrammaticPageTransitionControlling,
        targetViewController: UIViewController,
        targetViewControllers: [UIViewController]? = nil,
        direction: UIPageViewController.NavigationDirection,
        animated: Bool,
        restoringDataSource: UIPageViewControllerDataSource?,
        completion: @escaping (UIViewController) -> Void
    ) {
        let targetStack: [UIViewController]
        if pageTurnStyle == .curl, !animated {
            targetStack = [targetViewController]
        } else {
            targetStack = targetViewControllers ?? [targetViewController]
        }

        // Edge-spine double-sided curl requires [front, mirrored back]. A placeholder
        // or book boundary may temporarily have only the front, where UIKit would
        // raise for an animated transition; show that page without animation instead.
        let effectiveAnimated: Bool = {
            guard pageTurnStyle == .curl, animated, targetStack.count < 2 else { return animated }
            AppLogger.render("[CurlTrace] degrade animated curl → non-animated (stack count \(targetStack.count))")
            return false
        }()

        let finish: (UIViewController) -> Void = { settledViewController in
            controller.layoutIfNeeded()
            completion(settledViewController)
        }

        if effectiveAnimated && direction == .reverse && pageTurnStyle != .curl {
            controller.dataSource = nil
            controller.setViewControllers(targetStack, direction: .reverse, animated: true) { _ in
                // Defer the non-animated follow-up to avoid NSInternalInconsistencyException
                // in _UIQueuingScrollView — the just-completed animated scroll has not yet
                // fully unwound, and a synchronous second setViewControllers triggers
                // queuingScrollView:willManuallyScroll: to raise.
                DispatchQueue.main.async { [controller, targetStack, targetViewController, restoringDataSource, finish] in
                    controller.setViewControllers(targetStack, direction: .reverse, animated: false) { _ in
                        if self.pageTurnStyle == .slide {
                            controller.dataSource = restoringDataSource
                        }
                        finish(targetViewController)
                    }
                }
            }
            return
        }

        controller.setViewControllers(targetStack, direction: direction, animated: effectiveAnimated) { _ in
            finish(controller.viewControllers?.first ?? targetViewController)
        }
    }
}
