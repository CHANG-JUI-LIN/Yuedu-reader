import Testing
import UIKit
@testable import yuedu_app

@Suite("ProgrammaticPageTransitionPerformer", .serialized)
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
    @MainActor
    func reverseSlideTransitionIsStabilized() async {
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .slide)
        let container = FakePageContainer()
        let dataSource = FakeDataSource()
        let current = IndexedViewController(index: 1)
        let target = IndexedViewController(index: 0)
        container.viewControllers = [current]
        container.dataSource = dataSource

        let settledViewController = await withCheckedContinuation { continuation in
            performer.perform(
                on: container,
                targetViewController: target,
                direction: .reverse,
                animated: true,
                restoringDataSource: dataSource
            ) { settled in
                continuation.resume(returning: settled)
            }
        }

        #expect(container.animatedReverseCalls == 1)
        #expect(container.nonAnimatedCalls == 1)
        #expect(container.layoutIfNeededCalls == 1)
        #expect(container.dataSource === dataSource)
        #expect((settledViewController as? IndexedViewController)?.globalPageIndex == 0)
        #expect((container.viewControllers?.first as? IndexedViewController)?.globalPageIndex == 0)
    }

    @Test("animated curl transition keeps the provided double-sided stack")
    func animatedCurlTransitionKeepsProvidedDoubleSidedStack() {
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .curl)
        let container = FakePageContainer()
        let target = IndexedViewController(index: 2)
        let back = UIViewController()

        var settledViewController: UIViewController?

        performer.perform(
            on: container,
            targetViewController: target,
            targetViewControllers: [target, back],
            direction: .forward,
            animated: true,
            restoringDataSource: nil
        ) { settled in
            settledViewController = settled
        }

        #expect(container.viewControllers?.count == 2)
        #expect(container.viewControllers?.first === target)
        #expect(container.viewControllers?.last === back)
        #expect(settledViewController === target)
    }

    @Test("animated curl with a single-VC stack degrades to non-animated instead of crashing")
    func animatedCurlWithSingleControllerStackDegradesToNonAnimated() {
        // Regression: a freshly added local EPUB whose target chapter isn't laid out yet
        // yields a PlaceholderPageViewController, so transitionViewControllerStack returns a
        // 1-element stack. An *animated* page-curl requires 2 VCs; passing 1 made UIKit raise
        // in -_validatedViewControllersForTransitionWithViewControllers: → SIGABRT on open.
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .curl)
        let container = FakePageContainer()
        let target = IndexedViewController(index: 0)

        var settledViewController: UIViewController?

        performer.perform(
            on: container,
            targetViewController: target,
            targetViewControllers: [target], // no back page — single element
            direction: .forward,
            animated: true,
            restoringDataSource: nil
        ) { settled in
            settledViewController = settled
        }

        #expect(container.nonAnimatedCalls == 1)
        #expect(container.viewControllers?.count == 1)
        #expect(container.viewControllers?.first === target)
        #expect(settledViewController === target)
    }

    @Test("non-animated curl transition uses one visible controller")
    func nonAnimatedCurlTransitionUsesOneVisibleController() {
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .curl)
        let container = FakePageContainer()
        let target = IndexedViewController(index: 2)
        let back = UIViewController()

        var settledViewController: UIViewController?

        performer.perform(
            on: container,
            targetViewController: target,
            targetViewControllers: [target, back],
            direction: .forward,
            animated: false,
            restoringDataSource: nil
        ) { settled in
            settledViewController = settled
        }

        #expect(container.viewControllers?.count == 1)
        #expect(container.viewControllers?.first === target)
        #expect(settledViewController === target)
    }
}
