import SwiftUI
import UIKit

/// Hosts the migrated SwiftUI reader on the shelf's navigation controller.
///
/// On iOS 27 there is no inner navigation controller: the reader's `NavigationStack` adopts
/// the shelf's, so the bar this controller hides for the page is the same bar the reader's
/// `.toolbar` puts 返回 · 書名 · 封面 in. Each appearance therefore sets it to what the
/// reader's chrome is (`showsReaderChrome`), never to hidden outright: forcing it hidden
/// when the reader came back from 作品詳情 with its chrome up left the bottom bar on
/// screen and the top bar gone, and SwiftUI, whose visibility had not changed, never
/// showed it again — only hiding and re-showing the chrome brought it back. A reader
/// whose stack built a navigation controller of its own keeps the shelf's bar hidden
/// (`hasOwnNavigationController`).
@MainActor
final class ReaderHostingController: UIHostingController<AnyView> {
    private weak var outerNavigationController: UINavigationController?
    private var previousNavigationBarHidden: Bool?

    /// Whether the reader's chrome is up, reported by the reader through
    /// `ReaderNavigationCoordinator.readerChromeVisibilityDidChange`. Read only when
    /// this controller appears; while it is on screen the reader's `.toolbar` drives
    /// the bar itself.
    var showsReaderChrome = false

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
    /// TabView in the SwiftUI tree.) This manual path only runs on iOS 17 and can
    /// be deleted once iOS 17 support is dropped.
    ///
    /// iOS 18+ does not need it, but not because of `hidesBottomBarWhenPushed`:
    /// SwiftUI's TabView shows and hides the tab bar itself, and the reader's
    /// `hidesRootTabBar()` hides it from every tab (`RootTabBarVisibility`).
    /// `hidesBottomBarWhenPushed` takes no part there — on the iOS 26.5 simulator,
    /// with SwiftUI's hide taken away, the tab bar stayed over the reader.
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
        applyReaderNavigationBar(animated: animated)
        hideRootTabBar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Backstop for a cancelled interactive pop: UIKit normally calls
        // `viewWillAppear`, but the settled reader must never retain the
        // shelf's restored navigation bar if callback ordering changes.
        applyReaderNavigationBar(animated: false)
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
        // and the interaction hooks below set the bar from the reader again.
        restoreOuterNavigationBar(animated: animated)

        guard let coordinator = transitionCoordinator, coordinator.isInteractive else { return }
        coordinator.notifyWhenInteractionChanges { [weak self, weak navigationController] context in
            guard context.isCancelled,
                  let self,
                  let navigationController,
                  navigationController.topViewController === self else { return }
            self.applyReaderNavigationBar(animated: true)
            self.hideRootTabBar()
        }
        coordinator.animate(alongsideTransition: nil) { [weak self, weak navigationController] context in
            guard context.isCancelled,
                  let self,
                  let navigationController,
                  navigationController.topViewController === self else { return }
            self.applyReaderNavigationBar(animated: false)
            self.hideRootTabBar()
        }
    }

    /// Puts away the shelf's bar state and shows the bar exactly when the reader's
    /// chrome is up.
    private func applyReaderNavigationBar(animated: Bool) {
        guard let navigationController else { return }
        if outerNavigationController !== navigationController {
            outerNavigationController = navigationController
            previousNavigationBarHidden = navigationController.isNavigationBarHidden
        } else if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController.isNavigationBarHidden
        }
        navigationItem.hidesBackButton = true
        navigationController.setNavigationBarHidden(hasOwnNavigationController || !showsReaderChrome, animated: animated)
    }

    /// Whether the reader's `NavigationStack` built a navigation controller of its own inside
    /// this one instead of adopting the shelf's — the detached stack the tab-bar note above
    /// describes on iOS 17. The reader's bar is then that inner one, and the shelf's would only
    /// add an empty bar above it, so it stays hidden whatever the chrome is. The inner
    /// controller has been seen on iOS 17.5 only (iOS 27 adopts the shelf's); this can go
    /// once no supported version builds one.
    private var hasOwnNavigationController: Bool {
        func contains(_ controller: UIViewController) -> Bool {
            controller.children.contains { $0 is UINavigationController || contains($0) }
        }
        return contains(self)
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
        // iOS 18+: SwiftUI's TabView owns the tab bar (see `managedTabBarController`).
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
        return root.flatMap { UITabBarController.first(in: $0) }
    }

}
