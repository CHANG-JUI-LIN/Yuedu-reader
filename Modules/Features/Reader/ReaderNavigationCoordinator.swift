import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - ReaderNavigationCoordinator
//
// Owns reader push/pop requests, the directly-pushed UIKit destination, and
// source-card metadata for the active book. HomeView supplies a destination
// factory; this coordinator waits for the shelf navigation controller and then
// asks `ReaderNavigationTransitionDriver` to atomically own the push.
//
// The coordinator holds no strong reference cycle among the navigation
// controller, hosting controller, source view, or animator. Source providers
// are expected to capture weakly; `clearSource()` is idempotent and safe to
// call on both successful completion and cancellation.

@MainActor
final class ReaderNavigationCoordinator: ObservableObject {
    /// Retained identity for the reader destination. It stays non-nil through
    /// the closing animation so the animator and reader session keep the same
    /// book on an interactive cancel.
    @Published private(set) var readerBookID: UUID?

    /// Presentation state becomes true only after a UIKit push starts. During
    /// a pop it remains true until UIKit confirms completion.
    @Published private(set) var isReaderPresented = false

    /// The transition source recorded for the active book. Opens without live
    /// geometry retain a centered fallback source instead of losing the custom
    /// animator entirely.
    private(set) var source: ReaderTransitionSource?

    private let transitionDriver: ReaderNavigationTransitionDriver
    private var pendingDestinationFactory: (@MainActor () -> UIViewController)?
    private var pendingOpenCompletion: (@MainActor () -> Void)?
    private var pendingCloseAfterPush = false
    private var isProgrammaticPopPending = false

    init() {
        let driver = ReaderNavigationTransitionDriver()
        transitionDriver = driver
        driver.sourceProvider = { [weak self] in
            guard let self, let bookID = self.readerBookID else { return nil }
            return self.source ?? ReaderTransitionSource.fallback(bookID: bookID)
        }
        driver.readerIsPresented = { [weak self] in self?.isReaderPresented == true }
        driver.onInteractivePopCompleted = { [weak self] in
            self?.completeInteractivePop()
        }
        driver.onPopTransitionCompleted = { [weak self] completed in
            self?.completeProgrammaticPop(completed: completed)
        }
        driver.onPushTransitionCompleted = { [weak self] completed in
            self?.completePushTransition(completed: completed)
        }
    }

    // MARK: Open / close

    /// Record an open-book request. `source` carries the card geometry the
    /// animator should expand from; pass nil for entry points that have no
    /// visible source card (the animator falls back to a centered transition).
    func open(
        bookID: UUID,
        source: ReaderTransitionSource? = nil,
        destination: @escaping @MainActor () -> UIViewController,
        onTransitionCompleted: (@MainActor () -> Void)? = nil
    ) {
        guard readerBookID == nil, !isReaderPresented else { return }

        pendingCloseAfterPush = false
        isProgrammaticPopPending = false
        pendingOpenCompletion = onTransitionCompleted
        self.source = source ?? ReaderTransitionSource.fallback(bookID: bookID)
        self.readerBookID = bookID
        pendingDestinationFactory = destination
        beginPendingPushIfPossible()
    }

    private func beginPendingPushIfPossible() {
        guard transitionDriver.canStartNavigationTransition,
              let factory = pendingDestinationFactory else { return }
        pendingDestinationFactory = nil
        let destination = factory()

        // Set this before calling UIKit because a non-animated test/fallback
        // transaction may synchronously deliver `didShow` from inside push.
        isReaderPresented = true
        guard transitionDriver.startPush(destination) else {
            isReaderPresented = false
            readerBookID = nil
            source = nil
            pendingOpenCompletion = nil
            return
        }
    }

    /// Pop the directly-owned reader. State is cleared only after UIKit says
    /// the pop committed; a rejected or cancelled pop keeps the same reader.
    func close() {
        guard !transitionDriver.isInteractivePopInFlight else { return }
        guard isReaderPresented else { return }
        guard !isProgrammaticPopPending else { return }

        if transitionDriver.isPushTransitionInFlight {
            pendingCloseAfterPush = true
            return
        }

        isProgrammaticPopPending = true
        guard transitionDriver.startProgrammaticPop() else {
            isProgrammaticPopPending = false
            return
        }
    }

    /// Clear only the transition source, leaving the reader mounted. Kept for
    /// explicit fallback cleanup; normal navigation retains the source until
    /// a close transition finishes so the book can fold back to its shelf.
    func clearSource() {
        source = nil
    }

    // MARK: UIKit navigation bridge

    func attach(to navigationController: UINavigationController) {
        transitionDriver.attach(to: navigationController)
        beginPendingPushIfPossible()
    }

    func detachNavigationController() {
        transitionDriver.detach()
    }

    /// EPUB metadata becomes authoritative once the publication session is
    /// loaded. Updating the retained source makes programmatic and interactive
    /// closing fold around the same physical spine as the actual book.
    func updateOpeningDirection(_ direction: ReaderBookOpeningDirection) {
        guard let current = source else { return }
        source = current.replacingDirection(direction)
    }

    private func completeInteractivePop() {
        isProgrammaticPopPending = false
        isReaderPresented = false
        readerBookID = nil
        source = nil
    }

    private func completePushTransition(completed: Bool) {
        let completion = pendingOpenCompletion
        pendingOpenCompletion = nil
        if completed { completion?() }

        if !completed {
            isReaderPresented = false
            readerBookID = nil
            source = nil
            pendingDestinationFactory = nil
        }

        if pendingCloseAfterPush {
            pendingCloseAfterPush = false
            if completed {
                let completedBookID = readerBookID
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self,
                          self.readerBookID == completedBookID,
                          self.isReaderPresented else { return }
                    self.close()
                }
            }
        }
    }

    private func completeProgrammaticPop(completed: Bool) {
        isProgrammaticPopPending = false
        if completed {
            isReaderPresented = false
            readerBookID = nil
            source = nil
        }
    }

    /// The book id of the currently-open reader, if any.
    var activeBookID: UUID? { readerBookID }
}

// MARK: - Environment bridge
//
// Optional coordinator injected by migrated entry points (currently the
// bookshelf push). Modal presentations (online book detail, in-app browser,
// now-playing hub) do not inject a coordinator, so the reader falls back to
// its existing `dismiss` action there. Keeping this optional means the same
// `BookReaderView` works for both push and modal paths without branching on
// presentation style.

private struct ReaderNavigatorKey: EnvironmentKey {
    static let defaultValue: ReaderNavigationCoordinator? = nil
}

extension EnvironmentValues {
    var readerNavigator: ReaderNavigationCoordinator? {
        get { self[ReaderNavigatorKey.self] }
        set { self[ReaderNavigatorKey.self] = newValue }
    }
}
