import SwiftUI
import UIKit

/// Hosts the migrated SwiftUI reader while owning only the *outer* shelf
/// navigation chrome. The reader's own inner `NavigationStack` remains
/// untouched and continues to show its in-reader controls.
@MainActor
final class ReaderHostingController: UIHostingController<AnyView> {
    private weak var outerNavigationController: UINavigationController?
    private var previousNavigationBarHidden: Bool?

    /// The root `UITabBarController` whose tab bar we hide for the duration of the
    /// reader, and its original hidden state to restore on the way out.
    ///
    /// Why this is needed on iOS 17: the reader is pushed by a custom UIKit card
    /// transition onto the bookshelf's `UINavigationController`. That nav
    /// controller is not a direct child of the SwiftUI `TabView`'s backing
    /// `UITabBarController` on iOS 17, so `hidesBottomBarWhenPushed` never finds a
    /// bottom bar to hide — the root tab bar stays overlaid on top of the reader,
    /// visible and tappable. (ReaderView's `.toolbar(.hidden, for: .tabBar)` can't
    /// help either: the reader's inner NavigationStack is detached from the root
    /// TabView in the SwiftUI tree.) iOS 18+ wires the chain up and honors
    /// `hidesBottomBarWhenPushed`, so this manual path only runs on iOS 17 and can
    /// be deleted once iOS 17 support is dropped.
    private weak var managedTabBarController: UITabBarController?
    private var previousTabBarHidden: Bool?

    init(content: AnyView) {
        super.init(rootView: content)
        hidesBottomBarWhenPushed = true
        navigationItem.hidesBackButton = true
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hideOuterNavigationBar(animated: animated)
        hideRootTabBar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Backstop for a cancelled interactive pop: UIKit normally calls
        // `viewWillAppear`, but the settled reader must never retain the
        // shelf's restored navigation bar if callback ordering changes.
        hideOuterNavigationBar(animated: false)
        // Also re-run here: on the opening push the window (and thus the root
        // tab bar controller) may not be resolvable until the view is on screen.
        hideRootTabBar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // The root tab bar is resolved independently of the shelf nav controller,
        // so restore it before the guard below — a reader that detaches with a nil
        // navigationController must still hand the tab bar back to the shelf.
        restoreRootTabBar()

        guard let navigationController else { return }

        // Restore unconditionally before any disappearance. A successful pop
        // must leave the shelf's original bar state intact; if the reader is
        // merely covered or an interactive pop cancels, its appear callbacks
        // and the interaction hooks below hide the outer bar again.
        restoreOuterNavigationBar(animated: animated)

        guard let coordinator = transitionCoordinator, coordinator.isInteractive else { return }
        coordinator.notifyWhenInteractionChanges { [weak self, weak navigationController] context in
            guard context.isCancelled,
                  let self,
                  let navigationController,
                  navigationController.topViewController === self else { return }
            self.hideOuterNavigationBar(animated: true)
            self.hideRootTabBar()
        }
        coordinator.animate(alongsideTransition: nil) { [weak self, weak navigationController] context in
            guard context.isCancelled,
                  let self,
                  let navigationController,
                  navigationController.topViewController === self else { return }
            self.hideOuterNavigationBar(animated: false)
            self.hideRootTabBar()
        }
    }

    private func hideOuterNavigationBar(animated: Bool) {
        guard let navigationController else { return }
        if outerNavigationController !== navigationController {
            outerNavigationController = navigationController
            previousNavigationBarHidden = navigationController.isNavigationBarHidden
        } else if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController.isNavigationBarHidden
        }
        navigationItem.hidesBackButton = true
        navigationController.setNavigationBarHidden(true, animated: animated)
    }

    private func restoreOuterNavigationBar(animated: Bool) {
        guard let navigationController else { return }
        navigationController.setNavigationBarHidden(
            previousNavigationBarHidden ?? false,
            animated: animated
        )
    }

    // MARK: Root tab bar (iOS 17 only — see `managedTabBarController` doc)

    private func hideRootTabBar() {
        // iOS 18+ honors `hidesBottomBarWhenPushed`; leave the system in charge.
        guard #unavailable(iOS 18.0) else { return }
        guard let tabBarController = resolveRootTabBarController() else { return }
        if managedTabBarController !== tabBarController {
            managedTabBarController = tabBarController
            previousTabBarHidden = tabBarController.tabBar.isHidden
        } else if previousTabBarHidden == nil {
            previousTabBarHidden = tabBarController.tabBar.isHidden
        }
        tabBarController.tabBar.isHidden = true
    }

    private func restoreRootTabBar() {
        guard let tabBarController = managedTabBarController else { return }
        tabBarController.tabBar.isHidden = previousTabBarHidden ?? false
        managedTabBarController = nil
        previousTabBarHidden = nil
    }

    /// The standard `tabBarController` ancestor lookup is exactly the chain that
    /// comes back nil on iOS 17's SwiftUI `TabView` (the reason the bug exists),
    /// so fall back to searching from the window root for the app's root tab bar.
    private func resolveRootTabBarController() -> UITabBarController? {
        if let direct = tabBarController { return direct }
        let root = view.window?.rootViewController
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }?
                .rootViewController
        return root.flatMap { Self.firstTabBarController(in: $0) }
    }

    private static func firstTabBarController(in controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        for child in controller.children {
            if let found = firstTabBarController(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return firstTabBarController(in: presented)
        }
        return nil
    }

}
