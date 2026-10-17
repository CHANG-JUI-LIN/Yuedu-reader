import Combine
import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

// The contract `ContentView.rootStack` is built on (maintainer, 2026-10-16): one
// NavigationStack around the tab bar, so every pushed page covers it. What a tab's page
// declares for the bar does not reach that stack's bar, so the selected tab's title and
// every destination are declared on the tab bar itself. Measured on iOS 17.5, 18.6, 26.5
// and 27 before the app was moved onto it.
//
// 書架's card reader is pushed onto that stack by UIKit (`ReaderNavigationTransitionDriver`),
// not by the stack's path; the second half of this file is what it relies on.

@MainActor
private final class ContractState: ObservableObject {
    @Published var path = NavigationPath()
    @Published var tab = 0
    /// One entry each time tab A's page appears, with its `@State` identity.
    var identities: [UUID] = []
    var onAppear: (String) -> Void = { _ in }
}

private struct RouteOnTabBar: Hashable {}
private struct RouteInTab: Hashable {}
private struct RouteWithBottomBar: Hashable {}

/// Reports `viewDidAppear`: the page is on screen, not just built.
private struct AppearanceProbe: UIViewControllerRepresentable {
    let appeared: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(appeared: appeared) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.appeared = appeared }

    final class Controller: UIViewController {
        var appeared: () -> Void
        init(appeared: @escaping () -> Void) {
            self.appeared = appeared
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared()
        }
    }
}

private extension View {
    func reportsAppearance(_ name: String, to state: ContractState) -> some View {
        background(AppearanceProbe { state.onAppear(name) }.frame(width: 0, height: 0))
    }
}

private struct ContractTabA: View {
    @ObservedObject var state: ContractState
    @State private var identity = UUID()

    var body: some View {
        Text("Tab A")
            .reportsAppearance("tabA", to: state)
            .onAppear {
                state.identities.append(identity)
                state.onAppear("tabA.onAppear")
            }
    }
}

private struct ContractFixture: View {
    @ObservedObject var state: ContractState
    let fade: RootTabTitleFade

    var body: some View {
        NavigationStack(path: $state.path) {
            TabView(selection: $state.tab) {
                ContractTabA(state: state)
                    .tag(0)
                    .tabItem { Text("A") }
                Text("Tab B")
                    .reportsAppearance("tabB", to: state)
                    .navigationTitle("Tab B's own title")
                    .navigationDestination(for: RouteInTab.self) { _ in
                        Text("Pushed from a tab's destination").reportsAppearance("pushedInTab", to: state)
                    }
                    .tag(1)
                    .tabItem { Text("B") }
            }
            .rootTabTitle(state.tab == 0 ? "Title A" : "Title B", onScroll: .fadesTitle, fade: fade)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Text("Trailing") }
            }
            .navigationDestination(for: RouteOnTabBar.self) { _ in
                Text("Pushed").reportsAppearance("pushed", to: state)
            }
            .navigationDestination(for: RouteWithBottomBar.self) { _ in
                Text("Pushed with a bottom bar")
                    .reportsAppearance("pushedWithBottomBar", to: state)
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) { Text("Bottom") }
                    }
            }
        }
    }
}

/// Whether the card reader's controls are up, as a tap on its page toggles them.
@MainActor
private final class ReaderChrome: ObservableObject {
    @Published var shows = false
}

/// Stands in for `ReaderView` and `FixedPageReaderView`: UIKit page controllers inside
/// `ReaderNavigationContainer`, with the reader's bars declared the way they declare them.
private struct CardReaderPage: View {
    @ObservedObject var chrome: ReaderChrome

    var body: some View {
        ReaderNavigationContainer {
            Text("Reader")
                .background(PageControllers().frame(width: 0, height: 0))
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Close") {} }
                    ToolbarItem(placement: .bottomBar) { Button("Contents") {} }
                }
                .toolbar(chrome.shows ? .visible : .hidden, for: .navigationBar)
                .toolbar(chrome.shows ? .visible : .hidden, for: .bottomBar)
        }
    }
}

