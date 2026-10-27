import UIKit

@MainActor
protocol ProgrammaticPageTransitionControlling: AnyObject {
    var viewControllers: [UIViewController]? { get }
    var spineLocation: UIPageViewController.SpineLocation { get }

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

    @MainActor
    func perform(
        on controller: ProgrammaticPageTransitionControlling,
        targetViewController: UIViewController,
        targetViewControllers: [UIViewController]? = nil,
        direction: UIPageViewController.NavigationDirection,
        animated: Bool,
        completion: @escaping (UIViewController) -> Void
    ) {
        let targetStack: [UIViewController]
        // An edge spine's back page only exists for the turn; placed without one, the
        // front goes alone. A mid spine's two pages are both fronts and always go
        // together — UIKit raises for one.
        if pageTurnStyle == .curl, !animated, controller.spineLocation != .mid {
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

        // No animated `.scroll` turn reaches here: slide plays its own push over a
        // non-animated swap (`ReaderSlideTurnAnimation`), and cover / none never
        // animate through the page view controller. That is what retired the
        // reverse-slide workaround — nil the data source, animate, then re-set the
        // stack a runloop later — which patched UIKit settling a reverse `.scroll`
        // turn on the page it started from.
        controller.setViewControllers(targetStack, direction: direction, animated: effectiveAnimated) { _ in
            finish(controller.viewControllers?.first ?? targetViewController)
        }
    }
}
