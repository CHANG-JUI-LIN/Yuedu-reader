import SwiftUI
import UIKit

/// Hosts the SwiftUI reader that 書架's card transition pushes onto the root stack.
///
/// The reader is a page of that stack, with no `NavigationStack` of its own
/// (`ReaderNavigationContainer`), so its SwiftUI toolbar modifiers drive the root
/// stack's bars: hidden while the reader's controls are away, shown with them, and
/// back to the page below on a pop. This controller does not touch the navigation
/// bar — a second owner would fight them (the bar hidden under shown controls after
/// a detail page popped).
@MainActor
final class ReaderHostingController: UIHostingController<AnyView> {
    /// The root `UITabBarController` whose tab bar we hide for the duration of the
    /// reader, and its original hidden state to restore on the way out.
    ///
    /// Why this is needed on iOS 17: the reader is pushed by a custom UIKit card
    /// transition onto the bookshelf's `UINavigationController`. That nav
    /// controller is not a direct child of the SwiftUI `TabView`'s backing
    /// `UITabBarController` on iOS 17, so `hidesBottomBarWhenPushed` never finds a
    /// bottom bar to hide — the root tab bar stays overlaid on top of the reader,
    /// visible and tappable. (ReaderView's `.toolbar(.hidden, for: .tabBar)` can't
    /// help either: the reader's hosting controller starts a SwiftUI tree detached
    /// from the root TabView.) This manual path only runs on iOS 17 and can
    /// be deleted once iOS 17 support is dropped.
    ///
    /// iOS 18+ does not need it, but not because of `hidesBottomBarWhenPushed`:
    /// `hidesBottomBarWhenPushed` takes no part there — on the iOS 26.5 simulator,
    /// with SwiftUI's hide taken away, the tab bar stayed over the reader.
    ///
    /// Since 2026-10-16 the navigation controller is the root stack's, around the tab
    /// bar (`RootNavigation`): the reader is pushed over the tab bar controller and
    /// covers its bar on every version. What this hides is then under the reader;
    /// delete it once the iOS 17 card tests pass without it.
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
        hideRootTabBar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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

        guard navigationController != nil,
              let coordinator = transitionCoordinator, coordinator.isInteractive else { return }
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard context.isCancelled, let self,
                  self.navigationController?.topViewController === self else { return }
            self.hideRootTabBar()
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled, let self,
                  self.navigationController?.topViewController === self else { return }
            self.hideRootTabBar()
        }
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
