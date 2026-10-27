import Testing
import UIKit
@testable import yuedu_app

@Suite("ProgrammaticPageTransitionPerformer", .serialized)
@MainActor
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

    private final class FakePageContainer: ProgrammaticPageTransitionControlling {
        var viewControllers: [UIViewController]?
        var spineLocation: UIPageViewController.SpineLocation = .min
        var animatedCalls = 0
        var nonAnimatedCalls = 0

        func setViewControllers(
            _ viewControllers: [UIViewController]?,
            direction: UIPageViewController.NavigationDirection,
            animated: Bool,
            completion: ((Bool) -> Void)?
        ) {
            if animated {
                animatedCalls += 1
            } else {
                nonAnimatedCalls += 1
            }
            self.viewControllers = viewControllers
            completion?(true)
        }

        func layoutIfNeeded() {}
    }

    @Test("every animated slide turn runs our timed push, a lone tap included")
    func everyAnimatedSlideTurnRunsTimedPush() {
        #expect(ReaderSlideTurnAnimation.runsTimedPush(pageTurnStyle: .slide, animated: true))
        #expect(!ReaderSlideTurnAnimation.runsTimedPush(pageTurnStyle: .slide, animated: false))
        #expect(!ReaderSlideTurnAnimation.runsTimedPush(pageTurnStyle: .curl, animated: true))
        #expect(!ReaderSlideTurnAnimation.runsTimedPush(pageTurnStyle: .cover, animated: true))
        #expect(!ReaderSlideTurnAnimation.runsTimedPush(pageTurnStyle: .none, animated: true))
    }

    @Test("the slide push replays UIKit's own turn at ProMotion rates, shortened only by a burst")
    func slidePushMatchesUIKitTurn() {
        let lone = ReaderSlideTurnAnimation.pushTransition(direction: .forward, speed: 1)
        #expect(lone.type == .push)
        #expect(lone.subtype == .fromRight)
        // UIKit's programmatic `.scroll` turn, measured: 0.30s on a sine curve.
        #expect(abs(lone.duration - 0.3) < 0.0001)
        var start: [Float] = [0, 0]
        var end: [Float] = [0, 0]
        lone.timingFunction?.getControlPoint(at: 1, values: &start)
        lone.timingFunction?.getControlPoint(at: 2, values: &end)
        #expect(abs(start[0] - 0.365) < 0.0001 && start[1] == 0)
        #expect(abs(end[0] - 0.635) < 0.0001 && end[1] == 1)
        #expect(lone.preferredFrameRateRange.minimum == 80)
        #expect(lone.preferredFrameRateRange.maximum == 120)
        #expect(lone.preferredFrameRateRange.preferred == 120)

        let burst = ReaderSlideTurnAnimation.pushTransition(direction: .reverse, speed: 3)
        #expect(burst.subtype == .fromLeft)
        #expect(abs(burst.duration - 0.1) < 0.0001)
        #expect(burst.preferredFrameRateRange.maximum == 120)
    }

    @Test("the app unlocks ProMotion rates for its own Core Animation on iPhone")
    func appUnlocksProMotionRatesOnPhone() {
        // Without this key an iPhone caps every CAAnimation the app adds — the
        // slide push included — at 60Hz, while UIKit's own scrolling keeps 120Hz.
        #expect(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool == true)
    }

    @Test("the cover turn's UIView animations ask for 120Hz on their own")
    func coverTurnAnimationsAskForProMotionRates() throws {
        // The cover turn animates with `UIView.animate(... .curveEaseOut)`, whose
        // block API cannot state a frame rate. UIKit stamps its own request on the
        // animations it builds — measured 2026-09-26 on iOS 27: 30–120, preferring
        // 120 — so with `CADisableMinimumFrameDurationOnPhone` the cover turn runs at
        // ProMotion rates without a Core Animation rewrite, for as long as this holds.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let page = UIImageView(frame: window.bounds)
        let dim = UIView(frame: window.bounds)
        root.view.addSubview(page)
        root.view.addSubview(dim)

        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            page.frame.origin.x = -page.bounds.width
            dim.alpha = 0.35
        }
        let animations = [page.layer, dim.layer].flatMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        }
        #expect(animations.count == 2)
        for animation in animations {
            #expect(animation.preferredFrameRateRange.maximum == 120)
            #expect(animation.preferredFrameRateRange.preferred == 120)
        }
        page.layer.removeAllAnimations()
        dim.layer.removeAllAnimations()
    }

    @Test("a released cover page carries the finger's speed into its settle")
    func coverSettleSpringVelocityFollowsTheFinger() {
        // 300pt still to travel leftwards, finger moving left at 900pt/s: three
        // remaining-distances a second.
        #expect(ReaderCoverPageMotion.settleSpringVelocity(currentX: -100, destinationX: -400, velocityX: -900) == 3)
        // Same release mirrored for RTL.
        #expect(ReaderCoverPageMotion.settleSpringVelocity(currentX: 100, destinationX: 400, velocityX: 900) == 3)
        // A finger moving away from the resting place adds nothing.
        #expect(ReaderCoverPageMotion.settleSpringVelocity(currentX: -100, destinationX: -400, velocityX: 500) == 0)
        // Already there: no distance to express a velocity in.
        #expect(ReaderCoverPageMotion.settleSpringVelocity(currentX: -400, destinationX: -400, velocityX: -900) == 0)
        // A hard flick just short of the edge is capped, not multiplied.
        #expect(
            ReaderCoverPageMotion.settleSpringVelocity(currentX: -390, destinationX: -400, velocityX: -3000)
                == ReaderCoverPageMotion.maxSettleSpringVelocity
        )
    }

    @Test("the cover settle spring runs at 120Hz and cannot overshoot the page's resting edge")
    func coverSettleSpringNeverOvershoots() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let page = UIImageView(frame: window.bounds)
        root.view.addSubview(page)

        UIView.animate(
            withDuration: ReaderCoverPageMotion.settleDuration,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: ReaderCoverPageMotion.maxSettleSpringVelocity,
            options: []
        ) {
            page.frame.origin.x = -page.bounds.width
        }
        let springs = (page.layer.animationKeys() ?? [])
            .compactMap { page.layer.animation(forKey: $0) as? CASpringAnimation }
        let spring = try #require(springs.first)
        #expect(spring.preferredFrameRateRange.maximum == 120)
        #expect(spring.preferredFrameRateRange.preferred == 120)
        // Critically damped or over: no oscillation of its own.
        let naturalFrequency = (spring.stiffness / spring.mass).squareRoot()
        #expect(spring.damping >= 2 * (spring.stiffness * spring.mass).squareRoot() * 0.999)
        // A critically damped spring passes its target only when it starts faster
        // than its natural frequency (in remaining-distances per second).
        #expect(ReaderCoverPageMotion.maxSettleSpringVelocity <= naturalFrequency)
        print("coverSettleSpring stiffness=\(spring.stiffness) damping=\(spring.damping) mass=\(spring.mass) v0=\(spring.initialVelocity) naturalFrequency=\(naturalFrequency)")
        page.layer.removeAllAnimations()
    }

    @Test("animated curl transition keeps the provided mirrored back page")
    func animatedCurlTransitionKeepsProvidedBackPage() {
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
            animated: true
        ) { settled in
            settledViewController = settled
        }

        #expect(container.viewControllers?.count == 2)
        #expect(container.viewControllers?.first === target)
        #expect(container.viewControllers?.last === back)
        #expect(container.animatedCalls == 1)
        // Re-entering setViewControllers from UIKit's completion corrupts its
        // scroll transaction (App Store willManuallyScroll +728/+748).
        #expect(container.nonAnimatedCalls == 0)
        #expect(settledViewController === target)
    }

    @Test("animated double-sided curl with one controller degrades safely")
    func animatedCurlWithSingleControllerStackDegradesSafely() {
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .curl)
        let container = FakePageContainer()
        let target = IndexedViewController(index: 0)

        var settledViewController: UIViewController?

        performer.perform(
            on: container,
            targetViewController: target,
            targetViewControllers: [target],
            direction: .forward,
            animated: true
        ) { settled in
            settledViewController = settled
        }

        #expect(container.animatedCalls == 0)
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
            animated: false
        ) { settled in
            settledViewController = settled
        }

        #expect(container.viewControllers?.count == 1)
        #expect(container.viewControllers?.first === target)
        #expect(settledViewController === target)
    }

    @Test("a mid spine keeps both pages of the spread, animated or not")
    func midSpineKeepsBothPages() {
        let performer = ProgrammaticPageTransitionPerformer(pageTurnStyle: .curl)
        let container = FakePageContainer()
        container.spineLocation = .mid
        let target = IndexedViewController(index: 2)
        let partner = IndexedViewController(index: 3)

        for animated in [false, true] {
            performer.perform(
                on: container,
                targetViewController: target,
                targetViewControllers: [target, partner],
                direction: .forward,
                animated: animated
            ) { _ in }

            #expect(container.viewControllers?.count == 2)
            #expect(container.viewControllers?.last === partner)
        }
        #expect(container.animatedCalls == 1)
        #expect(container.nonAnimatedCalls == 1)
    }
}