/// The reader's pages are UIKit controllers. Without one inside, a reader with a stack
/// of its own stays on the root stack too.
private struct PageControllers: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

@MainActor
final class RootTabNavigationContractTests: XCTestCase {
    private var state: ContractState!
    private var host: UIHostingController<ContractFixture>!
    private var window: UIWindow!
    private var previousWindow: UIWindow?
    private var driver: ReaderNavigationTransitionDriver?

    override func setUp() async throws {
        state = ContractState()
        host = UIHostingController(rootView: ContractFixture(state: state, fade: RootTabTitleFade()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.rootViewController = host
        let shown = await appears("tabA") { window.makeKeyAndVisible() }
        XCTAssertTrue(shown, "The first tab never appeared")
    }

    override func tearDown() async throws {
        driver?.detach()
        driver = nil
        window?.isHidden = true
        window?.rootViewController = nil
        previousWindow?.makeKey()
        window = nil
        host = nil
        state = nil
    }

    /// Every page a tab pushes is registered once, on the tab bar, and opens whichever tab is
    /// selected — the 搜索 tab's works while 書架 is the only tab ever shown, say.
    func testDestinationOnTheTabBarOpensFromANeverSelectedTab() async {
        let pushed = await appears("pushed") { state.path.append(RouteOnTabBar()) }

        XCTAssertTrue(pushed)
        XCTAssertEqual(rootNavigationController?.viewControllers.count, 2)
    }

    /// The bar shows the selected tab's title, set on the tab bar; a tab page's own title
    /// never reaches it.
    func testTitleOnTheTabBarFollowsTheSelectedTab() async {
        XCTAssertEqual(rootNavigationController?.navigationBar.topItem?.title, "Title A")

        let shown = await appears("tabB") { state.tab = 1 }

        XCTAssertTrue(shown)
        XCTAssertEqual(rootNavigationController?.navigationBar.topItem?.title, "Title B")
    }

    /// Switching tabs keeps each tab's page and its state: nothing above the tab bar
    /// changes its identity with the selection.
    func testTabKeepsItsStateAcrossTabSwitches() async {
        _ = await appears("tabB") { state.tab = 1 }
        let back = await appears("tabA") { state.tab = 0 }

        XCTAssertTrue(back)
        XCTAssertEqual(Set(state.identities).count, 1)
    }

    /// Coming back from a pushed page brings the tab's page back into view, and its `onAppear`
    /// runs again: 探索 reloads 繼續閱讀 there, 設定 ends an appearance preview.
    func testTabPageAppearsAgainAfterAPop() async {
        _ = await appears("pushed") { state.path.append(RouteOnTabBar()) }

        let back = await appears("tabA.onAppear") { state.path.removeLast() }

        XCTAssertTrue(back)
        XCTAssertEqual(state.identities.count, 2)
        XCTAssertEqual(Set(state.identities).count, 1)
    }

    /// Why every destination is on the tab bar: from iOS 26 one declared by a tab's page is
    /// not there at all. (iOS 17 still finds it.)
    func testDestinationInsideATabIsIgnoredFromIOS26() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("iOS 17 and 18 still find a tab page's destination")
        }
        _ = await appears("tabB") { state.tab = 1 }

        let pushed = await appears("pushedInTab", timeout: 2) { state.path.append(RouteInTab()) }

        XCTAssertFalse(pushed)
    }

    /// A pushed page's bottom bar is the root stack's own toolbar, over the tab bar: the
    /// readers' progress controls are one. (iOS 26 draws that toolbar's items without a
    /// `UIToolbar` in the window, so the stack's state is what is checked.)
    func testPushedPageBottomBarIsTheStacksToolbar() async throws {
        let pushed = await appears("pushedWithBottomBar") { state.path.append(RouteWithBottomBar()) }
        XCTAssertTrue(pushed)
        let navigation = try XCTUnwrap(rootNavigationController)

        XCTAssertFalse(navigation.isToolbarHidden)
        XCTAssertGreaterThan(navigation.topViewController?.toolbarItems?.count ?? 0, 0)
    }

