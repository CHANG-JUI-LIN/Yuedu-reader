import SwiftUI
import UIKit

/// Lets the page that slides over the root tab bar cover it, the way a UIKit app's
/// `hidesBottomBarWhenPushed` page does, for the pages that ask through `.hidesRootTabBar()`.
///
/// A compatibility layer over SwiftUI's `TabView`, for one real case (maintainer, 2026-11-14,
/// iOS 27.2 simulator recordings): SwiftUI hides the tab bar the instant a push begins, so it
/// vanishes from under a page that has barely moved, and shows it only once a pop has fully
/// settled, about a quarter of a second after the page has left, so it springs into place.
/// UIKit's own answer is out of reach: `UINavigationController` slides the bar with the page
/// only when it is the tab bar controller's selected controller, and SwiftUI puts a
/// `TabHostingController` between the two.
///
/// SwiftUI stays the one owner of the bar and of whether it is hidden
/// (`RootTabBarVisibility`). For the length of a push or pop between a page that shows the bar
/// and one that hides it, this puts a picture of the bar in the page that shows it, where it
/// moves with that page and the other page covers it. A picture, because the pages are moved
/// by the render server: a mask over the real bar, moved from here, ran up to 130pt behind
/// the page on a push, whether animated alongside the transition or set frame by frame.
///
/// iOS 27 only. On iOS 26.5 a picture loses the bar's glass: taken of the bar's own views it
/// kept the selected tab and nothing else, and taken of the window it kept the icons and lost
/// the capsule, so the bar would change under the eye as a transition began and ended. There,
/// and on iOS 17 and 18, where this was not tried, the bar comes and goes as SwiftUI moves it.
///
/// Delete this when SwiftUI's `TabView` moves the bar with the page itself.
@available(iOS 27.0, *)
@MainActor
final class RootTabBarTransitionCover {
    static let shared = RootTabBarTransitionCover()

    /// The bar as it last looked on screen, and what it looked like that for.
    private struct Picture {
        let view: UIView
        /// Where it was taken, in the tab bar controller's view.
        let frame: CGRect
        let containerSize: CGSize
        let style: UIUserInterfaceStyle
        let tint: UIColor?
        let selectedIndex: Int
    }

    private var picture: Picture?
    private var transitionID: ObjectIdentifier?
    private let pages = NSHashTable<RootTabBarTransitionProbeController>.weakObjects()

    func register(_ page: RootTabBarTransitionProbeController) {
        pages.add(page)
    }

