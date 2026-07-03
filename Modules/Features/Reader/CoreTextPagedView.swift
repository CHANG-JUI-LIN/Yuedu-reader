import SwiftUI
import UIKit

struct CoreTextPageEngineView: UIViewControllerRepresentable {
    let engine: any PageRenderingProvider
    let pageTurnStyle: PageTurnStyle
    let theme: ReaderTheme
    let playbackHighlightText: String?
    let isRTL: Bool
    let isDoublePageSpread: Bool
    let spreadGutter: CGFloat
    let sessionCoordinator: ReaderSessionCoordinator?
    let externalTargetVersion: UInt
    let externalTargetPosition: CoreTextReadingPosition?
    let clearExternalTargetPosition: () -> Void
    @Binding var currentPage: Int
    let onPageChanged: (Int, CoreTextReadingPosition?) -> Void
    let onTapZone: (String) -> Void
    var onFootnoteTap: (String) -> Void = { _ in }

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
        pvc.isDoubleSided = pageTurnStyle == .curl && !isDoublePageSpread
        // cover / none mode: disable built-in swipe gesture (use custom pan or tap for page turns).
        if adapterDescriptor.disablesBuiltInSwipe {
            pvc.dataSource = nil
            for case let sv as UIScrollView in pvc.view.subviews {
                sv.isScrollEnabled = false
            }
        } else {
            pvc.dataSource = context.coordinator
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
        // Sync the binding so ReaderView.currentPage aligns with the engine-restored position.
        if initialPage != currentPage {
            context.coordinator.suppressNextTransition = true
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
        context.coordinator.bindEngineCallbacks(to: engine, pageViewController: pvc)

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.currentEngine = engine
        context.coordinator.sessionCoordinator = sessionCoordinator
        context.coordinator.currentPlaybackHighlightText = playbackHighlightText
        let spreadModeChanged = context.coordinator.isDoublePageSpread != isDoublePageSpread
        context.coordinator.isDoublePageSpread = isDoublePageSpread
        uiViewController.isDoubleSided = pageTurnStyle == .curl && !isDoublePageSpread
        context.coordinator.externalTargetPosition = externalTargetPosition
        context.coordinator.bindEngineCallbacks(to: engine, pageViewController: uiViewController)
        let clampedPage = max(0, min(currentPage, max(engine.totalPages - 1, 0)))
        AppLogger.render("[CurlTrace] updateUIViewController binding=\(currentPage) visible=\((uiViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
        let targetViewController = {
            if let externalTargetPosition {
                return context.coordinator.displayViewController(for: externalTargetPosition)
            }
            return context.coordinator.displayViewController(at: clampedPage)
        }
        if spreadModeChanged {
            let targetVC = targetViewController()
            context.coordinator.applyPlaybackHighlight(to: targetVC)
            uiViewController.setViewControllers(context.coordinator.viewControllerStack(startingWith: targetVC), direction: .forward, animated: false)
            uiViewController.view.layoutIfNeeded()
            _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
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
            let targetVC = targetViewController()
            context.coordinator.applyPlaybackHighlight(to: targetVC)
            uiViewController.setViewControllers(context.coordinator.viewControllerStack(startingWith: targetVC), direction: .forward, animated: false)
            _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
            if context.coordinator.externalTargetPosition != nil {
                DispatchQueue.main.async { context.coordinator.clearExternalTargetPosition() }
            }
            return
        }

        if let visible = uiViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) {
            if visible.globalPageIndex == clampedPage, externalTargetPosition == nil {
                context.coordinator.applyPlaybackHighlight(to: visible)
                return
            }
            var direction: UIPageViewController.NavigationDirection =
                clampedPage >= visible.globalPageIndex ? .forward : .reverse
            // RTL: swap navigation direction to match data source swap (Before↔After).
            if isRTL {
                direction = direction == .forward ? .reverse : .forward
            }

            // Suppress flag from makeUIViewController: force instant transition on first alignment.
            if context.coordinator.suppressNextTransition {
                context.coordinator.suppressNextTransition = false
                let targetVC = targetViewController()
                context.coordinator.applyPlaybackHighlight(to: targetVC)
                uiViewController.setViewControllers(context.coordinator.viewControllerStack(startingWith: targetVC), direction: direction, animated: false)
                _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                return
            }

            if externalTargetPosition != nil, !context.coordinator.isTransitioning {
                let targetVC = targetViewController()
                guard !(pageTurnStyle == .curl && context.coordinator.isPlaceholderDisplay(targetVC)) else { return }
                context.coordinator.applyPlaybackHighlight(to: targetVC)
                uiViewController.setViewControllers(context.coordinator.viewControllerStack(startingWith: targetVC), direction: direction, animated: false)
                uiViewController.view.layoutIfNeeded()
                _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                // One-shot: the external target is a positioning instruction. Once it has
                // been applied to a real page, clear it so later re-renders (or the user's
                // own page turns) are never forced back to it. Without this, the target
                // persists and updateUIViewController keeps snapping back — the curl
                // "animates then bounces back" bug after a scroll→paged switch.
                if !context.coordinator.isPlaceholderDisplay(targetVC) {
                    let clear = clearExternalTargetPosition
                    DispatchQueue.main.async { clear() }
                }
                return
            }

            // Non-adjacent page jumps (TOC navigation, offset recalculation) use instant transition to avoid cover chain reverse.
            let isAdjacent = context.coordinator.isAdjacentDisplayPage(clampedPage, to: visible.globalPageIndex)
            let shouldAnimate = (pageTurnStyle != .none) && isAdjacent

            if pageTurnStyle == .cover {
                if shouldAnimate {
                    context.coordinator.animateCoverTransition(
                        from: visible.globalPageIndex,
                        to: clampedPage,
                        direction: direction,
                        on: uiViewController
                    )
                } else if !context.coordinator.isTransitioning {
                    let targetVC = targetViewController()
                    context.coordinator.applyPlaybackHighlight(to: targetVC)
                    uiViewController.setViewControllers(context.coordinator.viewControllerStack(startingWith: targetVC), direction: direction, animated: false)
                    uiViewController.view.layoutIfNeeded()
                    _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                }
                return
            }

            if shouldAnimate {
                let effects = context.coordinator.requestPageTransition(
                    to: clampedPage,
                    visiblePage: visible.globalPageIndex
                )
                guard effects.contains(.requestPageTransition(targetPage: clampedPage)) else { return }
            } else if context.coordinator.isPageTransitioning {
                _ = context.coordinator.requestPageTransition(
                    to: clampedPage,
                    visiblePage: visible.globalPageIndex
                )
                return
            }

            context.coordinator.performProgrammaticTransition(
                on: uiViewController,
                to: clampedPage,
                from: visible.globalPageIndex,
                direction: direction,
                animated: shouldAnimate
            )
            return
        }

        let targetVC = targetViewController()
        context.coordinator.applyPlaybackHighlight(to: targetVC)
        uiViewController.setViewControllers(context.coordinator.viewControllerStack(startingWith: targetVC), direction: .forward, animated: false)
        _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            engine: engine,
            pageTurnStyle: pageTurnStyle,
            theme: theme,
            playbackHighlightText: playbackHighlightText,
            isRTL: isRTL,
            isDoublePageSpread: isDoublePageSpread,
            spreadGutter: spreadGutter,
            sessionCoordinator: sessionCoordinator,
            externalTargetPosition: externalTargetPosition,
            clearExternalTargetPosition: clearExternalTargetPosition,
            currentPage: $currentPage,
            onPageChanged: onPageChanged,
            onTapZone: onTapZone,
            onFootnoteTap: onFootnoteTap
        )
    }