    // MARK: 書架's card reader

    /// The card reader stays on the root stack once its push is over. It reopened 書架 at
    /// once when it still had a NavigationStack of its own (2026-10-17).
    func testCardReaderStaysOnTheRootStack() async throws {
        let (navigation, reader) = try await pushCardReader(navigator: ReaderNavigationCoordinator())

        XCTAssertTrue(navigation.topViewController === reader)
        XCTAssertEqual(navigation.viewControllers.count, 2)
    }

    /// Why the card reader joins the root stack instead of wrapping itself in one, as a
    /// modal reader does: from iOS 18, SwiftUI takes a UIKit-pushed page whose content is a
    /// NavigationStack around UIKit controllers off a stack that registers a
    /// `navigationDestination(for:)`. Without a destination, or on iOS 17.5, it stays.
    func testAReaderWithItsOwnStackIsTakenOffTheRootStackFromIOS18() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("iOS 17 leaves a pushed page with its own stack where it is")
        }
        // No navigator: `ReaderNavigationContainer` gives the reader a stack, as for a modal.
        let (navigation, reader) = try await pushCardReader(navigator: nil)

        XCTAssertFalse(navigation.topViewController === reader)
    }

    /// The reader's toolbar modifiers drive the root stack's bars: hidden while it opens,
    /// shown with its controls, hidden again with them.
    func testCardReaderBarsFollowItsControls() async throws {
        let chrome = ReaderChrome()
        var barHiddenAsTheCardOpens: Bool?
        let (navigation, reader) = try await pushCardReader(
            chrome: chrome,
            navigator: ReaderNavigationCoordinator(),
            beforeTheCardOpens: { barHiddenAsTheCardOpens = $0.isNavigationBarHidden }
        )
        XCTAssertEqual(barHiddenAsTheCardOpens, true, "The root page's bar must not ride over the opening card")
        XCTAssertTrue(navigation.isNavigationBarHidden)
        XCTAssertTrue(navigation.isToolbarHidden)

        chrome.shows = true

        let shown = await becomes { !navigation.isNavigationBarHidden && !navigation.isToolbarHidden }
        XCTAssertTrue(shown, "The reader's controls did not bring its bars")
        XCTAssertEqual(reader.navigationItem.leadingItemGroups.flatMap(\.barButtonItems).count, 1)
        XCTAssertEqual(reader.toolbarItems?.count, 1)

        chrome.shows = false

        let hidden = await becomes { navigation.isNavigationBarHidden && navigation.isToolbarHidden }
        XCTAssertTrue(hidden, "Putting the reader's controls away left its bars up")
    }

    /// Closing the reader gives the root page its bar back, with the tab's title.
    func testRootBarComesBackWhenTheCardReaderCloses() async throws {
        let (navigation, _) = try await pushCardReader(navigator: ReaderNavigationCoordinator())
        let driver = try XCTUnwrap(driver)
        let popped = expectation(description: "pop completed")
        driver.onPopTransitionCompleted = { completed in
            XCTAssertTrue(completed)
            popped.fulfill()
        }

        XCTAssertTrue(driver.startProgrammaticPop())
        await fulfillment(of: [popped], timeout: 5)

        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertTrue(navigation.isToolbarHidden)
        XCTAssertEqual(navigation.navigationBar.topItem?.title, "Title A")
    }

    /// A detail page above the reader shows its own bar, and the reader's bars are what
    /// its controls say again when the detail is popped — up or away.
    func testCardReaderBarsComeBackAfterADetailPage() async throws {
        let chrome = ReaderChrome()
        let (navigation, reader) = try await pushCardReader(chrome: chrome, navigator: ReaderNavigationCoordinator())
        let driver = try XCTUnwrap(driver)

        for controlsUp in [true, false] {
            chrome.shows = controlsUp
            let applied = await becomes { navigation.isNavigationBarHidden == !controlsUp }
            XCTAssertTrue(applied)
            let detail = UIHostingController(rootView: Text("Detail").toolbar(.visible, for: .navigationBar))

            XCTAssertTrue(driver.pushDetail(detail, above: reader))
            let detailShown = await becomes { navigation.topViewController === detail && navigation.transitionCoordinator == nil }
            XCTAssertTrue(detailShown)
            XCTAssertFalse(navigation.isNavigationBarHidden, "The detail page has a bar of its own")

            XCTAssertTrue(driver.popDetail(detail, returningTo: reader))
            let readerShown = await becomes { navigation.topViewController === reader && navigation.transitionCoordinator == nil }
            XCTAssertTrue(readerShown)
            XCTAssertEqual(navigation.isNavigationBarHidden, !controlsUp, "Controls up: \(controlsUp)")
            XCTAssertEqual(navigation.isToolbarHidden, !controlsUp, "Controls up: \(controlsUp)")
        }
    }

    // MARK: Helpers

    private var rootNavigationController: UINavigationController? {
        navigationControllers(in: host).first
    }

    /// Opens a `CardReaderPage` the way 書架 opens a book — the card driver and its
    /// animator pushing a `ReaderHostingController` onto the root stack — and returns once
    /// the push has completed and the stack has settled after it.
    private func pushCardReader(
        chrome: ReaderChrome? = nil,
        navigator: ReaderNavigationCoordinator?,
        beforeTheCardOpens: @escaping @MainActor (UINavigationController) -> Void = { _ in }
    ) async throws -> (UINavigationController, ReaderHostingController) {
        let navigation = try XCTUnwrap(rootNavigationController)
        let driver = ReaderNavigationTransitionDriver()
        self.driver = driver
        driver.sourceProvider = { ReaderTransitionSource(bookID: UUID()) }
        driver.contentReadyGate = { beforeTheCardOpens(navigation) }
        driver.attach(to: navigation)
        // The settle that counts is the one after the push: the driver schedules one when
        // the push completes, after any it scheduled before.
        let settled = expectation(description: "push completed and the stack settled")
        var pushCompleted = false
        driver.onPushTransitionCompleted = { completed in
            XCTAssertTrue(completed)
            pushCompleted = true
        }
        driver.onNavigationTransitionSettled = {
            guard pushCompleted else { return }
            pushCompleted = false
            settled.fulfill()
        }
        let reader = ReaderHostingController(content: AnyView(
            CardReaderPage(chrome: chrome ?? ReaderChrome()).environment(\.readerNavigator, navigator)
        ))

        XCTAssertTrue(driver.startPush(reader, animated: true))
        await fulfillment(of: [settled], timeout: 5)
        window.layoutIfNeeded()
        return (navigation, reader)
    }

    /// Waits for `condition`, checking it once per main-queue turn, and reports whether it
    /// held within `timeout`.
    private func becomes(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let met = expectation(description: "condition")
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() {
                met.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.async { check() }
            }
        }
        check()
        return await XCTWaiter().fulfillment(of: [met], timeout: timeout + 1) == .completed
    }

    private func appears(_ name: String, timeout: TimeInterval = 3, action: () -> Void) async -> Bool {
        let appeared = expectation(description: name)
        appeared.assertForOverFulfill = false
        state.onAppear = { if $0 == name { appeared.fulfill() } }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
        return await XCTWaiter().fulfillment(of: [appeared], timeout: timeout) == .completed
    }

    private func navigationControllers(in root: UIViewController) -> [UINavigationController] {
        ((root as? UINavigationController).map { [$0] } ?? []) + root.children.flatMap { navigationControllers(in: $0) }
    }
}