    /// A page that can hide the tab bar is about to appear or disappear.
    func pageWillChange(_ page: RootTabBarTransitionProbeController) {
        guard let coordinator = page.transitionCoordinator,
              coordinator.isAnimated,
              coordinator.presentationStyle == .none,
              transitionID != ObjectIdentifier(coordinator),
              let from = coordinator.viewController(forKey: .from),
              let to = coordinator.viewController(forKey: .to),
              let navigation = to.navigationController,
              navigation.viewControllers.contains(to),
              let tabBarController = navigation.tabBarController
        else { return }

        let fromHides = hidesTabBar(from)
        let toHides = hidesTabBar(to)
        let tabBar = tabBarController.tabBar
        guard fromHides != toHides,
              !Self.suppliesAnimator(navigation),
              let window = tabBar.window,
              tabBar.convert(tabBar.bounds, to: window).midY > window.bounds.midY,
              let barPage = (toHides ? from : to).viewIfLoaded
        else { return }

        finish()

        // Leaving a page that shows the bar, the bar is still up: SwiftUI hides it a moment
        // later, before the first frame of the push.
        if !tabBar.isHidden, tabBar.alpha == 1 {
            picture = Self.takePicture(of: tabBarController)
        }
        guard let picture, Self.isCurrent(picture, for: tabBarController) else {
            // No picture of the bar as it looks now (the appearance, the tint, the window or
            // the selected tab changed while it was hidden): it returns as SwiftUI shows it.
            self.picture = nil
            return
        }

        transitionID = ObjectIdentifier(coordinator)
        // The page fills the navigation controller's view once it is at rest.
        picture.view.frame = navigation.view.convert(picture.frame, from: tabBarController.view)
        barPage.addSubview(picture.view)

        let showsBarWhenCompleted = !toHides
        let queued = coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, self.transitionID == ObjectIdentifier(coordinator) else { return }
            // SwiftUI shows the bar a moment after this (iOS 27.2: still hidden here); the
            // picture leaves only once the bar is there.
            if showsBarWhenCompleted, !context.isCancelled {
                tabBar.isHidden = false
                tabBar.alpha = 1
            }
            self.finish()
        }
        if !queued { finish() }
    }

    /// Takes the picture out of the page. Safe to call with nothing in flight.
    private func finish() {
        transitionID = nil
        picture?.view.removeFromSuperview()
    }

    private func hidesTabBar(_ controller: UIViewController) -> Bool {
        pages.allObjects.contains { page in
            guard page.hidesTabBar else { return false }
            var ancestor: UIViewController? = page
            while let current = ancestor {
                if current === controller { return true }
                ancestor = current.parent
            }
            return false
        }
    }

    private static func takePicture(of tabBarController: UITabBarController) -> Picture? {
        let host: UIView = tabBarController.view
        let bar = tabBarController.tabBar.convert(tabBarController.tabBar.bounds, to: host)
        // The bar and what is below it, with room above for its shadow.
        let top = max(bar.minY - pictureMargin, 0)
        let frame = CGRect(x: 0, y: top, width: host.bounds.width, height: host.bounds.height - top)
        // The bar's own views, not the screen: the page shows through the picture as it
        // does through the bar.
        guard let source = barContainer(of: tabBarController),
              let view = source.resizableSnapshotView(
            from: source.convert(frame, from: host), afterScreenUpdates: false, withCapInsets: .zero
        ) else { return nil }
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return Picture(
            view: view, frame: frame, containerSize: host.bounds.size,
            style: tabBarController.traitCollection.userInterfaceStyle,
            tint: tabBarController.tabBar.tintColor,
            selectedIndex: tabBarController.selectedIndex
        )
    }

    private static let pictureMargin: CGFloat = 16

    private static func isCurrent(_ picture: Picture, for tabBarController: UITabBarController) -> Bool {
        picture.containerSize == tabBarController.view.bounds.size
            && picture.style == tabBarController.traitCollection.userInterfaceStyle
            && picture.tint == tabBarController.tabBar.tintColor
            && picture.selectedIndex == tabBarController.selectedIndex
    }

    /// The branch of the tab bar controller's view that holds the bar and none of the selected
    /// tab's content. On iOS 26+ that is a container around the bar, where its glass is drawn.
    private static func barContainer(of tabBarController: UITabBarController) -> UIView? {
        var container: UIView = tabBarController.tabBar
        while let parent = container.superview, parent !== tabBarController.view {
            container = parent
        }
        guard container.superview === tabBarController.view else { return nil }
        if let content = tabBarController.selectedViewController?.viewIfLoaded, content.isDescendant(of: container) {
            return nil
        }
        return container
    }

    /// A navigation controller whose delegate animates the transition itself (the reader's
    /// card) is not sliding a page over the bar.
    private static func suppliesAnimator(_ navigation: UINavigationController) -> Bool {
        navigation.delegate?.responds(
            to: #selector(UINavigationControllerDelegate.navigationController(_:animationControllerFor:from:to:))
        ) == true
    }
}

/// Reports a page's pushes and pops to `RootTabBarTransitionCover`.
@available(iOS 27.0, *)
final class RootTabBarTransitionProbeController: UIViewController {
    var hidesTabBar = false

    override func loadView() {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        self.view = view
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        RootTabBarTransitionCover.shared.pageWillChange(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        RootTabBarTransitionCover.shared.pageWillChange(self)
    }
}

@available(iOS 27.0, *)
private struct RootTabBarTransitionProbe: UIViewControllerRepresentable {
    let hidesTabBar: Bool

    func makeUIViewController(context: Context) -> RootTabBarTransitionProbeController {
        let controller = RootTabBarTransitionProbeController()
        controller.hidesTabBar = hidesTabBar
        RootTabBarTransitionCover.shared.register(controller)
        return controller
    }

    func updateUIViewController(_ controller: RootTabBarTransitionProbeController, context: Context) {
        controller.hidesTabBar = hidesTabBar
    }
}

/// Puts the probe on a page that can hide the tab bar, where the cover applies.
///
/// An overlay, never a background: a UIKit view behind a page reorders its accessibility
/// elements, and VoiceOver's touch then lands on the page instead of its bottom bar
/// (`reservingNavigationBackSwipe()`).
struct RootTabBarTransitionCovering: ViewModifier {
    let hidesTabBar: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.overlay(RootTabBarTransitionProbe(hidesTabBar: hidesTabBar).frame(width: 0, height: 0))
        } else {
            content
        }
    }
}