    final class Coordinator: NSObject,
        UIPageViewControllerDataSource,
        UIPageViewControllerDelegate
    {
        var currentEngine: any PageRenderingProvider
        let pageTurnStyle: PageTurnStyle
        var currentTheme: ReaderTheme
        var currentPlaybackHighlightText: String?
        var sessionCoordinator: ReaderSessionCoordinator?
        @Binding var currentPage: Int
        let onPageChanged: (Int, CoreTextReadingPosition?) -> Void
        let onTapZone: (String) -> Void
        let onFootnoteTap: (String) -> Void
        let isRTL: Bool
        var isDoublePageSpread: Bool
        let spreadGutter: CGFloat
        let clearExternalTargetPosition: () -> Void
        var externalTargetPosition: CoreTextReadingPosition? {
            didSet {
                guard let externalTargetPosition else { return }
                currentCoreTextPosition = externalTargetPosition
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

        private enum NavigationMode {
            case jump
            case interactiveTurn

            var allowsPlaceholder: Bool {
                self == .jump
            }
        }

        private var activeCurlTransitionCount = 0
        private var hasDeferredChapterReady = false
        private var lastCurlBeginTime: CFAbsoluteTime = 0
        private static let curlWatchdogTimeout: CFAbsoluteTime = 2.5

        // Cover animation overlay components
        private let coverOverlayView = UIView()
        private let coverCurrentImageView = UIImageView()
        private let coverDimView = UIView()
        private let coverShadowView = UIView()
        private let coverIncomingImageView = UIImageView()
        private var coverTargetPage: Int?
        private var coverDirection: ReaderCoverTurnDirection?
        /// Set to true after makeUIViewController has set the initial page,
        /// so the subsequent updateUIViewController skips redundant backward animation (binding not yet synced).
        fileprivate var suppressNextTransition = false
        fileprivate var currentCoreTextPosition: CoreTextReadingPosition?
        private var pendingNavigation: PendingNavigation?
        weak var coverPageViewController: UIPageViewController?
        private weak var callbackEngineObject: AnyObject?
        private var callbackEngineIdentifier: ObjectIdentifier?
        fileprivate var isTransitioning = false

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

        private func beginCurlTransitionIfNeeded() {
            guard pageTurnStyle == .curl else { return }
            resetCurlCountIfStale()
            activeCurlTransitionCount += 1
            lastCurlBeginTime = CFAbsoluteTimeGetCurrent()
        }

        private func deferChapterReadyIfCurlIsAnimating() -> Bool {
            guard pageTurnStyle == .curl else { return false }
            guard activeCurlTransitionCount > 0 else { return false }
            hasDeferredChapterReady = true
            AppLogger.render("[CurlTrace] defer handleChapterReady during curl transition count=\(activeCurlTransitionCount)")
            return true
        }

        /// A dropped UIPageViewController completion leaks the counter, which would
        /// defer chapter-ready refreshes forever (snapshot pages never swap to real
        /// content). Real curl animations finish well under 2.5s, so a positive count
        /// older than that is a leak — reset it at the next page-turn begin. The turn's
        /// own finish then reaches zero and replays the owed `hasDeferredChapterReady`
        /// via the existing didFinish/completion path (safe: never mid-gesture).
        private func resetCurlCountIfStale() {
            guard activeCurlTransitionCount > 0,
                  CFAbsoluteTimeGetCurrent() - lastCurlBeginTime >= Self.curlWatchdogTimeout else { return }
            AppLogger.render("⟐ curl watchdog: resetting leaked count=\(activeCurlTransitionCount)")
            activeCurlTransitionCount = 0
        }

        private func finishCurlTransitionIfNeeded(on pageViewController: UIPageViewController) {
            guard pageTurnStyle == .curl else { return }
            guard activeCurlTransitionCount > 0 else { return }
            activeCurlTransitionCount -= 1
            guard activeCurlTransitionCount == 0 else { return }
            let shouldRefresh = hasDeferredChapterReady
            hasDeferredChapterReady = false
            if shouldRefresh {
                handleChapterReady(on: pageViewController)
            }
        }

        fileprivate func viewControllerStack(startingWith viewController: UIViewController) -> [UIViewController] {
            [viewController]
        }

        private func curlBackPage(
            logicalPageIndex: Int
        ) -> PageBackViewController? {
            guard let contentPage = ReaderCurlBackPageResolver.contentPageIndex(
                logicalPageIndex: logicalPageIndex,
                totalPages: currentEngine.totalPages
            ) else { return nil }
            return PageBackViewController(
                virtualIndex: ReaderCurlVirtualIndex.backIndex(
                    forLogicalPage: logicalPageIndex,
                    isRTL: isRTL
                ),
                logicalPageIndex: logicalPageIndex,
                globalPageIndex: contentPage,
                backgroundColor: curlBackPageColor,
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
            return [
                viewController,
                backPage
            ]
        }

        init(engine: any PageRenderingProvider,
             pageTurnStyle: PageTurnStyle,
             theme: ReaderTheme,
             playbackHighlightText: String?,
             isRTL: Bool,
             isDoublePageSpread: Bool,
             spreadGutter: CGFloat,
             sessionCoordinator: ReaderSessionCoordinator?,
             externalTargetPosition: CoreTextReadingPosition?,
             clearExternalTargetPosition: @escaping () -> Void,
             currentPage: Binding<Int>,
             onPageChanged: @escaping (Int, CoreTextReadingPosition?) -> Void,
             onTapZone: @escaping (String) -> Void,
             onFootnoteTap: @escaping (String) -> Void) {
            self.currentEngine = engine
            self.pageTurnStyle = pageTurnStyle
            self.currentTheme = theme
            self.currentPlaybackHighlightText = playbackHighlightText
            self.isRTL = isRTL
            self.isDoublePageSpread = isDoublePageSpread
            self.spreadGutter = spreadGutter
            self.sessionCoordinator = sessionCoordinator
            self.externalTargetPosition = externalTargetPosition
            self.clearExternalTargetPosition = clearExternalTargetPosition
            self._currentPage = currentPage
            self.onPageChanged = onPageChanged
            self.onTapZone = onTapZone
            self.onFootnoteTap = onFootnoteTap
            if let externalTargetPosition {
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

            engine.onChapterReady = { [weak self, weak pageViewController] _ in
                DispatchQueue.main.async {
                    guard let self, let pageViewController else { return }
                    guard self.callbackEngineIdentifier == identifier else { return }
                    let line =
                        "[StartupTrace][ReaderView.Coordinator] onChapterReady currentPage=\(self.currentPage) enginePage=\(engine.currentPage) totalPages=\(engine.totalPages)"
                    AppLogger.render(line)
                    NSLog("%@", line)
                    self.handleChapterReady(on: pageViewController)
                }
            }

            engine.onNavigateToPage = { [weak self] page in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.callbackEngineIdentifier == identifier else { return }
                    self.handleNavigate(to: page)
                }
            }

            if let coreTextEngine = engine as? CoreTextPageEngine {
                coreTextEngine.onFootnoteTap = { [weak self] note in
                    DispatchQueue.main.async {
                        guard let self, self.callbackEngineIdentifier == identifier else { return }
                        self.onFootnoteTap(note)
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
                engine.onNavigateToPage = nil
            }
            if let coreTextEngine = callbackEngineObject as? CoreTextPageEngine {
                coreTextEngine.onFootnoteTap = nil
            }
            callbackEngineObject = nil
            callbackEngineIdentifier = nil
        }

        fileprivate func displayViewController(at index: Int) -> UIViewController {
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
            guard isDoublePageSpread else {
                return currentEngine.pageViewController(for: position)
            }

            if let page = currentEngine.pageIndex(for: position) {
                return displayViewController(at: page)
            }

            let page = (currentEngine.pageViewController(for: position) as? any PageIndexProviding)?.globalPageIndex
                ?? currentEngine.estimatedGlobalPage(for: position)
                ?? 0
            return spreadViewController(containingPage: page)
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

        private func handleChapterReady(on pageViewController: UIPageViewController) {
            guard !deferChapterReadyIfCurlIsAnimating() else { return }
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

            pageViewController.setViewControllers(viewControllerStack(startingWith: freshVC), direction: direction, animated: false)
            applyPlaybackHighlight(to: freshVC)
            let resolved = syncStablePosition(afterShowing: freshVC, notifyFallback: false)
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
                    self.currentEngine.warmUpNext(currentGlobalPage: page)
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
                    let shouldAnimate = (pageTurnStyle != .none) && isAdjacentDisplayPage(targetPage, to: visiblePage)
                    performProgrammaticTransition(
                        on: pageViewController,
                        to: targetPage,
                        from: visiblePage,
                        direction: direction,
                        animated: shouldAnimate
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
            animated: Bool
        ) {
            let targetViewController = displayViewController(at: targetPage)
            applyPlaybackHighlight(to: targetViewController)
            let finishTransition: (UIViewController) -> Void = { shownViewController in
                if let resolvedPage = self.syncStablePosition(afterShowing: shownViewController, notifyFallback: true) {
                    self.continueQueuedTransitionIfNeeded(on: pageViewController, showing: resolvedPage)
                } else {
                    self.continueQueuedTransitionIfNeeded(on: pageViewController, showing: targetPage)
                }
                self.finishCurlTransitionIfNeeded(on: pageViewController)
            }
            if pageTurnStyle == .curl, animated {
                beginCurlTransitionIfNeeded()
            }

            if let sessionCoordinator {
                sessionCoordinator.performProgrammaticPageTransition(
                    pageTurnStyle: pageTurnStyle,
                    on: pageViewController,
                    targetViewController: targetViewController,
                    targetViewControllers: transitionViewControllerStack(
                        startingWith: targetViewController,
                        animated: animated,
                        visiblePage: visiblePage
                    ),
                    direction: direction,
                    animated: animated,
                    restoringDataSource: self
                ) { settledViewController in
                    finishTransition(settledViewController)
                }
                return
            }

            ProgrammaticPageTransitionPerformer(pageTurnStyle: pageTurnStyle).perform(
                on: pageViewController,
                targetViewController: targetViewController,
                targetViewControllers: transitionViewControllerStack(
                    startingWith: targetViewController,
                    animated: animated,
                    visiblePage: visiblePage
                ),
                direction: direction,
                animated: animated,
                restoringDataSource: self
            ) { settledViewController in
                finishTransition(settledViewController)
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            let w = view.bounds.width
            let rawZone = x < w * 0.3 ? "left" : x > w * 0.7 ? "right" : "center"
            let zone: String
            if rawZone == "center" {
                zone = "center"
            } else if GlobalSettings.shared.readerTapBothSidesNextPage {
                // Setting: both side zones advance to the next page (center still = menu).
                // "right" is what ReaderView maps to goToNextPage(), regardless of RTL.
                zone = "right"
            } else if isRTL {
                // Mirror the data source swap: swipe left-to-right = "before" = next page.
                // Tap left side → same as swiping left → next page.  Tap right → prev page.
                zone = rawZone == "left" ? "right" : "left"
            } else {
                zone = rawZone
            }
            DispatchQueue.main.async { self.onTapZone(zone) }
        }

        func captureStablePosition(from viewController: UIViewController) {
            currentCoreTextPosition = readingPosition(from: viewController)
        }

        func applyPlaybackHighlight(to viewController: UIViewController) {
            guard !(viewController is PageBackViewController) else { return }
            if let spread = viewController as? ReaderSpreadPageViewController {
                spread.applyPlaybackHighlight(text: currentPlaybackHighlightText)
                return
            }
            (viewController as? CoreTextPageViewController)?.setPlaybackHighlight(
                text: currentPlaybackHighlightText
            )
        }

        @discardableResult
        func syncStablePosition(afterShowing viewController: UIViewController, notifyFallback: Bool) -> Int? {
            let fallbackPage = (viewController as? any PageIndexProviding)?.globalPageIndex ?? currentPage

            if let position = readingPosition(from: viewController) {
                currentCoreTextPosition = position

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

        private func navigationViewController(
            for target: NavigationTarget,
            mode: NavigationMode
        ) -> UIViewController? {
            let viewController: UIViewController
            let pageDescription: String
            switch target {
            case .position(let position):
                viewController = displayViewController(for: position)
                pageDescription = "\(position)"
            case .page(let page):
                viewController = displayViewController(at: page)
                pageDescription = "page=\(page)"
            }

            if isPlaceholderDisplay(viewController) {
                if mode.allowsPlaceholder || allowsInteractiveChapterEndPlaceholder(target, mode: mode) {
                    pendingNavigation = PendingNavigation(target: target)
                    AppLogger.render("[FlipTrace] navigation \(mode) placeholder target=\(pageDescription)")
                    return viewController
                }
                // UIPageViewController data source MUST NOT return nil during an interactive
                // gesture — that raises NSInvalidArgumentException.  Return the placeholder
                // anyway; it will be replaced when the chapter layout completes.
                if mode == .interactiveTurn {
                    return viewController
                }
                return nil
            }

            pendingNavigation = nil
            applyPlaybackHighlight(to: viewController)
            return viewController
        }

        private func allowsInteractiveChapterEndPlaceholder(
            _ target: NavigationTarget,
            mode: NavigationMode
        ) -> Bool {
            guard mode == .interactiveTurn else { return false }
            guard case .position(let position) = target else { return false }
            return position.charOffset == .max
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            // RTL: swipe left-to-right = "before" in physical gesture, but should go to NEXT page.
            // So swap Before↔After for RTL books so the swipe direction matches the reading direction.
            if isRTL {
                return pageForward(from: viewController)
            }
            return pageBackward(from: viewController)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            if isRTL {
                return pageBackward(from: viewController)
            }
            return pageForward(from: viewController)
        }

        private func pageBackward(from viewController: UIViewController) -> UIViewController? {
            if let backPage = viewController as? PageBackViewController {
                return navigationViewController(
                    for: .page(backPage.logicalPageIndex),
                    mode: .interactiveTurn
                )
            }

            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex > 0 else { return nil }

            if isDoublePageSpread {
                guard let targetPage = previousDisplayPage(before: vc.globalPageIndex) else { return nil }
                return navigationViewController(for: .page(targetPage), mode: .interactiveTurn)
            }

            if usesCurlBackPages {
                let logicalPage = vc.globalPageIndex - 1
                return curlBackPage(logicalPageIndex: logicalPage)
            }
            let (currentSpine, currentLocal) = currentEngine.localPosition(for: vc.globalPageIndex)
            if currentLocal == 0 && currentSpine > 0 {
                AppLogger.render("[FlipTrace] pageBackward crossing chapter fromSpine=\(currentSpine) page=\(vc.globalPageIndex) toSpine=\(currentSpine - 1)")
                let targetPosition = CoreTextReadingPosition.chapterEnd(currentSpine - 1)
                let previousVC = navigationViewController(
                    for: .position(targetPosition),
                    mode: .interactiveTurn
                )
                AppLogger.render("[FlipTrace] pageBackward landing type=\(previousVC.map { "\(type(of: $0))" } ?? "nil") page=\((previousVC as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
                return previousVC
            }
            let previousVC = navigationViewController(
                for: .page(vc.globalPageIndex - 1),
                mode: .interactiveTurn
            )
            AppLogger.render("[FlipTrace] pageBackward sameChapter fromPage=\(vc.globalPageIndex) landingType=\(previousVC.map { "\(type(of: $0))" } ?? "nil") page=\(vc.globalPageIndex - 1)")
            return previousVC
        }

        private func pageForward(from viewController: UIViewController) -> UIViewController? {
            if let backPage = viewController as? PageBackViewController {
                guard backPage.logicalPageIndex + 1 < currentEngine.totalPages else { return nil }
                return navigationViewController(
                    for: .page(backPage.logicalPageIndex + 1),
                    mode: .interactiveTurn
                )
            }

            guard let vc = viewController as? any PageIndexProviding & UIViewController else { return nil }

            if isDoublePageSpread {
                guard let targetPage = nextDisplayPage(after: vc.globalPageIndex) else { return nil }
                return navigationViewController(for: .page(targetPage), mode: .interactiveTurn)
            }

            if usesCurlBackPages {
                return curlBackPage(logicalPageIndex: vc.globalPageIndex)
            }
            guard vc.globalPageIndex < currentEngine.totalPages - 1 else { return nil }
            let (currentSpine, _) = currentEngine.localPosition(for: vc.globalPageIndex)
            if let lastPage = currentEngine.lastPageIndex(ofChapter: currentSpine),
               vc.globalPageIndex == lastPage {
                AppLogger.render("[FlipTrace] pageForward crossing chapter fromSpine=\(currentSpine) page=\(vc.globalPageIndex) toSpine=\(currentSpine + 1)")
                let nextPosition = CoreTextReadingPosition.chapterStart(currentSpine + 1)
                if pageTurnStyle != .curl,
                   let targetPage = currentEngine.pageIndex(for: nextPosition),
                   let snapVC = currentEngine.snapshotViewController(at: targetPage) {
                    AppLogger.render("[FlipTrace] pageForward snapshot landing page=\(targetPage) type=\(type(of: snapVC))")
                    return snapVC
                }
                let nextVC = navigationViewController(
                    for: .position(nextPosition),
                    mode: .interactiveTurn
                )
                AppLogger.render("[FlipTrace] pageForward realOrPlaceholder landing type=\(nextVC.map { "\(type(of: $0))" } ?? "nil") page=\((nextVC as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
                return nextVC
            }
            let nextIndex = vc.globalPageIndex + 1
            if pageTurnStyle != .curl,
               let snapVC = currentEngine.snapshotViewController(at: nextIndex) {
                AppLogger.render("[FlipTrace] pageForward snapshot landing page=\(nextIndex) type=\(type(of: snapVC))")
                return snapVC
            }
            let nextVC = navigationViewController(for: .page(nextIndex), mode: .interactiveTurn)
            AppLogger.render("[FlipTrace] pageForward sameChapter fromPage=\(vc.globalPageIndex) landingType=\(nextVC.map { "\(type(of: $0))" } ?? "nil") page=\(nextIndex)")
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
            sessionCoordinator?.beginInteractivePageTransition()
            beginCurlTransitionIfNeeded()
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            AppLogger.render("[CurlTrace] didFinish completed=\(completed) visible=\((pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1) binding=\(currentPage)")

            defer {
                finishCurlTransitionIfNeeded(on: pvc)
            }

            guard completed else {
                let settledPage = (pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex
                    ?? currentPage
                continueQueuedTransitionIfNeeded(on: pvc, showing: settledPage)
                return
            }

            if pvc.viewControllers?.first is PageBackViewController {
                if let resolvedPage = syncStablePosition(afterShowing: pvc.viewControllers!.first!, notifyFallback: false) {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: resolvedPage)
                } else {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: currentPage)
                }
                return
            }

            // Snapshot replacement is unsafe for curl: the page curl animation internally
            // uses current/target/back side/under-page views, and replacing during or
            // immediately after curl can corrupt the transition state.
            if pageTurnStyle != .curl,
               let snapVC = pvc.viewControllers?.first as? SnapshotPageViewController {
                AppLogger.render("[FlipTrace] didFinish landing SNAPSHOT page=\(snapVC.globalPageIndex)")
                let realVC: UIViewController
                if let position = snapVC.coreTextReadingPosition {
                    realVC = currentEngine.pageViewController(for: position)
                } else {
                    realVC = currentEngine.pageViewController(at: snapVC.globalPageIndex)
                }
                AppLogger.render("[FlipTrace] didFinish replaceSnapshot realType=\(type(of: realVC)) page=\((realVC as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
                applyPlaybackHighlight(to: realVC)
                pvc.setViewControllers([realVC], direction: .forward, animated: false)
                if let resolvedPage = syncStablePosition(afterShowing: realVC, notifyFallback: false) {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: resolvedPage)
                } else {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: snapVC.globalPageIndex)
                }
                return
            }

            guard let vc = pvc.viewControllers?.first as? any PageIndexProviding & UIViewController else { return }
            AppLogger.render("[FlipTrace] didFinish landing type=\(type(of: vc)) page=\(vc.globalPageIndex)")
            if let resolvedPage = syncStablePosition(afterShowing: vc, notifyFallback: false) {
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
            static let commitProgressRatio: CGFloat = 0.34
            static let commitVelocityThreshold: CGFloat = 560.0
            static let settleAnimationDuration: TimeInterval = 0.22
            static let maxDimmingAlpha: CGFloat = 0.35
        }

        @objc func handleCoverPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began && isTransitioning {
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
                }
                guard coverTargetPage != nil, let coverDirection else { return }
                let motion = ReaderCoverPageMotion(direction: coverDirection, isRTL: isRTL)
                let rawProgress = min(max(abs(translationX) / width, 0), 0.999)
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
                let progress = min(max(abs(translationX) / width, 0), 1)
                let shouldCommit = progress > GestureConstants.commitProgressRatio || abs(velocityX) > GestureConstants.commitVelocityThreshold
                isTransitioning = true

                UIView.animate(withDuration: GestureConstants.settleAnimationDuration, delay: 0, options: [.curveEaseOut]) {
                    let destX = motion.settledX(width: width, shouldCommit: shouldCommit)
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
                            self.captureStablePosition(from: realVC)
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
                    self.isTransitioning = false
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
            guard !isTransitioning else { return }
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
            
            isTransitioning = true
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
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    let destX = motion.settledX(width: width, shouldCommit: true)
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    self.coverDimView.alpha = 0
                } completion: { _ in
                    // Capture the latest binding value.
                    let latestPage = self.currentPage
                    let realVC = self.displayViewController(at: latestPage)
                    AppLogger.render("[FlipTrace] coverProgrammatic forward latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    self.warmUpNext(currentGlobalPage: latestPage)

                    self.resetCoverOverlay()
                    self.isTransitioning = false
                }
            } else {
                guard let targetSnapshot = renderSnapshotForDisplayPage(targetPage) else {
                    let latestPage = self.currentPage
                    let realVC = displayViewController(at: latestPage)
                    AppLogger.render("[FlipTrace] coverProgrammatic backward snapshotMiss targetPage=\(targetPage) latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    self.captureStablePosition(from: realVC)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    self.warmUpNext(currentGlobalPage: latestPage)
                    self.resetCoverOverlay()
                    self.isTransitioning = false
                    return
                }
                coverCurrentImageView.image = renderSnapshotForDisplayPage(oldPage)
                setupIncomingView(for: targetPage, snapshot: targetSnapshot, motion: motion, in: view)
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    let destX = motion.settledX(width: width, shouldCommit: true)
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    self.coverDimView.alpha = 0.3
                } completion: { _ in
                    let latestPage = self.currentPage
                    let realVC = self.displayViewController(at: latestPage)
                    AppLogger.render("[FlipTrace] coverProgrammatic backward latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    self.warmUpNext(currentGlobalPage: latestPage)

                    self.resetCoverOverlay()
                    self.isTransitioning = false
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
    }
}
