import Testing
import UIKit
@testable import yuedu_app

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
    func preservesDisabledAlternatePop() throws {
        guard #available(iOS 26.0, *) else { return }
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
