import Combine
import Testing
import UIKit
@testable import yuedu_app

/// The bottom tab bar shows on a tab's root page only: a page pushed over the root, or
/// presented over it, hides it. A menu is not a page.
@Suite("Root tab bar on tab roots only", .serialized)
@MainActor
struct RootTabBarRootOnlyTests {
    @Test("A covered root hides the tab bar only while its tab is selected")
    func coveredRootOfSelectedTab() {
        let visibility = RootTabBarVisibility()
        visibility.setSelectedTab("bookshelf")
        #expect(!visibility.isTabBarHidden)
        visibility.setCoveredRoots(["settings"])
        #expect(!visibility.isTabBarHidden)
        visibility.setCoveredRoots(["bookshelf", "settings"])
        #expect(visibility.isTabBarHidden)
        visibility.setSelectedTab("explore")
        #expect(!visibility.isTabBarHidden)
        visibility.setSelectedTab("settings")
        #expect(visibility.isTabBarHidden)
        visibility.setCoveredRoots([])
        #expect(!visibility.isTabBarHidden)
    }

    @Test("Where the tab bar sits at the top, only a screen's own request hides it")
    func topTabBarKeepsRequestsOnly() {
        let visibility = RootTabBarVisibility()
        visibility.setSelectedTab("bookshelf")
        visibility.setHidesOverCoveredRoot(false)
        visibility.setCoveredRoots(["bookshelf"])
        #expect(!visibility.isTabBarHidden)
        let request = UUID()
        visibility.setRequest(request, hidesTabBar: true)
        #expect(visibility.isTabBarHidden)
        visibility.setRequest(request, hidesTabBar: false)
        #expect(!visibility.isTabBarHidden)
        visibility.setHidesOverCoveredRoot(true)
        #expect(visibility.isTabBarHidden)
    }

    @Test("A page pushed over the root covers it, and popping back uncovers it")
    func pushCoversRoot() {
        let root = UIViewController()
        // The anchor's view controller can sit inside the stack's entry.
        let page = UIViewController()
        root.addChild(page)
        let navigation = UINavigationController(rootViewController: root)
        #expect(TabRootCoverage.state(of: page, windowRoot: navigation) == .uncovered)
        navigation.pushViewController(UIViewController(), animated: false)
        #expect(TabRootCoverage.state(of: page, windowRoot: navigation) == .covered)
        navigation.popViewController(animated: false)
        #expect(TabRootCoverage.state(of: page, windowRoot: navigation) == .uncovered)
    }

    @Test("Pages, popovers included, count as covering the root; menus, alerts and the search controller do not")
    func whatCoversRoot() throws {
        #expect(TabRootCoverage.coversRoot(UIViewController()))
        #expect(TabRootCoverage.coversRoot(UINavigationController(rootViewController: UIViewController())))
        #expect(TabRootCoverage.coversRoot(makePopover()))
        #expect(!TabRootCoverage.coversRoot(try makeUIKitPrivateController()))
        #expect(!TabRootCoverage.coversRoot(UIAlertController(title: "", message: nil, preferredStyle: .alert)))
        #expect(!TabRootCoverage.coversRoot(UIAlertController(title: "", message: nil, preferredStyle: .actionSheet)))
        #expect(!TabRootCoverage.coversRoot(UISearchController(searchResultsController: nil)))
    }

    @Test("A sheet presented over the root covers it until it is dismissed; an alert does not")
    func presentationCoversRoot() async throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try makeWindow(root: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }

        await present(UIViewController(), from: root)
        #expect(TabRootCoverage.state(of: root, windowRoot: navigation) == .covered)
        await dismiss(from: root)
        #expect(TabRootCoverage.state(of: root, windowRoot: navigation) == .uncovered)

