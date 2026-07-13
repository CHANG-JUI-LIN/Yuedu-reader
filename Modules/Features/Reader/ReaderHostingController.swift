import SwiftUI
import UIKit

/// Hosts the migrated SwiftUI reader while owning only the *outer* shelf
/// navigation chrome. The reader's own inner `NavigationStack` remains
/// untouched and continues to show its in-reader controls.
@MainActor
final class ReaderHostingController: UIHostingController<AnyView> {
    private weak var outerNavigationController: UINavigationController?
    private var previousNavigationBarHidden: Bool?

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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Backstop for a cancelled interactive pop: UIKit normally calls
        // `viewWillAppear`, but the settled reader must never retain the
        // shelf's restored navigation bar if callback ordering changes.
        hideOuterNavigationBar(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
        }
        coordinator.animate(alongsideTransition: nil) { [weak self, weak navigationController] context in
            guard context.isCancelled,
                  let self,
                  let navigationController,
                  navigationController.topViewController === self else { return }
            self.hideOuterNavigationBar(animated: false)
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

}
