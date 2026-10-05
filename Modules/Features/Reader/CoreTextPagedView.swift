import SwiftUI
import UIKit

struct CoreTextPageEngineView: UIViewControllerRepresentable {
    let engine: any PageRenderingProvider
    let pageTurnStyle: PageTurnStyle
    let theme: ReaderTheme
    let playbackHighlight: ReaderPlaybackHighlight?
    let isRTL: Bool
    let isDoublePageSpread: Bool
    let spreadGutter: CGFloat
    let sessionCoordinator: ReaderSessionCoordinator?
    let externalTargetVersion: UInt
    let externalTargetPosition: CoreTextReadingPosition?
    let pageTurnCommand: ReaderPageTurnCommand?
    let clearExternalTargetPosition: () -> Void
    @Binding var currentPage: Int
    /// Changes when 頁眉／頁腳 say something new — a clock tick, the battery, a
    /// style edit — without the pagination changing. Pages already on screen were
    /// handed their bars when they were built, so they need telling.
    var pageBarsRevision: UInt = 0
    /// 自動閱讀's curtain: which page is being revealed over the current one.
    /// `nil` when the mode is off. Changes once per page, not once per frame —
    /// the reveal's *position* comes through `autoReadRevealHandle` instead.
    var autoReadRevealPage: Int?
    var autoReadRevealHandle: ReaderAutoReadRevealHandle?
    let onPageChanged: (Int, CoreTextReadingPosition?) -> Void
    let onTapZone: (TouchAction) -> Void
    /// A swipe or drag started turning the page. Never called for turns the app
    /// issues (taps go through `onTapZone`, and TTS or 自動閱讀 are programmatic).
    var onUserPageTurnBegan: () -> Void = {}
    var onSwipeUpExit: () -> Void = {}
    /// Read when the pull-down gesture begins, so the pill can say "加入" or
    /// "移除" before the finger has travelled far enough to commit.
    var isCurrentPageBookmarked: () -> Bool = { false }
    /// Adds or removes this page's bookmark. Same call as the top bar's button.
    var onPullDownBookmark: () -> Void = {}
    var visibleRefreshCommit: ReaderVisibleRefreshCommit?
    var onVisibleRefreshFinished: (UInt64, ReaderVisibleRefreshOutcome) -> Void = { _, _ in }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let adapterDescriptor = PageViewControllerPagingAdapterDescriptor(pageTurnStyle: pageTurnStyle)
        let options: [UIPageViewController.OptionsKey: Any] = [
            .spineLocation: adapterDescriptor.spineLocation(isRTL: isRTL).rawValue
        ]
        let pvc = UIPageViewController(
            transitionStyle: adapterDescriptor.transitionStyle,
            navigationOrientation: .horizontal,
            options: options
        )
        pvc.isDoubleSided = adapterDescriptor.isDoubleSided && !isDoublePageSpread
        // cover / none mode: disable built-in swipe gesture (use custom pan or tap for page turns).
        if adapterDescriptor.disablesBuiltInSwipe {
            pvc.dataSource = nil
            for case let sv as UIScrollView in pvc.view.subviews {
                sv.isScrollEnabled = false
            }
        } else {
            pvc.dataSource = context.coordinator
            adapterDescriptor.disableBuiltInTapToTurn(on: pvc)
            context.coordinator.pageTurnTrace.observeBuiltInGestures(of: pvc)
        }
        pvc.delegate = context.coordinator

        // RTL books: reverse swipe direction so left-to-right swipe = next page.
        if isRTL {
            pvc.view.semanticContentAttribute = .forceRightToLeft
            for subview in pvc.view.subviews {
                guard let scrollView = subview as? UIScrollView else { continue }
                scrollView.semanticContentAttribute = .forceRightToLeft
            }
        }

        // Prefer SwiftUI binding's currentPage to avoid jumping back to old coordinates when switching page styles.
        let initialPage = engine.totalPages > 0
            ? max(0, min(currentPage, engine.totalPages - 1))
            : 0
        let initialVC = context.coordinator.displayViewController(at: initialPage)
        context.coordinator.applyPlaybackHighlight(to: initialVC)
        context.coordinator.captureStablePosition(from: initialVC)
        pvc.setViewControllers(context.coordinator.viewControllerStack(startingWith: initialVC), direction: .forward, animated: false)
        // Absorb any stale page-turn command so a rebuilt controller (page-style
        // switch recreates the coordinator) never replays an old intent.
        context.coordinator.lastExecutedTurnVersion = pageTurnCommand?.version ?? 0
        // Sync the binding (display output) so ReaderView.currentPage aligns with
        // the engine-restored position.
        if initialPage != currentPage {
            DispatchQueue.main.async {
                self.currentPage = initialPage
                self.onPageChanged(initialPage, nil)
            }
        }

        // Tap zone recognizer: left 30% → prev, right 30% → next, center → menu
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        pvc.view.addGestureRecognizer(tap)

