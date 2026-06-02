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

        // An *animated* page-curl (isDoubleSided = true, spine at .min/.max) requires a
        // two-element double-sided stack [front, back]. The caller can legitimately end up
        // with a single VC — the target page is still a PlaceholderPageViewController (chapter
        // not yet laid out, e.g. a freshly added local EPUB) or no back page exists at a book
        // boundary. Feeding that 1-element stack to an animated curl makes UIPageViewController
        // raise in -_validatedViewControllersForTransitionWithViewControllers: → SIGABRT.
        // Degrade to a non-animated set: one VC is valid when not animating, so the page still
        // appears, just without the curl on this single turn.
        let effectiveAnimated: Bool = {
            guard pageTurnStyle == .curl, animated, targetStack.count < 2 else { return animated }
            print("[CurlTrace] degrade animated curl → non-animated (stack count \(targetStack.count))")
            return false
        }()

        let finish: (UIViewController) -> Void = { settledViewController in
            controller.layoutIfNeeded()
            completion(settledViewController)
        }

        if effectiveAnimated && direction == .reverse && pageTurnStyle != .curl {
            controller.dataSource = nil
            controller.setViewControllers(targetStack, direction: .reverse, animated: true) { _ in
                controller.setViewControllers(targetStack, direction: .reverse, animated: false) { _ in
                    if self.pageTurnStyle == .slide {
                        controller.dataSource = restoringDataSource
                    }
                    finish(targetViewController)
                }
            }
            return
        }

        controller.setViewControllers(targetStack, direction: direction, animated: effectiveAnimated) { _ in
            finish(controller.viewControllers?.first ?? targetViewController)
        }
    }
}
