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

    /// True from the moment a reader push is handed to UIKit until that
    /// transition commits. The card animation itself runs on the render server
    /// and no longer needs the main thread, but anything the reader commits
    /// while it is in flight lands in the same render pass — a chapter
    /// pagination or a cover decode there shows up as a dropped transition
    /// frame. Work that the first visible page does not depend on waits on
    /// `awaitOpeningTransitionEnd()` instead of racing the animation.
    ///
    /// Deliberately **not** `@Published`: publishing it would invalidate the
    /// reader's SwiftUI body at the exact moment the transition starts, which
    /// is precisely the kind of commit this gate exists to keep out of the
    /// animation.
    private(set) var isOpeningTransitionActive = false

    /// Continuations parked in `awaitOpeningTransitionEnd()`. MainActor-isolated
    /// like the rest of this type, so appending and resuming never race.
    private var openingTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set once the reader reports its first page laid out. The card animation
    /// waits for this before it starts driving, so the reader's own startup —
    /// CSS parse, embedded-font registration, CoreText pagination, measured on
    /// device at 34–67ms and landing 4–7ms into the animation — runs while the
    /// card is still at rest instead of inside the animation window.
    private var isReaderContentReady = false
    private var readerContentReadyWaiters: [CheckedContinuation<Void, Never>] = []

    /// FALLBACK (disclosed): ceiling on how long the card will sit still
    /// waiting for a first page. Two real cases need it — a slow book (large
    /// EPUB on a cold cache, or an online book) that takes seconds to lay out,
    /// and a reader that never reports ready at all (content fails to parse, or
    /// a non-CoreText path that never drives `isCoreTextReady`). Without it the
    /// card would freeze on the shelf tile for as long as the book takes, which
    /// reads as a hung app — far worse than opening onto a spinner. Measured
    /// warm first-page work is 34–67ms, so 100ms clears the common case with
    /// room to spare while keeping the tap responsive. Can be deleted only if
    /// every reader path is made to signal on both success and failure exits.
    private static let readerContentReadyCeiling: Duration = .milliseconds(100)
    private var readerContentReadyCeilingTask: Task<Void, Never>?

    /// True when the ceiling fired, i.e. the animation started while the reader
    /// was still showing its loading chrome. The reader reads this to hold that
    /// chrome until the transition commits: swapping the real first page in
    /// mid-animation would commit the entire first layout into the animation's
    /// render pass — the exact hitch this whole change removes. A book that
    /// made the deadline never sets it, so fast opens are never held back.
    private(set) var openingStartedWithoutContent = false

    /// Start timestamp of the in-flight opening transition, for the `⏱
    /// reader.open.transition` span. A measured duration far above the nominal
    /// animation length is the signal that the main thread was blocked during
    /// the open, since the completion callback that ends it is main-thread.
    private var openingTransitionStart: TimeInterval?

    /// Main-thread stall sampler, live only while an opening transition runs.
    /// The card animation itself is committed to the render server, so a frame
    /// is dropped only when the main thread misses a vsync. Stage spans cannot
    /// show that: an async span's elapsed time includes suspension, so a 50ms
    /// `epub.font.fetch` may have blocked nothing at all. A display link
    /// measures the blocking directly — the gaps between its own callbacks.
    private var openingStallLink: CADisplayLink?
    private var openingStallLastTimestamp: CFTimeInterval?
    private var openingStallCount = 0
    private var openingStallWorst: CFTimeInterval = 0
    private var openingStallWorstAt: CFTimeInterval = 0
    private var openingStallLostTime: CFTimeInterval = 0
    /// Media-time origin for the sampler, so a stall can be reported at its
    /// offset into the transition rather than as a bare duration.
    private var openingStallOrigin: CFTimeInterval = 0
    /// Gap between arming the sampler and its first callback. The main thread
    /// is blocked for that whole window by the synchronous push work — UIKit
    /// building the animator and SwiftUI laying out the reader for the first
    /// time — which all happens *before* the animation is committed. A stall
    /// there delays the animation's start instead of dropping its frames, so
    /// it needs to be told apart from the in-flight stalls below.
    private var openingStallStartupBlock: CFTimeInterval = 0

    private let transitionDriver: ReaderNavigationTransitionDriver
    private var pendingDestinationFactory: (@MainActor () -> UIViewController)?
    private var pendingDestinationViewController: UIViewController?
    /// The reader controller currently pushed (or being pushed). Held weakly so
    /// that if some agent other than this coordinator removes it from the stack
    /// — SwiftUI reconciling its `NavigationStack`, a system back-gesture — we
    /// can notice on the next settle and reset instead of locking the shelf.
    private weak var presentedReaderController: UIViewController?
    private var pendingOpenCompletion: (@MainActor () -> Void)?
    private var pendingPushRetryTask: Task<Void, Never>?
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
        driver.contentReadyGate = { [weak self] in
            await self?.awaitReaderContentReady()
        }
        driver.onInteractivePopCompleted = { [weak self] in
            self?.completeInteractivePop()
        }
        driver.onPopTransitionCompleted = { [weak self] completed in
            self?.completeProgrammaticPop(completed: completed)
        }
        driver.onPushTransitionCompleted = { [weak self] completed in
            self?.completePushTransition(completed: completed)
        }
        driver.onNavigationTransitionSettled = { [weak self] in
            self?.navigationTransitionDidSettle()
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
        AppLogger.info("⟐ coordinator.open bookID=\(bookID) hasSource=\(source != nil) readerBookID=\(String(describing: readerBookID)) isReaderPresented=\(isReaderPresented)")

        // Same book double-tap while push still in flight: update source
        // geometry so animation still reflects live card position.
        if readerBookID == bookID, transitionDriver.isPushTransitionInFlight {
            if let source {
                self.source = source
            }
            AppLogger.info("⟐ coordinator.open: same-book in-flight push, updated source")
            return
        }

        // Reader already on screen: ignore second tap. User can swipe to
        // close and tap again. Different-book taps during push animation
        // are also harmless — the push resolves and the next tap will
        // succeed. Calling close() here while isReaderPresented is true
        // but push hasn't settled triggers a pop in the middle of a push
        // transition, which corrupts UIKit state and causes the "flash
        // back to shelf and lock up" symptom.
        if isReaderPresented {
            AppLogger.info("⟐ coordinator.open: reader already presented, ignoring tap")
            return
        }

        guard readerBookID == nil else {
            AppLogger.info("⟐ coordinator.open REJECTED: another book pending existingBookID=\(String(describing: readerBookID))")
            return
        }

        pendingCloseAfterPush = false
        isProgrammaticPopPending = false
        // A fresh book must lay out its own first page before the card starts
        // turning; the previous book's readiness says nothing about this one.
        isReaderContentReady = false
        openingStartedWithoutContent = false
        pendingPushRetryTask?.cancel()
        pendingPushRetryTask = nil
        pendingOpenCompletion = onTransitionCompleted
        self.source = source ?? ReaderTransitionSource.fallback(bookID: bookID)
        self.readerBookID = bookID
        pendingDestinationFactory = destination
        pendingDestinationViewController = nil
        beginPendingPushIfPossible()
    }

    private func beginPendingPushIfPossible(allowDeferredRetry: Bool = true) {
        guard pendingDestinationFactory != nil || pendingDestinationViewController != nil else {
            AppLogger.info("⟐ coordinator.beginPendingPush nothing pending")
            return
        }
        guard transitionDriver.canStartNavigationTransition else {
            AppLogger.info("⟐ coordinator.beginPendingPush can't start now (transition busy) allowDeferredRetry=\(allowDeferredRetry)")
            if allowDeferredRetry { schedulePendingPushRetry() }
            return
        }

        let destination: UIViewController
        if let pendingDestinationViewController {
            destination = pendingDestinationViewController
        } else {
            guard let factory = pendingDestinationFactory else { return }
            pendingDestinationFactory = nil
            destination = factory()
            pendingDestinationViewController = destination
        }

        // Set this before calling UIKit because a non-animated test/fallback
        // transaction may synchronously deliver `didShow` from inside push.
        isReaderPresented = true
        guard transitionDriver.startPush(destination) else {
            AppLogger.info("⟐ coordinator.beginPendingPush startPush refused; will retry=\(allowDeferredRetry)")
            isReaderPresented = false
            if allowDeferredRetry { schedulePendingPushRetry() }
            return
        }
        AppLogger.info("⟐ coordinator.beginPendingPush startPush accepted")
        openingTransitionStart = ProcessInfo.processInfo.systemUptime
        isOpeningTransitionActive = true
        beginOpeningStallSampling()
        armReaderContentReadyCeiling()
        pendingPushRetryTask?.cancel()
        pendingPushRetryTask = nil
        pendingDestinationViewController = nil
        presentedReaderController = destination
    }

    /// Suspends until the opening transition has committed. Returns immediately
    /// when nothing is in flight, so modal entry points (which have no
    /// coordinator at all) and work started on a settled reader are never
    /// delayed. Awaits the published state rather than a timer — the signal is
    /// UIKit's own transition completion.
    /// Returns whether it actually had to wait, so callers can log the
    /// difference between "the gate was already open" and "this never ran at
    /// all" — two states that look identical when only real waits are traced.
    @discardableResult
    func awaitOpeningTransitionEnd() async -> Bool {
        // The guard and the append both run synchronously on the main actor, so
        // a transition cannot finish between them and strand this waiter.
        guard isOpeningTransitionActive else { return false }
        await withCheckedContinuation { continuation in
            openingTransitionWaiters.append(continuation)
        }
        return true
    }

    /// Called by the reader once its first page is laid out. Idempotent — the
    /// first caller wins and the ceiling is stood down.
    func signalReaderContentReady() {
        guard !isReaderContentReady else { return }
        isReaderContentReady = true
        readerContentReadyCeilingTask?.cancel()
        readerContentReadyCeilingTask = nil

        guard !readerContentReadyWaiters.isEmpty else { return }
        let waiters = readerContentReadyWaiters
        readerContentReadyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the reader's first page is laid out (or the ceiling
    /// fires). Returns immediately once ready, so a second transition for an
    /// already-warm reader is never held back.
    func awaitReaderContentReady() async {
        guard !isReaderContentReady else { return }
        await withCheckedContinuation { continuation in
            readerContentReadyWaiters.append(continuation)
        }
    }

    private func armReaderContentReadyCeiling() {
        readerContentReadyCeilingTask?.cancel()
        readerContentReadyCeilingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readerContentReadyCeiling)
            guard !Task.isCancelled, let self, !self.isReaderContentReady else { return }
            AppLogger.info("⟐ reader-nav content-ready ceiling fired; starting animation on the loading chrome")
            self.openingStartedWithoutContent = true
            self.signalReaderContentReady()
        }
    }

    private func beginOpeningStallSampling() {
        openingStallLink?.invalidate()
        openingStallLastTimestamp = nil
        openingStallCount = 0
        openingStallWorst = 0
        openingStallWorstAt = 0
        openingStallLostTime = 0
        openingStallStartupBlock = 0
        openingStallOrigin = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(sampleOpeningStall(_:)))
        link.add(to: .main, forMode: .common)
        openingStallLink = link
    }

    @objc private func sampleOpeningStall(_ link: CADisplayLink) {
        defer { openingStallLastTimestamp = link.timestamp }
        guard let last = openingStallLastTimestamp else {
            // First callback: everything before it was the synchronous push
            // path holding the main thread, not a dropped animation frame.
            openingStallStartupBlock = link.timestamp - openingStallOrigin
            return
        }
        // `duration` reports the active refresh interval, so this adapts to
        // ProMotion instead of assuming a 60Hz budget.
        let budget = link.duration > 0 ? link.duration : 1.0 / 60.0
        let gap = link.timestamp - last
        guard gap > budget * 1.5 else { return }
        openingStallCount += 1
        openingStallLostTime += gap - budget
        guard gap > openingStallWorst else { return }
        openingStallWorst = gap
        openingStallWorstAt = last - openingStallOrigin
    }

    /// Clears the opening gate, closes its span, and releases every waiter.
    /// Idempotent, and reached from every path that ends a push — the normal
    /// completion, the driver's watchdog rollback, and the external-detach
    /// self-heal — so a waiter can never be left parked forever.
    private func endOpeningTransition(committed: Bool) {
        openingStallLink?.invalidate()
        openingStallLink = nil
        readerContentReadyCeilingTask?.cancel()
        readerContentReadyCeilingTask = nil
        // Release anything still parked on the first page: the transition is
        // over, so waiting for it can only strand the waiter.
        signalReaderContentReady()

        if let start = openingTransitionStart {
            let ms = { (seconds: CFTimeInterval) in String(format: "%.0f", seconds * 1000) }
            // `startup` is main-thread time spent before the animation was even
            // committed (felt as a delay after the tap, not as a dropped frame).
            // `worst@at` is the longest single freeze and how far into the
            // transition it happened — the offset is what says which stage of
            // the reader's own startup caused it.
            SourcePerfTrace.record(
                "reader.open.transition",
                "committed=\(committed) startup=\(ms(openingStallStartupBlock))ms "
                + "stalls=\(openingStallCount) "
                + "worst=\(ms(openingStallWorst))ms@\(ms(openingStallWorstAt))ms "
                + "lost=\(ms(openingStallLostTime))ms",
                since: start
            )
            openingTransitionStart = nil
        }
        isOpeningTransitionActive = false

        guard !openingTransitionWaiters.isEmpty else { return }
        let waiters = openingTransitionWaiters
        openingTransitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func schedulePendingPushRetry() {
        guard pendingPushRetryTask == nil else { return }
        // Only a system-owned transition (UIKit's coordinator lingering after
        // a pop) needs an armed wait: its end is observable through its own
        // completion callback. When the blocker is this driver's own
        // operation, `finishTransition` → `navigationTransitionDidSettle`
        // re-arms the pending push, so arming here would just spin.
        guard transitionDriver.hasBlockingSystemTransition else { return }
        pendingPushRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Await the real end-of-transition signal. The single-yield retry
            // this replaces could resume before UIKit released the
            // coordinator, burning the only attempt and stranding the staged
            // open forever (shelf ignores every later tap).
            await self.transitionDriver.waitForBlockingSystemTransitionEnd()
            // One scheduling hop: UIKit releases `transitionCoordinator`
            // after the completion callback returns, not inside it.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self.pendingPushRetryTask = nil
            self.beginPendingPushIfPossible(allowDeferredRetry: true)
        }
    }

    /// UIKit can keep its transition coordinator alive through the completion
    /// callback's current run loop. Retrying from this settled-state event
    /// lets a shelf tap made immediately after pop reuse the queued reader.
    func navigationTransitionDidSettle() {
        pendingPushRetryTask?.cancel()
        pendingPushRetryTask = nil
        reconcileIfReaderDetached()
        beginPendingPushIfPossible()
    }

    /// Reset reader state when the pushed reader controller has left the
    /// navigation stack without this coordinator driving the pop. SwiftUI can
    /// reconcile the directly-pushed controller off its `NavigationStack` (most
    /// visibly during an impatient double-tap open), and a system back-gesture
    /// would do the same. When that happens no `completeInteractivePop` /
    /// `completeProgrammaticPop` ever fires, so without this the coordinator
    /// stays convinced a reader is presented and refuses every future open.
    /// Guarded to run only while the stack is idle so it never races a real
    /// transition that is still mid-flight.
    private func reconcileIfReaderDetached() {
        guard isReaderPresented,
              let reader = presentedReaderController,
              !transitionDriver.isTransitionActive,
              !isProgrammaticPopPending,
              !transitionDriver.isInteractivePopInFlight,
              !transitionDriver.stackContains(reader)
        else { return }

        AppLogger.info("⟐ coordinator reconcile: reader controller popped externally; resetting state")
        endOpeningTransition(committed: false)
        pendingPushRetryTask?.cancel()
        pendingPushRetryTask = nil
        pendingCloseAfterPush = false
        isProgrammaticPopPending = false
        isReaderPresented = false
        readerBookID = nil
        source = nil
        presentedReaderController = nil
        pendingDestinationFactory = nil
        pendingDestinationViewController = nil
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
        // `detach()` drops the driver's pending operation without delivering a
        // completion, so nothing else would ever reopen the gate. Release it
        // here or a parked preload leaks its continuation with the shelf.
        endOpeningTransition(committed: false)
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
        pendingPushRetryTask?.cancel()
        pendingPushRetryTask = nil
        isProgrammaticPopPending = false
        isReaderPresented = false
        readerBookID = nil
        source = nil
        presentedReaderController = nil
    }

    private func completePushTransition(completed: Bool) {
        endOpeningTransition(committed: completed)
        let completion = pendingOpenCompletion
        pendingOpenCompletion = nil
        if completed { completion?() }

        if !completed {
            pendingPushRetryTask?.cancel()
            pendingPushRetryTask = nil
            isReaderPresented = false
            readerBookID = nil
            source = nil
            presentedReaderController = nil
            pendingDestinationFactory = nil
            pendingDestinationViewController = nil
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
            pendingPushRetryTask?.cancel()
            pendingPushRetryTask = nil
            isReaderPresented = false
            readerBookID = nil
            source = nil
            presentedReaderController = nil
        }
    }

    /// The book id of the currently-open reader, if any.
    var activeBookID: UUID? { readerBookID }

    /// Fallback of last resort: a staged open whose deferred push lost every
    /// re-arm signal (all known signal paths are now awaited — this guards the
    /// unknown ones). Trigger: a book is staged (`readerBookID` set) but
    /// nothing was ever pushed, no retry is armed, and the driver is fully
    /// idle — a state no live open can occupy. Clearing it lets the current
    /// tap open normally instead of being ignored forever. Delete once device
    /// logs confirm the log line below never fires.
    private func resetStrandedStagedOpenIfNeeded() {
        guard readerBookID != nil,
              !isReaderPresented,
              presentedReaderController == nil,
              pendingPushRetryTask == nil,
              !isProgrammaticPopPending,
              !transitionDriver.isTransitionActive
        else { return }

        AppLogger.info("⟐ coordinator reset stranded staged open bookID=\(String(describing: readerBookID))")
        readerBookID = nil
        source = nil
        pendingDestinationFactory = nil
        pendingDestinationViewController = nil
        pendingOpenCompletion = nil
        pendingCloseAfterPush = false
    }

    /// Whether a fresh shelf tap should be ignored because a reader is already
    /// staged or on screen. Call this instead of reading `isReaderPresented`
    /// directly from the shelf: it first self-heals a stranded state (a reader
    /// controller removed by an external agent, e.g. SwiftUI reconciling its
    /// `NavigationStack`, or a staged open whose deferred push never fired),
    /// so a genuinely idle shelf can never get permanently stuck ignoring
    /// every tap.
    func shouldIgnoreOpenRequest() -> Bool {
        reconcileIfReaderDetached()
        resetStrandedStagedOpenIfNeeded()
        return isReaderPresented || readerBookID != nil
    }
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
