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
        direction: UIPageViewController.NavigationDirection,
        animated: Bool,
        restoringDataSource: UIPageViewControllerDataSource?,
        completion: @escaping (UIViewController) -> Void
    ) {
        let finish: (UIViewController) -> Void = { settledViewController in
            controller.layoutIfNeeded()
            completion(settledViewController)
        }

        if animated && direction == .reverse && pageTurnStyle != .curl {
            controller.dataSource = nil
            controller.setViewControllers([targetViewController], direction: .reverse, animated: true) { _ in
                controller.setViewControllers([targetViewController], direction: .reverse, animated: false) { _ in
                    if self.pageTurnStyle == .slide {
                        controller.dataSource = restoringDataSource
                    }
                    finish(targetViewController)
                }
            }
            return
        }

        controller.setViewControllers([targetViewController], direction: direction, animated: animated) { _ in
            finish(controller.viewControllers?.first ?? targetViewController)
        }
    }
}
