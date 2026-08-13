import Testing
import Foundation
import UIKit
@testable import yuedu_app

/// Covers the opening-transition gate that keeps non-first-page reader work
/// (neighbour pagination, cover decode) out of the card animation's render
/// pass. The gate's dangerous failure is parking a waiter that nothing will
/// ever release — that would stall an ordinary page turn forever, so both
/// tests here pin the "never latches closed" side of the contract.
///
/// The in-flight half (gate closed for the duration of a real push, waiters
/// released on commit) depends on UIKit transition timing and is verified on
/// device through the `⏱ reader.open.transition` and
/// `⏱ reader.open.deferredPreload` spans instead of a flaky unit test.
@MainActor
@Suite("ReaderNavigationCoordinator opening gate", .serialized)
struct ReaderNavigationOpeningGateTests {

    @Test("an idle coordinator never parks a waiter")
    func idleGateReturnsImmediately() async {
        let coordinator = ReaderNavigationCoordinator()
        #expect(coordinator.isOpeningTransitionActive == false)
        // Reaching the next line at all is the assertion: a gate that parked
        // here would hang every page turn made on a settled reader.
        await coordinator.awaitOpeningTransitionEnd()
        #expect(coordinator.isOpeningTransitionActive == false)
    }

    @Test("an open that never starts a push leaves the gate open")
    func refusedOpenDoesNotCloseGate() async {
        // No navigation controller attached, so the push can never start. The
        // gate must not latch closed here: nothing would ever reopen it, and
        // every later deferred preload would park permanently.
        let coordinator = ReaderNavigationCoordinator()
        coordinator.open(
            bookID: UUID(),
            destination: { UIViewController() }
        )
        #expect(coordinator.isOpeningTransitionActive == false)
        await coordinator.awaitOpeningTransitionEnd()
    }
}
