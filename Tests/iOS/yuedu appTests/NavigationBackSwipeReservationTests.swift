import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// The reader's shape: a full-screen UIKit page under SwiftUI bars at the top and the bottom.
private struct PageUnderBars: View {
    let page: UIView

    var body: some View {
        ZStack {
            HostedPage(page: page).ignoresSafeArea()
            VStack {
                Button("退出閱讀") {}
                Spacer()
                Button("設定") {}
            }
        }
    }
}

/// What the app wraps a reader's page in, each of which can move a bottom bar after the page
/// for VoiceOver.
enum ReaderPageProbe: CaseIterable {
    case backSwipeReservation
    case rootTabBarTransitionCover
    case rootTabBarHiding
    case rootTabBarHiddenFromTab
}

private struct HostedPage: UIViewRepresentable {
    let page: UIView
    func makeUIView(context: Context) -> UIView { page }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class OriginalBackDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { true }
    @objc func upstreamOnlyEventGate() -> Bool { false }
}

@Suite("Navigation back swipe reservation", .serialized)
@MainActor
struct NavigationBackSwipeReservationTests {
    @Test("native and book-card navigation share the same reserved start region")
    func sharedStartRegion() {
        for x: CGFloat in [-1, 0, 8, 18, 30, 31, 120] {
            for translation in [CGPoint.zero, CGPoint(x: 10, y: 2), CGPoint(x: 2, y: 10), CGPoint(x: -5, y: 0)] {
                #expect(NavigationBackSwipePolicy.shouldBegin(initialX: x, translation: translation, containerWidth: 400)
                    == ReaderCardTransitionMath.shouldBeginEdgeSwipe(initialX: x, translationX: translation.x, translationY: translation.y, containerWidth: 400))
            }
        }
        #expect(NavigationBackSwipePolicy.shouldBegin(initialX: 18, translation: CGPoint(x: 50, y: 5), containerWidth: 400))
        #expect(!NavigationBackSwipePolicy.shouldBegin(initialX: 31, translation: CGPoint(x: 50, y: 5), containerWidth: 400))
        #expect(!NavigationBackSwipePolicy.shouldBegin(initialX: 10, translation: CGPoint(x: 5, y: 50), containerWidth: 400))
        #expect(!NavigationBackSwipePolicy.contains(initialX: 0, containerWidth: 0))
    }

    @Test("a cover's edge swipe closes when it goes far or fast enough, not when pulled back (FB-206)")
    func coverCloseThreshold() {
        // Far enough, slowly.
        #expect(NavigationBackSwipePolicy.completesClose(
            translation: CGPoint(x: 80, y: 10), velocity: .zero, containerWidth: 1024))
        // Short, but flicked.
        #expect(NavigationBackSwipePolicy.completesClose(
            translation: CGPoint(x: 20, y: 0), velocity: CGPoint(x: 500, y: 0), containerWidth: 1024))
        // Short and slow.
        #expect(!NavigationBackSwipePolicy.completesClose(
            translation: CGPoint(x: 79, y: 0), velocity: CGPoint(x: 499, y: 0), containerWidth: 1024))
        // Pulled back toward the edge as it lifts.
        #expect(!NavigationBackSwipePolicy.completesClose(
            translation: CGPoint(x: 200, y: 0), velocity: CGPoint(x: -50, y: 0), containerWidth: 1024))
        // Mostly vertical.
        #expect(!NavigationBackSwipePolicy.completesClose(
            translation: CGPoint(x: 100, y: 150), velocity: CGPoint(x: 900, y: 0), containerWidth: 1024))
        #expect(!NavigationBackSwipePolicy.completesClose(
            translation: CGPoint(x: 100, y: 0), velocity: .zero, containerWidth: 0))
    }

    @Test("hidden chrome gets native back without a navigation delegate or new recognizer")
    func enablesNativeBackAndRestoresOwnership() throws {
        let root = UIViewController(), reader = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        nav.setViewControllers([root, reader], animated: false)
        nav.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let gesture = try #require(NavigationBackSwipeReservationController.backGesture(in: nav))
        let original = OriginalBackDelegate()
        gesture.delegate = original
        gesture.isEnabled = false
        reader.navigationItem.hidesBackButton = true
        nav.setNavigationBarHidden(true, animated: false)
        let navDelegate = nav.delegate
        let recognizers = nav.view.gestureRecognizers?.count
        let reservation = NavigationBackSwipeReservationController()
        let alternatePop = if #available(iOS 26.0, *) { nav.interactivePopGestureRecognizer } else { nil as UIGestureRecognizer? }
        alternatePop?.isEnabled = true
        reservation.attach(to: nav, destination: reader)
        #expect(gesture.delegate === reservation)
        #expect(gesture.isEnabled)
        if let alternatePop { #expect(!alternatePop.isEnabled) }
        #expect(nav.delegate === navDelegate)
        #expect(nav.view.gestureRecognizers?.count == recognizers)
        #expect(reservation.gestureRecognizerShouldBegin(gesture))
        let delegate: any UIGestureRecognizerDelegate = reservation
        #expect(delegate.gestureRecognizer?(gesture, shouldReceive: UIEvent()) ?? true)
        #expect(!(delegate.gestureRecognizer?(gesture, shouldRequireFailureOf: UIPanGestureRecognizer()) ?? false))
        #expect(!reservation.responds(to: #selector(OriginalBackDelegate.upstreamOnlyEventGate)))
        #expect(reservation.gestureRecognizer(gesture, shouldBeRequiredToFailBy: UIPanGestureRecognizer()))
        #expect(!reservation.gestureRecognizer(gesture, shouldBeRequiredToFailBy: UITapGestureRecognizer()))
        reservation.detach()
        #expect(gesture.delegate === original)
        #expect(!gesture.isEnabled)
        if let alternatePop { #expect(alternatePop.isEnabled) }
    }

    @Test("book-card edge recognizer gives pans priority but leaves taps ungated")
    func cardGesturePriority() {
        let edge = NavigationBackEdgePanGestureRecognizer()
        #expect(edge.shouldBeRequiredToFail(by: UIPanGestureRecognizer()))
        #expect(!edge.canBePrevented(by: UIPanGestureRecognizer()))
        #expect(!edge.shouldBeRequiredToFail(by: UITapGestureRecognizer()))
    }

    @Test("refresh reapplies edge-only arbitration and restores an originally disabled alternate pop")
    @available(iOS 26.0, *)
    func preservesDisabledAlternatePop() throws {
        let reader = UIViewController()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.setViewControllers([nav.viewControllers[0], reader], animated: false)
        nav.loadViewIfNeeded()
        let alternatePop = try #require(nav.interactivePopGestureRecognizer)
        alternatePop.isEnabled = false
        let reservation = NavigationBackSwipeReservationController()
        reservation.attach(to: nav, destination: reader)
        alternatePop.isEnabled = true
        reservation.attach(to: nav, destination: reader)
        #expect(!alternatePop.isEnabled)
        reservation.detach()
        #expect(!alternatePop.isEnabled)
    }

    @Test("covered pages cannot pop and adjacent reservations restore UIKit's delegate")
    func adjacentDestinationsTransferOwnership() throws {
        let root = UIViewController(), first = UIViewController(), second = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        nav.setViewControllers([root, first], animated: false)
        nav.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let gesture = try #require(NavigationBackSwipeReservationController.backGesture(in: nav))
        let original = OriginalBackDelegate()
        gesture.delegate = original
        let alternatePop = if #available(iOS 26.0, *) { nav.interactivePopGestureRecognizer } else { nil as UIGestureRecognizer? }
        alternatePop?.isEnabled = true
        let a = NavigationBackSwipeReservationController(), b = NavigationBackSwipeReservationController()
        a.attach(to: nav, destination: first)
        nav.setViewControllers([root, first, second], animated: false)
        #expect(!a.gestureRecognizerShouldBegin(gesture))
        b.attach(to: nav, destination: second)
        a.detach()
        #expect(gesture.delegate === b)
        if let alternatePop { #expect(!alternatePop.isEnabled) }
        b.detach()
        #expect(gesture.delegate === original)
        if let alternatePop { #expect(alternatePop.isEnabled) }
    }

    /// Feedback #15: with the reservation in a background, VoiceOver's touch on a detail-pushed
    /// reader's bottom bar landed on the page (see `reservingNavigationBackSwipe`). XCUITest does
    /// not see this — its tree has its own order, and it called the bar hittable throughout — so
    /// this reads the hosting view's own accessibility elements. Everything else the app wraps
    /// a reader's page in is held to the same, in a stack of its own and in a tab's.
    @Test(
        "a page the app wraps leaves its bottom bar to VoiceOver's touch",
        arguments: ReaderPageProbe.allCases, [false, true]
    )
    func reservationKeepsBottomBarTouchable(_ probe: ReaderPageProbe, inTabView: Bool) async throws {
        let hidden = RootTabBarVisibility()
        hidden.setRequest(UUID(), hidesTabBar: true)
        let order = try await voiceOverOrder(inTabView: inTabView) { page in
            switch probe {
            case .backSwipeReservation: PageUnderBars(page: page).reservingNavigationBackSwipe()
            case .rootTabBarTransitionCover:
                PageUnderBars(page: page).modifier(RootTabBarTransitionCovering(hidesTabBar: true))
            // The whole of `hidesRootTabBar()`. Until 2026-11-14 an `accessibilityHidden` on
            // the clear colour in its background put 設定 after the page here; the app's
            // reader, built differently, was not affected.
            case .rootTabBarHiding: PageUnderBars(page: page).hidesRootTabBar()
            // What `ContentView` puts behind every tab while any page hides the bar.
            case .rootTabBarHiddenFromTab: PageUnderBars(page: page).background { RootTabBarHider(visibility: hidden) }
            }
        }
        #expect(try #require(order.firstIndex(of: "設定")) < (try #require(order.firstIndex(of: Self.pageLabel))), "\(order)")
    }

    private static let pageLabel = "正文"

    /// The labels of a pushed page's accessibility elements, in the order VoiceOver's touch
    /// tries them: the page built by `content` around a full-screen UIKit view labelled 正文.
    private func voiceOverOrder<Content: View>(
        inTabView: Bool, @ViewBuilder content: @escaping (UIView) -> Content
    ) async throws -> [String] {
        let page = UIView()
        page.isAccessibilityElement = true
        page.accessibilityLabel = Self.pageLabel
        // SwiftUI builds no accessibility elements until something reads them — VoiceOver, or
        // XCUITest's automation. Turned on here as XCUITest does it, and back off after.
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let automationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setAutomationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let wasEnabled = automationEnabled()
        setAutomationEnabled(true)
        defer { setAutomationEnabled(wasEnabled) }

        let stack = NavigationStack(path: .constant([1])) {
            Color.clear.navigationDestination(for: Int.self) { _ in content(page) }
        }
        let root: UIViewController = inTabView
            ? UIHostingController(rootView: TabView { stack.tabItem { Label("One", systemImage: "1.circle") } })
            : UIHostingController(rootView: stack)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        // The accessibility elements of the view hosting the page: the page (or the UIKit view
        // holding it) and the bars' SwiftUI elements. VoiceOver's touch takes the first of them
        // under the finger (seen in the app with lldb), so 設定 has to come before the page.
        func hostedElements() -> [NSObject]? {
            var view = page.superview
            while let host = view {
                if let elements = host.accessibilityElements as? [NSObject],
                   elements.contains(where: { ($0 as? UIView).map(page.isDescendant(of:)) ?? false }),
                   elements.contains(where: { $0.accessibilityLabel == "設定" }) {
                    return elements
                }
                view = host.superview
            }
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var found = hostedElements()
        while found == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            found = hostedElements()
        }
        let elements = try #require(found, "the pushed page never reached the accessibility tree")
        return elements.map { element in
            if let view = element as? UIView, page.isDescendant(of: view) { return Self.pageLabel }
            return element.accessibilityLabel ?? String(describing: type(of: element))
        }
    }

    @Test("root pages do not take over the system recognizer")
    func rootPageRemainsUntouched() throws {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let gesture = try #require(NavigationBackSwipeReservationController.backGesture(in: nav))
        let original = gesture.delegate
        let reservation = NavigationBackSwipeReservationController()
        reservation.attach(to: nav, destination: root)
        #expect(gesture.delegate === original)
    }
}
