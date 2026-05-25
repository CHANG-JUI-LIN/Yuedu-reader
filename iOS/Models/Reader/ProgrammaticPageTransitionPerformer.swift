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
        let targetStack = pageTurnStyle == .curl
            ? [targetViewController]
            : (targetViewControllers ?? [targetViewController])
        let finish: (UIViewController) -> Void = { settledViewController in
            controller.layoutIfNeeded()
            completion(settledViewController)
        }

        if animated && direction == .reverse && pageTurnStyle != .curl {
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

        controller.setViewControllers(targetStack, direction: direction, animated: animated) { _ in
            finish(controller.viewControllers?.first ?? targetViewController)
        }
    }
}