        await present(UIAlertController(title: "", message: nil, preferredStyle: .alert), from: root)
        #expect(TabRootCoverage.state(of: root, windowRoot: navigation) == .uncovered)
        await dismiss(from: root)
    }

    @Test("A sheet covers the root where it reaches a tab bar at the bottom, not where it floats clear")
    func sheetCoversRootWhereItReachesTabBar() async throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try makeWindow(root: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let tabBar = CGRect(x: 0, y: window.bounds.maxY - 83, width: window.bounds.width, height: 83)
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .formSheet

        await present(sheet, from: root)
        // A compact width (an iPhone) raises the sheet from the bottom edge, over the tab
        // bar; a regular one (an iPad) floats it in the middle of the window.
        let reachesTabBar = window.traitCollection.horizontalSizeClass == .compact
        #expect(TabRootCoverage.coversRoot(sheet, tabBar: tabBar) == reachesTabBar)
        await dismiss(from: root)
    }

    /// iOS 17's SwiftUI TabView leaves the window's root out of the root page's
    /// ancestors, so a sheet the app presents from there reaches the page only through
    /// the window.
    @Test("A sheet the window's root presents covers a root page outside its ancestors")
    func windowRootPresentationCoversRoot() async throws {
        let container = UIViewController()
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        container.view.addSubview(navigation.view)
        let window = try makeWindow(root: container)
        defer { window.isHidden = true; window.rootViewController = nil }

        await present(UIViewController(), from: container)
        #expect(root.presentedViewController == nil)
        #expect(TabRootCoverage.state(of: root, windowRoot: container) == .covered)
        await dismiss(from: container)
        #expect(TabRootCoverage.state(of: root, windowRoot: container) == .uncovered)
    }

    @Test("Pushing, popping, presenting and dismissing reach the tab bar", .timeLimit(.minutes(1)))
    func transitionsReachTabBar() async throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = try makeWindow(root: navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let visibility = RootTabBarVisibility()
        visibility.setSelectedTab("tab")
        let anchor = TabRootCoverageAnchor()
        anchor.reports(to: visibility, as: "tab")
        root.view.addSubview(anchor)
        defer { TabRootCoverageMonitor.unregister(anchor) }
        // The root page is on screen before anything covers it, as in the app: the
        // navigation controller puts its root's view on the window at its first layout.
        window.layoutIfNeeded()
        try #require(anchor.window === window)
        await waitUntil(visibility, isTabBarHidden: false)

        navigation.pushViewController(UIViewController(), animated: false)
        await waitUntil(visibility, isTabBarHidden: true)
        navigation.popViewController(animated: false)
        await waitUntil(visibility, isTabBarHidden: false)

        await present(UIViewController(), from: root)
        await waitUntil(visibility, isTabBarHidden: true)
        await dismiss(from: root)
        await waitUntil(visibility, isTabBarHidden: false)
    }

    // MARK: - Helpers

    /// Stands in for the private controller UIKit presents a menu as, which a test cannot
    /// create: a view controller of a class with a UIKit-private name.
    private func makeUIKitPrivateController() throws -> UIViewController {
        let name = "_UIYueduTestMenuViewController"
        if NSClassFromString(name) == nil, let subclass = objc_allocateClassPair(UIViewController.self, name, 0) {
            objc_registerClassPair(subclass)
        }
        let menuClass: AnyClass = try #require(NSClassFromString(name))
        let controller = UIViewController()
        object_setClass(controller, menuClass)
        return controller
    }

    private func makePopover() -> UIViewController {
        let popover = UIViewController()
        popover.modalPresentationStyle = .popover
        return popover
    }

    private func makeWindow(root: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private func present(_ page: UIViewController, from presenter: UIViewController) async {
        await withCheckedContinuation { continuation in
            presenter.present(page, animated: false) { continuation.resume() }
        }
    }

    private func dismiss(from presenter: UIViewController) async {
        await withCheckedContinuation { continuation in
            presenter.dismiss(animated: false) { continuation.resume() }
        }
    }

    private func waitUntil(_ visibility: RootTabBarVisibility, isTabBarHidden: Bool) async {
        for await hidden in visibility.$isTabBarHidden.values where hidden == isTabBarHidden { break }
    }
}
