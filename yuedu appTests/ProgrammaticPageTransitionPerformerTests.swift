import Testing
import UIKit
@testable import yuedu_app

@Suite("ProgrammaticPageTransitionPerformer")
struct ProgrammaticPageTransitionPerformerTests {

    private final class IndexedViewController: UIViewController, PageIndexProviding {
        let globalPageIndex: Int

        init(index: Int) {
            self.globalPageIndex = index
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class FakeDataSource: NSObject, UIPageViewControllerDataSource {
        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? { nil }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? { nil }
    }

    private final class FakePageContainer: ProgrammaticPageTransitionControlling {
        var dataSource: UIPageViewControllerDataSource?
        var viewControllers: [UIViewController]?
        var animatedReverseCalls = 0
        var nonAnimatedCalls = 0
        var layoutIfNeededCalls = 0

        func setViewControllers(
            _ viewControllers: [UIViewController]?,
            direction: UIPageViewController.NavigationDirection,
            animated: Bool,
            completion: ((Bool) -> Void)?
        ) {
            if animated && direction == .reverse {
                animatedReverseCalls += 1
                // Simulate the UIKit bug: completion fires, but visible controller is still the old one
                completion?(true)
                return
            }

            if !animated {
                nonAnimatedCalls += 1
            }

            self.viewControllers = viewControllers
            completion?(true)
        }

        func layoutIfNeeded() {
            layoutIfNeededCalls += 1
        }
    }

    @Test("reverse slide re-applies target non-animated so settled page stays on target")
    func reverseSlideTransitionIsStabilized() {
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .slide)
        let container = FakePageContainer()
        let dataSource = FakeDataSource()
        let current = IndexedViewController(index: 1)
        let target = IndexedViewController(index: 0)
        container.viewControllers = [current]
        container.dataSource = dataSource

        var settledViewController: UIViewController?

        performer.perform(
            on: container,
            targetViewController: target,
            direction: .reverse,
            animated: true,
            restoringDataSource: dataSource
        ) { settled in
            settledViewController = settled
        }

        #expect(container.animatedReverseCalls == 1)
        #expect(container.nonAnimatedCalls == 1)
        #expect(container.layoutIfNeededCalls == 1)
        #expect(container.dataSource === dataSource)
        #expect((settledViewController as? IndexedViewController)?.globalPageIndex == 0)
        #expect((container.viewControllers?.first as? IndexedViewController)?.globalPageIndex == 0)
    }
}
