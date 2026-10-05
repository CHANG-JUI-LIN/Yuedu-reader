import ObjectiveC
import SwiftUI
import UIKit

extension View {
    /// Marks a tab's root page: a tab bar at the bottom shows while this page is the one on
    /// screen, and hides while any page covers it and reaches the tab bar — pushed onto its
    /// navigation stack, or presented over it as a sheet, a full-screen cover or a popover.
    /// A sheet floating clear of the tab bar, as in a wide iPad window before iOS 18, leaves
    /// it up; so does a menu, an alert, a confirmation dialog or the search field: none of
    /// them is a page.
    ///
    /// `rootTabTitle(_:onScroll:)` applies it, so every tab root has it.
    func showsRootTabBarOnlyHere() -> some View {
        background {
            TabRootCoverageReporter()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// Whether another page covers a tab's root page, read from UIKit: SwiftUI has no signal
/// for a sheet or a popover covering a page (the page stays on screen beneath it), and
/// a page pushed over the root is no screen of the root's to mark.
@MainActor
enum TabRootCoverage {
    enum State: Equatable {
        case uncovered
        case covered
        /// A swipe back, or a sheet pulled down, is uncovering the root and can still be
        /// called off. The state before it stands until it ends.
        case undecided
    }

    /// `root`: the root page's view controller. `windowRoot`: its window's root view
    /// controller, which presents the app's sheets and covers.
    static func state(of root: UIViewController, windowRoot: UIViewController?) -> State {
        var isCovered = false
        var isInteractive = false
        if let navigation = root.navigationController {
            if navigation.topViewController !== stackEntry(of: root, in: navigation) {
                isCovered = true
            }
            if navigation.transitionCoordinator?.isInteractive == true { isInteractive = true }
        }
        // Both: `presentedViewController` reaches the presentations of the root's
        // ancestors, but on iOS 17 the root's ancestors stop short of the window's root
        // (see `ReaderHostingController.resolveRootTabBarController`).
        let tabBar = bottomTabBarFrame(of: root, windowRoot: windowRoot)
        for presenter in [root, windowRoot] {
            var presented = presenter?.presentedViewController
            while let page = presented {
                if coversRoot(page, tabBar: tabBar) { isCovered = true }
                if page.transitionCoordinator?.isInteractive == true { isInteractive = true }
                presented = page.presentedViewController
            }
        }
        if isCovered { return .covered }
        return isInteractive ? .undecided : .uncovered
    }

    /// Whether a presented view controller is a page over the root that reaches the tab
    /// bar. An alert or a confirmation dialog is not a page; nor is the search field's own
    /// controller, which a tab root's active search presents; nor a menu, such as one
    /// opened from a toolbar button on the root (product decision, 2026-10-05). A popover
    /// is a page: a compact width shows it as a sheet over the tab bar. A sheet that floats
    /// clear of the tab bar does not reach it (2026-10-05). A page on its way out no
    /// longer covers the root.
    ///
    /// `tabBar`: where a tab bar at the bottom sits, in window coordinates.
    static func coversRoot(_ presented: UIViewController, tabBar: CGRect? = nil) -> Bool {
        if presented is UIAlertController || presented is UISearchController { return false }
        if isUIKitControl(presented) { return false }
        if let tabBar, isSheet(presented, clearOf: tabBar) { return false }
        return !presented.isBeingDismissed
    }

    /// A sheet in a regular width is a card in the middle of the window, which can stay
    /// clear of a tab bar at the bottom — as on an iPad before iOS 18, where a wide window
    /// keeps the tab bar at the bottom. In a compact width a sheet rises from the bottom
    /// edge, over the tab bar, so it always reaches it.
    ///
    /// Read from the frame the presentation gives the sheet rather than from its view,
    /// which is still on its way in. Without that frame, the sheet reaches the tab bar.
    private static func isSheet(_ presented: UIViewController, clearOf tabBar: CGRect) -> Bool {
        guard let sheet = presented.sheetPresentationController,
              let container = sheet.containerView,
              container.window != nil,
              container.traitCollection.horizontalSizeClass == .regular
        else { return false }
        let frame = container.convert(sheet.frameOfPresentedViewInContainerView, to: nil)
        return !frame.isEmpty && !frame.intersects(tabBar)
    }

    /// Where a tab bar at the bottom sits, in its window's coordinates: as tall as the tab
    /// bar, along the window's bottom edge. Placed there rather than read from its frame,
    /// which can move off screen while it is hidden. Nil without a tab bar or a window.
    private static func bottomTabBarFrame(
        of root: UIViewController,
        windowRoot: UIViewController?
    ) -> CGRect? {
        let tabBarController = root.tabBarController
            ?? windowRoot.flatMap { UITabBarController.first(in: $0) }
        guard let window = windowRoot?.viewIfLoaded?.window ?? root.viewIfLoaded?.window,
              let tabBar = tabBarController?.tabBar,
              tabBar.bounds.height > 0
        else { return nil }
        let bounds = window.bounds
        return CGRect(
            x: bounds.minX,
            y: bounds.maxY - tabBar.bounds.height,
            width: bounds.width,
            height: tabBar.bounds.height
        )
    }

    /// A control UIKit presents for itself — a menu above all — rather than a page the app
    /// presents. UIKit presents a menu as a view controller of a private class, with no
    /// public type to test for; UIKit's private classes are the ones named `_UI…`. No page
    /// the app presents is: the app's and SwiftUI's classes have Swift's names (`_Tt…`),
    /// and the pages UIKit offers — the share sheet, the document picker — public ones.
    private static func isUIKitControl(_ presented: UIViewController) -> Bool {
        NSStringFromClass(type(of: presented)).hasPrefix("_UI")
    }

    /// The view controller in `navigation`'s stack that holds `page`.
    private static func stackEntry(
        of page: UIViewController,
        in navigation: UINavigationController
    ) -> UIViewController? {
        var current: UIViewController? = page
        while let controller = current {
            if controller.parent === navigation { return controller }
            current = controller.parent
        }
        return nil
    }
}

/// Behind a tab's root page: reports through `TabRootCoverageMonitor` whether another page
/// covers it, to the tab bar's `RootTabBarVisibility` under the tab's name.
private struct TabRootCoverageReporter: UIViewRepresentable {
    @Environment(\.rootTabBarVisibility) private var visibility
    @Environment(\.rootTabBarTab) private var tab

    func makeUIView(context: Context) -> TabRootCoverageAnchor {
        TabRootCoverageAnchor()
    }

    func updateUIView(_ anchor: TabRootCoverageAnchor, context: Context) {
        anchor.reports(to: visibility, as: tab)
    }

    static func dismantleUIView(_ anchor: TabRootCoverageAnchor, coordinator: ()) {
        TabRootCoverageMonitor.unregister(anchor)
    }
}

/// Sits on the root page, so its responder chain leads to the root page's view controller.
final class TabRootCoverageAnchor: UIView {
    private weak var visibility: RootTabBarVisibility?
    private var tab: String?
    private weak var rootPage: UIViewController?
    /// The window the page was last on. A push, or a full-screen cover, takes the page off
    /// it; the window's root still presents what covers it.
    private weak var lastWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Only records it: this runs inside a SwiftUI update, where publishing is not allowed.
    func reports(to visibility: RootTabBarVisibility?, as tab: String?) {
        guard self.visibility !== visibility || self.tab != tab else { return }
        self.visibility = visibility
        self.tab = tab
        TabRootCoverageMonitor.setNeedsEvaluation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off the window means a page covers the root; what covers it is still to report.
        guard let window else { return }
        lastWindow = window
        rootPage = owningViewController
        TabRootCoverageMonitor.register(self)
    }

    /// What to report, or nil with nowhere to report it.
    func coverage() -> (visibility: RootTabBarVisibility, tab: String, state: TabRootCoverage.State)? {
        guard let visibility, let tab, let rootPage else { return nil }
        let state = TabRootCoverage.state(of: rootPage, windowRoot: lastWindow?.rootViewController)
        return (visibility, tab, state)
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

/// Re-reads every tab root's coverage whenever any view controller appears or disappears.
///
/// UIKit announces a push, a pop, a presentation and a dismissal to nobody but the view
/// controllers involved — a navigation controller's delegate belongs to SwiftUI, a
/// presentation controller's too — so the hook is on `UIViewController`'s own appearance
/// methods, which every one of those transitions calls on the pages it moves: the page
/// pushed or presented appears, the one popped or dismissed disappears. Installed once,
/// when the first tab root shows, and needed for as long as the tab bar hides over pages.
@MainActor
enum TabRootCoverageMonitor {
    private static let anchors = NSHashTable<TabRootCoverageAnchor>.weakObjects()
    /// Everything reported to before, to clear one whose roots have all gone.
    private static let reported = NSHashTable<RootTabBarVisibility>.weakObjects()
    private static var isEvaluationScheduled = false

    static func register(_ anchor: TabRootCoverageAnchor) {
        _ = appearanceHooks
        anchors.add(anchor)
        setNeedsEvaluation()
    }

    static func unregister(_ anchor: TabRootCoverageAnchor) {
        anchors.remove(anchor)
        setNeedsEvaluation()
    }

    /// On the main queue's next turn rather than right away: an appearance method can run
    /// inside a SwiftUI update — SwiftUI pushes and presents from one — where publishing
    /// is not allowed. The turn also folds the dozen callbacks of one transition into one
    /// reading. Not a delay: nothing waits for anything to settle.
    static func setNeedsEvaluation() {
        guard !isEvaluationScheduled else { return }
        isEvaluationScheduled = true
        DispatchQueue.main.async {
            isEvaluationScheduled = false
            evaluate()
        }
    }

    private static func evaluate() {
        var coveredRoots: [ObjectIdentifier: (visibility: RootTabBarVisibility, tabs: Set<String>)] = [:]
        for anchor in anchors.allObjects {
            guard let coverage = anchor.coverage() else { continue }
            let key = ObjectIdentifier(coverage.visibility)
            var entry = coveredRoots[key] ?? (coverage.visibility, [])
            switch coverage.state {
            case .covered:
                entry.tabs.insert(coverage.tab)
            case .undecided:
                if coverage.visibility.isRootCovered(coverage.tab) { entry.tabs.insert(coverage.tab) }
            case .uncovered:
                break
            }
            coveredRoots[key] = entry
        }
        for visibility in reported.allObjects where coveredRoots[ObjectIdentifier(visibility)] == nil {
            visibility.setCoveredRoots([])
            reported.remove(visibility)
        }
        for entry in coveredRoots.values {
            entry.visibility.setCoveredRoots(entry.tabs)
            reported.add(entry.visibility)
        }
    }

    private static let appearanceHooks: Void = {
        hook(#selector(UIViewController.viewWillAppear(_:)))
        hook(#selector(UIViewController.viewWillDisappear(_:)))
        hook(#selector(UIViewController.viewDidDisappear(_:)))
    }()

    private static func hook(_ selector: Selector) {
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else {
            AppLogger.error("⟐ tab bar: no UIViewController method to hook", context: ["selector": NSStringFromSelector(selector)])
            return
        }
        typealias AppearanceIMP = @convention(c) (UIViewController, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: AppearanceIMP.self)
        let replacement: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
            original(controller, selector, animated)
            MainActor.assumeIsolated { setNeedsEvaluation() }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