        // cover mode: add custom pan gesture + overlay
        if adapterDescriptor.usesCoverOverlay {
            context.coordinator.setupCoverOverlay(on: pvc.view)
            context.coordinator.coverPageViewController = pvc
            let pan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleCoverPan(_:))
            )
            pan.maximumNumberOfTouches = 1
            pvc.view.addGestureRecognizer(pan)
        }
        if adapterDescriptor.usesInstantPan {
            context.coordinator.instantPanPageViewController = pvc
            let pan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleInstantPan(_:))
            )
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pvc.view.addGestureRecognizer(pan)
        }

        // Swipe-up exit: only begins on a clearly upward drag (delegate-gated),
        // so page-turn pans/taps keep their behavior. Reads the setting at
        // begin time, so toggling it needs no controller rebuild.
        let exitPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipeUpExitPan(_:))
        )
        exitPan.maximumNumberOfTouches = 1
        exitPan.delegate = context.coordinator
        context.coordinator.swipeUpExitPanGesture = exitPan
        pvc.view.addGestureRecognizer(exitPan)

        // Pull-down bookmark: the exit gesture's mirror image, gated the same way
        // — it only begins on a clearly downward drag, and reads its setting at
        // begin time so toggling it needs no controller rebuild. The page itself
        // comes down, and its ribbon grows or retracts with the finger.
        let bookmarkPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePullDownBookmarkPan(_:))
        )
        bookmarkPan.maximumNumberOfTouches = 1
        bookmarkPan.delegate = context.coordinator
        context.coordinator.pullDownBookmarkPanGesture = bookmarkPan
        context.coordinator.pullDownPageViewController = pvc
        pvc.view.addGestureRecognizer(bookmarkPan)

        context.coordinator.bindEngineCallbacks(to: engine, pageViewController: pvc)

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        let updateTrace = context.coordinator.pageTurnTrace.beginUpdatePass()
        defer { context.coordinator.pageTurnTrace.endUpdatePass(updateTrace) }
        context.coordinator.currentEngine = engine
        context.coordinator.sessionCoordinator = sessionCoordinator
        // Refreshed every pass, ahead of the early returns below: these two read
        // live reader state (which page is showing, whether it is bookmarked), so
        // a copy captured once at makeCoordinator time would answer for the page
        // the book opened on.
        context.coordinator.isCurrentPageBookmarked = isCurrentPageBookmarked
        context.coordinator.onPullDownBookmark = onPullDownBookmark
        context.coordinator.currentPlaybackHighlight = playbackHighlight
        let spreadModeChanged = context.coordinator.isDoublePageSpread != isDoublePageSpread
        context.coordinator.isDoublePageSpread = isDoublePageSpread
        uiViewController.isDoubleSided = PageViewControllerPagingAdapterDescriptor(
            pageTurnStyle: pageTurnStyle
        ).isDoubleSided && !isDoublePageSpread
        context.coordinator.externalTargetPosition = externalTargetPosition
        context.coordinator.bindEngineCallbacks(to: engine, pageViewController: uiViewController)
        context.coordinator.applyAutoReadReveal(
            page: autoReadRevealPage,
            handle: autoReadRevealHandle,
            on: uiViewController
        )
        if context.coordinator.lastAppliedPageBarsRevision != pageBarsRevision {
            context.coordinator.lastAppliedPageBarsRevision = pageBarsRevision
            uiViewController.viewControllers?.forEach {
                context.coordinator.applyPageBars(to: $0)
            }
        }
        if let commit = visibleRefreshCommit,
           commit.mode == .paged,
           context.coordinator.lastAppliedRefreshTransactionID != commit.transactionID {
            // `applyVisibleRefresh` acknowledges synchronously, and this method runs
            // *inside* SwiftUI's view update. `onVisibleRefreshFinished` clears the
            // renderer's `@Published pendingVisibleRefreshCommit`, so completing inline
            // publishes mid-update — "Publishing changes from within view updates is not
            // allowed, this will cause undefined behavior." Hand the outcome back on the
            // next main-queue turn, the same treatment `clearExternalTargetPosition` gets
            // below; the UIKit page swap still happens now, so the page is right this
            // frame, and the coordinator's own transaction bookkeeping is unaffected.
            let finish = onVisibleRefreshFinished
            context.coordinator.applyVisibleRefresh(
                commit,
                on: uiViewController,
                completion: { transactionID, outcome in
                    DispatchQueue.main.async { finish(transactionID, outcome) }
                }
            )
            return
        }
        // Phase-2 executor model: this method no longer reconciles the currentPage
        // binding against the visible page (the old implicit channel that caused
        // correction-transition oscillation). It executes exactly three inputs:
        // appearance rebuilds (spread/theme), the Navigator-owned external target
        // (position command), and an explicit ReaderPageTurnCommand. The binding
        // is display output; between commands the PVC's visible page is truth.
        let displayFallbackPage = max(0, min(currentPage, max(engine.totalPages - 1, 0)))
        let targetViewController = {
            if let externalTargetPosition {
                return context.coordinator.displayViewController(for: externalTargetPosition)
            }
            return context.coordinator.displayViewController(at: displayFallbackPage)
        }

        if spreadModeChanged {
            _ = context.coordinator.setPage(targetViewController(), on: uiViewController, layoutNow: true)
            if context.coordinator.externalTargetPosition != nil {
                DispatchQueue.main.async { context.coordinator.clearExternalTargetPosition() }
            }
            return
        }
        if context.coordinator.currentTheme != theme {
            context.coordinator.currentTheme = theme
            engine.applyThemeChange(
                textColor: UIColor(theme.textColor),
                backgroundColor: UIColor(theme.backgroundColor)
            )
            _ = context.coordinator.setPage(targetViewController(), on: uiViewController)
            if context.coordinator.externalTargetPosition != nil {
                DispatchQueue.main.async { context.coordinator.clearExternalTargetPosition() }
            }
            return
        }

        guard let visible = uiViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) else {
            // No visible page yet (first layout race): align to the best-known target.
            _ = context.coordinator.setPage(targetViewController(), on: uiViewController)
            return
        }

        // 1) Position command: Navigator-owned external target (TOC jump, restore,
        //    mode switch, TTS anchor). One-shot — cleared once applied to a real page.
        if externalTargetPosition != nil {
            // A stack write on top of an in-flight transition — UIKit's interactive
            // one or ours — corrupts its pending state. Park the target and replay it
            // when the stack comes free.
            if context.coordinator.isStackWriteBlocked {
                context.coordinator.deferExternalTarget()
                return
            }
            let targetVC = targetViewController()
            // Flip to the destination immediately — INCLUDING its loading placeholder — so a jump
            // to an unfetched online chapter shows a「加载中」page at once instead of freezing on the
            // current page until the seconds-long 段評 fetch finishes (Legado's jump-then-load feel;
            // the user called out our load-then-jump as a big part of the perceived lag). The curl
            // path used to `return` here and stay put until content arrived. It's safe to show the
            // placeholder now: `setPage` is a non-animated `setViewControllers` (no curl animation
            // runs on it), the data source returns placeholders for neighbours during an interactive
            // curl (no NSInvalidArgumentException), and the one-shot clear below intentionally keeps
            // `externalTargetPosition` alive while a placeholder is showing so `handleChapterReady`
            // still swaps in the real content once the layout completes.
            _ = context.coordinator.setPage(targetVC, on: uiViewController, layoutNow: true)
            // One-shot: without this the target persists and every re-render snaps
            // back — the curl "animates then bounces back" bug after scroll→paged.
            if !context.coordinator.isPlaceholderDisplay(targetVC) {
                let clear = clearExternalTargetPosition
                DispatchQueue.main.async { clear() }
            }
            return
        }

        // 2) Page-turn command (tap zones, volume keys). Executed exactly once per
        //    version; stale re-renders with the same command are no-ops.
        if let command = pageTurnCommand, command.version != context.coordinator.lastExecutedTurnVersion {
            context.coordinator.lastExecutedTurnVersion = command.version
            // Resolve the command's absolute position against the CURRENT
            // pagination. A page index only exists inside the layout that
            // produced it; a chapter boundary layout landing between issue and
            // execution renumbers every page after it, so the raw index would
            // land on content the user never asked for (the "jumped one page
            // too far" bug family). The position keeps the intent anchored to
            // content; the raw index is the fallback while the target chapter
            // has no layout yet (pageIndex(for:) returns nil).
            let resolvedTarget = command.targetPosition.flatMap { engine.pageIndex(for: $0) }
            let target = max(0, min(resolvedTarget ?? command.target, max(engine.totalPages - 1, 0)))
            guard target != visible.globalPageIndex else {
                context.coordinator.pageTurnTrace.commandExecuted(
                    version: command.version, target: target, visible: visible.globalPageIndex,
                    speed: context.coordinator.activeTurnSpeed, adjacent: false, route: "samePage"
                )
                return
            }
            // Rapid-tap speed-up: register cadence now, before the cover / slide /
            // curl branches read activeTurnSpeed.
            let turnSpeed = context.coordinator.registerTurnSpeed()
            AppLogger.render("[CurlTrace] turnCommand v\(command.version) target=\(target) visible=\(visible.globalPageIndex) speed=\(String(format: "%.2f", turnSpeed))")

            var direction: UIPageViewController.NavigationDirection =
                target >= visible.globalPageIndex ? .forward : .reverse
            // RTL: swap navigation direction to match data source swap (Before↔After).
            if isRTL {
                direction = direction == .forward ? .reverse : .forward
            }
            let isAdjacent = context.coordinator.isAdjacentDisplayPage(target, to: visible.globalPageIndex)
            let shouldAnimate = command.animated && (pageTurnStyle != .none) && isAdjacent
            let traceCommand = { (route: StaticString) in
                context.coordinator.pageTurnTrace.commandExecuted(
                    version: command.version, target: target, visible: visible.globalPageIndex,
                    speed: turnSpeed, adjacent: isAdjacent, route: route
                )
            }

            if pageTurnStyle == .cover {
                traceCommand("cover")
                if shouldAnimate {
                    context.coordinator.animateCoverTransition(
                        from: visible.globalPageIndex,
                        to: target,
                        direction: direction,
                        on: uiViewController
                    )
                } else if !context.coordinator.isAnimatingTransition {
                    let targetVC = context.coordinator.displayViewController(at: target)
                    _ = context.coordinator.setPage(targetVC, on: uiViewController, direction: direction, layoutNow: true)
                }
                return
            }

            if shouldAnimate {
                let effects = context.coordinator.requestPageTransition(
                    to: target,
                    visiblePage: visible.globalPageIndex
                )
                // Deferred: the queue recorded the latest target; the running
                // transition's settle chains to it (latest intent wins).
                guard effects.contains(.requestPageTransition(targetPage: target)) else {
                    traceCommand("queued")
                    // The turn on screen finishes before this one starts; draw its
                    // pages meanwhile.
                    context.coordinator.prefetchPages(around: target)
                    return
                }
            } else if context.coordinator.isPageTransitioning {
                _ = context.coordinator.requestPageTransition(
                    to: target,
                    visiblePage: visible.globalPageIndex
                )
                traceCommand("queued")
                context.coordinator.prefetchPages(around: target)
                return
            }

            traceCommand(shouldAnimate ? "start" : "instant")
            context.coordinator.performProgrammaticTransition(
                on: uiViewController,
                to: target,
                from: visible.globalPageIndex,
                direction: direction,
                animated: shouldAnimate
            )
            return
        }

        // 3) No command: keep the playback highlight fresh and leave the PVC alone.
        context.coordinator.applyPlaybackHighlight(to: visible)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            engine: engine,
            pageTurnStyle: pageTurnStyle,
            theme: theme,
            playbackHighlight: playbackHighlight,
            isRTL: isRTL,
            isDoublePageSpread: isDoublePageSpread,
            spreadGutter: spreadGutter,
            sessionCoordinator: sessionCoordinator,
            externalTargetPosition: externalTargetPosition,
            clearExternalTargetPosition: clearExternalTargetPosition,
            currentPage: $currentPage,
            onPageChanged: onPageChanged,
            onTapZone: onTapZone,
            onUserPageTurnBegan: onUserPageTurnBegan,
            onSwipeUpExit: onSwipeUpExit,
            isCurrentPageBookmarked: isCurrentPageBookmarked,
            onPullDownBookmark: onPullDownBookmark
        )
    }

    final class Coordinator: NSObject,
        UIPageViewControllerDataSource,
        UIPageViewControllerDelegate,
        UIGestureRecognizerDelegate
    {
        var currentEngine: any PageRenderingProvider
        let pageTurnStyle: PageTurnStyle
        var currentTheme: ReaderTheme
        var currentPlaybackHighlight: ReaderPlaybackHighlight?
        var sessionCoordinator: ReaderSessionCoordinator?
        @Binding var currentPage: Int
        let onPageChanged: (Int, CoreTextReadingPosition?) -> Void
        let onTapZone: (TouchAction) -> Void
        let onUserPageTurnBegan: () -> Void
        let onSwipeUpExit: () -> Void
        var isCurrentPageBookmarked: () -> Bool
        var onPullDownBookmark: () -> Void
        let isRTL: Bool
        var isDoublePageSpread: Bool
        private(set) var lastAppliedRefreshTransactionID: UInt64 = 0
        let spreadGutter: CGFloat
        let clearExternalTargetPosition: () -> Void
        var externalTargetPosition: CoreTextReadingPosition? {
            didSet {
                guard let externalTargetPosition else { return }
                setCurrentPosition(externalTargetPosition, .externalTarget)
                pendingNavigation = PendingNavigation(target: .position(externalTargetPosition))
            }
        }

        private enum NavigationTarget {
            case position(CoreTextReadingPosition)
            case page(Int)
        }

        private struct PendingNavigation {
            let target: NavigationTarget
        }

        /// The one owner of "may the page stack be rewritten right now?", shared by
        /// every page-turn style. See `ReaderStackWriteGate`.
        private var stackWriteGate = ReaderStackWriteGate()
        /// Snapshot of the page count used by UIKit's cached double-sided neighbours.
        /// Hold a shrinking count until the next stack write so an in-flight curl
        /// never loses a controller that UIKit already requested.
        private var stackWriteTotalPages = 0
        // Cover animation overlay components
        private let coverOverlayView = UIView()
        private let coverCurrentImageView = UIImageView()
        private let coverDimView = UIView()
        private let coverShadowView = UIView()
        private let coverIncomingImageView = UIImageView()
        private var coverTargetPage: Int?
        private var coverDirection: ReaderCoverTurnDirection?
        /// Version of the last ReaderPageTurnCommand this coordinator executed.
        /// updateUIViewController runs on every SwiftUI render; the version check
        /// makes each command fire exactly once.
        fileprivate var lastExecutedTurnVersion: UInt = 0
        /// Rapid-tap speed-up: the faster consecutive page turns arrive, the faster
        /// the flip animation plays (Legado-style). `ReaderTurnBurstPacer` turns the
        /// tap rhythm into a speed; chained catch-up transitions inherit the last
        /// value since they don't re-register a user tap.
        private var turnPacer = ReaderTurnBurstPacer()
        var activeTurnSpeed: Float { turnPacer.speed }
        /// The tapped turn now animating: the layer whose clock its animations run
        /// on, and the speed already built into those animations' durations. Nil
        /// for a finger-driven turn, which is never retimed.
        private var turnInFlight: (layer: CALayer, builtInSpeed: Float)?
        private static let slideTransitionKey = "readerSlideTurn"
        /// Instruments signposts for every turn, tapped or swiped.
        let pageTurnTrace: ReaderPageTurnTrace
        /// Held while any turn animates, tapped or swiped.
        private let turnFrameRate = ReaderTurnFrameRateRequest()
        /// UIKit pairs `willTransitionTo` with `didFinishAnimating`; this keeps an
        /// unpaired callback from releasing a hold a tapped turn still owns.
        private var nativeTurnHoldsFrameRate = false
        /// Where the reader is, and the only thing allowed to say so.
        ///
        /// `private(set)` is the point. Four separate places used to assign this directly
        /// and exactly **one** of them told the sentry, so every position guard — A1, G1,
        /// G2, G3 — was blind to the other three. The whole 覆蓋 page-turn style lived in
        /// that blind spot: turning pages with it reported nothing at all.
        ///
        /// Instrumenting the *paths* is what let that happen; a path can be added without
        /// anyone remembering. Instrumenting the *variable* cannot be bypassed, because
        /// assignment from outside `setCurrentPosition` no longer compiles.
        fileprivate private(set) var currentCoreTextPosition: CoreTextReadingPosition?

        /// Why the position is changing. A new caller has to choose, which is the job.
        enum PositionWrite {
            /// A turn that landed — any animation style, gesture or command.
            case settled(readerDriven: Bool, isPlaceholder: Bool)
            /// The navigator handed down a destination. Deliberately *not* a settle: the
            /// stack write that follows reports where it actually lands, and counting both
            /// would report one navigation twice.
            case externalTarget
        }

        func setCurrentPosition(_ position: CoreTextReadingPosition?, _ write: PositionWrite) {
            currentCoreTextPosition = position
            guard case let .settled(readerDriven, isPlaceholder) = write,
                  let position else { return }
            ReaderPositionSentry.shared.observeCommit(
                position,
                source: .pagedTurn,
                isPlaceholder: isPlaceholder,
                readerDriven: readerDriven
            )
        }
        private var pendingNavigation: PendingNavigation?
        weak var coverPageViewController: UIPageViewController?
        weak var instantPanPageViewController: UIPageViewController?
        // Swipe-up exit gesture state
        weak var swipeUpExitPanGesture: UIPanGestureRecognizer?
        private var swipeUpExitChipContainer: UIView?
        private weak var swipeUpExitChipIcon: UIImageView?
        private var swipeUpExitArmed = false
        private let swipeUpExitHaptic = UIImpactFeedbackGenerator(style: .medium)
        // Pull-down bookmark gesture state
        weak var pullDownBookmarkPanGesture: UIPanGestureRecognizer?
        weak var pullDownPageViewController: UIPageViewController?
        /// The hint in the gap the pulled page opens above itself. Parented to the
        /// page view controller's view just above its top edge, so it comes down
        /// with the page and shows in the gap the page leaves.
        private let pullDownHintLabel = UILabel()
        /// The page whose ribbon the finger is driving.
        private weak var pullDownRibbonHost: (any ReaderBookmarkRibbonHosting)?
        /// Read once at `.began`; the hint must not flip mid-drag because a
        /// neighbouring page settled underneath the finger.
        private var pullDownBookmarkWasBookmarked = false
        private var pullDownBookmarkPhase: ReaderPullDownBookmarkMotion.Phase = .pulling
        private let pullDownBookmarkHaptic = UIImpactFeedbackGenerator(style: .medium)
        private weak var callbackEngineObject: AnyObject?
        private var callbackEngineIdentifier: ObjectIdentifier?

        var isPageTransitioning: Bool {
            sessionCoordinator?.isPageTransitioning ?? false
        }

        private var curlBackPageColor: UIColor {
            UIColor(currentTheme.backgroundColor)
        }

        fileprivate var pageStride: Int {
            isDoublePageSpread ? 2 : 1
        }

        private var fixedLayoutPairingProvider: FixedLayoutSpreadPairingProviding? {
            currentEngine as? FixedLayoutSpreadPairingProviding
        }

        private func nextDisplayPage(after page: Int) -> Int? {
            if isDoublePageSpread,
               let next = fixedLayoutPairingProvider?.nextFixedLayoutSpreadPage(after: page) {
                return next
            }
            let target = page + pageStride
            return target < currentEngine.totalPages ? target : nil
        }

        private func previousDisplayPage(before page: Int) -> Int? {
            if isDoublePageSpread,
               let previous = fixedLayoutPairingProvider?.previousFixedLayoutSpreadPage(before: page) {
                return previous
            }
            let target = page - pageStride
            return target >= 0 ? target : nil
        }

        fileprivate func isAdjacentDisplayPage(_ targetPage: Int, to visiblePage: Int) -> Bool {
            nextDisplayPage(after: visiblePage) == targetPage ||
                previousDisplayPage(before: visiblePage) == targetPage
        }

        private var usesCurlBackPages: Bool {
            pageTurnStyle == .curl && !isDoublePageSpread
        }

        /// Register a fresh user-initiated page turn and return the flip speed to
        /// use. Called once per user command; chained catch-up transitions read
        /// `activeTurnSpeed` without re-registering. A turn still on screen picks
        /// the new speed up at once, so a burst does not wait out a slow turn
        /// before the fast ones start.
        @discardableResult
        fileprivate func registerTurnSpeed() -> Float {
            let speed = turnPacer.registerTap(at: CACurrentMediaTime())
            speedUpTurnInFlight()
            return speed
        }

        /// Marks the tapped turn whose animations were just added under `layer`,
        /// their durations already divided by `builtInSpeed`.
        private func beginRetimableTurn(on layer: CALayer, builtInSpeed: Float) {
            endRetimableTurn()
            turnInFlight = (layer, max(builtInSpeed, 1))
        }

        /// Only ever faster: a turn that started quickly finishes quickly even if
        /// the tapping has eased off since.
        private func speedUpTurnInFlight() {
            guard let turn = turnInFlight else { return }
            let clockSpeed = activeTurnSpeed / turn.builtInSpeed
            guard clockSpeed > turn.layer.speed else { return }
            pageTurnTrace.speedUp(to: clockSpeed)
            ReaderTurnLayerClock.setSpeed(clockSpeed, on: turn.layer)
        }

        /// The turn has landed and nothing under its layer is animating any more.
        private func endRetimableTurn() {
            guard let turn = turnInFlight else { return }
            ReaderTurnLayerClock.reset(turn.layer)
            turnInFlight = nil
        }

        /// True while UIKit or one of our animations owns the page stack.
        fileprivate var isStackWriteBlocked: Bool { stackWriteGate.isBusy }
        fileprivate var isAnimatingTransition: Bool { stackWriteGate.isAnimatingTransition }

        fileprivate func beginAnimatedTransition() {
            stackWriteGate.beginTransition()
        }

        /// Ends the animation window and hands any owed stack write to `drainStackWrites`.
        fileprivate func endAnimatedTransition(on pageViewController: UIPageViewController) {
            stackWriteGate.endTransition()
            drainStackWrites(on: pageViewController)
        }

        fileprivate func deferExternalTarget() {
            _ = stackWriteGate.request(.externalTarget)
        }

        /// Replays the one write owed after UIKit gave the stack back.
        ///
        /// Always on the next runloop turn, never inline: a `setViewControllers` inside
        /// `didFinishAnimating` (or inside a transition completion) re-seeds
        /// `_UIQueuingScrollView` while it is still unwinding the just-finished scroll,
        /// which is how a slide page turn at a chapter boundary used to land a page too
        /// far. Same reasoning as `continueQueuedTransitionIfNeeded`.
        private func drainStackWrites(on pageViewController: UIPageViewController) {
            guard stackWriteGate.hasPendingWrites, !stackWriteGate.isBusy else { return }
            DispatchQueue.main.async { [weak self, weak pageViewController] in
                guard let self, let pageViewController else { return }
                guard let write = self.stackWriteGate.drain() else { return }
                AppLogger.render("[FlipTrace] stackWrite replay \(write)")
                switch write {
                case .chapterReady:
                    // A deferred write is already owed; the spine that prompted it is not
                    // recorded because the placement is driven by the current position.
                    self.handleChapterReady(nil, on: pageViewController)
                case .link(let page):
                    self.applyLinkNavigation(to: page, on: pageViewController)
                case .externalTarget:
                    self.applyDeferredExternalTarget(on: pageViewController)
                }
            }
        }

        /// Applies an external target that arrived while the stack was owned elsewhere.
        /// A cancelled turn can settle on the page it started from, which publishes no
        /// binding change and therefore no further `updateUIViewController` pass —
        /// without this replay the jump would be stranded until the next unrelated
        /// re-render.
        private func applyDeferredExternalTarget(on pageViewController: UIPageViewController) {
            guard let position = externalTargetPosition else { return }
            let targetVC = displayViewController(for: position)
            setPage(targetVC, on: pageViewController, layoutNow: true)
            guard !isPlaceholderDisplay(targetVC) else { return }
            let clear = clearExternalTargetPosition
            DispatchQueue.main.async { clear() }
        }

        /// The single non-animated stack writer. Every code path that places a page
        /// without animation (appearance rebuilds, position commands, chapter-ready
        /// refreshes, snapshot swaps, initial alignment) goes through here, so the
        /// highlight/stack/sync sequence can't drift between call sites. Animated
        /// transitions go through performProgrammaticTransition instead.
        @discardableResult
        fileprivate func setPage(
            _ targetVC: UIViewController,
            on pageViewController: UIPageViewController,
            direction: UIPageViewController.NavigationDirection = .forward,
            layoutNow: Bool = false,
            notifyFallback: Bool = true
        ) -> Int? {
            let stackWriteTrace = pageTurnTrace.beginStackWrite(targetVC)
            defer { pageTurnTrace.endStep(stackWriteTrace) }
            applyPlaybackHighlight(to: targetVC)
            pageViewController.setViewControllers(
                viewControllerStack(startingWith: targetVC),
                direction: direction,
                animated: false
            )
            if layoutNow {
                pageViewController.view.layoutIfNeeded()
            }
            let shownPage = syncStablePosition(afterShowing: targetVC, notifyFallback: notifyFallback)
            // Opening, a jump or a chapter landing: no turn has settled to warm the
            // neighbours, so the first swipe would draw its page mid-gesture.
            if let page = (targetVC as? any PageIndexProviding)?.globalPageIndex {
                prefetchPages(around: page)
            }
            return shownPage
        }

        /// Draws the pages a turn from `page` will show before the turn asks for them.
        /// A spread turns two pages at a time, so the next spread is drawn too.
        fileprivate func prefetchPages(around page: Int) {
            currentEngine.prefetchPageImages(around: page)
            if isDoublePageSpread {
                currentEngine.prefetchPageImages(around: page + pageStride)
            }
        }

        func applyVisibleRefresh(
            _ commit: ReaderVisibleRefreshCommit,
            on pageViewController: UIPageViewController,
            completion: @escaping (UInt64, ReaderVisibleRefreshOutcome) -> Void
        ) {
            guard commit.mode == .paged,
                  commit.transactionID != lastAppliedRefreshTransactionID
            else { return }

            let target = displayViewController(for: commit.position)
            guard !isPlaceholderDisplay(target) else {
                completion(
                    commit.transactionID,
                    .failed(.layoutUnavailable(commit.position.spineIndex))
                )
                return
            }
            _ = setPage(target, on: pageViewController, layoutNow: true)
            lastAppliedRefreshTransactionID = commit.transactionID
            completion(commit.transactionID, .applied)
        }

        fileprivate func viewControllerStack(startingWith viewController: UIViewController) -> [UIViewController] {
            stackWriteTotalPages = currentEngine.totalPages
            return [viewController]
        }

        private var curlNeighbourPageCount: Int {
            max(currentEngine.totalPages, stackWriteTotalPages)
        }

        private func curlBackPage(logicalPageIndex: Int) -> PageBackViewController? {
            guard let contentPage = ReaderCurlBackPageResolver.contentPageIndex(
                logicalPageIndex: logicalPageIndex,
                totalPages: curlNeighbourPageCount
            ) else { return nil }
            let snapshotTrace = pageTurnTrace.beginCurlBack(page: contentPage)
            let renderedPageImage = currentEngine.renderSnapshot(forPage: contentPage)
            pageTurnTrace.endCurlBack(snapshotTrace, hasImage: renderedPageImage != nil)
            return PageBackViewController(
                virtualIndex: ReaderCurlVirtualIndex.backIndex(
                    forLogicalPage: logicalPageIndex,
                    isRTL: isRTL
                ),
                logicalPageIndex: logicalPageIndex,
                globalPageIndex: contentPage,
                backgroundColor: curlBackPageColor,
                // The back is the same fully composed page, mirrored by
                // PageBackViewController. This preserves dark mode, built-in/custom
                // colors, custom images, and text without leaking the next page.
                // If an unloaded/FXL provider cannot snapshot yet, the controller
                // keeps the effective theme/custom color as a crash-safe back. Remove
                // that fallback once every PageRenderingProvider supports snapshots.
                renderedPageImage: renderedPageImage,
                readingPosition: currentEngine.readingPosition(forPage: contentPage)
            )
        }

        fileprivate func transitionViewControllerStack(
            startingWith viewController: UIViewController,
            animated: Bool,
            visiblePage: Int
        ) -> [UIViewController] {
            guard usesCurlBackPages,
                  animated,
                  !isPlaceholderDisplay(viewController),
                  let page = viewController as? any PageIndexProviding & UIViewController else {
                return viewControllerStack(startingWith: viewController)
            }
            let logicalPage = ReaderCurlBackPageResolver.logicalPageIndex(
                targetPage: page.globalPageIndex,
                visiblePage: visiblePage
            )
            guard let backPage = curlBackPage(logicalPageIndex: logicalPage) else {
                return viewControllerStack(startingWith: viewController)
            }
            stackWriteTotalPages = currentEngine.totalPages
            return [viewController, backPage]
        }

        init(engine: any PageRenderingProvider,
             pageTurnStyle: PageTurnStyle,
             theme: ReaderTheme,
             playbackHighlight: ReaderPlaybackHighlight?,
             isRTL: Bool,
             isDoublePageSpread: Bool,
             spreadGutter: CGFloat,
             sessionCoordinator: ReaderSessionCoordinator?,
             externalTargetPosition: CoreTextReadingPosition?,
             clearExternalTargetPosition: @escaping () -> Void,
             currentPage: Binding<Int>,
             onPageChanged: @escaping (Int, CoreTextReadingPosition?) -> Void,
             onTapZone: @escaping (TouchAction) -> Void,
             onUserPageTurnBegan: @escaping () -> Void = {},
             onSwipeUpExit: @escaping () -> Void = {},
             isCurrentPageBookmarked: @escaping () -> Bool = { false },
             onPullDownBookmark: @escaping () -> Void = {}) {
            self.currentEngine = engine
            self.pageTurnStyle = pageTurnStyle
            self.pageTurnTrace = ReaderPageTurnTrace(pageTurnStyle: pageTurnStyle)
            self.currentTheme = theme
            self.currentPlaybackHighlight = playbackHighlight
            self.isRTL = isRTL
            self.isDoublePageSpread = isDoublePageSpread
            self.spreadGutter = spreadGutter
            self.sessionCoordinator = sessionCoordinator
            self.externalTargetPosition = externalTargetPosition
            self.clearExternalTargetPosition = clearExternalTargetPosition
            self._currentPage = currentPage
            self.onPageChanged = onPageChanged
            self.onTapZone = onTapZone
            self.onUserPageTurnBegan = onUserPageTurnBegan
            self.onSwipeUpExit = onSwipeUpExit
            self.isCurrentPageBookmarked = isCurrentPageBookmarked
            self.onPullDownBookmark = onPullDownBookmark
            if let externalTargetPosition {
                // Direct, because a method call before `super.init` does not compile. Safe
                // to leave outside the funnel only because `.externalTarget` reports
                // nothing anyway — the stack write that follows is what lands and reports.
                self.currentCoreTextPosition = externalTargetPosition
                self.pendingNavigation = PendingNavigation(target: .position(externalTargetPosition))
            }
        }

        deinit {
            clearEngineCallbacks()
        }

        func bindEngineCallbacks(to engine: any PageRenderingProvider, pageViewController: UIPageViewController) {
            let identifier = ObjectIdentifier(engine as AnyObject)
            if callbackEngineIdentifier == identifier {
                return
            }

            clearEngineCallbacks()
            callbackEngineObject = engine as AnyObject
            callbackEngineIdentifier = identifier

            engine.onChapterReady = { [weak self, weak pageViewController] spineIndex in
                DispatchQueue.main.async {
                    guard let self, let pageViewController else { return }
                    guard self.callbackEngineIdentifier == identifier else { return }
                    let line =
                        "[StartupTrace][ReaderView.Coordinator] onChapterReady spine=\(spineIndex.map(String.init) ?? "all") currentPage=\(self.currentPage) enginePage=\(engine.currentPage) totalPages=\(engine.totalPages)"
                    AppLogger.render(line)
                    NSLog("%@", line)
                    if let spineIndex { self.unresolvedChapters.removeValue(forKey: spineIndex) }
                    let chapterReadyTrace = self.pageTurnTrace.beginChapterReady(spine: spineIndex)
                    self.handleChapterReady(spineIndex, on: pageViewController)
                    self.pageTurnTrace.endStep(chapterReadyTrace)
                }
            }

            engine.onChapterLayoutUnresolved = { [weak self] spineIndex, outcome in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.callbackEngineIdentifier == identifier else { return }
                    self.unresolvedChapters[spineIndex] = outcome
                }
            }

            engine.onNavigateToPage = { [weak self] page in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.callbackEngineIdentifier == identifier else { return }
                    self.handleNavigate(to: page)
                }
            }

            if let linkEngine = engine as? any LinkNavigationProviding {
                linkEngine.onLinkNavigate = { [weak self, weak pageViewController] page in
                    DispatchQueue.main.async {
                        guard let self, let pageViewController else { return }
                        guard self.callbackEngineIdentifier == identifier else { return }
                        self.handleLinkNavigate(to: page, on: pageViewController)
                    }
                }
            }

            if engine.currentPage > 0, currentPage == 0 {
                handleNavigate(to: engine.currentPage)
            }
        }

        private func clearEngineCallbacks() {
            if let engine = callbackEngineObject as? any PageRenderingProvider {
                engine.onChapterReady = nil
                engine.onChapterLayoutUnresolved = nil
                engine.onNavigateToPage = nil
            }
            if let linkEngine = callbackEngineObject as? any LinkNavigationProviding {
                linkEngine.onLinkNavigate = nil
            }
            callbackEngineObject = nil
            callbackEngineIdentifier = nil
            unresolvedChapters.removeAll()
        }

        fileprivate func displayViewController(at index: Int) -> UIViewController {
            installAccessibilityActions(on: makeDisplayViewController(at: index))
        }

        private func makeDisplayViewController(at index: Int) -> UIViewController {
            guard isDoublePageSpread else {
                return currentEngine.pageViewController(at: index)
            }

            let totalPages = currentEngine.totalPages
            let clamped = totalPages > 0 ? max(0, min(index, totalPages - 1)) : 0
            if let fixedLayoutPair = fixedLayoutPairingProvider?.fixedLayoutSpreadPair(containing: clamped),
               fixedLayoutPair.isSinglePage {
                return currentEngine.pageViewController(at: fixedLayoutPair.globalPageIndex)
            }
            return spreadViewController(containingPage: clamped)
        }

        fileprivate func displayViewController(for position: CoreTextReadingPosition) -> UIViewController {
            installAccessibilityActions(on: makeDisplayViewController(for: position))
        }

        private func makeDisplayViewController(for position: CoreTextReadingPosition) -> UIViewController {
            guard isDoublePageSpread else {
                return currentEngine.pageViewController(for: position)
            }

            if let page = currentEngine.pageIndex(for: position) {
                return makeDisplayViewController(at: page)
            }

            let page = (currentEngine.pageViewController(for: position) as? any PageIndexProviding)?.globalPageIndex
                ?? currentEngine.estimatedGlobalPage(for: position)
                ?? 0
            return spreadViewController(containingPage: page)
        }

        /// Single funnel for VoiceOver wiring: every page the coordinator hands to
        /// UIPageViewController — visible page, data-source neighbours, spread halves —
        /// passes through here, so a page can never reach the screen unreachable to
        /// VoiceOver. `onTapZone` is the same sink the tap zones use, so the
        /// accessibility commands and the touch commands stay one path.
        @discardableResult
        private func installAccessibilityActions(on viewController: UIViewController) -> UIViewController {
            switch viewController {
            case let page as CoreTextPageViewController:
                page.accessibilityUsesRTLPageOrder = isRTL
                page.onAccessibilityAction = { [weak self] action in
                    self?.performAccessibilityAction(action)
                }
            case let page as BrowserLayoutPageViewController:
                page.accessibilityUsesRTLPageOrder = isRTL
                page.onAccessibilityAction = { [weak self] action in
                    self?.performAccessibilityAction(action)
                }
            case let placeholder as PlaceholderPageViewController:
                placeholder.onAccessibilityAction = { [weak self] action in
                    self?.performAccessibilityAction(action)
                }
            case let spread as ReaderSpreadPageViewController:
                spread.pageViewControllers.forEach { _ = installAccessibilityActions(on: $0) }
            default:
                break
            }
            return viewController
        }

        private func performAccessibilityAction(_ action: TouchAction) {
            DispatchQueue.main.async { self.onTapZone(action) }
        }

        /// Build the two-page spread that contains `page`, snapping the pair to a
        /// fixed even-page grid so spreads always tile (0,1)(2,3)… regardless of the
        /// entry page (TOC jump, position restore). Without snapping, entering on an
        /// odd page offsets every following spread by one and the centre gutter
        /// appears to drift off-centre.
        private func spreadViewController(containingPage page: Int) -> UIViewController {
            if let fixedLayoutPair = fixedLayoutPairingProvider?.fixedLayoutSpreadPair(containing: page) {
                let left = fixedLayoutPair.leftPage.map { currentEngine.pageViewController(at: $0) }
                let right = fixedLayoutPair.rightPage.map { currentEngine.pageViewController(at: $0) }
                return ReaderSpreadPageViewController(
                    globalPageIndex: fixedLayoutPair.globalPageIndex,
                    leftViewController: left,
                    rightViewController: right,
                    gutter: spreadGutter,
                    backgroundColor: UIColor(currentTheme.backgroundColor)
                )
            }

            let totalPages = currentEngine.totalPages
            let pairStart = (max(0, page) / 2) * 2
            let primary = currentEngine.pageViewController(at: pairStart)
            let secondaryPage = pairStart + 1
            let secondary = secondaryPage < totalPages
                ? currentEngine.pageViewController(at: secondaryPage)
                : nil

            return ReaderSpreadPageViewController(
                globalPageIndex: pairStart,
                primaryViewController: primary,
                secondaryViewController: secondary,
                isRTL: isRTL,
                gutter: spreadGutter,
                backgroundColor: UIColor(currentTheme.backgroundColor)
            )
        }

        /// Chapters whose last layout attempt finished without one, and why.
        ///
        /// Written by `onChapterLayoutUnresolved`, cleared by `onChapterReady`. This is
        /// bookkeeping for the detector below and nothing else — it never triggers a
        /// re-layout. `Technotes/ReaderChapterSupply.md` rules out the self-healing poll
        /// that used to live here; observing is not repairing.
        fileprivate var unresolvedChapters: [Int: ChapterLayoutOutcome] = [:]

        /// A 載入中 page the reader is still looking at when they try to turn again.
        ///
        /// No timer: the trigger is the user's own next gesture, which is also the
        /// moment the symptom is real to them. Reported once per chapter — someone
        /// stuck on one swipes repeatedly, and an anomaly per swipe would bury the log
        /// it is supposed to make readable.
        private func reportStuckPlaceholderIfNeeded(showing viewController: UIViewController) {
            guard isPlaceholderDisplay(viewController),
                  let position = (viewController as? CoreTextReadingPositionProviding)?
                      .coreTextReadingPosition,
                  let outcome = unresolvedChapters[position.spineIndex]
            else { return }

            // Cleared so a run of swipes produces one report, not one each. The next
            // failed attempt on this chapter writes it back.
            unresolvedChapters.removeValue(forKey: position.spineIndex)

            AppLogger.anomaly(
                localized("章節停在載入中且沒有再次嘗試"),
                category: .reader,
                detail: [
                    "chapter=\(position.spineIndex)",
                    "charOffset=\(position.charOffset)",
                    "outcome=\(outcome.rawValue)",
                    "laidOutChapters=\(currentEngine.layouts.keys.sorted())",
                    "totalPages=\(currentEngine.totalPages)",
                ].joined(separator: "\n")
            )
        }

        fileprivate func isPlaceholderDisplay(_ viewController: UIViewController) -> Bool {
            if viewController is PlaceholderPageViewController { return true }
            if let spread = viewController as? ReaderSpreadPageViewController {
                return spread.containsPlaceholderPage
            }
            return false
        }

        private func renderSnapshotForDisplayPage(_ page: Int) -> UIImage? {
            guard isDoublePageSpread else {
                return currentEngine.renderSnapshot(forPage: page)
            }

            if let fixedLayoutPair = fixedLayoutPairingProvider?.fixedLayoutSpreadPair(containing: page) {
                guard !fixedLayoutPair.isSinglePage else {
                    return currentEngine.renderSnapshot(forPage: fixedLayoutPair.globalPageIndex)
                }
                let leftImage = fixedLayoutPair.leftPage.flatMap { currentEngine.renderSnapshot(forPage: $0) }
                let rightImage = fixedLayoutPair.rightPage.flatMap { currentEngine.renderSnapshot(forPage: $0) }
                guard leftImage != nil || rightImage != nil else { return nil }
                let reference = leftImage ?? rightImage!
                let pageWidth = reference.size.width
                let pageHeight = max(leftImage?.size.height ?? reference.size.height, rightImage?.size.height ?? reference.size.height)
                let resultSize = CGSize(width: pageWidth * 2 + spreadGutter, height: pageHeight)
                let renderer = UIGraphicsImageRenderer(size: resultSize)
                return renderer.image { context in
                    UIColor(currentTheme.backgroundColor).setFill()
                    context.fill(CGRect(origin: .zero, size: resultSize))
                    leftImage?.draw(in: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
                    rightImage?.draw(in: CGRect(
                        x: pageWidth + spreadGutter,
                        y: 0,
                        width: pageWidth,
                        height: pageHeight
                    ))
                }
            }

            guard let primary = currentEngine.renderSnapshot(forPage: page) else { return nil }
            let secondaryPage = page + 1
            let secondary: UIImage?
            if secondaryPage < currentEngine.totalPages {
                guard let image = currentEngine.renderSnapshot(forPage: secondaryPage) else { return nil }
                secondary = image
            } else {
                secondary = nil
            }

            let pageWidth = primary.size.width
            let pageHeight = max(primary.size.height, secondary?.size.height ?? primary.size.height)
            let resultSize = CGSize(width: pageWidth * 2 + spreadGutter, height: pageHeight)
            let renderer = UIGraphicsImageRenderer(size: resultSize)
            return renderer.image { context in
                UIColor(currentTheme.backgroundColor).setFill()
                context.fill(CGRect(origin: .zero, size: resultSize))

                let leftImage = isRTL ? secondary : primary
                let rightImage = isRTL ? primary : secondary
                leftImage?.draw(in: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
                rightImage?.draw(in: CGRect(
                    x: pageWidth + spreadGutter,
                    y: 0,
                    width: pageWidth,
                    height: pageHeight
                ))
            }
        }

        /// `spineIndex` is the chapter whose layout landed, or nil for a change that
        /// affects the whole book (page offsets rebuilt, appearance applied).
        ///
        /// Every layout install announces itself, neighbours included, so most calls here
        /// concern a chapter the reader is not looking at. Such a chapter changes only where
        /// the visible page falls in the global numbering — `spinePageOffsets` shifted — so
        /// republish that index for the footer and leave the stack alone. Rewriting it would
        /// re-create the visible page controller once per preloaded chapter, while the reader
        /// is simply reading.
        ///
        /// A placeholder must never take that shortcut: `committedReadingPosition` refuses to
        /// guess a position for one, which is exactly the stuck-載入中 case this path exists
        /// to resolve.
        private func handleChapterReady(
            _ spineIndex: Int?,
            on pageViewController: UIPageViewController
        ) {
            if let spineIndex,
               pendingNavigation == nil,
               externalTargetPosition == nil,
               let visible = pageViewController.viewControllers?.first,
               let visiblePosition = committedReadingPosition(of: visible),
               visiblePosition.spineIndex != spineIndex {
                if let page = currentEngine.pageIndex(for: visiblePosition) {
                    handleNavigate(to: page)
                }
                return
            }
            guard stackWriteGate.request(.chapterReady) == .performNow else { return }
            let engine = currentEngine
            let fallbackPage = max(0, min(currentPage, max(engine.totalPages - 1, 0)))
            let freshVC: UIViewController
            let targetPage: Int

            if let pendingNavigation,
               let resolved = resolvedNavigation(pendingNavigation.target) {
                freshVC = resolved.viewController
                targetPage = resolved.page
                self.pendingNavigation = nil
            } else if let position = currentCoreTextPosition {
                freshVC = displayViewController(for: position)
                targetPage = engine.pageIndex(for: position)
                    ?? (freshVC as? any PageIndexProviding)?.globalPageIndex
                    ?? fallbackPage
            } else {
                targetPage = fallbackPage
                freshVC = displayViewController(at: targetPage)
            }
            let prepareLine =
                "[StartupTrace][ReaderView.Coordinator] handleChapterReady targetPage=\(targetPage) fallbackPage=\(fallbackPage)"
            AppLogger.render(prepareLine)
            NSLog("%@", prepareLine)

            var direction: UIPageViewController.NavigationDirection
            if let first = pageViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) {
                direction = targetPage >= first.globalPageIndex ? .forward : .reverse
            } else {
                direction = .forward
            }
            if isRTL { direction = direction == .forward ? .reverse : .forward }

            let resolved = setPage(freshVC, on: pageViewController, direction: direction, notifyFallback: false)
            let resolvedLine =
                "[StartupTrace][ReaderView.Coordinator] handleChapterReady syncedPage=\(resolved ?? -1)"
            AppLogger.render(resolvedLine)
            NSLog("%@", resolvedLine)
            if let target = externalTargetPosition,
               let resolved,
               currentEngine.pageIndex(for: target) == resolved {
                externalTargetPosition = nil
                clearExternalTargetPosition()
            }
        }

        private func publishCurrentPage(
            _ page: Int,
            position: CoreTextReadingPosition? = nil,
            notify: Bool
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Latest intent wins (Readium-style): while a page-turn burst is
                // still chaining (a queued transition was handed off and has not
                // settled yet), this settle is intermediate. Writing it back would
                // drag the binding behind the user's newest taps — eating them and
                // triggering reverse "correction" transitions. The final transition
                // in the chain publishes the real page.
                if self.isPageTransitioning, self.currentPage != page {
                    return
                }

                let didChange = self.currentPage != page
                let publishTrace = self.pageTurnTrace.beginPublish(page: page, changed: didChange)
                defer { self.pageTurnTrace.endStep(publishTrace) }

                if didChange {
                    self.currentPage = page
                }

                if notify, didChange || position != nil {
                    self.onPageChanged(page, position)
                }
            }
        }

        private func handleNavigate(to page: Int) {
            let clamped = max(0, min(page, max(currentEngine.totalPages - 1, 0)))
            publishCurrentPage(clamped, notify: true)
        }

        /// A tapped in-content link (TOC table, cross-reference). Unlike `handleNavigate` —
        /// which only republishes the binding for pagination-offset corrections — a link tap
        /// must move the visible page itself: the executor model never reconciles the
        /// binding against the page view controller between commands.
        private func handleLinkNavigate(to page: Int, on pageViewController: UIPageViewController) {
            let clamped = max(0, min(page, max(currentEngine.totalPages - 1, 0)))
            guard stackWriteGate.request(.link(page: clamped)) == .performNow else { return }
            applyLinkNavigation(to: clamped, on: pageViewController)
        }

        private func applyLinkNavigation(to clamped: Int, on pageViewController: UIPageViewController) {
            let targetVC = displayViewController(at: clamped)
            guard !isPlaceholderDisplay(targetVC) else {
                // Chapter layout not ready yet — park the target; handleChapterReady
                // consumes pendingNavigation once the real page exists.
                pendingNavigation = PendingNavigation(target: .page(clamped))
                return
            }
            _ = setPage(targetVC, on: pageViewController, layoutNow: true)
        }

        @discardableResult
        func requestPageTransition(to targetPage: Int, visiblePage: Int) -> [ReaderEffect] {
            sessionCoordinator?.send(.pageTurnRequested(
                targetPage: targetPage,
                visiblePage: visiblePage
            )) ?? [.requestPageTransition(targetPage: targetPage)]
        }

        func warmUpNext(currentGlobalPage: Int) {
            let effects = sessionCoordinator?.send(.warmUpNext(currentGlobalPage: currentGlobalPage))
                ?? [.warmUpNext(currentGlobalPage: currentGlobalPage)]
            for effect in effects {
                guard case let .warmUpNext(page) = effect else { continue }
                Task { @MainActor in
                    let warmUpTrace = self.pageTurnTrace.beginWarmUp(page: page)
                    self.currentEngine.warmUpNext(currentGlobalPage: page)
                    self.pageTurnTrace.endStep(warmUpTrace)
                }
            }
        }

        private func applyTransitionEffects(
            _ effects: [ReaderEffect],
            on pageViewController: UIPageViewController,
            showing visiblePage: Int
        ) {
            for effect in effects {
                switch effect {
                case let .warmUpNext(currentGlobalPage):
                    warmUpNext(currentGlobalPage: currentGlobalPage)

                case let .requestPageTransition(targetPage):
                    var direction: UIPageViewController.NavigationDirection =
                        targetPage >= visiblePage ? .forward : .reverse
                    if isRTL {
                        direction = direction == .forward ? .reverse : .forward
                    }
                    // Chained continuation of a tap burst (this path is only fed by
                    // queued page turns; TOC-style jumps never come through here).
                    // Animate it even when the accumulated target is non-adjacent —
                    // snapping here is why rapid tapping made animations vanish.
                    // The queue keeps only the latest target, so at most one
                    // animation of lag ever accumulates (Legado's abort-and-restart
                    // feel, within UIPageViewController's no-abort constraint).
                    // Cover keeps its own overlay animator path; .none stays instant.
                    let shouldAnimate = pageTurnStyle == .slide || pageTurnStyle == .curl
                    performProgrammaticTransition(
                        on: pageViewController,
                        to: targetPage,
                        from: visiblePage,
                        direction: direction,
                        animated: shouldAnimate,
                        chained: true
                    )

                default:
                    break
                }
            }
        }

        private func continueQueuedTransitionIfNeeded(
            on pageViewController: UIPageViewController,
            showing visiblePage: Int
        ) {
            guard let sessionCoordinator else { return }
            let effects = sessionCoordinator.send(.pageTransitionSettled(visiblePage: visiblePage))
            guard !effects.isEmpty else { return }
            if effects.contains(where: { if case .requestPageTransition = $0 { true } else { false } }) {
                pageTurnTrace.queueChained(visible: visiblePage)
            }
            // This runs inside the *completion* of the previous animated setViewControllers.
            // Starting the next animated transition synchronously here makes
            // _UIQueuingScrollView raise NSInternalInconsistencyException — it is still
            // settling the just-finished scroll. Hop to the next runloop so the page view
            // controller fully unwinds before the queued transition begins. (State was
            // already advanced synchronously by `send(.pageTransitionSettled:)` above.)
            DispatchQueue.main.async { [weak self] in
                self?.applyTransitionEffects(effects, on: pageViewController, showing: visiblePage)
            }
        }

        fileprivate func performProgrammaticTransition(
            on pageViewController: UIPageViewController,
            to targetPage: Int,
            from visiblePage: Int,
            direction: UIPageViewController.NavigationDirection,
            animated: Bool,
            chained: Bool = false
        ) {
            let turnTrace = pageTurnTrace.beginTapTurn(
                from: visiblePage, to: targetPage, speed: activeTurnSpeed,
                animated: animated, chained: chained
            )
            let buildTrace = pageTurnTrace.beginBuild(to: targetPage)
            let targetViewController = displayViewController(at: targetPage)
            applyPlaybackHighlight(to: targetViewController)
            pageTurnTrace.endStep(buildTrace)
            // Rapid-tap speed-up (curl): UIKit's setViewControllers(animated:) has no
            // duration parameter, so the page-curl animation is scaled via the
            // container layer's timing. Set before the animation is added; reset to
            // 1× on settle so it never leaks into interactive swipes or later lone
            // taps. Chained catch-up turns re-apply activeTurnSpeed on their own call.
            // The speed is re-based, never assigned: assigning it is what left the curl
            // drawn every few refreshes — `ReaderTurnLayerClock` has the measurements.
            // UIKit's own slide can't use this — see `runsTimedSlide` below; the push
            // that replaces it carries its speed in its duration, and only a speed-up
            // arriving mid-turn goes through the layer clock (`speedUpTurnInFlight`).
            let scalesNativeTransition = animated && pageTurnStyle == .curl
            if scalesNativeTransition {
                beginRetimableTurn(on: pageViewController.view.layer, builtInSpeed: 1)
                ReaderTurnLayerClock.setSpeed(activeTurnSpeed, on: pageViewController.view.layer)
            }
            let runsTimedSlide = ReaderSlideTurnAnimation.runsTimedPush(
                pageTurnStyle: pageTurnStyle,
                animated: animated
            )
            let finishTransition: (UIViewController) -> Void = { shownViewController in
                self.endRetimableTurn()
                let resolvedPage = self.syncStablePosition(afterShowing: shownViewController, notifyFallback: true)
                self.continueQueuedTransitionIfNeeded(on: pageViewController, showing: resolvedPage ?? targetPage)
                self.endAnimatedTransition(on: pageViewController)
                if animated { self.turnFrameRate.end() }
                self.pageTurnTrace.endTapTurn(turnTrace, landed: resolvedPage)
            }
            if animated {
                beginAnimatedTransition()
                turnFrameRate.begin()
            }
            // Once the turn has started, draw the pages a following tap would turn
            // to while this one animates — the render server plays it, not the main
            // thread.
            defer { prefetchPages(around: targetPage) }

            func runTransition(
                animated animatedFlag: Bool,
                completion: @escaping (UIViewController) -> Void
            ) {
                let stack = self.transitionViewControllerStack(
                    startingWith: targetViewController,
                    animated: animatedFlag,
                    visiblePage: visiblePage
                )
                if let sessionCoordinator = self.sessionCoordinator {
                    sessionCoordinator.performProgrammaticPageTransition(
                        pageTurnStyle: self.pageTurnStyle,
                        on: pageViewController,
                        targetViewController: targetViewController,
                        targetViewControllers: stack,
                        direction: direction,
                        animated: animatedFlag,
                        completion: completion
                    )
                    return
                }
                ProgrammaticPageTransitionPerformer(pageTurnStyle: self.pageTurnStyle).perform(
                    on: pageViewController,
                    targetViewController: targetViewController,
                    targetViewControllers: stack,
                    direction: direction,
                    animated: animatedFlag,
                    completion: completion
                )
            }

            // A slide turn runs as an explicit CATransition instead of the page view
            // controller's own animation — `ReaderSlideTurnAnimation` says why. A push
            // moves two layer snapshots, the same visual (both pages translate
            // together) with a duration we own, and the page swap itself becomes
            // non-animated, so the stack is free again the moment the push lands and
            // a queued tap follows at once.
            let startTrace = pageTurnTrace.beginStart(to: targetPage)
            defer { pageTurnTrace.endStep(startTrace) }
            guard runsTimedSlide else {
                runTransition(animated: animated, completion: finishTransition)
                return
            }
            var settled: UIViewController?
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                finishTransition(settled ?? targetViewController)
            }
            beginRetimableTurn(on: pageViewController.view.layer, builtInSpeed: activeTurnSpeed)
            pageViewController.view.layer.add(
                ReaderSlideTurnAnimation.pushTransition(direction: direction, speed: activeTurnSpeed),
                forKey: Self.slideTransitionKey
            )
            runTransition(animated: false) { settled = $0 }
            // Commit the post-swap layout inside the same transaction so the
            // transition's "after" state is the new page, not a half-laid-out one.
            pageViewController.view.layoutIfNeeded()
            CATransaction.commit()
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let action: TouchAction
            if GlobalSettings.shared.readerTapBothSidesNextPage {
                let xFraction = point.x / max(view.bounds.width, 1)
                action = (0.3...0.7).contains(xFraction) ? .toggleMenu : .nextPage
            } else {
                let config = TouchZoneConfig.effective(
                    isProActive: SubscriptionStore.shared.isProActive,
                    isRTL: isRTL
                )
                action = config.action(at: point, in: view.bounds.size)
            }
            pageTurnTrace.tapRecognized(action, at: point, in: view.bounds.size)
            DispatchQueue.main.async {
                self.onTapZone(action)
                self.pageTurnTrace.tapDispatched()
            }
        }

        /// The landing of a 覆蓋 turn, and the initial stack.
        ///
        /// - Parameter readerDriven: 覆蓋 turns are all the reader asking — an interactive
        ///   drag, or a turn command from a tap or a volume key. The initial stack is not.
        func captureStablePosition(from viewController: UIViewController, readerDriven: Bool = false) {
            setCurrentPosition(
                readingPosition(from: viewController),
                .settled(readerDriven: readerDriven, isPlaceholder: isPlaceholderDisplay(viewController))
            )
        }

        var lastAppliedPageBarsRevision: UInt = 0

        /// Sits above every page, outside `UIPageViewController`'s own hierarchy,
        /// exactly like `coverOverlayView`. It never receives touches.
        let autoReadRevealView = AutoReadRevealView()

        /// Puts the next page over the current one and moves the clip line.
        ///
        /// The snapshot already carries 頁眉／頁腳 because it comes from
        /// `renderSnapshot` → `renderPage`, the same function that draws the live
        /// page — so the revealed page brings its own bars, as it does in legado.
        func applyAutoReadReveal(
            page: Int?,
            handle: ReaderAutoReadRevealHandle?,
            on pageViewController: UIPageViewController
        ) {
            guard let page else {
                handle?.setProgress = nil
                autoReadRevealView.removeFromSuperview()
                autoReadRevealView.setPageImage(nil, pageIndex: nil)
                return
            }
            if autoReadRevealView.superview !== pageViewController.view {
                pageViewController.view.addSubview(autoReadRevealView)
            }
            autoReadRevealView.frame = pageViewController.view.bounds
            pageViewController.view.bringSubviewToFront(autoReadRevealView)
            if autoReadRevealView.imagePageIndex != page {
                autoReadRevealView.setPageImage(
                    currentEngine.renderSnapshot(forPage: page),
                    pageIndex: page
                )
                // A new page starts its curtain closed, whatever the last frame of
                // the previous one left behind.
                autoReadRevealView.setProgress(0)
            }
            autoReadRevealView.setEdgeColor(.tintColor)
            handle?.setProgress = { [weak autoReadRevealView] progress in
                autoReadRevealView?.setProgress(CGFloat(progress))
            }
        }

        /// Re-hands a page its bars. New pages get theirs from the engine when they
        /// are built; this is only for the ones already on screen.
        func applyPageBars(to viewController: UIViewController) {
            guard let engine = currentEngine as? PageBarsProviding,
                  let provider = engine.pageBarsProvider
            else { return }
            if let spread = viewController as? ReaderSpreadPageViewController {
                spread.pageViewControllers.forEach { applyPageBars(to: $0) }
                return
            }
            guard let page = viewController as? CoreTextPageViewController else { return }
            page.pageBars = provider(page.globalPageIndex)
        }

        func applyPlaybackHighlight(to viewController: UIViewController) {
            guard !(viewController is PageBackViewController) else { return }
            if let spread = viewController as? ReaderSpreadPageViewController {
                spread.applyPlaybackHighlight(currentPlaybackHighlight)
                return
            }
            (viewController as? CoreTextPageViewController)?.setPlaybackHighlight(currentPlaybackHighlight)
            (viewController as? BrowserLayoutPageViewController)?.setPlaybackHighlight(currentPlaybackHighlight)
        }

        @discardableResult
        /// - Parameter readerDriven: true only when a swipe the reader made is what put
        ///   this page on screen. Every other caller here is the app re-placing the stack
        ///   — a chapter landing, a queued transition, a link — and those are precisely the
        ///   moves that have to justify themselves.
        func syncStablePosition(
            afterShowing viewController: UIViewController,
            notifyFallback: Bool,
            readerDriven: Bool = false
        ) -> Int? {
            let fallbackPage = (viewController as? any PageIndexProviding)?.globalPageIndex ?? currentPage

            if let position = readingPosition(from: viewController) {
                setCurrentPosition(
                    position,
                    .settled(
                        readerDriven: readerDriven,
                        isPlaceholder: isPlaceholderDisplay(viewController)
                    )
                )

                if let resolvedPage = currentEngine.pageIndex(for: position) {
                    publishCurrentPage(resolvedPage, position: position, notify: true)
                    return resolvedPage
                }

                publishCurrentPage(fallbackPage, position: position, notify: notifyFallback)

                if notifyFallback {
                    return fallbackPage
                }

                return nil
            }

            publishCurrentPage(fallbackPage, notify: notifyFallback)

            if notifyFallback {
                return fallbackPage
            }

            return nil
        }

        /// The position a page can be stepped from.
        ///
        /// Unlike `readingPosition(from:)` this refuses to guess: a placeholder that
        /// cannot name its own offset is a page nobody has measured, and stepping from
        /// the chapter-start fallback would walk to the wrong neighbour. UIKit reads
        /// nil as "no page that way", which is the honest answer while a chapter is
        /// still paginating.
        private func committedReadingPosition(of viewController: UIViewController) -> CoreTextReadingPosition? {
            if isPlaceholderDisplay(viewController) {
                return (viewController as? CoreTextReadingPositionProviding)?.coreTextReadingPosition
            }
            return readingPosition(from: viewController)
        }

        private func readingPosition(from viewController: UIViewController) -> CoreTextReadingPosition? {
            if let provider = viewController as? CoreTextReadingPositionProviding,
               let position = provider.coreTextReadingPosition {
                return position
            }
            if let provider = viewController as? (any PageIndexProviding & UIViewController) {
                return currentEngine.readingPosition(forPage: provider.globalPageIndex)
            }
            return nil
        }

        private func resolvedNavigation(_ target: NavigationTarget) -> (viewController: UIViewController, page: Int)? {
            switch target {
            case .position(let position):
                guard let page = currentEngine.pageIndex(for: position) else { return nil }
                let viewController = displayViewController(for: position)
                guard !isPlaceholderDisplay(viewController) else { return nil }
                return (viewController, page)
            case .page(let page):
                guard page >= 0, page < currentEngine.totalPages else { return nil }
                let viewController = displayViewController(at: page)
                guard !isPlaceholderDisplay(viewController) else { return nil }
                return (viewController, page)
            }
        }

        /// Vends a neighbour page for the data source.
        ///
        /// Deliberately free of coordinator state: UIKit calls this speculatively, at
        /// times of its own choosing, for pages the reader may never turn to. Recording
        /// navigation intent here made a prefetch indistinguishable from a commit.
        /// Intent is recorded where the turn actually lands — `didFinishAnimating`.
        ///
        /// A placeholder is returned rather than nil: the data source MUST NOT return
        /// nil during an interactive gesture, which raises NSInvalidArgumentException.
        /// It is replaced once the chapter layout completes.
        private func neighbourViewController(for target: NavigationTarget) -> UIViewController? {
            let viewController: UIViewController
            switch target {
            case .position(let position):
                viewController = displayViewController(for: position)
            case .page(let page):
                viewController = displayViewController(at: page)
            }
            applyPlaybackHighlight(to: viewController)
            return viewController
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            let neighbourTrace = pageTurnTrace.beginNeighbour("before")
            // RTL: swipe left-to-right = "before" in physical gesture, but should go to NEXT page.
            // So swap Before↔After for RTL books so the swipe direction matches the reading direction.
            let neighbour = isRTL ? pageForward(from: viewController) : pageBackward(from: viewController)
            pageTurnTrace.endNeighbour(neighbourTrace, neighbour)
            return neighbour
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            let neighbourTrace = pageTurnTrace.beginNeighbour("after")
            let neighbour = isRTL ? pageBackward(from: viewController) : pageForward(from: viewController)
            pageTurnTrace.endNeighbour(neighbourTrace, neighbour)
            return neighbour
        }

        private func pageBackward(from viewController: UIViewController) -> UIViewController? {
            if let backPage = viewController as? PageBackViewController {
                return neighbourViewController(for: .page(backPage.logicalPageIndex))
            }

            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex > 0 else { return nil }

            if isDoublePageSpread {
                guard let targetPage = previousDisplayPage(before: vc.globalPageIndex) else { return nil }
                return neighbourViewController(for: .page(targetPage))
            }

            if usesCurlBackPages {
                return curlBackPage(logicalPageIndex: vc.globalPageIndex - 1)
            }

            // Position space from here down: see `PagePositionWalking`. The index the
            // page is showing under right now is not an identity UIKit may hold.
            guard let current = committedReadingPosition(of: vc),
                  let previous = currentEngine.positionBefore(current) else { return nil }
            let previousVC = neighbourViewController(for: .position(previous))
            AppLogger.render("[FlipTrace] pageBackward from=\(current) to=\(previous) landingType=\(previousVC.map { "\(type(of: $0))" } ?? "nil")")
            return previousVC
        }

        private func pageForward(from viewController: UIViewController) -> UIViewController? {
            if let backPage = viewController as? PageBackViewController {
                guard backPage.logicalPageIndex + 1 < curlNeighbourPageCount else { return nil }
                return neighbourViewController(for: .page(backPage.logicalPageIndex + 1))
            }

            guard let vc = viewController as? any PageIndexProviding & UIViewController else { return nil }

            if isDoublePageSpread {
                guard let targetPage = nextDisplayPage(after: vc.globalPageIndex) else { return nil }
                return neighbourViewController(for: .page(targetPage))
            }

            if usesCurlBackPages {
                // Double-sided interactive curl asks for a back and then a front.
                // At the book's end, returning a back first advertises a transition
                // whose second controller is nil; UIKit rejects that incomplete pair.
                guard vc.globalPageIndex < curlNeighbourPageCount - 1 else { return nil }
                return curlBackPage(logicalPageIndex: vc.globalPageIndex)
            }

            // Position space from here down: see `PagePositionWalking`. Crossing a
            // chapter boundary no longer depends on `lastPageIndex(ofChapter:)` (which
            // goes silent while a chapter is partially paginated) or on `totalPages`
            // (which is re-derived every time any chapter's layout lands).
            guard let current = committedReadingPosition(of: vc),
                  let next = currentEngine.positionAfter(current) else { return nil }
            let nextVC = neighbourViewController(for: .position(next))
            AppLogger.render("[FlipTrace] pageForward from=\(current) to=\(next) landingType=\(nextVC.map { "\(type(of: $0))" } ?? "nil")")
            return nextVC
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(
            _ pvc: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            // Use right-hand spine for RTL curl animation to match physical book physics.
            if isRTL && pageTurnStyle == .curl {
                if let current = pvc.viewControllers?.first {
                    pvc.setViewControllers(viewControllerStack(startingWith: current), direction: .forward, animated: false)
                }
                return .max
            }
            return .min
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            pageTurnTrace.beginNativeTurn(
                on: pvc,
                from: (pvc.viewControllers?.first as? any PageIndexProviding & UIViewController)?.globalPageIndex,
                ourAnimationRunning: stackWriteGate.isAnimatingTransition
            )
            if !nativeTurnHoldsFrameRate {
                nativeTurnHoldsFrameRate = true
                turnFrameRate.begin()
            }
            stackWriteGate.beginGesture()
            // The reader's swipe, not an animation of ours, puts the menu away.
            if !stackWriteGate.isAnimatingTransition { onUserPageTurnBegan() }
            if let visible = pvc.viewControllers?.first {
                reportStuckPlaceholderIfNeeded(showing: visible)
            }
            // Invariant G1's start line. Recorded here rather than in the data source
            // on purpose: `viewControllerBefore/After` are speculative queries UIKit
            // makes for pages the reader may never reach, and writing coordinator
            // state from them is what invariant 3 of `Technotes/ReaderPagingContract.md`
            // forbids. `willTransitionTo` is a real transition starting.
            if let visible = pvc.viewControllers?.first,
               let start = committedReadingPosition(of: visible) {
                ReaderPositionSentry.shared.expectGesture(
                    from: start,
                    before: currentEngine.positionBefore(start),
                    after: currentEngine.positionAfter(start),
                    // The gate is already counting animations we started ourselves, so
                    // it is the one thing here that can tell a user's swipe apart from
                    // a `setViewControllers(animated: true)` the app issued.
                    isProgrammatic: stackWriteGate.isAnimatingTransition
                )
            }
            // Report the destination when it is exactly known, so a tap queued during
            // this swipe can be re-anchored against a real page rather than replayed as
            // a stale absolute index. Nil while the far side is still paginating — an
            // estimate would make the re-anchoring worse than not doing it.
            let interactiveTarget = (pendingViewControllers.first as? CoreTextReadingPositionProviding)?
                .coreTextReadingPosition
                .flatMap { currentEngine.pageIndex(for: $0) }
            sessionCoordinator?.beginInteractivePageTransition(target: interactiveTarget)
            // The page beyond the one coming in belongs to the next swipe. UIKit builds
            // it the moment this turn lands, and a fast reader is already dragging again
            // ~15ms later (2026-10-05 trace): a render started on landing finished
            // ~10ms after the page had to be drawn on the main thread. Started now, it
            // has the whole of this swipe.
            if let interactiveTarget {
                prefetchPages(around: interactiveTarget)
            }
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            pageTurnTrace.endNativeTurn(
                completed: completed,
                landed: (pvc.viewControllers?.first as? any PageIndexProviding & UIViewController)?.globalPageIndex
            )
            if nativeTurnHoldsFrameRate {
                nativeTurnHoldsFrameRate = false
                turnFrameRate.end()
            }
            stackWriteGate.endGesture()
            AppLogger.render("[CurlTrace] didFinish completed=\(completed) visible=\((pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1) binding=\(currentPage)")

            // Any write owed while UIKit held the stack is replayed on the next
            // runloop turn — never inline here. See `drainStackWrites`.
            defer { drainStackWrites(on: pvc) }

            guard completed else {
                // The swipe was abandoned and UIKit put the original page back. There
                // is no landing to judge.
                ReaderPositionSentry.shared.cancelExpectation()
                let settledPage = (pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex
                    ?? currentPage
                continueQueuedTransitionIfNeeded(on: pvc, showing: settledPage)
                return
            }

            if pvc.viewControllers?.first is PageBackViewController {
                if let resolvedPage = syncStablePosition(
                    afterShowing: pvc.viewControllers!.first!,
                    notifyFallback: false
                ) {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: resolvedPage)
                } else {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: currentPage)
                }
                return
            }

            // No stack write happens here. `setViewControllers` inside this delegate
            // callback re-seeds `_UIQueuingScrollView` while it is still unwinding the
            // just-finished scroll — the same hazard `continueQueuedTransitionIfNeeded`
            // hops a runloop to avoid. The chapter-boundary snapshot handoff that used
            // to force one is gone: a snapshot only ever existed once the chapter was
            // laid out, so the real page was always available anyway.
            guard let vc = pvc.viewControllers?.first as? any PageIndexProviding & UIViewController else { return }
            AppLogger.render("[FlipTrace] didFinish landing type=\(type(of: vc)) page=\(vc.globalPageIndex)")
            // The turn committed, so this IS navigation intent — unlike the speculative
            // data-source queries that produced the page. Landing on a placeholder parks
            // the destination so `handleChapterReady` swaps in the real content instead
            // of snapping back to where the turn started.
            if isPlaceholderDisplay(vc),
               let settledPosition = (vc as? CoreTextReadingPositionProviding)?.coreTextReadingPosition {
                pendingNavigation = PendingNavigation(target: .position(settledPosition))
            } else {
                pendingNavigation = nil
            }
            if let resolvedPage = syncStablePosition(
                afterShowing: vc,
                notifyFallback: false,
                // The gate is counting animations we started ourselves, so it is what
                // separates the reader's swipe from a transition the app issued.
                readerDriven: !stackWriteGate.isAnimatingTransition
            ) {
                continueQueuedTransitionIfNeeded(on: pvc, showing: resolvedPage)
            } else {
                continueQueuedTransitionIfNeeded(on: pvc, showing: vc.globalPageIndex)
            }
        }

        // MARK: - Cover overlay setup

        func setupCoverOverlay(on view: UIView) {
            coverOverlayView.translatesAutoresizingMaskIntoConstraints = false
            coverOverlayView.isHidden = true
            coverOverlayView.isUserInteractionEnabled = false
            coverOverlayView.clipsToBounds = false
            coverOverlayView.backgroundColor = .clear
            view.addSubview(coverOverlayView)
            NSLayoutConstraint.activate([
                coverOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                coverOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                coverOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
                coverOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            coverCurrentImageView.contentMode = .scaleAspectFill
            coverCurrentImageView.clipsToBounds = true
            coverCurrentImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            coverOverlayView.addSubview(coverCurrentImageView)

            let screenCornerRadius = (UIScreen.main.value(forKey: "displayCornerRadius") as? CGFloat) ?? 0
            let radius = screenCornerRadius > 0 ? screenCornerRadius : 12

            // Shadow view: placed below the incoming view, not clipped, allowing shadow overflow.
            coverShadowView.backgroundColor = .clear
            coverShadowView.layer.shadowColor = UIColor.black.cgColor
            coverShadowView.layer.shadowOpacity = 0.3
            coverShadowView.layer.shadowRadius = 14
            coverOverlayView.addSubview(coverShadowView)

            coverIncomingImageView.contentMode = .scaleAspectFill
            coverIncomingImageView.clipsToBounds = true
            coverIncomingImageView.layer.cornerRadius = radius
            coverIncomingImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            coverOverlayView.addSubview(coverIncomingImageView)

            // Dimming overlay (backward): overlaid on the old page, gradually darkens as the previous page covers in.
            coverDimView.backgroundColor = .black
            coverDimView.alpha = 0
            coverDimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            coverCurrentImageView.addSubview(coverDimView)
        }

        // MARK: - Cover pan gesture
        
        private enum GestureConstants {
            static let initialTranslationThreshold: CGFloat = 18.0
            static let instantPanDistanceThreshold: CGFloat = 44.0
            static let instantPanVelocityThreshold: CGFloat = 420.0
            static let maxDimmingAlpha: CGFloat = 0.35
        }

        @objc func handleInstantPan(_ gesture: UIPanGestureRecognizer) {
            guard pageTurnStyle == .none,
                  let pvc = instantPanPageViewController,
                  let view = gesture.view else { return }

            if gesture.state == .began && (isAnimatingTransition || isPageTransitioning) {
                gesture.state = .cancelled
                return
            }

            guard gesture.state == .ended else { return }

            let translationX = gesture.translation(in: view).x
            let velocityX = gesture.velocity(in: view).x
            let turnDirection: ReaderCoverTurnDirection?
            if abs(translationX) >= GestureConstants.instantPanDistanceThreshold {
                turnDirection = ReaderCoverPageMotion.direction(
                    for: translationX,
                    threshold: GestureConstants.instantPanDistanceThreshold,
                    isRTL: isRTL
                )
            } else if abs(velocityX) >= GestureConstants.instantPanVelocityThreshold {
                turnDirection = ReaderCoverPageMotion.direction(
                    for: velocityX,
                    threshold: GestureConstants.instantPanVelocityThreshold,
                    isRTL: isRTL
                )
            } else {
                turnDirection = nil
            }

            guard let turnDirection else { return }
            let visiblePage = (pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex
                ?? currentPage
            let targetPage: Int?
            switch turnDirection {
            case .forward:
                targetPage = nextDisplayPage(after: visiblePage)
            case .backward:
                targetPage = previousDisplayPage(before: visiblePage)
            }
            guard let targetPage else { return }

            var navigationDirection: UIPageViewController.NavigationDirection =
                targetPage >= visiblePage ? .forward : .reverse
            if isRTL {
                navigationDirection = navigationDirection == .forward ? .reverse : .forward
            }

            onUserPageTurnBegan()
            performProgrammaticTransition(
                on: pvc,
                to: targetPage,
                from: visiblePage,
                direction: navigationDirection,
                animated: false
            )
        }

        @objc func handleCoverPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began && isAnimatingTransition {
                gesture.state = .cancelled
                return
            }
            let width = max(view.bounds.width, 1)
            let translationX = gesture.translation(in: view).x
            let velocityX = gesture.velocity(in: view).x

            switch gesture.state {
            case .began:
                coverTargetPage = nil
                coverDirection = nil
                // Cancel any previous in-flight animation; don't show overlay until direction is confirmed.
                coverOverlayView.layer.removeAllAnimations()
                coverIncomingImageView.layer.removeAllAnimations()
                coverDimView.layer.removeAllAnimations()
                coverDimView.alpha = 0

            case .changed:
                if coverTargetPage == nil {
                    guard let turnDirection = ReaderCoverPageMotion.direction(
                        for: translationX,
                        threshold: GestureConstants.initialTranslationThreshold,
                        isRTL: isRTL
                    ) else { return }
                    let motion = ReaderCoverPageMotion(direction: turnDirection, isRTL: isRTL)

                    if turnDirection == .forward,
                       let target = nextDisplayPage(after: currentPage) {
                        coverDirection = turnDirection
                        guard renderSnapshotForDisplayPage(target) != nil else {
                            let targetVC = displayViewController(at: target)
                            if isPlaceholderDisplay(targetVC) {
                                pendingNavigation = PendingNavigation(target: .page(target))
                                AppLogger.render("[FlipTrace] coverInteractive forward blocked placeholder targetPage=\(target)")
                            }
                            return
                        }
                        coverTargetPage = target
                        coverOverlayView.frame = view.bounds
                        coverCurrentImageView.frame = view.bounds
                        coverOverlayView.isHidden = false
                        setupForwardOutgoing(currentPageSnapshot: currentPage, newPage: target, motion: motion, in: view)
                    } else if turnDirection == .backward,
                              let target = previousDisplayPage(before: currentPage) {
                        // Don't start animation if snapshot is not ready (chapter not loaded).
                        guard let targetSnapshot = renderSnapshotForDisplayPage(target) else { return }
                        coverDirection = turnDirection
                        coverTargetPage = target
                        coverOverlayView.frame = view.bounds
                        coverCurrentImageView.frame = view.bounds
                        coverCurrentImageView.image = renderSnapshotForDisplayPage(currentPage)
                        coverOverlayView.isHidden = false
                        setupIncomingView(for: target, snapshot: targetSnapshot, motion: motion, in: view)
                    }
                    if coverTargetPage != nil { onUserPageTurnBegan() }
                }
                guard coverTargetPage != nil, let coverDirection else { return }
                let motion = ReaderCoverPageMotion(direction: coverDirection, isRTL: isRTL)
                let rawProgress = min(motion.dragProgress(translationX: translationX, width: width), 0.999)
                let newX = motion.interactiveX(progress: rawProgress, width: width)
                coverIncomingImageView.frame.origin.x = newX
                coverShadowView.frame.origin.x = newX
                if coverDirection == .backward {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = rawProgress * GestureConstants.maxDimmingAlpha
                } else if coverDirection == .forward {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = (1 - rawProgress) * GestureConstants.maxDimmingAlpha
                }

            case .ended, .cancelled, .failed:
                guard let targetPage = coverTargetPage, let coverDirection else {
                    resetCoverOverlay()
                    return
                }
                let motion = ReaderCoverPageMotion(direction: coverDirection, isRTL: isRTL)
                let shouldCommit = motion.shouldCommit(
                    translationX: translationX,
                    velocityX: velocityX,
                    width: width
                )
                beginAnimatedTransition()

                let destX = motion.settledX(width: width, shouldCommit: shouldCommit)
                UIView.animate(
                    withDuration: ReaderCoverPageMotion.settleDuration,
                    delay: 0,
                    usingSpringWithDamping: 1,
                    initialSpringVelocity: ReaderCoverPageMotion.settleSpringVelocity(
                        currentX: coverIncomingImageView.frame.origin.x,
                        destinationX: destX,
                        velocityX: velocityX
                    ),
                    options: []
                ) {
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    if coverDirection == .backward {
                        self.coverDimView.alpha = shouldCommit ? GestureConstants.maxDimmingAlpha : 0
                    } else if coverDirection == .forward {
                        self.coverDimView.alpha = shouldCommit ? 0 : GestureConstants.maxDimmingAlpha
                    }
                } completion: { _ in
                    if shouldCommit {
                        var settledPosition: CoreTextReadingPosition?
                        // Set the real VC immediately so updateUIViewController returns early, avoiding double animation.
                        if let pvc = self.coverPageViewController {
                            let realVC = self.displayViewController(at: targetPage)
                            AppLogger.render("[FlipTrace] coverInteractive commit targetPage=\(targetPage) realType=\(type(of: realVC))")
                            self.applyPlaybackHighlight(to: realVC)
                            pvc.setViewControllers([realVC], direction: .forward, animated: false)
                            pvc.view.layoutIfNeeded()
                            self.captureStablePosition(from: realVC, readerDriven: true)
                            settledPosition = self.readingPosition(from: realVC)
                        }
                        self.publishCurrentPage(
                            targetPage,
                            position: settledPosition,
                            notify: true
                        )
                        self.warmUpNext(currentGlobalPage: targetPage)
                    }
                    self.resetCoverOverlay()
                    if let pvc = self.coverPageViewController {
                        self.endAnimatedTransition(on: pvc)
                    }
                }

            default:
                break
            }
        }

        // MARK: - Cover programmatic transition (tap zone)

        func animateCoverTransition(
            from oldPage: Int,
            to targetPage: Int,
            direction: UIPageViewController.NavigationDirection,
            on pvc: UIPageViewController
        ) {
            guard !isAnimatingTransition else { return }
            guard let view = pvc.view else { return }
            
            // Boundary protection
            let total = currentEngine.totalPages
            guard targetPage >= 0, total == 0 || targetPage < total else {
                resetCoverOverlay()
                return
            }
            if renderSnapshotForDisplayPage(targetPage) == nil {
                let targetVC = displayViewController(at: targetPage)
                if isPlaceholderDisplay(targetVC) {
                    pendingNavigation = PendingNavigation(target: .page(targetPage))
                    AppLogger.render("[FlipTrace] coverProgrammatic blocked placeholder targetPage=\(targetPage)")
                    return
                }
            }
            
            beginAnimatedTransition()
            let width = max(view.bounds.width, 1)

            // Clean up any lingering animation state.
            coverOverlayView.layer.removeAllAnimations()
            coverIncomingImageView.layer.removeAllAnimations()
            coverShadowView.layer.removeAllAnimations()
            coverDimView.layer.removeAllAnimations()

            coverOverlayView.frame = view.bounds
            coverCurrentImageView.frame = view.bounds
            coverOverlayView.isHidden = false

            let turnDirection: ReaderCoverTurnDirection = targetPage >= oldPage ? .forward : .backward
            let motion = ReaderCoverPageMotion(direction: turnDirection, isRTL: isRTL)

            if turnDirection == .forward {
                setupForwardOutgoing(currentPageSnapshot: oldPage, newPage: targetPage, motion: motion, in: view)
                coverDimView.alpha = 0.35
                beginRetimableTurn(on: coverOverlayView.layer, builtInSpeed: activeTurnSpeed)
                UIView.animate(withDuration: 0.25 / Double(activeTurnSpeed), delay: 0, options: [.curveEaseOut]) {
                    let destX = motion.settledX(width: width, shouldCommit: true)
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    self.coverDimView.alpha = 0
                } completion: { _ in
                    self.endRetimableTurn()
                    // Capture the latest binding value.
                    let latestPage = self.currentPage
                    let realVC = self.displayViewController(at: latestPage)
                    AppLogger.render("[FlipTrace] coverProgrammatic forward latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC, readerDriven: true)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    self.warmUpNext(currentGlobalPage: latestPage)

                    self.resetCoverOverlay()
                    self.endAnimatedTransition(on: pvc)
                }
            } else {
                guard let targetSnapshot = renderSnapshotForDisplayPage(targetPage) else {
                    let latestPage = self.currentPage
                    let realVC = displayViewController(at: latestPage)
                    AppLogger.render("[FlipTrace] coverProgrammatic backward snapshotMiss targetPage=\(targetPage) latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    self.captureStablePosition(from: realVC, readerDriven: true)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    self.warmUpNext(currentGlobalPage: latestPage)
                    self.resetCoverOverlay()
                    self.endAnimatedTransition(on: pvc)
                    return
                }
                coverCurrentImageView.image = renderSnapshotForDisplayPage(oldPage)
                setupIncomingView(for: targetPage, snapshot: targetSnapshot, motion: motion, in: view)
                beginRetimableTurn(on: coverOverlayView.layer, builtInSpeed: activeTurnSpeed)
                UIView.animate(withDuration: 0.25 / Double(activeTurnSpeed), delay: 0, options: [.curveEaseOut]) {
                    let destX = motion.settledX(width: width, shouldCommit: true)
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    self.coverDimView.alpha = 0.3
                } completion: { _ in
                    self.endRetimableTurn()
                    let latestPage = self.currentPage
                    let realVC = self.displayViewController(at: latestPage)
                    AppLogger.render("[FlipTrace] coverProgrammatic backward latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC, readerDriven: true)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    self.warmUpNext(currentGlobalPage: latestPage)

                    self.resetCoverOverlay()
                    self.endAnimatedTransition(on: pvc)
                }
            }
        }

        private func showCurrentSnapshot(page: Int, on view: UIView) {
            coverOverlayView.frame = view.bounds
            coverCurrentImageView.frame = view.bounds
            coverCurrentImageView.image = renderSnapshotForDisplayPage(page)
            coverOverlayView.isHidden = false
        }

        private func setupForwardOutgoing(
            currentPageSnapshot: Int,
            newPage: Int,
            motion: ReaderCoverPageMotion,
            in view: UIView
        ) {
            let width = max(view.bounds.width, 1)
            let h = view.bounds.height
            // New page as static background.
            coverCurrentImageView.image = renderSnapshotForDisplayPage(newPage)
            coverCurrentImageView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            coverIncomingImageView.layer.maskedCorners = motion.movingEdgeCorners
            coverIncomingImageView.image = renderSnapshotForDisplayPage(currentPageSnapshot)
            coverIncomingImageView.frame = CGRect(x: motion.initialX(width: width), y: 0, width: width, height: h)
            coverShadowView.layer.maskedCorners = motion.movingEdgeCorners
            coverShadowView.layer.shadowOffset = motion.shadowOffset
            coverShadowView.frame = CGRect(x: motion.initialX(width: width), y: 0, width: width, height: h)
            coverShadowView.layer.shadowPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: h)).cgPath
            coverDimView.frame = CGRect(x: 0, y: 0, width: width, height: h)
        }

        private func setupIncomingView(
            for targetPage: Int,
            snapshot: UIImage?,
            motion: ReaderCoverPageMotion,
            in view: UIView
        ) {
            let width = max(view.bounds.width, 1)
            let h = view.bounds.height
            coverIncomingImageView.layer.maskedCorners = motion.movingEdgeCorners
            coverIncomingImageView.image = snapshot
            coverIncomingImageView.frame = CGRect(x: motion.initialX(width: width), y: 0, width: width, height: h)
            coverShadowView.layer.maskedCorners = motion.movingEdgeCorners
            coverShadowView.layer.shadowOffset = motion.shadowOffset
            coverShadowView.frame = CGRect(x: motion.initialX(width: width), y: 0, width: width, height: h)
            coverShadowView.layer.shadowPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: h)).cgPath
            coverDimView.frame = coverCurrentImageView.bounds
            coverDimView.alpha = 0
        }

        private func resetCoverOverlay() {
            coverOverlayView.isHidden = true
            coverCurrentImageView.frame.origin.x = 0
            coverCurrentImageView.image = nil
            coverIncomingImageView.image = nil
            coverShadowView.frame = .zero
            coverDimView.alpha = 0
            coverTargetPage = nil
            coverDirection = nil
        }

        // MARK: - Swipe-up exit gesture

        @objc func handleSwipeUpExitPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let progress = ReaderSwipeUpExitMotion.progress(
                forTranslationY: gesture.translation(in: view).y
            )

            switch gesture.state {
            case .began:
                swipeUpExitArmed = false
                swipeUpExitHaptic.prepare()
                let chip = ensureSwipeUpExitChip(in: view)
                chip.layer.removeAllAnimations()
                chip.isHidden = false
                applySwipeUpExitChipLayout(progress: progress, in: view)

            case .changed:
                let armed = progress >= ReaderSwipeUpExitMotion.commitProgress
                if armed != swipeUpExitArmed {
                    swipeUpExitArmed = armed
                    if armed { swipeUpExitHaptic.impactOccurred() }
                }
                applySwipeUpExitChipLayout(progress: progress, in: view)

            case .ended, .cancelled, .failed:
                let shouldExit = gesture.state == .ended && ReaderSwipeUpExitMotion.shouldCommit(
                    progress: progress,
                    velocityY: gesture.velocity(in: view).y
                )
                swipeUpExitArmed = false
                if shouldExit {
                    UIView.animate(withDuration: ReaderSwipeUpExitMotion.commitFadeDuration) {
                        self.swipeUpExitChipContainer?.alpha = 0
                    } completion: { _ in
                        self.swipeUpExitChipContainer?.isHidden = true
                    }
                    onSwipeUpExit()
                } else {
                    UIView.animate(
                        withDuration: ReaderSwipeUpExitMotion.cancelSettleDuration,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        self.applySwipeUpExitChipLayout(progress: 0, in: view)
                    } completion: { _ in
                        self.swipeUpExitChipContainer?.isHidden = true
                    }
                }

            default:
                break
            }
        }

        /// Builds the ✕ chip lazily and keeps it parented to the gesture's view.
        /// A blur circle adapts to any reader background; the icon follows the
        /// current theme's text color.
        private func ensureSwipeUpExitChip(in view: UIView) -> UIView {
            let chip: UIView
            if let existing = swipeUpExitChipContainer {
                chip = existing
            } else {
                let size = ReaderSwipeUpExitMotion.chipDiameter
                let container = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
                container.isUserInteractionEnabled = false
                container.layer.shadowColor = UIColor.black.cgColor
                container.layer.shadowOpacity = 0.18
                container.layer.shadowRadius = 10
                container.layer.shadowOffset = CGSize(width: 0, height: 4)

                let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
                blur.frame = container.bounds
                blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                blur.clipsToBounds = true
                blur.layer.cornerRadius = size / 2
                container.addSubview(blur)

                let icon = UIImageView(
                    image: UIImage(
                        systemName: "xmark",
                        withConfiguration: UIImage.SymbolConfiguration(
                            pointSize: ReaderSwipeUpExitMotion.chipIconPointSize,
                            weight: .semibold
                        )
                    )
                )
                icon.contentMode = .center
                icon.frame = container.bounds
                icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(icon)

                swipeUpExitChipContainer = container
                swipeUpExitChipIcon = icon
                chip = container
            }
            swipeUpExitChipIcon?.tintColor = UIColor(currentTheme.textColor)
            if chip.superview !== view {
                chip.removeFromSuperview()
                view.addSubview(chip)
            }
            view.bringSubviewToFront(chip)
            return chip
        }

        private func applySwipeUpExitChipLayout(progress: CGFloat, in view: UIView) {
            guard let chip = swipeUpExitChipContainer else { return }
            var scale = ReaderSwipeUpExitMotion.chipScale(forProgress: progress)
            if swipeUpExitArmed { scale *= ReaderSwipeUpExitMotion.armedScaleBoost }
            chip.center = CGPoint(
                x: view.bounds.midX,
                y: ReaderSwipeUpExitMotion.chipCenterY(
                    forProgress: progress,
                    viewHeight: view.bounds.height,
                    bottomSafeInset: view.safeAreaInsets.bottom
                )
            )
            chip.transform = CGAffineTransform(scaleX: scale, y: scale)
            chip.alpha = ReaderSwipeUpExitMotion.chipAlpha(forProgress: progress)
        }

        // MARK: - Pull-down bookmark gesture

        @objc func handlePullDownBookmarkPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translationY = gesture.translation(in: view).y
            let progress = ReaderPullDownBookmarkMotion.progress(forTranslationY: translationY)

            switch gesture.state {
            case .began:
                pullDownBookmarkWasBookmarked = isCurrentPageBookmarked()
                pullDownBookmarkPhase = .pulling
                pullDownBookmarkHaptic.prepare()
                view.layer.removeAnimation(forKey: Self.pullDownSettleAnimationKey)
                preparePullDownHint(in: view)
                pullDownRibbonHost = bookmarkRibbonHost()
                pullDownRibbonHost?.beginInteractiveBookmarkRibbon()
                applyPullDown(translationY: translationY, progress: progress, in: view)

            case .changed:
                let phase = ReaderPullDownBookmarkMotion.phase(forProgress: progress)
                if phase != pullDownBookmarkPhase {
                    pullDownBookmarkPhase = phase
                    if phase == .armed { pullDownBookmarkHaptic.impactOccurred() }
                    updatePullDownHintText()
                }
                applyPullDown(translationY: translationY, progress: progress, in: view)

            case .ended, .cancelled, .failed:
                let wasBookmarked = pullDownBookmarkWasBookmarked
                let commits = gesture.state == .ended && ReaderPullDownBookmarkMotion.shouldCommit(
                    progress: progress,
                    velocityY: gesture.velocity(in: view).y
                )
                if commits {
                    // Also raises the 已加入／已移除 toast and its announcement — the
                    // same ones the top bar's button gets.
                    onPullDownBookmark()
                }
                // The ribbon settles on the outcome now rather than when the page's
                // bars next come round; those follow the store and say the same thing.
                pullDownRibbonHost?.endInteractiveBookmarkRibbon(
                    isBookmarked: commits ? !wasBookmarked : wasBookmarked
                )
                pullDownRibbonHost = nil
                settlePullDown(in: view)
                pullDownBookmarkPhase = .pulling

            default:
                break
            }
        }

        /// The page the reader is on — the one `isCurrentPageBookmarked` answers for.
        /// In a spread that is one of the two halves, not the spread.
        private func bookmarkRibbonHost() -> (any ReaderBookmarkRibbonHosting)? {
            for viewController in pullDownPageViewController?.viewControllers ?? [] {
                if let spread = viewController as? ReaderSpreadPageViewController {
                    let halves = spread.pageViewControllers
                    let current = halves.first {
                        ($0 as? any PageIndexProviding)?.globalPageIndex == currentPage
                    }
                    return (current ?? halves.first) as? any ReaderBookmarkRibbonHosting
                }
                if let host = viewController as? any ReaderBookmarkRibbonHosting {
                    return host
                }
            }
            return nil
        }

        /// Moves the whole page down through the container layer's `sublayerTransform`.
        ///
        /// Not a view transform on UIPageViewController's own subviews: its content
        /// view re-lays its queuing scroll view out on every frame, setting `frame`
        /// back to its bounds, and a frame set on a transformed view is taken out of
        /// `center` — measured on the simulator, `transform.ty` read 46pt while
        /// `center` had been pulled up 45pt to match, so the page never moved.
        /// UIKit layout never touches `sublayerTransform`, and it carries everything
        /// the page shows at once: both halves of a spread, the cover overlay, the
        /// auto-read curtain, the ribbon, and the hint riding above the page's edge.
        private func applyPullDown(translationY: CGFloat, progress: CGFloat, in view: UIView) {
            let offset = ReaderPullDownBookmarkMotion.pageOffset(forTranslationY: translationY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer.sublayerTransform = CATransform3DMakeTranslation(0, offset, 0)
            CATransaction.commit()
            pullDownRibbonHost?.setInteractiveBookmarkRibbonReveal(
                ReaderPullDownBookmarkMotion.ribbonReveal(
                    progress: progress,
                    wasBookmarked: pullDownBookmarkWasBookmarked
                )
            )
            pullDownHintLabel.alpha = ReaderPullDownBookmarkMotion.hintAlpha(forProgress: progress)
        }

        static let pullDownSettleAnimationKey = "pullDownBookmarkSettle"

        /// The page springs back into place, carrying the hint up with its edge.
        private func settlePullDown(in view: UIView) {
            let layer = view.layer
            let from = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()

            let animation: CABasicAnimation
            let duration: TimeInterval
            if UIAccessibility.isReduceMotionEnabled {
                // Reduce Motion: no spring overshoot, just a short ease home.
                animation = CABasicAnimation(keyPath: "sublayerTransform")
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                duration = ReaderPullDownBookmarkMotion.reducedMotionSettleDuration
            } else {
                let spring = CASpringAnimation(
                    perceptualDuration: ReaderPullDownBookmarkMotion.settleDuration,
                    bounce: ReaderPullDownBookmarkMotion.settleBounce
                )
                animation = spring
                duration = spring.settlingDuration
            }
            animation.fromValue = NSValue(caTransform3D: from)
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = duration
            layer.add(animation, forKey: Self.pullDownSettleAnimationKey)

            UIView.animate(
                withDuration: min(duration, ReaderPullDownBookmarkMotion.settleDuration),
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.pullDownHintLabel.alpha = 0
            }
        }

        private func preparePullDownHint(in view: UIView) {
            let label = pullDownHintLabel
            if label.superview !== view {
                label.removeFromSuperview()
                label.font = UIFont.preferredFont(forTextStyle: .footnote)
                label.adjustsFontForContentSizeCategory = true
                label.textAlignment = .center
                label.isUserInteractionEnabled = false
                // VoiceOver hears the outcome as an announcement instead.
                label.isAccessibilityElement = false
                view.addSubview(label)
            }
            view.bringSubviewToFront(label)
            label.textColor = UIColor(currentTheme.textColor).withAlphaComponent(0.6)
            label.layer.removeAllAnimations()
            label.alpha = 0
            updatePullDownHintText()
        }

        /// Sets the wording and parks the hint just above the page's top edge, where
        /// the pull reveals it.
        private func updatePullDownHintText() {
            let label = pullDownHintLabel
            label.text = localized(ReaderPullDownBookmarkMotion.hintKey(
                isBookmarked: pullDownBookmarkWasBookmarked,
                phase: pullDownBookmarkPhase
            ))
            label.sizeToFit()
            label.center = CGPoint(
                x: label.superview?.bounds.midX ?? label.center.x,
                y: ReaderPullDownBookmarkMotion.hintCenterY(hintHeight: label.bounds.height)
            )
        }

        // MARK: - UIGestureRecognizerDelegate (swipe-up exit / pull-down bookmark)

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === pullDownBookmarkPanGesture {
                guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                      let view = pan.view,
                      GlobalSettings.shared.readerPullDownToBookmark,
                      !isAnimatingTransition, !isPageTransitioning,
                      // A 載入中 page is not a page yet; there is nothing to bookmark.
                      let visible = pullDownPageViewController?.viewControllers?.first,
                      !isPlaceholderDisplay(visible) else { return false }
                return ReaderPullDownBookmarkMotion.shouldBegin(velocity: pan.velocity(in: view))
            }
            guard gestureRecognizer === swipeUpExitPanGesture else { return true }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view,
                  GlobalSettings.shared.readerSwipeUpToExit,
                  !isAnimatingTransition, !isPageTransitioning else { return false }
            return ReaderSwipeUpExitMotion.shouldBegin(velocity: pan.velocity(in: view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Horizontal page-turn pans on the same container (cover / instant /
            // curl) wait for the vertical pans, which fail immediately unless the
            // drag is clearly up or down — page turns keep their responsiveness.
            guard gestureRecognizer === swipeUpExitPanGesture
                    || gestureRecognizer === pullDownBookmarkPanGesture else { return false }
            // Not each other: the two vertical pans are mutually exclusive by
            // direction already, and making each wait for the other is a cycle.
            guard otherGestureRecognizer !== swipeUpExitPanGesture,
                  otherGestureRecognizer !== pullDownBookmarkPanGesture else { return false }
            return otherGestureRecognizer is UIPanGestureRecognizer
                && otherGestureRecognizer.view === gestureRecognizer.view
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Selection-handle drags travel vertically too; the page content's own
            // pan wins whenever a text selection can consume the touch — on either
            // engine's page.
            guard gestureRecognizer === swipeUpExitPanGesture
                    || gestureRecognizer === pullDownBookmarkPanGesture else { return false }
            return otherGestureRecognizer is UIPanGestureRecognizer
                && (otherGestureRecognizer.view is CoreTextPageView
                    || otherGestureRecognizer.view is BrowserLayoutPageView)
        }
    }
}
