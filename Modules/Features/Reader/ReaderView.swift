import Combine
import SwiftUI
import UIKit

private let uiFeedbackDuration: Double = 0.25

// MARK: - Main Reader View
struct ReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var readerConfig = ReaderConfig.shared

    // MARK: - Speculative Pre-Layout for Cross-Chapter Scrolling
    @State private var scrollVelocity: CGFloat = 0.0
    @State private var isGhostModeActive: Bool = false
    
    private func updateScrollVelocity(_ newVelocity: CGFloat) {
        scrollVelocity = newVelocity
        if abs(scrollVelocity) > 1000 && !isGhostModeActive {
            isGhostModeActive = true
        } else if abs(scrollVelocity) < 500 && isGhostModeActive {
            isGhostModeActive = false
            speculativePreLayoutNextChapter()
        }
    }
    
    private func speculativePreLayoutNextChapter() {
        Task { @MainActor in
            guard currentChapterIndex + 1 < chapters.count else { return }
            if let engine = epubRenderer.engine {
                applyReaderEffects(
                    readerSessionCoordinator?.send(.warmUpNext(currentGlobalPage: currentPage + 1))
                        ?? [.warmUpNext(currentGlobalPage: currentPage + 1)],
                    engine: engine
                )
            }
        }
    }


    @State private var chapters: [BookChapter] = []
    @State private var allPages: [PageContent] = []
    @State private var currentPage = 0
    @State private var showBars = false
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var showBookmarks = false

    // Online chapter lazy loading
    @StateObject private var readerViewModel = ReaderViewModel()
    @State private var observedChapterStates: [Int: ChapterLoadState] = [:]

    /// Top safe area (points), passed to EPUB engine as minimum margin-top.
    @State private var readerSafeAreaTop: CGFloat = 59
    @State private var readerViewportSize: CGSize = UIScreen.main.bounds.size
    @StateObject private var volumeHandler = VolumeKeyHandler()

    @StateObject private var autoReader = AutoReadController()
    @StateObject private var ttsCoordinator = TTSCoordinator()
    @StateObject private var mediaOverlayCoordinator = EPUBMediaOverlayPlaybackCoordinator()
    /// Plays an EPUB chapter's authored background soundtrack (controls-less autoplay/loop `<audio>`).
    @State private var backgroundAudioCoordinator = EPUBBackgroundAudioCoordinator()
    /// The active EPUB publication session, retained so the background-audio coordinator can read chapter
    /// HTML and resolve resource URLs on chapter change.
    @State private var activePublicationSession: PublicationSession?

    private func syncReaderBrightnessFromSystem() {
        let current = Double(UIScreen.main.brightness)
        systemBrightness = current
        settings.readerBrightness = current
    }

    private func restoreReaderDisplayStateAfterResume() {
        guard let engine = epubRenderer.engine, isEPUB, engine.totalPages > 0 else { return }
        let (spineIndex, charOffset) = engine.charOffset(forPage: currentPage)
        currentChapterIndex = spineIndex
        moveReaderSession(
            to: CoreTextReadingPosition(spineIndex: spineIndex, charOffset: charOffset),
            source: .restored,
            pageIndex: currentPage,
            totalPages: engine.totalPages,
            shouldPersist: false
        )
    }

    @StateObject private var epubRenderer = EPUBPageRenderer()

    @State private var showTTSPanel = false
    @State private var showDownloadOptions = false
    @State private var showAutoReadPanel = false
    @State private var ttsChapterIndex: Int? = nil
    @State private var showTTSJumpPrompt = false
    @State private var ttsJumpPromptChapterIndex: Int? = nil
    @State private var ttsPlaybackAnchor: CoreTextReadingPosition?
    @State private var isAligningReaderToTTSAnchor = false
    @State private var showMediaOverlayPanel = false
    @State private var activeMediaOverlayChapterIndex: Int? = nil

    @State private var currentChapterIndex = 0

    // Scroll mode progress tracking
    @State private var scrollVisibleChapter = 0
    @State private var scrollResliceToken: UInt = 0
    @State private var pendingScrollJumpTarget: CoreTextReadingPosition?

    @State private var readerSessionCoordinator: ReaderSessionCoordinator?
    @State private var readingStatsTracker: ReadingStatsSessionTracker?

    @State private var isRestoringPosition = true
    @State private var savedCoreTextRestoreTarget: (chapterIndex: Int, charOffset: Int)?
    @State private var isApplyingCoreTextRestore = false
    @State private var isLoadingPipeline = false
    @State private var curlStartupStartedAt: CFAbsoluteTime?
    @State private var hasLoggedCurlInteractiveReady = false
    @State private var hasPerformedInitialLoad = false
    @State private var activeFixedLayoutOrientationRequest: FixedLayoutOrientation?

    // Source change
    @State private var showChangeSourceSheet = false
    @State private var reviewTarget: ReaderHTMLUtilities.ReviewTarget?
    @State private var coreTextExternalTargetVersion: UInt = 0
    @State private var bookDocument: (any BookDocument)? = nil
    @State private var contentProvider: (any BookContentProvider)? = nil
    @State private var readerCapabilities: ReaderCapabilities = .reflowableText

    // Source change state managed by ViewModel, exposed via computed properties to avoid duplicate state in the view.
    private var changeSourceOrigins: [BookOrigin] { readerViewModel.changeSourceOrigins }
    private var changeSourceLoading: Bool { readerViewModel.changeSourceLoading }
    private var changeSourceError: String? { readerViewModel.changeSourceError }
    private var changeSourceFailedKeys: Set<String> { readerViewModel.changeSourceFailedKeys }

    @State private var systemBrightness: Double = 0.5

    private var fontSize: CGFloat {
        get { readerConfig.fontSize }
        nonmutating set { readerConfig.fontSize = newValue }
    }

    private var readerTheme: ReaderTheme {
        get { readerConfig.theme }
        nonmutating set { readerConfig.theme = newValue }
    }


    private var usesReadableReaderWidth: Bool {
        horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }

    private var overlayContentMaxWidth: CGFloat {
        usesReadableReaderWidth ? DSLayout.readableOverlayWidth : .infinity
    }

    private var extraReaderHorizontalInset: CGFloat {
        usesReadableReaderWidth ? DSLayout.readerRegularExtraHorizontalInset : 0
    }

    private var effectivePageMarginH: CGFloat {
        readerConfig.pageMarginH + extraReaderHorizontalInset
    }

    private var isLandscapeViewport: Bool {
        readerViewportSize.width > readerViewportSize.height
    }

    private var effectiveReaderSpreadMode: ReaderSpreadMode {
        guard usesReadableReaderWidth,
              !effectiveScrollMode
        else {
            return .singlePage
        }

        if usesFixedLayoutRenderer {
            guard fixedLayoutAllowsDoublePageSpread else { return .singlePage }
        } else {
            guard isLandscapeViewport else { return .singlePage }
        }

        switch settings.readerSpreadMode {
        case .singlePage:
            return .singlePage
        case .auto, .doublePage:
            return .doublePage
        }
    }

    private var fixedLayoutAllowsDoublePageSpread: Bool {
        switch epubRenderer.fixedLayoutOrientation {
        case .portrait:
            guard !isLandscapeViewport else { return false }
        case .landscape:
            guard isLandscapeViewport else { return false }
        case .auto:
            break
        }

        switch epubRenderer.fixedLayoutSpread {
        case .none:
            return false
        case .landscape:
            return isLandscapeViewport
        case .portrait:
            return !isLandscapeViewport && UIDevice.current.userInterfaceIdiom == .pad
        case .both:
            return true
        case .auto:
            return isLandscapeViewport || UIDevice.current.userInterfaceIdiom == .pad
        }
    }

    private var isDoublePageSpreadActive: Bool {
        effectiveReaderSpreadMode == .doublePage
    }

    private var readerPageStep: Int {
        isDoublePageSpreadActive ? 2 : 1
    }

    private func nextReaderPage(after page: Int, maxPage: Int) -> Int {
        if isDoublePageSpreadActive,
           let pairingProvider = epubRenderer.engine as? FixedLayoutSpreadPairingProviding,
           let next = pairingProvider.nextFixedLayoutSpreadPage(after: page) {
            return min(maxPage, next)
        }
        return min(maxPage, page + readerPageStep)
    }

    private func previousReaderPage(before page: Int) -> Int {
        if isDoublePageSpreadActive,
           let pairingProvider = epubRenderer.engine as? FixedLayoutSpreadPairingProviding,
           let previous = pairingProvider.previousFixedLayoutSpreadPage(before: page) {
            return max(0, previous)
        }
        return max(0, page - readerPageStep)
    }

    /// Composed two-page spreads can't render a native page-curl (the spine sits in
    /// the centre, which UIPageViewController only supports when it owns both pages),
    /// so fall back to slide in double-page mode to keep tap/swipe turns animated.
    private var effectivePageTurnStyle: PageTurnStyle {
        isDoublePageSpreadActive && settings.pageTurnStyle == .curl ? .slide : settings.pageTurnStyle
    }

    private var readerPageViewIdentity: String {
        "\(effectivePageTurnStyle.rawValue)-\(effectiveReaderSpreadMode.rawValue)"
    }

    private var currentReaderRenderSize: CGSize {
        readerRenderSize(forViewport: readerViewportSize)
    }

    private func readerRenderSize(forViewport viewportSize: CGSize) -> CGSize {
        guard effectiveReaderSpreadMode == .doublePage else { return viewportSize }
        return CGSize(
            width: max(1, (viewportSize.width - DSLayout.readerSpreadGutter) / 2),
            height: max(1, viewportSize.height)
        )
    }

    private var systemVerticalPadding: CGFloat {
        ReaderLayoutMetrics.minimumVerticalPadding
    }

    // ── Derived Properties ──
    var book: ReadingBook? { store.books.first(where: { $0.id == bookId }) }

    var isEPUB: Bool {
        book?.resolvedPipelineKind == .epub
    }

    var isTXT: Bool {
        book?.resolvedPipelineKind == .txt
    }

    @State private var isVerticalEPUB = false

    private var usesCoreTextEPUB: Bool {
        epubRenderer.engine != nil
    }

    private var isFixedLayoutEPUB: Bool {
        isEPUB && epubRenderer.layoutMode == .prePaginated
    }

    private var usesFixedLayoutRenderer: Bool {
        isEPUB && isFixedLayoutEPUB
    }

    private var usesPagedRenderer: Bool { usesCoreTextEPUB }

    private var renderedPageCount: Int {
        if let engine = epubRenderer.engine, usesCoreTextEPUB { return engine.totalPages }
        return allPages.count
    }

    /// The single TOC entry to highlight as "current". EPUB uses spine index + in-spine
    /// character offset because the TOC/nav list is not guaranteed to be 1:1 with the spine.
    private var currentTOCChapterID: UUID? {
        currentTOCChapter?.id
    }

    private var currentTOCChapter: BookChapter? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let position = engine.charOffset(forPage: currentPage)
            return tocChapter(
                forSpineIndex: position.spineIndex,
                charOffset: position.charOffset
            )
        }

        return chapters.first(where: { $0.index == currentChapterIndex })
            ?? (chapters.indices.contains(currentChapterIndex) ? chapters[currentChapterIndex] : nil)
    }

    private func tocChapter(forSpineIndex spineIndex: Int, charOffset: Int) -> BookChapter? {
        ReaderTOCSelection.currentChapter(
            in: chapters,
            currentSpineIndex: spineIndex,
            currentCharOffset: charOffset
        ) { chapter in
            guard let engine = epubRenderer.engine else { return 0 }
            return tocAnchorOffset(for: chapter, engine: engine)
        }
    }

    private func tocAnchorOffset(
        for chapter: BookChapter,
        engine: any PageRenderingProvider
    ) -> Int? {
        guard let fragment = chapter.fragment, !fragment.isEmpty else { return 0 }

        if let cfi = EPUBCFIResolver.parse(fragment),
           let session = activePublicationSession {
            let resolver = EPUBCFIResolver(
                spineReferences: session.opfSpineReferences,
                manifestItemsByID: session.opfManifestItemsByID
            )
            let spineIndex = resolver.resolveSpineIndex(cfi, chapters: session.chapters) ?? chapter.index
            guard let layout = engine.layouts[spineIndex] else { return nil }
            return resolver.resolveCharOffset(
                cfi,
                anchorOffsets: layout.anchorOffsets,
                contentLength: layout.attributedString.length
            )
        }

        return engine.charOffset(forSpine: chapter.index, fragment: fragment)
    }

    private func tocPosition(
        for chapter: BookChapter,
        engine: (any PageRenderingProvider)?
    ) -> CoreTextReadingPosition {
        guard usesCoreTextEPUB,
              let engine,
              let fragment = chapter.fragment,
              !fragment.isEmpty
        else {
            return CoreTextReadingPosition(spineIndex: chapter.index, charOffset: 0)
        }

        var spineIndex = chapter.index
        if let cfi = EPUBCFIResolver.parse(fragment),
           let session = activePublicationSession {
            let resolver = EPUBCFIResolver(
                spineReferences: session.opfSpineReferences,
                manifestItemsByID: session.opfManifestItemsByID
            )
            spineIndex = resolver.resolveSpineIndex(cfi, chapters: session.chapters) ?? chapter.index
        }

        let charOffset = tocAnchorOffset(for: chapter, engine: engine) ?? 0
        return CoreTextReadingPosition(spineIndex: spineIndex, charOffset: charOffset)
    }

    private var tocPageOffsets: [UUID: Int] {
        guard let engine = epubRenderer.engine, usesCoreTextEPUB else { return [:] }
        var offsets: [UUID: Int] = [:]
        for chapter in chapters {
            // Resolve the entry's anchor to a char offset so sub-sections of one spine map to
            // distinct pages; fall back to the spine start when the anchor isn't laid out yet.
            let position = tocPosition(for: chapter, engine: engine)
            offsets[chapter.id] = engine.pageIndex(
                forSpine: position.spineIndex,
                charOffset: position.charOffset
            )
        }
        return offsets
    }

    private var localEPUBBookIdentifier: String? {
        guard let currentBook = book, usesCoreTextEPUB else { return nil }
        if currentBook.resolvedPipelineKind == .epub {
            return store.localEPUBURL(for: currentBook).standardizedFileURL.path
        }
        if currentBook.resolvedPipelineKind == .txt {
            return currentBook.id.uuidString
        }
        return "coretext-\(currentBook.id.uuidString)"
    }

    private func onlineChapterRef(for chapterIndex: Int) -> OnlineChapterRef? {
        guard let refs = book?.onlineChapters, refs.indices.contains(chapterIndex) else { return nil }
        return refs[chapterIndex]
    }

    private func cachedChapterPackage(for chapterIndex: Int) -> ChapterPackage? {
        guard let currentBook = book,
              let ref = onlineChapterRef(for: chapterIndex)
        else {
            return nil
        }

        let sanitizedURL = RuleEngine.sanitizeExtractedURL(ref.url)
        return dependencies.bookSourceFetcher.loadChapterPackageSync(
            bookId: currentBook.id,
            chapterIndex: chapterIndex,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        ) ?? (
            sanitizedURL != ref.url
                ? dependencies.bookSourceFetcher.loadChapterPackageSync(
                    bookId: currentBook.id,
                    chapterIndex: chapterIndex,
                    expectedSourceURL: ref.url,
                    expectedTOCTitle: ref.title
                )
                : nil
        )
    }

    private func isChapterContentAvailable(at chapterIndex: Int) -> Bool {
        guard let package = cachedChapterPackage(for: chapterIndex) else {
            print("[CacheDebug] isChapterContentAvailable ch=\(chapterIndex) → false (no package)")
            return false
        }
        let ok = package.state == .cached && !package.content.isEmpty
        if !ok {
            print("[CacheDebug] isChapterContentAvailable ch=\(chapterIndex) → false pkgState=\(package.state) contentLen=\(package.content.count)")
        }
        return ok
    }

    private var currentChapterOverlayState: ReaderChapterOverlayState {
        guard book?.onlineChapters?.isEmpty == false else { return .hidden }
        return ReaderChapterPresentation.overlayState(
            isContentAvailable: isChapterContentAvailable(at: currentChapterIndex),
            loadState: readerViewModel.chapterState(for: currentChapterIndex)
        )
    }

    private var telemetryPipelineKind: String {
        book?.resolvedPipelineKind.rawValue ?? "epub"
    }

    private func progressTrace(_ message: String) {
        print("[ProgressTrace][ReaderView][\(bookId.uuidString)] \(message)")
    }

    private var currentReaderPresentationState: ReaderPresentationState {
        ReaderPresentationState(
            location: readerSessionCoordinator?.state.location
                ?? ReaderLocation(spineIndex: currentChapterIndex, charOffset: 0),
            direction: effectiveWritingMode.isVertical ? .rtl : .ltr,
            spreadMode: effectiveReaderSpreadMode,
            viewportSize: readerViewportSize,
            appearance: ReaderAppearance(settings: buildRenderSettings(), theme: readerTheme),
            pagingStyle: ReaderPagingStyle(pageTurnStyle: settings.pageTurnStyle)
        )
    }

    private func handleReaderViewportSizeChange(_ newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }

        let previousSize = readerViewportSize
        readerViewportSize = newSize
        epubRenderer.notifyViewportSize(newSize)
        readerSessionCoordinator?.send(.updateViewport(newSize))
        readerSessionCoordinator?.send(.updateSpreadMode(effectiveReaderSpreadMode))

        let sizeChanged =
            abs(newSize.width - previousSize.width) > 0.5 ||
            abs(newSize.height - previousSize.height) > 0.5
        guard sizeChanged else { return }

        let targetRenderSize = readerRenderSize(forViewport: newSize)

        guard let engine = epubRenderer.engine, engine.renderSize != .zero else {
            if epubRenderer.scrollEngine != nil {
                performUnifiedRelayout(targetSize: targetRenderSize)
            }
            return
        }

        if abs(targetRenderSize.width - engine.renderSize.width) > 0.5 ||
            abs(targetRenderSize.height - engine.renderSize.height) > 0.5 {
            performUnifiedRelayout(targetSize: targetRenderSize)
        }
    }

    private func ensureReaderNavigator(initialPosition: CoreTextReadingPosition) {
        if readerSessionCoordinator == nil {
            var state = currentReaderPresentationState
            state.location = ReaderLocation(initialPosition, source: .restored)
            let navigator = ReaderNavigator(
                initialState: state,
                positionStore: dependencies.readingPositionStore,
                bookId: book?.id.uuidString ?? bookId.uuidString
            )
            readerSessionCoordinator = ReaderSessionCoordinator(navigator: navigator)
            return
        }
        readerSessionCoordinator?.send(.updateAppearance(currentReaderPresentationState.appearance))
        readerSessionCoordinator?.send(.updateViewport(readerViewportSize))
        readerSessionCoordinator?.send(.updateDirection(effectiveWritingMode.isVertical ? .rtl : .ltr))
        readerSessionCoordinator?.send(.updatePagingStyle(ReaderPagingStyle(pageTurnStyle: settings.pageTurnStyle)))
        readerSessionCoordinator?.send(.updateSpreadMode(effectiveReaderSpreadMode))
    }

    private func moveReaderSession(
        to position: CoreTextReadingPosition,
        source: ReaderLocation.Source,
        pageIndex: Int? = nil,
        totalPages: Int? = nil,
        isEstimated: Bool = false,
        shouldPersist: Bool = true
    ) {
        ensureReaderNavigator(initialPosition: position)
        switch source {
        case .settledPage:
            readerSessionCoordinator?.send(.settlePage(
                position: position,
                pageIndex: pageIndex,
                totalPages: totalPages,
                persist: shouldPersist
            ))
        case .scrollCommit:
            readerSessionCoordinator?.send(.scrollCommit(position: position))
        case .internalLink:
            readerSessionCoordinator?.send(.internalLinkResolved(
                position: position,
                pageIndex: pageIndex,
                totalPages: totalPages
            ))
        case .jump:
            readerSessionCoordinator?.send(.jumpToPosition(
                position: position,
                pageIndex: pageIndex,
                totalPages: totalPages,
                isEstimated: isEstimated
            ))
        case .modeSwitch:
            readerSessionCoordinator?.send(.switchMode(position: position))
        case .restored:
            readerSessionCoordinator?.navigator.restore(
                to: position,
                pageIndex: pageIndex,
                totalPages: totalPages,
                isEstimated: isEstimated
            )
        case .placeholder:
            readerSessionCoordinator?.send(.jumpToPosition(
                position: position,
                pageIndex: pageIndex,
                totalPages: totalPages,
                isEstimated: true
            ))
        }
    }

    private func setCoreTextExternalTarget(_ position: CoreTextReadingPosition) {
        readerSessionCoordinator?.setExternalTarget(position)
        coreTextExternalTargetVersion &+= 1
    }

    private func clearCoreTextExternalTarget() {
        readerSessionCoordinator?.send(.clearExternalTarget)
        coreTextExternalTargetVersion &+= 1
    }

    private func applyReaderEffects(
        _ effects: [ReaderEffect],
        engine: any PageRenderingProvider
    ) {
        for effect in effects {
            switch effect {
            case let .warmUpNext(currentGlobalPage):
                engine.warmUpNext(currentGlobalPage: currentGlobalPage)
            default:
                break
            }
        }
    }

    private func coreTextPositionIfLayoutReady(
        engine: any PageRenderingProvider,
        page: Int
    ) -> (spineIndex: Int, charOffset: Int)? {
        let (spineIndex, charOffset) = engine.charOffset(forPage: page)
        guard engine.layouts[spineIndex] != nil else { return nil }
        return (spineIndex, charOffset)
    }

    private func scheduleCoreTextPageChanged(
        _ newPage: Int,
        engine: any PageRenderingProvider,
        visiblePosition: CoreTextReadingPosition? = nil
    ) {
        DispatchQueue.main.async {
            handleCoreTextPageChanged(newPage, engine: engine, visiblePosition: visiblePosition)
        }
    }

    private func handleCoreTextPageChanged(
        _ newPage: Int,
        engine: any PageRenderingProvider,
        visiblePosition: CoreTextReadingPosition? = nil
    ) {
        let newChapter = visiblePosition?.spineIndex ?? engine.charOffset(forPage: newPage).spineIndex
        let chapterChanged = newChapter != currentChapterIndex

        currentChapterIndex = newChapter
        let settledPosition = visiblePosition
            ?? engine.readingPosition(forPage: newPage)
            ?? CoreTextReadingPosition(
                spineIndex: engine.charOffset(forPage: newPage).spineIndex,
                charOffset: engine.charOffset(forPage: newPage).charOffset
            )
        moveReaderSession(
            to: settledPosition,
            source: .settledPage,
            pageIndex: newPage,
            totalPages: engine.totalPages,
            shouldPersist: false
        )

        progressTrace("onPageChanged page=\(newPage) chapter=\(currentChapterIndex) visiblePosition=\(String(describing: visiblePosition))")

        if chapterChanged {
            ensureChapterReady(chapterIndex: newChapter)
            // Switch the authored background soundtrack to the new chapter's (or stop it if none).
            if let session = activePublicationSession {
                Task { await backgroundAudioCoordinator.update(session: session, chapterIndex: newChapter) }
            }
            // Keep BOTH neighbors paginated, not just forward ones. Previously only
            // chapters ahead stayed warm, so turning back (or a nearby TOC jump) hit a
            // cold chapter and stalled on on-demand pagination — the "laggy" feel.
            if let engine = epubRenderer.engine, usesCoreTextEPUB {
                for neighbor in [newChapter - 1, newChapter + 1]
                where chapters.indices.contains(neighbor) && isChapterContentAvailable(at: neighbor) {
                    Task { await engine.preloadChapter(at: neighbor) }
                }
            }
        }

        guard ReaderProgressSyncPolicy.shouldPersistOnPageChanged(
            isCoreTextReady: epubRenderer.isCoreTextReady,
            totalPages: engine.totalPages,
            isRestoringPosition: isRestoringPosition
        ) else {
            progressTrace(
                "onPageChanged skipPersist page=\(newPage) ready=\(epubRenderer.isCoreTextReady) totalPages=\(engine.totalPages) restoring=\(isRestoringPosition)"
            )
            return
        }

        guard coreTextPositionIfLayoutReady(engine: engine, page: newPage) != nil else {
            progressTrace("onPageChanged skipPersist page=\(newPage) reason=layoutNotReady")
            return
        }

        epubRenderer.updateCurrentPosition(globalPage: newPage, engine: engine)

        readerSessionCoordinator?.send(.settlePage(
            position: settledPosition,
            pageIndex: newPage,
            totalPages: engine.totalPages,
            persist: true
        ))
    }

    /// EPUB font asset directory (Documents/{uuid}_epub_assets/).
    var epubAssetsURL: URL? {
        guard let b = book, b.isLegacyParsedEPUB else { return nil }
        let assetsDir = b.contentFilename.replacingOccurrences(
            of: "_epub.json", with: "_epub_assets")
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docsDir.appendingPathComponent(assetsDir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Base URL for the current chapter: assets root + chapter subdirectory (for resolving relative font paths in CSS).
    var epubBaseURL: URL? {
        guard let assetsURL = epubAssetsURL else { return nil }
        if isEPUB {
            guard chapters.indices.contains(currentChapterIndex) else { return assetsURL }
            let href = chapters[currentChapterIndex].href
            guard !href.isEmpty, href != "synthetic_cover" else { return assetsURL }
            let hrefDir = (href as NSString).deletingLastPathComponent
            return hrefDir.isEmpty ? assetsURL : assetsURL.appendingPathComponent(hrefDir)
        }
        guard chapters.indices.contains(currentPage) else { return assetsURL }
        let href = chapters[currentPage].href
        guard !href.isEmpty, href != "synthetic_cover" else { return assetsURL }
        let hrefDir = (href as NSString).deletingLastPathComponent
        return hrefDir.isEmpty ? assetsURL : assetsURL.appendingPathComponent(hrefDir)
    }

    var currentChapterTitle: String {
        if usesCoreTextEPUB {
            if let chapter = currentTOCChapter {
                return chapter.title
            }
            return book?.title ?? ""
        }
        guard !allPages.isEmpty else { return "" }
        return allPages[min(currentPage, allPages.count - 1)].chapterTitle
    }

    var canGoPrevChapter: Bool { currentChapterIndex > 0 }
    var canGoNextChapter: Bool { currentChapterIndex < chapters.count - 1 }

    /// Footer intrinsic height (points), excluding safe area bottom.
    private let footerOverlayHeight: CGFloat = ReaderLayoutMetrics.footerHeight

    private var currentTopBarBookmarkPosition: CoreTextReadingPosition? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let position = engine.readingPosition(forPage: currentPage)
                ?? CoreTextReadingPosition(spineIndex: engine.charOffset(forPage: currentPage).spineIndex, charOffset: 0)
            return .chapterStart(position.spineIndex)
        }
        if !allPages.isEmpty {
            let page = allPages[min(currentPage, allPages.count - 1)]
            return .chapterStart(page.chapterIndex)
        }
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return .chapterStart(currentChapterIndex)
    }

    /// Whether the current chapter has a topbar bookmark.
    var isCurrentPageBookmarked: Bool {
        guard let position = currentTopBarBookmarkPosition else { return false }
        return store.isChapterStartBookmarked(bookId: bookId, chapterIndex: position.spineIndex)
    }

    private func bookmarkChapterTitle(for chapterIndex: Int) -> String {
        if usesCoreTextEPUB,
           let chapter = tocChapter(forSpineIndex: chapterIndex, charOffset: 0) {
            return chapter.title
        }
        if chapters.indices.contains(chapterIndex) {
            return chapters[chapterIndex].title
        }
        if let page = allPages.first(where: { $0.chapterIndex == chapterIndex }) {
            return page.chapterTitle
        }
        return currentChapterTitle
    }

    /// Current page excerpt (first 30 characters).
    var currentPageExcerpt: String {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            return String(engine.plainText(forPage: currentPage).prefix(30))
        }
        guard !allPages.isEmpty else { return "" }
        let content = allPages[min(currentPage, allPages.count - 1)].content
        return String(content.prefix(30))
    }

    private var coreTextTextAnnotations: [CoreTextTextAnnotation] {
        (book?.bookmarks ?? []).compactMap(\.coreTextTextAnnotation)
    }

    private func syncCoreTextTextAnnotations() {
        let annotations = coreTextTextAnnotations
        epubRenderer.engine?.setTextAnnotations(annotations)
        epubRenderer.scrollEngine?.textAnnotations = annotations
    }

    private func addUnderlineBookmark(_ request: CoreTextUnderlineSelectionRequest) {
        let position = request.position
        guard chapters.indices.contains(position.spineIndex) else { return }
        if request.removesExistingUnderline {
            store.removeTextAnnotation(
                bookId: bookId,
                position: position,
                length: request.length,
                style: request.style,
                color: request.color
            )
            syncCoreTextTextAnnotations()
            return
        }
        store.addTextAnnotation(
            bookId: bookId,
            chapterIndex: position.spineIndex,
            chapterTitle: bookmarkChapterTitle(for: position.spineIndex),
            position: position,
            length: request.length,
            excerpt: request.excerpt.isEmpty ? currentPageExcerpt : String(request.excerpt.prefix(80)),
            style: request.style,
            color: request.color
        )
        syncCoreTextTextAnnotations()
    }

    /// Overall reading progress percentage.
    var totalProgressPercent: String {
        if usesCoreTextEPUB, let engine = epubRenderer.engine {
            let (spine, offset) = engine.charOffset(forPage: currentPage)
            let pct = engine.totalProgress(forSpine: spine, charOffset: offset) * 100
            return String(format: "%.2f%%", pct)
        }
        guard !allPages.isEmpty else { return "0.00%" }
        let pct = Double(currentPage) / Double(max(allPages.count - 1, 1)) * 100
        return String(format: "%.2f%%", pct)
    }

    /// Chapter page info.
    var chapterPageInfo: String {
        if book?.isOnline == true && readerViewModel.chapterState(for: currentChapterIndex) == .loading {
            return ""
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let (spineIndex, charOffset) = engine.charOffset(forPage: currentPage)
            guard let layout = engine.layouts[spineIndex], !layout.pageRanges.isEmpty else {
                return ""
            }
            let localPage = layout.pageIndex(for: charOffset) + 1
            return "\(localPage)/\(layout.pageRanges.count)"
        }
        guard !allPages.isEmpty else { return "" }
        let page = allPages[min(currentPage, allPages.count - 1)]
        let total = allPages.filter { $0.chapterIndex == page.chapterIndex }.count
        return "\(page.pageInChapter + 1)/\(total)"
    }

    /// Current page text (for TTS).
    var currentPageText: String {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            return engine.plainText(forPage: currentPage)
        }
        guard !allPages.isEmpty else { return "" }
        return allPages[min(currentPage, allPages.count - 1)].content
    }

    private var activePlaybackHighlightText: String? {
        if mediaOverlayCoordinator.playbackState != .stopped {
            return currentMediaOverlayHighlightText()
        }
        return ttsCoordinator.playbackState == .stopped ? nil : ttsCoordinator.currentSegmentText
    }

    private var activeTTSChapterTitle: String {
        let index = ttsChapterIndex ?? currentChapterIndex
        guard chapters.indices.contains(index) else { return currentChapterTitle }
        return chapters[index].title
    }

    private var ttsNowPlayingBookTitle: String {
        let title = book?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? activeTTSChapterTitle : title
    }

    private var ttsNowPlayingAuthor: String {
        book?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func ttsNowPlayingArtwork() -> UIImage? {
        if let coverPath = book?.coverImagePath,
           let image = loadTOCStyleCoverImage(filename: coverPath) {
            return image
        }
        return makeTOCStyleTitleCardArtwork(title: ttsNowPlayingBookTitle)
    }

    private func loadTOCStyleCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func makeTOCStyleTitleCardArtwork(title: String) -> UIImage? {
        let size = CGSize(width: 512, height: 768)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return renderer.image { context in
            UIColor.secondarySystemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph
            ]
            let rect = CGRect(x: 56, y: 64, width: size.width - 112, height: size.height - 128)
            let titleString = displayTitle.isEmpty ? "閱讀" : displayTitle
            (titleString as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil
            )
        }
    }

    // ── Body ──
    var body: some View {
        buildBody()
            .task {
                guard readerSessionCoordinator == nil else { return }
                let fallback = CoreTextReadingPosition(spineIndex: 0, charOffset: 0)
                ensureReaderNavigator(initialPosition: fallback)
                let restored = await readerSessionCoordinator?.restore()
                if let restored {
                    currentChapterIndex = restored.spineIndex
                    scrollVisibleChapter = restored.spineIndex
                    pendingScrollJumpTarget = restored.coreTextPosition
                }
                isRestoringPosition = false
            }
    }

    private func buildBody() -> AnyView {
        AnyView(
            ZStack(alignment: .top) {
            readerTheme.backgroundColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: uiFeedbackDuration), value: readerTheme)

            if chapters.isEmpty {
                VStack {
                    Spacer()
                    ProgressView(localized("載入中…"))
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if usesFixedLayoutRenderer, let flEngine = epubRenderer.engine {
                CoreTextPageEngineView(
                    engine: flEngine,
                    pageTurnStyle: effectivePageTurnStyle,
                    theme: readerTheme,
                    playbackHighlightText: nil,
                    isRTL: epubRenderer.pageProgressionDirection == .rtl,
                    isDoublePageSpread: isDoublePageSpreadActive,
                    spreadGutter: DSLayout.readerSpreadGutter,
                    sessionCoordinator: nil,
                    externalTargetVersion: 0,
                    externalTargetPosition: nil,
                    clearExternalTargetPosition: {},
                    currentPage: $currentPage,
                    onPageChanged: { newPage, _ in
                        currentPage = newPage
                    },
                    onTapZone: { zone in
                        switch zone {
                        case "left":
                            guard !showBars else { return }
                            goToPrevPage()
                        case "right":
                            guard !showBars else { return }
                            goToNextPage()
                        default:
                            withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                        }
                    }
                )
                .id(readerPageViewIdentity)
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if effectiveScrollMode {
                // scrollBody must stay mounted so the collection host drives the
                // engine's start()/isReady. Overlay (not replace) the loading state,
                // otherwise the engine never kicks off and loading spins forever.
                ZStack {
                    scrollBody
                    if epubRenderer.scrollEngine != nil, !epubRenderer.scrollEngineReady {
                        readerTheme.backgroundColor
                            .ignoresSafeArea()
                            .overlay { ProgressView(localized("載入中…")) }
                            .transition(.opacity)
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
                .animation(.easeOut(duration: 0.2), value: epubRenderer.scrollEngineReady)
            } else if let ctEngine = epubRenderer.engine, epubRenderer.isCoreTextReady {
                let _ = { print("[ReaderView] Using CoreText engine") }()
                CoreTextPageEngineView(
                    engine: ctEngine,
                    pageTurnStyle: effectivePageTurnStyle,
                    theme: readerTheme,
                    playbackHighlightText: activePlaybackHighlightText,
                    // RTL page-turn flow applies to both vertical-rl CJK and
                    // horizontal RTL bidi scripts (Hebrew, Arabic, …).
                    isRTL: epubRenderer.pageProgressionDirection == .rtl || effectiveWritingMode.isVertical,
                    isDoublePageSpread: isDoublePageSpreadActive,
                    spreadGutter: DSLayout.readerSpreadGutter,
                    sessionCoordinator: readerSessionCoordinator,
                    externalTargetVersion: coreTextExternalTargetVersion,
                    externalTargetPosition: readerSessionCoordinator?.externalTargetPosition,
                    clearExternalTargetPosition: { clearCoreTextExternalTarget() },
                    currentPage: $currentPage,
                    onPageChanged: { newPage, visiblePosition in
                        scheduleCoreTextPageChanged(newPage, engine: ctEngine, visiblePosition: visiblePosition)
                    },
                    onTapZone: { zone in
                        switch zone {
                        case "left":
                            guard !showBars else { return }
                            goToPrevPage()
                        case "right":
                            guard !showBars else { return }
                            goToNextPage()
                        default:
                            withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                        }
                    }
                )
                .id(readerPageViewIdentity)
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if usesCoreTextEPUB {
                VStack {
                    Spacer()
                    ProgressView(localized("載入中…"))
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // Network fetch status overlay is disabled per user request.
            // Logic is preserved in currentChapterOverlayState + refreshCurrentChapter().
            // To restore the UI, uncomment the switch block below:
            //
            //   if !showBars {
            //       switch currentChapterOverlayState {
            //       case .hidden, .loading: EmptyView()
            //       case .failed(let message): /* error tip + retry button */
            //       }
            //   }

            // Top/Bottom bars
            if !showBars && !effectiveScrollMode && !chapters.isEmpty {
                VStack {
                    Spacer()
                    bottomFooter
                }
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            if showBars { topBar }
            if showBars, let b = book, shouldShowDownloadProgress(for: b) {
                downloadProgressOverlay(for: b)
                    .zIndex(60)
            }
            if showBars { bottomBar }
            if showTTSJumpPrompt {
                VStack {
                    Spacer()
                    ttsJumpPromptView(alignment: showBars ? .trailing : .center)
                        .padding(.horizontal, showBars ? 20 : 120)
                        .padding(.bottom, showBars ? 150 : ttsJumpPromptCollapsedBottomPadding)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
            if showBars {
                TTSFloatingPlayerOverlay()
                    .zIndex(50)
            }
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .preference(key: ReaderSafeAreaTopKey.self, value: g.safeAreaInsets.top)
                    .preference(key: ReaderViewportSizeKey.self, value: g.size)
            }
        )
        .onPreferenceChange(ReaderSafeAreaTopKey.self) {
            readerSafeAreaTop = max($0, windowSafeTop)
        }
        .onPreferenceChange(ReaderViewportSizeKey.self) { newSize in
            handleReaderViewportSizeChange(newSize)
        }
        .animation(.easeInOut(duration: 0.25), value: chapters.isEmpty)
        .statusBarHidden(!showBars)
        .animation(.easeInOut(duration: 0.25), value: showBars)
        .modifier(HideTabBarModifier())
        .onAppear {
            readerViewModel.configure(chapterFetcher: dependencies.chapterFetcher)
            ReaderTelemetry.shared.log(
                "reader_load_start",
                attributes: [
                    "bookId": bookId.uuidString,
                    "pipelineKind": telemetryPipelineKind,
                    "turnStyle": settings.pageTurnStyle.rawValue,
                    "scrollMode": effectiveScrollMode ? "1" : "0",
                ]
            )
            readerConfig.syncFromGlobalSettings()
            if !hasPerformedInitialLoad {
                hasPerformedInitialLoad = true
                performInitialLoad()
            } else {
                restoreReaderDisplayStateAfterResume()
            }
            beginReadingStatsSession()
            syncCoreTextTextAnnotations()
            systemBrightness = Double(UIScreen.main.brightness)
            if settings.followSystemBrightness {
                settings.readerBrightness = systemBrightness
            } else {
                UIScreen.main.brightness = CGFloat(settings.readerBrightness)
            }
            volumeHandler.onPageTurn = { dir in
                switch dir {
                case .prev: goToPrevPage()
                case .next: goToNextPage()
                }
            }
            if volumeHandler.isEnabled { volumeHandler.startListening() }
            autoReader.onNextPage = { goToNextPage() }
            ttsCoordinator.showsGlobalFloatingPlayer = true
            setTTSFloatingOverlayVisible(showBars)
            ttsCoordinator.onPageFinishedWithPronunciation = {
                ttsLog("[TTS][Reader] onChapterFinished ttsChapter=\(ttsChapterIndex.map(String.init) ?? "nil") currentChapter=\(currentChapterIndex)")
                return advanceTTSChapterFromEngine()
            }
            ttsCoordinator.onWillResume = {
                alignReaderToTTSAnchorIfNeeded()
            }
            ttsCoordinator.onNextTrackRequested = {
                startAdjacentTTSChapter(delta: 1)
            }
            ttsCoordinator.onPreviousTrackRequested = {
                startAdjacentTTSChapter(delta: -1)
            }
            ttsCoordinator.onStop = {
                ttsChapterIndex = nil
                ttsPlaybackAnchor = nil
                showTTSJumpPrompt = false
                ttsJumpPromptChapterIndex = nil
            }
        }
        .onDisappear {
            ttsLog("[TTS][Reader] onDisappear cleanup only ttsPlaying=\(ttsCoordinator.isPlaying)")
            epubRenderer.engine?.cancelPendingWork()
            if !settings.followSystemBrightness {
                UIScreen.main.brightness = CGFloat(systemBrightness)
            }
            saveProgress()
            finishReadingStatsSession()
            restoreFixedLayoutOrientationPreference()
            if let b = book, b.isOnline {
                Task {
                    await readerViewModel.cancelAll(for: b.id)
                }
            }
            volumeHandler.stopListening()
            autoReader.pause()
            mediaOverlayCoordinator.stop()
            EPUBVideoPlaybackManager.shared.stopAll()
            backgroundAudioCoordinator.stop()
            setTTSFloatingOverlayVisible(false)
        }
        .onChanged(of: scenePhase) { phase in
            ttsLog("[TTS][Reader] scenePhase=\(String(describing: phase)) ttsPlaying=\(ttsCoordinator.isPlaying)")
            if phase == .background || phase == .inactive {
                ttsCoordinator.refreshNowPlayingForSystemSurfaces()
                epubRenderer.engine?.cancelPendingWork()
                saveProgress()
                finishReadingStatsSession()
            } else if phase == .active {
                restoreReaderDisplayStateAfterResume()
                beginReadingStatsSession()
            }
        }
        .onReceive(epubRenderer.$scrollEngine) { engine in
            guard engine != nil else { return }
            syncCoreTextTextAnnotations()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in
            epubRenderer.engine?.cancelPendingWork()
            saveProgress()
            finishReadingStatsSession()
        }
        .onChanged(of: settings.readerBrightness) { val in
            if !settings.followSystemBrightness { UIScreen.main.brightness = CGFloat(val) }
        }
        .onChanged(of: settings.followSystemBrightness) { follow in
            if follow {
                syncReaderBrightnessFromSystem()
            } else {
                UIScreen.main.brightness = CGFloat(settings.readerBrightness)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification))
        { _ in
            let current = Double(UIScreen.main.brightness)
            systemBrightness = current
            if settings.followSystemBrightness {
                settings.readerBrightness = current
            }
        }
        .onReceive(readerConfig.refresh) { kind in
            handleReaderConfigRefresh(kind)
        }
        .onReceive(NotificationCenter.default.publisher(for: .coreTextUnderlineSelectionRequested)) { notification in
            guard let request = notification.userInfo?["request"] as? CoreTextUnderlineSelectionRequest else { return }
            addUnderlineBookmark(request)
        }
        .onReceive(readerViewModel.$chapterStates) { states in
            handleChapterStateChanges(states)
        }
        .onChanged(of: settings.pageTurnStyle) { _ in
            if settings.pageTurnStyle == .curl {
                beginCurlStartupTrace(reason: "style_changed")
            } else {
                curlStartupStartedAt = nil
                hasLoggedCurlInteractiveReady = false
            }
        }
        .onChanged(of: settings.scrollMode) { enabled in
            handleScrollModeChanged(enabled)
        }
        .onChanged(of: settings.readerWritingMode) { _ in
            handleReaderConfigRefresh(.layout)
        }
        .onChanged(of: effectiveReaderSpreadMode) { _ in
            readerSessionCoordinator?.send(.updateSpreadMode(effectiveReaderSpreadMode))
            performUnifiedRelayout(targetSize: currentReaderRenderSize)
        }
        .onChanged(of: book?.bookmarks ?? []) { _ in
            syncCoreTextTextAnnotations()
        }
        .onChanged(of: showBars) { visible in
            setTTSFloatingOverlayVisible(visible)
        }
        .onChanged(of: currentChapterIndex) { _ in
            handleReaderPositionChangedForTTS()
        }
        .onChanged(of: currentPage) { _ in
            updateReadingStatsPosition()
            handleReaderPositionChangedForTTS()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsFloatingPlayerOpenPanel)) { _ in
            showTTSPanel = true
        }
        .onChanged(of: scrollVisibleChapter) { newChapter in
            autoSaveProgress()
            handleReaderPositionChangedForTTS()
            if let session = activePublicationSession {
                Task { await backgroundAudioCoordinator.update(session: session, chapterIndex: newChapter) }
            }
        }
        .sheet(isPresented: $showSettings) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                ReaderSettingsView(
                    fontSize: Binding(
                        get: { fontSize },
                        set: { fontSize = $0 }
                    ),
                    theme: Binding(
                        get: { readerTheme },
                        set: { readerTheme = $0 }
                    ),
                    capabilities: readerCapabilities,
                    allowsUserSelectedReaderFont: book?.allowsUserSelectedReaderFont == true,
                    isVerticalWritingMode: effectiveWritingMode.isVertical
                )
            }
        }
        .sheet(isPresented: $showDownloadOptions) {
            if let b = book {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    ReaderDownloadOptionsView(
                        bookTitle: b.title,
                        currentChapterIndex: currentChapterIndex,
                        totalChapters: b.onlineChapters?.count ?? chapters.count,
                        onStart: { startChapterIndex, chapterCount in
                            showDownloadOptions = false
                            startOfflineDownload(
                                startChapterIndex: startChapterIndex,
                                chapterCount: chapterCount
                            )
                        },
                        onCancel: {
                            showDownloadOptions = false
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showTOC) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                ReaderMenuView(
                    chapters: chapters,
                    coverImagePath: book?.coverImagePath,
                    bookTitle: book?.title ?? "",
                    currentPage: currentPage,
                    totalPages: renderedPageCount,
                    tocLayoutMode: .from(writingMode: effectiveWritingMode),
                    pageOffsets: tocPageOffsets,
                    currentIndex: currentChapterIndex,
                    currentChapterID: currentTOCChapterID,
                    onSelectChapter: { jumpToTOCEntry($0) },
                    isPresented: $showTOC
                )
            }
        }
        .sheet(isPresented: $showBookmarks) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                ReaderBookmarkListView(
                    bookTitle: book?.title ?? "",
                    bookmarks: book?.bookmarks ?? [],
                    pageNumber: { inChapterPageNumber(for: $0) },
                    onSelect: { bm in
                        showBookmarks = false
                        jumpToBookmark(bm)
                    },
                    onDelete: { deleteBookmarkEntry($0) },
                    isPresented: $showBookmarks
                )
            }
        }
        .sheet(isPresented: $showTTSPanel) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                TTSPanelView(
                    tts: ttsCoordinator,
                    chapters: chapters,
                    currentReaderChapterIndex: currentChapterIndex,
                    activeTTSChapterIndex: ttsChapterIndex,
                    activeChapterTitle: activeTTSChapterTitle,
                    onPlayPause: { handleTTSPlayPause() },
                    onPreviousChapter: { startAdjacentTTSChapter(delta: -1) },
                    onNextChapter: { startAdjacentTTSChapter(delta: 1) },
                    onSelectChapter: { startTTSChapter($0, syncReader: true) }
                )
            }
        }
        .sheet(isPresented: $showMediaOverlayPanel) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                if let chapterIndex = activeMediaOverlayChapterIndex,
                   let overlay = epubRenderer.mediaOverlaysByChapter[chapterIndex] {
                    EPUBMediaOverlayPlayerView(
                        title: chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : currentChapterTitle,
                        overlay: overlay,
                        chapterIndex: chapterIndex,
                        coordinator: mediaOverlayCoordinator,
                        resourceURL: { epubRenderer.resourceURL(for: $0) }
                    )
                } else {
                    ContentUnavailableView(
                        localized("媒體旁白"),
                        systemImage: "waveform",
                        description: Text(localized("目前章節沒有媒體旁白"))
                    )
                }
            }
        }
        .sheet(isPresented: $showAutoReadPanel) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                AutoReadPanelView(autoReader: autoReader)
            }
        }
        .sheet(isPresented: $showChangeSourceSheet) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                changeSourceSheetContent
            }
        }
        .sheet(item: $reviewTarget) { target in
            JsBridgeBrowserView(
                urlString: target.url,
                title: target.title.isEmpty ? localized("段評") : target.title
            ) { _ in
                reviewTarget = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChanged(of: showChangeSourceSheet) { show in
            if show { loadOtherOrigins() }
        }
        .onChanged(of: epubRenderer.isCoreTextReady) { ready in
            if ready {
                if !isVerticalEPUB && epubRenderer.cssDetectedVerticalWritingMode {
                    isVerticalEPUB = true
                }
                syncCoreTextTextAnnotations()
                applyInitialProgressIfNeeded()
                updateReadingStatsPosition()
            }
        }
        .onChanged(of: epubRenderer.fixedLayoutOrientation) { _ in
            updateFixedLayoutOrientationPreference()
        }
        .onChanged(of: allPages.count) { _ in
            applyInitialProgressIfNeeded()
            updateReadingStatsPosition()
        }
        .onChanged(of: chapters.count) { _ in
            applyInitialProgressIfNeeded()
        }
        )
    }

    private func performInitialLoad() {
        refreshInitialRestoreState()
        guard let currentBook = book, currentBook.isOnline else {
            loadContent()
            return
        }

        let needsRepair =
            (currentBook.bookSourceId != nil)
            && (
                (currentBook.tocURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || (currentBook.onlineChapters?.isEmpty != false)
                    || (currentBook.runtimeVariables?.isEmpty ?? true)
            )

        guard needsRepair else {
            loadContent()
            return
        }

        // Bookshelf has chapters: open reader immediately, repair metadata in background.
        if currentBook.onlineChapters?.isEmpty == false {
            loadContent()
            Task {
                _ = try? await store.refreshOnlineBookMetadata(
                    bookId: currentBook.id,
                    forceInfoRefresh: true,
                    bookSourceFetcher: dependencies.bookSourceFetcher
                )
            }
        } else {
            // No chapters: open as soon as the first batch of TOC arrives, without waiting for the full TOC.
            Task {
                _ = try? await store.refreshOnlineBookMetadata(
                    bookId: currentBook.id,
                    forceInfoRefresh: true,
                    bookSourceFetcher: dependencies.bookSourceFetcher,
                    onFirstChaptersReady: { repairedBook in
                        guard repairedBook.id == currentBook.id, self.chapters.isEmpty else { return }
                        self.loadContent()
                    }
                )
                await MainActor.run {
                    if self.chapters.isEmpty {
                        loadContent()
                    }
                }
            }
        }
    }

    private func refreshInitialRestoreState() {
        let fallback = CoreTextReadingPosition(spineIndex: currentChapterIndex, charOffset: 0)
        ensureReaderNavigator(initialPosition: fallback)
        guard let restored = readerSessionCoordinator?.restoreSync(),
              restored.source == .restored else {
            savedCoreTextRestoreTarget = nil
            isApplyingCoreTextRestore = false
            progressTrace("refreshInitialRestoreState source=none target=nil")
            return
        }

        let position = restored.coreTextPosition
        savedCoreTextRestoreTarget = (position.spineIndex, max(0, position.charOffset))
        setCoreTextExternalTarget(position)
        currentChapterIndex = position.spineIndex
        scrollVisibleChapter = position.spineIndex
        pendingScrollJumpTarget = position
        isApplyingCoreTextRestore = false
        progressTrace(
            "refreshInitialRestoreState source=positionStore target=(\(position.spineIndex),\(position.charOffset))"
        )
    }

    private func applyInitialProgressIfNeeded() {
        if let engine = epubRenderer.engine {
            progressTrace(
                "applyInitialProgress start enginePage=\(engine.currentPage) totalPages=\(engine.totalPages) target=\(savedCoreTextRestoreTarget.map { "(\($0.chapterIndex),\($0.charOffset))" } ?? "nil")"
            )

            if let target = savedCoreTextRestoreTarget,
               !isApplyingCoreTextRestore {
                isApplyingCoreTextRestore = true
                Task { @MainActor in
                    defer { self.isApplyingCoreTextRestore = false }
                    let maxSpine = max(0, self.chapters.count - 1)
                    let spineIndex = max(0, min(target.chapterIndex, maxSpine))
                    self.progressTrace("applyInitialProgress tryPreciseRestore requested=(\(target.chapterIndex),\(target.charOffset)) clampedSpine=\(spineIndex)")
                    await engine.preloadChapter(at: spineIndex)
                    guard let resolvedPage = ReaderProgressRestoreResolver.resolvePage(
                        chapterIndex: spineIndex,
                        charOffset: target.charOffset,
                        resolver: { position in
                            engine.pageIndex(for: position)
                        }
                    ) else {
                        self.progressTrace("applyInitialProgress preciseRestore unresolved keepTarget=(\(target.chapterIndex),\(target.charOffset))")
                        return
                    }
                    self.progressTrace("applyInitialProgress preciseRestore resolvedPage=\(resolvedPage) from=(\(spineIndex),\(target.charOffset))")
                    self.currentPage = resolvedPage
                    self.currentChapterIndex = spineIndex
                    self.moveReaderSession(
                        to: CoreTextReadingPosition(spineIndex: spineIndex, charOffset: target.charOffset),
                        source: .restored,
                        pageIndex: resolvedPage,
                        totalPages: engine.totalPages,
                        shouldPersist: false
                    )
                    self.ensureChapterReady(chapterIndex: spineIndex)
                    self.epubRenderer.updateCurrentPosition(globalPage: resolvedPage, engine: engine)
                    self.savedCoreTextRestoreTarget = nil
                    self.isRestoringPosition = false
                }
                return
            }
            return
        }
    }

    private func beginCurlStartupTrace(reason: String) {
        guard settings.pageTurnStyle == .curl else { return }
        curlStartupStartedAt = CFAbsoluteTimeGetCurrent()
        hasLoggedCurlInteractiveReady = false
        ReaderTelemetry.shared.log(
            "curl_startup_begin",
            attributes: [
                "bookId": bookId.uuidString,
                "pipelineKind": telemetryPipelineKind,
                "reason": reason,
            ]
        )
    }

    private func logCurlInteractiveReadyIfNeeded(source: String) {
        guard !hasLoggedCurlInteractiveReady else { return }
        hasLoggedCurlInteractiveReady = true
        let durationMs: String
        if let startedAt = curlStartupStartedAt {
            durationMs = "\((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)"
        } else {
            durationMs = "0"
        }
        ReaderTelemetry.shared.log(
            "curl_interactive_ready",
            attributes: [
                "bookId": bookId.uuidString,
                "pipelineKind": telemetryPipelineKind,
                "source": source,
                "pageIndex": "\(currentPage)",
                "durationMs": durationMs,
            ]
        )
    }

    private func handleScrollModeChanged(_ enabled: Bool) {
        if enabled {
            guard let position = currentPagedReadingPositionForModeSwitch() else { return }
            moveReaderSession(to: position, source: .modeSwitch)
            currentChapterIndex = position.spineIndex
            scrollVisibleChapter = position.spineIndex
            pendingScrollJumpTarget = position
            return
        }

        pendingScrollJumpTarget = nil
        let position = readerSessionCoordinator?.state.location.coreTextPosition
            ?? CoreTextReadingPosition(spineIndex: scrollVisibleChapter, charOffset: 0)
        moveReaderSession(to: position, source: .modeSwitch)
        currentChapterIndex = position.spineIndex

        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            setCoreTextExternalTarget(position)
            _ = engine.pageViewController(for: position)
            if let exactPage = engine.pageIndex(for: position) {
                currentPage = exactPage
            } else if let estimatedPage = engine.estimatedGlobalPage(for: position) {
                currentPage = estimatedPage
            }
            epubRenderer.currentEpubPage = currentPage
            ensureChapterReady(chapterIndex: position.spineIndex, priority: .jump)
            return
        }

        if let page = findChapterFirstPage(position.spineIndex) {
            currentPage = page
        }
    }

    private func currentPagedReadingPositionForModeSwitch() -> CoreTextReadingPosition? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            return engine.readingPosition(forPage: currentPage)
                ?? CoreTextReadingPosition(
                    spineIndex: engine.charOffset(forPage: currentPage).spineIndex,
                    charOffset: engine.charOffset(forPage: currentPage).charOffset
                )
        }

        guard !allPages.isEmpty else { return nil }
        let page = allPages[min(currentPage, allPages.count - 1)]
        return CoreTextReadingPosition(spineIndex: page.chapterIndex, charOffset: 0)
    }

    // MARK: - Bottom Footer (overlay for slide/cover/tab modes)
    private var bottomFooter: some View {
        ReaderOverlayFooter(
            pageInfo: chapterPageInfo,
            progress: totalProgressPercent,
            textColor: readerTheme.textColor,
            footerPadding: readerConfig.footerBottomPadding
        )
    }

    private var windowSafeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top) ?? readerSafeAreaTop
    }

    private var keyWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { scene in
                scene.activationState == .foregroundActive &&
                    scene.windows.contains(where: \.isKeyWindow)
            }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.windows.contains(where: \.isKeyWindow) }
    }

    private func updateFixedLayoutOrientationPreference() {
        guard usesFixedLayoutRenderer else {
            restoreFixedLayoutOrientationPreference()
            return
        }

        let orientation = epubRenderer.fixedLayoutOrientation
        guard orientation != .auto else {
            restoreFixedLayoutOrientationPreference()
            return
        }

        guard activeFixedLayoutOrientationRequest != orientation else { return }
        activeFixedLayoutOrientationRequest = orientation
        ReaderOrientationController.shared.request(orientation, in: keyWindowScene)
    }

    private func restoreFixedLayoutOrientationPreference() {
        guard activeFixedLayoutOrientationRequest != nil else { return }
        activeFixedLayoutOrientationRequest = nil
        ReaderOrientationController.shared.restoreDefault(in: keyWindowScene)
    }

    /// Returns the key window's bottom safe area inset (used for manual compensation in full-screen reading).
    private var windowSafeBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom) ?? 0
    }

    private var effectiveReaderSafeTop: CGFloat {
        max(readerSafeAreaTop, windowSafeTop)
    }

    // MARK: - Inline Footer (curl mode: baked into page texture, moves with the page)
    private func inlineFooter(forPage idx: Int) -> some View {
        let info = pageFooterInfo(forPage: idx)
        return ReaderInlineFooter(
            pageInfo: info.pageInfo,
            progress: info.progress,
            textColor: readerTheme.textColor,
            footerPadding: readerConfig.footerBottomPadding
        )
    }

    /// Computes footer info (chapter page + progress percentage) for the given page.
    private func pageFooterInfo(forPage idx: Int) -> (pageInfo: String, progress: String) {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let (spineIndex, charOffset) = engine.charOffset(forPage: idx)
            guard let layout = engine.layouts[spineIndex], !layout.pageRanges.isEmpty else {
                return ("", "0.00%")
            }
            let localPage = layout.pageIndex(for: charOffset) + 1
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset) * 100
            return ("\(localPage)/\(layout.pageRanges.count)", String(format: "%.2f%%", pct))
        } else {
            guard !allPages.isEmpty, idx >= 0, idx < allPages.count else { return ("", "0.00%") }
            let page = allPages[idx]
            let total = allPages.filter { $0.chapterIndex == page.chapterIndex }.count
            let pct = Double(idx) / Double(max(allPages.count - 1, 1)) * 100
            return ("\(page.pageInChapter + 1)/\(total)", String(format: "%.2f%%", pct))
        }
    }

    // MARK: - TXT Vertical Scroll Mode
    @ViewBuilder
    private var scrollBody: some View {
        if let scrollEngine = epubRenderer.scrollEngine {
            let initialPos = computeScrollInitialPosition()
            CoreTextScrollHostView(
                engine: scrollEngine,
                axis: scrollAxis,
                horizontalInset: effectivePageMarginH,
                verticalInset: scrollAxis.isHorizontalRTL
                    ? ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
                    : readerConfig.pageMarginV,
                bottomMargin: scrollAxis.isHorizontalRTL
                    ? ReaderLayoutMetrics.bottomInset(
                        safeBottom: 0,
                        footerBottomPadding: readerConfig.footerBottomPadding,
                        footerTextGap: readerConfig.footerTextGap
                      )
                    : 0,
                backgroundColor: readerTheme.uiBackgroundColor,
                initialChapter: initialPos.chapter,
                initialCharOffset: initialPos.charOffset,
                resliceToken: scrollResliceToken,
                playbackHighlightText: activePlaybackHighlightText,
                textAnnotations: coreTextTextAnnotations,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                },
                onProgressCommit: { position in
                    pendingScrollJumpTarget = nil
                    scrollVisibleChapter = position.spineIndex
                    currentChapterIndex = position.spineIndex
                    moveReaderSession(to: position, source: .scrollCommit)
                    let pct = epubRenderer.engine?.totalProgress(forSpine: position.spineIndex, charOffset: position.charOffset) ?? 0
                    store.updatePosition(bookId: bookId, position: pct)
                },
                onInternalLinkTap: { href in
                    if let target = ReaderHTMLUtilities.reviewTarget(fromHref: href) {
                        reviewTarget = target
                        return
                    }
                    Task {
                        guard let targetPage = await epubRenderer.resolveInternalLink(href, fromSpineIndex: currentChapterIndex),
                              let pagedEngine = epubRenderer.engine else { return }
                        let (spine, charOffset) = pagedEngine.charOffset(forPage: targetPage)
                        await MainActor.run {
                            let position = CoreTextReadingPosition(spineIndex: spine, charOffset: charOffset)
                            moveReaderSession(
                                to: position,
                                source: .internalLink,
                                pageIndex: targetPage,
                                totalPages: pagedEngine.totalPages
                            )
                            currentChapterIndex = spine
                            scrollVisibleChapter = spine
                            pendingScrollJumpTarget = position
                            scrollResliceToken &+= 1
                        }
                    }
                },
                onChapterContentRequired: { chapterIndex in
                    ensureChapterReady(chapterIndex: chapterIndex)
                }
            )
            .background(readerTheme.backgroundColor)
            .ignoresSafeArea()
            .modifier(ScrollConfigObserver(readerConfig: readerConfig, readerTheme: readerTheme) { scheduleScrollReslice() })
        } else {
            legacyScrollBody
        }
    }

    private func scheduleScrollReslice() {
        guard let engine = epubRenderer.scrollEngine else { return }
        engine.updateRenderSettings(buildRenderSettings())
        scrollResliceToken &+= 1
    }

    /// Scroll mode starting position priority:
    /// 1) Paged engine ready → use current page's (spine, charOffset) (same-session switch)
    /// 2) Persisted snapshot (mode == .scroll) → restore from last exit position (cold start)
    /// 3) Fallback to currentChapterIndex / 0
    private func computeScrollInitialPosition() -> (chapter: Int, charOffset: Int) {
        if let position = readerSessionCoordinator?.state.location.coreTextPosition {
            return (position.spineIndex, position.charOffset)
        }
        if let target = pendingScrollJumpTarget {
            return (target.spineIndex, target.charOffset)
        }
        return (max(0, currentChapterIndex), 0)
    }

    private func buildRenderSettings() -> ReaderRenderSettings {
        let topInset = ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
        let bottomInset = ReaderLayoutMetrics.bottomInset(
            safeBottom: 0,
            footerBottomPadding: readerConfig.footerBottomPadding,
            footerTextGap: readerConfig.footerTextGap
        )
        return ReaderRenderSettings(
            theme: readerTheme.rawValue,
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor,
            fontSize: readerConfig.fontSize,
            lineHeightMultiple: readerConfig.lineHeightMultiple,
            lineSpacing: readerConfig.lineSpacing,
            paragraphSpacing: readerConfig.paragraphSpacing,
            letterSpacing: readerConfig.letterSpacing,
            marginH: effectivePageMarginH,
            marginV: readerConfig.pageMarginV,
            footerHeight: ReaderLayoutMetrics.footerHeight,
            contentInsets: UIEdgeInsets(
                top: topInset,
                left: effectivePageMarginH,
                bottom: bottomInset,
                right: effectivePageMarginH
            ),
            writingMode: effectiveWritingMode
        )
    }

    private var effectiveWritingMode: ReaderWritingMode {
        guard isVerticalEPUB || book?.allowsVerticalWritingMode == true else {
            return .horizontal
        }
        return isVerticalEPUB ? .verticalRTL : settings.readerWritingMode
    }

    private var effectiveScrollMode: Bool {
        settings.scrollMode
    }

    private var scrollAxis: CoreTextScrollAxis {
        effectiveWritingMode.isVertical ? .horizontalRTL : .vertical
    }

    private var legacyScrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { ci, chapter in
                        Text(chapter.title.converted(to: settings.textConversion))
                            .font(.system(size: fontSize + 8, weight: .bold, design: .serif))
                            .foregroundColor(readerTheme.textColor)
                            .padding(.top, 80)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)
                            .id("chapter_\(ci)")
                            .onAppear { scrollVisibleChapter = ci }

                        if chapter.content.isEmpty && book?.isOnline == true {
                            VStack(spacing: 16) {
                                ProgressView()
                                Text(localized("載入章節中…"))
                                    .font(.system(size: fontSize - 2, design: .serif))
                                    .foregroundColor(readerTheme.textColor.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .onAppear { ensureChapterReady(chapterIndex: ci) }
                        } else {
                            let cleaned = chapter.content
                            let paragraphs = cleaned.converted(to: settings.textConversion)
                                .components(separatedBy: "\n").filter { !$0.isEmpty }
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                                Text(para)
                                    .font(.system(size: fontSize, design: .serif))
                                    .foregroundColor(readerTheme.textColor)
                                    .kerning(readerConfig.letterSpacing)
                                    .lineSpacing(readerConfig.lineSpacing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, readerConfig.paragraphSpacing)
                            }
                            Color.clear.frame(height: max(0, 48 - readerConfig.paragraphSpacing)).clipped()
                        }

                        Divider()
                            .padding(.horizontal, 24)
                            .opacity(0.25)
                    }
                    Color.clear.frame(height: 80)
                }
            }
            .onAppear {
                if scrollVisibleChapter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("chapter_\(scrollVisibleChapter)", anchor: .top)
                    }
                }
            }
        }
        .background(readerTheme.backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
        }
    }

    private func goToPrevPage() {
        guard currentPage > 0 else { return }
        let targetPage = previousReaderPage(before: currentPage)
        switch effectivePageTurnStyle {
        case .none:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { currentPage = targetPage }
        case .slide:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage = targetPage
            }
        case .cover, .curl:
            currentPage = targetPage
        }
    }

    private func goToNextPage() {
        let maxPage: Int
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            maxPage = engine.totalPages - 1
        } else {
            maxPage = allPages.count - 1
        }
        guard currentPage < maxPage else { return }
        let targetPage = nextReaderPage(after: currentPage, maxPage: maxPage)
        switch effectivePageTurnStyle {
        case .none:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { currentPage = targetPage }
        case .slide:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage = targetPage
            }
        case .cover, .curl:
            currentPage = targetPage
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        ReaderTopBar(
            theme: readerTheme,
            chapterTitle: currentChapterTitle.converted(to: settings.textConversion),
            isBookmarked: isCurrentPageBookmarked,
            overlayMaxWidth: overlayContentMaxWidth,
            onBack: {
                saveProgress()
                presentationMode.wrappedValue.dismiss()
            },
            onToggleBookmark: {
                guard let position = currentTopBarBookmarkPosition else { return }
                withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                    store.toggleBookmark(
                        bookId: bookId,
                        chapterIndex: position.spineIndex,
                        chapterTitle: bookmarkChapterTitle(for: position.spineIndex),
                        position: position,
                        excerpt: currentPageExcerpt
                    )
                }
            }
        )
    }

    // MARK: - Bottom Bar
    private var bottomBar: some View {
        ReaderBottomControlBar(
            readerTheme: Binding(
                get: { readerTheme },
                set: { readerTheme = $0 }
            ),
            overlayContentMaxWidth: overlayContentMaxWidth,
            showRefreshButton: !(book?.onlineChapters?.isEmpty ?? true),
            showChangeSourceButton: book?.isOnline == true && book?.bookSourceId != nil,
            showDownloadButton: book?.isOnline == true,
            downloadButtonIcon: downloadButtonIcon,
            canGoPrevChapter: canGoPrevChapter,
            canGoNextChapter: canGoNextChapter,
            chapterPageInfo: chapterPageInfo,
            totalProgressPercent: totalProgressPercent,
            chapterSliderProgressValue: { chapterSliderProgressValue() },
            applyChapterSliderProgress: { applyChapterSliderProgress($0) },
            chapterTitleForProgress: { chapterTitle(forProgress: $0) },
            onPrevChapter: { jumpToChapter(currentChapterIndex - 1) },
            onNextChapter: { jumpToChapter(currentChapterIndex + 1) },
            onRefresh: { refreshCurrentChapter() },
            onOpenChangeSource: { showChangeSourceSheet = true },
            onDownloadAction: { handleDownloadAction() },
            onOpenTTS: { openPlaybackPanel() },
            onOpenTOC: { showTOC = true },
            onOpenBookmarks: { showBookmarks = true },
            onOpenSettings: { showSettings = true }
        )
    }

    private func shouldShowDownloadProgress(for book: ReadingBook) -> Bool {
        guard book.isOnline, book.offlineDownloadTask != nil else { return false }
        switch book.offlineDownloadState {
        case .downloading, .failed:
            return true
        case .none, .available:
            return false
        }
    }

    private func downloadProgressOverlay(for book: ReadingBook) -> some View {
        GeometryReader { proxy in
            ReaderDownloadProgressPanel(
                book: book,
                readerTheme: readerTheme,
                onResume: { resumeOfflineDownload(for: book) }
            )
            .frame(width: downloadProgressPanelWidth(in: proxy.size), height: 64)
            .position(downloadProgressPanelPosition(in: proxy.size))
        }
        .allowsHitTesting(true)
        .ignoresSafeArea(.keyboard)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func downloadProgressPanelWidth(in size: CGSize) -> CGFloat {
        min(max(size.width - 52, 148), 340)
    }

    private func downloadProgressPanelPosition(in size: CGSize) -> CGPoint {
        let width = downloadProgressPanelWidth(in: size)
        let height: CGFloat = 64
        return CGPoint(
            x: width / 2 + 26,
            y: size.height - 136 - height / 2
        )
    }

    private func ttsJumpPromptView(alignment: Alignment) -> some View {
        HStack(spacing: 8) {
            Button {
                jumpBackToTTSChapter()
            } label: {
                Label(localized("原進度"), systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 18)
                .overlay(Color.white.opacity(0.18))

            Button {
                startTTSFromPromptChapter()
            } label: {
                Label(localized("從本章開始聽"), systemImage: "headphones")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.48), in: Capsule())
        .frame(maxWidth: 520, alignment: alignment)
        .accessibilityLabel(ttsJumpPromptMessage)
    }

    private var ttsJumpPromptCollapsedBottomPadding: CGFloat {
        let footerBandBottomFromBottom = max(
            0,
            readerConfig.footerBottomPadding
        )
        let footerBandCenterFromBottom = footerBandBottomFromBottom
            + ReaderLayoutMetrics.footerHeight / 2
        let estimatedPromptHeight: CGFloat = 36
        return max(8, footerBandCenterFromBottom - estimatedPromptHeight / 2)
    }

    private var ttsJumpPromptMessage: String {
        guard let ttsChapterIndex, chapters.indices.contains(ttsChapterIndex) else {
            return localized("你已移到其他章節，可以選擇回到正在朗讀的位置，或從目前章節重新開始。")
        }
        return String(
            format: localized("聽書仍在「%@」，可以選擇回去，或改從目前章節開始。"),
            chapters[ttsChapterIndex].title
        )
    }

    // MARK: - Source Change Sheet
    private var changeSourceSheetContent: AnyView {
        AnyView(NavigationStack {
            List {
                // 目前使用中的書源 — always visible with a checkmark so the user knows
                // which source is active (search results below exclude this one).
                Section(localized("目前書源")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentSourceName)
                                .foregroundColor(.primary)
                            if let last = book?.onlineChapters?.last?.title, !last.isEmpty {
                                Text(last)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                }

                // 其他可切換的書源。Results stream in one source at a time, so show them
                // as soon as the first match arrives instead of blocking on the full
                // fan-out (459 sources can take minutes).
                Section {
                    if !changeSourceOrigins.isEmpty {
                        ForEach(changeSourceOrigins) { origin in
                            Button { switchToOrigin(origin) } label: { changeSourceRow(origin) }
                        }
                        if changeSourceLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(localized("正在搜尋更多書源…"))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if changeSourceLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(localized("正在搜尋其他書源…"))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(localized("暫無其他書源"))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(localized("其他書源"))
                } footer: {
                    if let err = changeSourceError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(localized("換源"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        loadOtherOrigins(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(changeSourceLoading)
                    .accessibilityLabel(localized("重新搜尋"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("關閉")) { showChangeSourceSheet = false }
                }
            }
        })
    }

    /// A single switchable-origin row; flags origins that previously failed to switch.
    @ViewBuilder
    private func changeSourceRow(_ origin: BookOrigin) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(origin.sourceName)
                    .foregroundColor(.primary)
                // Aggregation sources share one sourceName across channels;
                // lastChapter distinguishes them.
                if !origin.lastChapter.isEmpty {
                    Text(origin.lastChapter)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if changeSourceFailedKeys.contains(ChangeSourceCache.urlKey(origin.bookUrl)) {
                Text(localized("載入失敗"))
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Switches the book to the chosen origin. On success dismisses the sheet and
    /// reloads; on failure flags the origin (persisted) and keeps the sheet open so
    /// the user can try another. (Reading position handling unchanged.)
    private func switchToOrigin(_ origin: BookOrigin) {
        Task {
            do {
                try await store.updateOnlineBookSource(bookId: bookId, origin: origin)
                await MainActor.run {
                    showChangeSourceSheet = false
                    loadContent()
                }
            } catch {
                await MainActor.run {
                    readerViewModel.markOriginFailed(bookId: bookId, bookUrl: origin.bookUrl)
                    readerViewModel.reportChangeSourceError(error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private func circleBtn(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(readerTheme.textColor.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(Color.clear)
                .clipShape(Circle())
                .overlay(Circle().stroke(readerTheme.textColor.opacity(0.3), lineWidth: 1))
        }
    }

    /// Looks up the chapter title for a given progress value (0–1), used for the drag HUD.
    private func chapterTitle(forProgress value: Double) -> String {
        let totalChapters = book?.onlineChapters?.count ?? chapters.count
        if book?.isOnline == true && totalChapters > 0 {
            let targetIndex = max(0, min(Int(round(value * Double(totalChapters - 1))), totalChapters - 1))
            if let refs = book?.onlineChapters, refs.indices.contains(targetIndex) {
                return refs[targetIndex].title
            }
            return chapters.indices.contains(targetIndex) ? chapters[targetIndex].title : ""
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let pos = engine.position(forProgress: value)
            if let chapter = tocChapter(forSpineIndex: pos.spineIndex, charOffset: pos.charOffset) {
                return chapter.title
            }
        }
        guard allPages.count > 1 else { return chapters.first?.title ?? "" }
        let pageIdx = max(0, min(Int(value * Double(allPages.count - 1)), allPages.count - 1))
        let chIdx = allPages[pageIdx].chapterIndex
        if chapters.indices.contains(chIdx) { return chapters[chIdx].title }
        return ""
    }

    private func chapterSliderProgressValue() -> Double {
        // Scroll mode: approximate using chapter index (chunks may not be fully loaded, no reliable character count).
        if effectiveScrollMode {
            let total = max(chapters.count - 1, 1)
            return Double(min(scrollVisibleChapter, total)) / Double(total)
        }
        let totalChapters = book?.onlineChapters?.count ?? chapters.count
        guard totalChapters > 1 else { return 0 }
        if book?.isOnline == true {
            return Double(currentChapterIndex) / Double(totalChapters - 1)
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let pos = engine.charOffset(forPage: currentPage)
            return engine.totalProgress(forSpine: pos.spineIndex, charOffset: pos.charOffset)
        }
        guard allPages.count > 1 else { return 0 }
        return Double(currentPage) / Double(allPages.count - 1)
    }

    private func applyChapterSliderProgress(_ value: Double) {
        // Scroll mode: round to nearest chapter, then reslice the engine.
        if effectiveScrollMode, let scrollEngine = epubRenderer.scrollEngine {
            let total = max(chapters.count - 1, 1)
            let target = max(0, min(Int(round(value * Double(total))), total))
            scrollVisibleChapter = target
            currentChapterIndex = target
            let width = scrollEngine.contentWidth
            Task { await scrollEngine.reslice(restoreAt: target, contentWidth: width) }
            return
        }
        let totalChapters = book?.onlineChapters?.count ?? chapters.count
        if book?.isOnline == true && totalChapters > 1 {
            let targetIndex = max(0, min(Int(round(value * Double(totalChapters - 1))), totalChapters - 1))
            jumpToChapter(targetIndex)
            return
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let pos = engine.position(forProgress: value)
            jumpToChapter(pos.spineIndex, charOffset: pos.charOffset)
            return
        }
        currentPage = max(
            0,
            min(
                Int(value * Double(max(allPages.count - 1, 1))),
                max(allPages.count - 1, 0)
            )
        )
    }

    private func currentTTSReaderPosition() -> CoreTextReadingPosition? {
        if effectiveScrollMode {
            if let location = readerSessionCoordinator?.state.location.coreTextPosition {
                return location
            }
            return CoreTextReadingPosition(spineIndex: scrollVisibleChapter, charOffset: 0)
        }

        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            guard engine.totalPages > 0 else { return nil }
            let page = max(0, min(currentPage, engine.totalPages - 1))
            return engine.readingPosition(forPage: page)
                ?? CoreTextReadingPosition(
                    spineIndex: engine.charOffset(forPage: page).spineIndex,
                    charOffset: engine.charOffset(forPage: page).charOffset
                )
        }

        guard !allPages.isEmpty else {
            return chapters.indices.contains(currentChapterIndex)
                ? CoreTextReadingPosition(spineIndex: currentChapterIndex, charOffset: 0)
                : nil
        }
        let page = allPages[max(0, min(currentPage, allPages.count - 1))]
        return CoreTextReadingPosition(spineIndex: page.chapterIndex, charOffset: page.pageInChapter)
    }

    private func isReaderAtTTSAnchor(_ anchor: CoreTextReadingPosition) -> Bool {
        if effectiveScrollMode {
            return currentChapterIndex == anchor.spineIndex
        }

        if let engine = epubRenderer.engine, usesCoreTextEPUB,
           let anchorPage = engine.pageIndex(for: anchor) {
            return currentPage == anchorPage
        }

        guard let current = currentTTSReaderPosition() else { return false }
        return current == anchor
    }

    private func setActiveTTSAnchor(_ anchor: CoreTextReadingPosition, alignReader: Bool) {
        ttsPlaybackAnchor = anchor
        showTTSJumpPrompt = false
        ttsJumpPromptChapterIndex = nil
        if alignReader {
            alignReaderToTTSAnchorIfNeeded()
        }
    }

    private func alignReaderToTTSAnchorIfNeeded() {
        guard let anchor = ttsPlaybackAnchor,
              chapters.indices.contains(anchor.spineIndex),
              !isReaderAtTTSAnchor(anchor)
        else { return }

        isAligningReaderToTTSAnchor = true
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
        }
        jumpToChapter(anchor.spineIndex, charOffset: anchor.charOffset)
        DispatchQueue.main.async {
            isAligningReaderToTTSAnchor = false
        }
    }

    private func handleTTSPlayPause() {
        switch ttsCoordinator.playbackState {
        case .playing:
            ttsCoordinator.pause()
        case .paused:
            ttsCoordinator.resume()
        case .stopped:
            startTTSChapter(currentChapterIndex, syncReader: false)
        }
    }

    private func openPlaybackPanel() {
        let chapterIndex = currentChapterIndex
        if isEPUB, epubRenderer.mediaOverlaysByChapter[chapterIndex] != nil {
            activeMediaOverlayChapterIndex = chapterIndex
            showMediaOverlayPanel = true
        } else {
            showTTSPanel = true
        }
    }

    private func currentMediaOverlayHighlightText() -> String? {
        guard let chapterIndex = mediaOverlayCoordinator.currentChapterIndex,
              let fragment = mediaOverlayCoordinator.currentFragment,
              let overlay = epubRenderer.mediaOverlaysByChapter[chapterIndex],
              let layout = epubRenderer.engine?.layouts[chapterIndex],
              layout.attributedString.length > 0
        else {
            return mediaOverlayCoordinator.currentFragment?.textFragmentID
                ?? mediaOverlayCoordinator.currentFragment?.id
        }

        let anchorID = fragment.textFragmentID ?? fragment.id
        guard let start = layout.anchorOffsets[anchorID],
              start >= 0,
              start < layout.attributedString.length
        else {
            return anchorID
        }

        let nextStart = overlay.fragments
            .compactMap { next -> Int? in
                guard next.id != fragment.id else { return nil }
                let nextID = next.textFragmentID ?? next.id
                guard let offset = layout.anchorOffsets[nextID], offset > start else { return nil }
                return offset
            }
            .min()
        let end = min(nextStart ?? min(layout.attributedString.length, start + 180), layout.attributedString.length)
        guard end > start else { return anchorID }

        let text = (layout.attributedString.string as NSString)
            .substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? anchorID : text
    }

    private func setTTSFloatingOverlayVisible(_ visible: Bool) {
        Task { @MainActor in
            TTSFloatingPlayerState.shared.setReaderOverlayVisible(visible)
        }
    }

    @discardableResult
    private func startTTSChapter(_ chapterIndex: Int, syncReader: Bool) -> Bool {
        guard chapters.indices.contains(chapterIndex) else { return false }
        mediaOverlayCoordinator.stop()
        let narration = narrationForTTSChapter(chapterIndex)
        let text = narration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ttsLog("[TTS][Reader] startTTSChapter ignored empty chapter=\(chapterIndex)")
            if syncReader {
                jumpToChapter(chapterIndex)
            }
            ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
            return false
        }

        ttsChapterIndex = chapterIndex
        setActiveTTSAnchor(.chapterStart(chapterIndex), alignReader: true)
        ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
        ttsCoordinator.speak(
            text: text,
            title: chapters[chapterIndex].title,
            bookTitle: ttsNowPlayingBookTitle,
            author: ttsNowPlayingAuthor,
            artwork: ttsNowPlayingArtwork(),
            pronunciationHints: narration.pronunciationHints
        )
        ttsCoordinator.refreshNowPlayingForSystemSurfaces()
        return true
    }

    @discardableResult
    private func startAdjacentTTSChapter(delta: Int) -> Bool {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        let target = baseChapter + delta
        guard chapters.indices.contains(target) else { return false }
        return startTTSChapter(target, syncReader: true)
    }

    private func advanceTTSChapterFromEngine() -> TTSNarrationUnit? {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        let target = baseChapter + 1
        guard chapters.indices.contains(target) else {
            ttsChapterIndex = nil
            return nil
        }
        let narration = narrationForTTSChapter(target)
        let text = narration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ensureChapterReady(chapterIndex: target, priority: .jump)
            return nil
        }
        ttsChapterIndex = target
        setActiveTTSAnchor(.chapterStart(target), alignReader: true)
        ttsCoordinator.updateNowPlayingChapter(title: chapters[target].title, text: text)
        return narration
    }

    private func handleReaderPositionChangedForTTS() {
        guard !isAligningReaderToTTSAnchor else { return }
        guard ttsCoordinator.playbackState != .stopped,
              let anchor = ttsPlaybackAnchor
        else {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
            return
        }

        guard !isReaderAtTTSAnchor(anchor) else {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
            return
        }

        ttsJumpPromptChapterIndex = currentTTSReaderPosition()?.spineIndex ?? currentChapterIndex
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = true
        }
    }

    private func jumpBackToTTSChapter() {
        guard let anchor = ttsPlaybackAnchor,
              chapters.indices.contains(anchor.spineIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
        }
        alignReaderToTTSAnchorIfNeeded()
    }

    private func startTTSFromPromptChapter() {
        let target = ttsJumpPromptChapterIndex ?? currentChapterIndex
        _ = startTTSChapter(target, syncReader: false)
    }

    private func narrationForTTSChapter(_ chapterIndex: Int) -> TTSNarrationUnit {
        guard chapters.indices.contains(chapterIndex) else {
            return TTSNarrationUnit(text: "")
        }
        if let engine = epubRenderer.engine,
           usesCoreTextEPUB,
           let layout = engine.layouts[chapterIndex],
           layout.attributedString.length > 0 {
            let hints = TTSPronunciationAnnotator.hints(
                in: layout.attributedString,
                lexicons: activePublicationSession?.pronunciationLexicons ?? [],
                bookLanguage: activePublicationSession?.language
            )
            return TTSNarrationUnit(text: layout.attributedString.string, pronunciationHints: hints)
        }
        let pageText = allPages
            .filter { $0.chapterIndex == chapterIndex }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageText.isEmpty { return TTSNarrationUnit(text: pageText) }
        return TTSNarrationUnit(text: chapters[chapterIndex].content)
    }

    private func textForTTSChapter(_ chapterIndex: Int) -> String {
        narrationForTTSChapter(chapterIndex).text
    }

    // MARK: - Logic
    private func findChapterFirstPage(_ chapterIdx: Int) -> Int? {
        return allPages.firstIndex(where: { $0.chapterIndex == chapterIdx })
    }

    private func jumpToBookmark(_ bookmark: Bookmark) {
        let position = bookmark.position
        guard chapters.indices.contains(position.spineIndex) else { return }
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            currentChapterIndex = position.spineIndex
            scrollVisibleChapter = position.spineIndex
            pendingScrollJumpTarget = position
            moveReaderSession(to: position, source: .jump)
            scrollResliceToken &+= 1
            return
        }
        jumpToChapter(position.spineIndex, charOffset: position.charOffset)
    }

    /// 標註所在章節內的頁碼（1-based）；CoreText 引擎不可用時回傳 nil。
    private func inChapterPageNumber(for bookmark: Bookmark) -> Int? {
        guard usesCoreTextEPUB, let engine = epubRenderer.engine else { return nil }
        let position = bookmark.position
        if let layout = engine.layouts[position.spineIndex] {
            return layout.pageIndex(for: position.charOffset) + 1
        }
        // 章節尚未排版：用引擎相同的保守估算（~400 字/頁）。
        return max(0, position.charOffset / 400) + 1
    }

    /// 從清單刪除一筆書籤或標註；標註需同步重繪 overlay。
    private func deleteBookmarkEntry(_ bookmark: Bookmark) {
        store.removeBookmark(bookId: bookId, bookmarkId: bookmark.id)
        if bookmark.kind == .underline || bookmark.kind == .highlight {
            syncCoreTextTextAnnotations()
        }
    }

    /// Navigate to a TOC entry, honoring its in-spine anchor so sub-sections of one spine file
    /// land on their own page instead of the file's start.
    private func jumpToTOCEntry(_ chapter: BookChapter) {
        let position = tocPosition(for: chapter, engine: epubRenderer.engine)
        jumpToChapter(position.spineIndex, charOffset: position.charOffset)
    }

    private func jumpToChapter(_ idx: Int, charOffset: Int = 0) {
        guard chapters.indices.contains(idx) else { return }
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            let position = CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset)
            currentChapterIndex = idx
            scrollVisibleChapter = idx
            pendingScrollJumpTarget = position
            moveReaderSession(to: position, source: .jump)
            scrollResliceToken &+= 1
            ensureChapterReady(chapterIndex: idx, priority: .jump)
            return
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let position = CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset)
            print("[FlipTrace] ReaderView.jumpToChapter request spine=\(idx) charOffset=\(charOffset) layoutReady=\(engine.layouts[idx] != nil)")
            ensureReaderNavigator(initialPosition: position)
            setCoreTextExternalTarget(position)
            _ = engine.pageViewController(for: position)
            currentChapterIndex = idx
            if let exactPage = engine.pageIndex(for: position) {
                currentPage = exactPage
                moveReaderSession(to: position, source: .jump, pageIndex: exactPage, totalPages: engine.totalPages)
                print("[FlipTrace] ReaderView.jumpToChapter exact spine=\(idx) page=\(exactPage)")
            } else if let estimatedPage = engine.estimatedGlobalPage(for: position) {
                currentPage = estimatedPage
                moveReaderSession(
                    to: position,
                    source: .jump,
                    pageIndex: estimatedPage,
                    totalPages: engine.totalPages,
                    isEstimated: true
                )
                print("[FlipTrace] ReaderView.jumpToChapter placeholder spine=\(idx) page=\(estimatedPage)")
            } else {
                moveReaderSession(to: position, source: .jump)
            }
            epubRenderer.currentEpubPage = currentPage
            let alreadyReady = readerViewModel.chapterState(for: idx) == .ready
            ensureChapterReady(chapterIndex: idx, priority: .jump)
            if alreadyReady, isChapterContentAvailable(at: idx) {
                Task { await engine.notifyChapterDataChanged(at: idx) }
            }
            if idx > 0 { Task { await engine.preloadChapter(at: idx - 1) } }
            if idx < chapters.count - 1 { Task { await engine.preloadChapter(at: idx + 1) } }
        } else {
            currentChapterIndex = idx
            if let p = findChapterFirstPage(idx) { currentPage = p }
            moveReaderSession(to: CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset), source: .jump)
            ensureChapterReady(chapterIndex: idx, priority: .jump)
        }
    }

    private func beginReadingStatsSession() {
        guard readingStatsTracker == nil, let currentBook = book else { return }
        readingStatsTracker = ReadingStatsSessionTracker(
            bookId: currentBook.id.uuidString,
            bookTitle: currentBook.title,
            startCharacterOffset: currentReadingStatsCharacterOffset()
        )
    }

    private func updateReadingStatsPosition() {
        guard var tracker = readingStatsTracker else { return }
        tracker.updateVisibleCharacterOffset(currentReadingStatsCharacterOffset())
        readingStatsTracker = tracker
    }

    private func finishReadingStatsSession() {
        guard var tracker = readingStatsTracker else { return }
        tracker.updateVisibleCharacterOffset(currentReadingStatsCharacterOffset())
        if let session = tracker.finish() {
            ReadingStatsStore.shared.recordSession(session)
        }
        readingStatsTracker = nil
    }

    private func currentReadingStatsCharacterOffset() -> Int? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            if effectiveScrollMode, let location = readerSessionCoordinator?.state.location {
                return readingStatsCharacterOffset(
                    spineIndex: location.spineIndex,
                    charOffset: location.charOffset,
                    layouts: engine.layouts
                )
            }

            guard engine.totalPages > 0 else { return nil }
            let page = max(0, min(currentPage, engine.totalPages - 1))
            let position = engine.charOffset(forPage: page)
            return readingStatsCharacterOffset(
                spineIndex: position.spineIndex,
                charOffset: position.charOffset,
                layouts: engine.layouts
            )
        }

        guard !allPages.isEmpty else { return nil }
        let page = max(0, min(currentPage, allPages.count - 1))
        return allPages.prefix(page).reduce(0) { total, page in
            total + page.content.count
        }
    }

    private func readingStatsCharacterOffset(
        spineIndex: Int,
        charOffset: Int,
        layouts: [Int: CoreTextPaginator.ChapterLayout]
    ) -> Int {
        let previousLength = layouts.reduce(into: 0) { total, entry in
            if entry.key < spineIndex {
                total += entry.value.attributedString.length
            }
        }
        let currentLength = layouts[spineIndex]?.attributedString.length ?? max(0, charOffset)
        return previousLength + min(max(0, charOffset), currentLength)
    }

    private func autoSaveProgress() {
        guard !isRestoringPosition else { return }

        if effectiveScrollMode {
            progressTrace("autoSave scroll visibleChapter=\(scrollVisibleChapter)")
            store.updatePosition(
                bookId: bookId,
                position: Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1))
            )
            return
        }

        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let total = engine.totalPages
            guard total > 0 else { return }
            let candidatePage: Int = {
                if currentPage == 0, engine.currentPage > 0 {
                    return engine.currentPage
                }
                return currentPage
            }()
            guard let resolved = coreTextPositionIfLayoutReady(engine: engine, page: candidatePage) else {
                progressTrace("autoSave coreText skipped page=\(candidatePage) reason=layoutNotReady")
                return
            }
            let spineIndex = resolved.spineIndex
            let charOffset = resolved.charOffset
            currentChapterIndex = spineIndex
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset)
            let normalized = min(1.0, max(0.0, pct))
            progressTrace(
                "autoSave coreText page=\(candidatePage) spine=\(spineIndex) charOffset=\(charOffset) pct=\(String(format: "%.6f", normalized))"
            )
            store.updatePosition(bookId: bookId, position: normalized)
        } else if !effectiveScrollMode && !allPages.isEmpty {
            let page = allPages[min(currentPage, allPages.count - 1)]
            currentChapterIndex = page.chapterIndex
            maybeEarlyPrefetchIfNearChapterEnd()
            let progress = Double(currentPage) / Double(max(allPages.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
            progressTrace(
                "autoSave paged currentPage=\(currentPage) chapter=\(page.chapterIndex) pageInChapter=\(page.pageInChapter) pct=\(String(format: "%.6f", normalized))"
            )
            store.updatePosition(bookId: bookId, position: normalized)
        } else {
            let progress = Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
            progressTrace(
                "autoSave scroll visibleChapter=\(scrollVisibleChapter) pct=\(String(format: "%.6f", normalized))"
            )
            store.updatePosition(bookId: bookId, position: normalized)
        }
    }

    private func saveProgress() {
        let wasRestoring = isRestoringPosition
        progressTrace("saveProgress begin wasRestoring=\(wasRestoring)")
        isRestoringPosition = false
        autoSaveProgress()
        isRestoringPosition = wasRestoring
        if let navigator = readerSessionCoordinator?.navigator {
            Task {
                await navigator.flush()
            }
        }
    }

    private func refreshCurrentChapter() {
        guard let b = book, let refs = b.onlineChapters, !refs.isEmpty else { return }
        let idx = currentChapterIndex
        print("[StateDebug] refreshCurrentChapter ch=\(idx) ← clearing ENTIRE book cache and restarting fetch")
        // Clear all cached chapters for the entire book since the "next chapter misdetected as next page"
        // bug contaminates subsequent chapters into the current chapter's cache. Clearing just the current
        // chapter is insufficient; the whole book must be purged.
        dependencies.bookSourceFetcher.clearAllChapterCache(bookId: b.id)
        store.clearAllCachedChapterFilenames(bookId: b.id)
        for ref in refs {
            readerViewModel.resetChapterState(for: ref.index)
        }
        // Immediately invalidate the current chapter's layout and show loading UI
        // so the user doesn't continue seeing the old (concatenated) content while the refetch completes.
        if let engine = epubRenderer.engine {
            Task { await engine.notifyChapterDataChanged(at: idx) }
        }
        ensureChapterReady(chapterIndex: idx, priority: .jump)
    }

    private var downloadButtonIcon: String {
        guard let b = book else { return "icloud.and.arrow.down" }
        switch b.offlineDownloadState {
        case .none, .failed:
            return "icloud.and.arrow.down"
        case .downloading:
            return "arrow.down.circle"
        case .available:
            return "checkmark.icloud"
        }
    }

    private func handleDownloadAction() {
        guard let b = book, b.isOnline else { return }
        if b.offlineDownloadState == .available {
            store.clearOnlineDownload(bookId: b.id)
            return
        }
        if b.offlineDownloadState == .downloading {
            return
        }
        showDownloadOptions = true
    }

    private func startOfflineDownload(startChapterIndex: Int, chapterCount: Int) {
        guard let b = book, b.isOnline else { return }
        readerViewModel.handleDownloadAction(
            book: b,
            store: store,
            startChapterIndex: startChapterIndex,
            chapterCount: chapterCount
        )
    }

    private func resumeOfflineDownload(for book: ReadingBook) {
        guard let task = book.offlineDownloadTask?.clamped(to: book.onlineChapters?.count ?? 0) else {
            showDownloadOptions = true
            return
        }
        readerViewModel.handleDownloadAction(
            book: book,
            store: store,
            startChapterIndex: task.startChapterIndex,
            chapterCount: task.totalChapterCount
        )
    }

    /// Source change search has been moved to ReaderViewModel.loadOtherOrigins. This method only triggers it and passes required data.
    private func loadOtherOrigins(forceRefresh: Bool = false) {
        guard let b = book, let currentSourceId = b.bookSourceId else { return }
        readerViewModel.loadOtherOrigins(
            book: b,
            currentSourceId: currentSourceId,
            enabledSources: BookSourceStore.shared.enabledSources,
            store: store,
            forceRefresh: forceRefresh
        )
    }

    /// Display name of the source the book is currently being read from.
    private var currentSourceName: String {
        guard let id = book?.bookSourceId,
              let source = BookSourceStore.shared.sources.first(where: { $0.id == id }),
              !source.bookSourceName.isEmpty else { return localized("未知書源") }
        return source.bookSourceName
    }

    // MARK: - Online Chapter Lazy Loading
    private func ensureChapterReady(
        chapterIndex: Int,
        priority: ChapterFetchPriority = .immediate
    ) {
        guard let currentBook = book else { return }
        print("[StateDebug] ensureChapterReady ch=\(chapterIndex) priority=\(priority) currentCh=\(currentChapterIndex)")
        Task { @MainActor in
            await readerViewModel.ensureChapterReady(
                book: currentBook,
                chapterIndex: chapterIndex,
                priority: priority,
                store: store
            )
        }
    }

    private func handleChapterStateChanges(_ states: [Int: ChapterLoadState]) {
        let previousStates = observedChapterStates
        observedChapterStates = states

        for (chapterIndex, newState) in states where previousStates[chapterIndex] != newState {
            print("[StateDebug] chapterStates[\(chapterIndex)] \(String(describing: previousStates[chapterIndex])) → \(newState) currentChapter=\(currentChapterIndex) usesCoreText=\(usesCoreTextEPUB) isCoreTextReady=\(epubRenderer.isCoreTextReady)")
            if newState == .ready {
                prefetchAdjacentChapters(around: chapterIndex)
            }
            applyChapterRefreshAction(for: chapterIndex, newState: newState)
        }
    }

    private func applyChapterRefreshAction(for chapterIndex: Int, newState: ChapterLoadState) {
        let contentAvailable = isChapterContentAvailable(at: chapterIndex)
        if effectiveScrollMode, let scrollEngine = epubRenderer.scrollEngine {
            if newState == .ready, contentAvailable {
                Task { await scrollEngine.retryChapterIfNeeded(chapterIndex) }
                return
            }
            if chapterIndex == currentChapterIndex,
               newState == .ready,
               !contentAvailable {
                print("[StateDebug] scroll resetAndRefetchChapter ch=\(chapterIndex)")
                refreshCurrentChapter()
                return
            }
        }
        let action = ReaderChapterPresentation.refreshAction(
            changedChapterIndex: chapterIndex,
            currentChapterIndex: currentChapterIndex,
            usesCoreText: usesCoreTextEPUB,
            newState: newState,
            isContentAvailable: contentAvailable
        )
        print("[StateDebug] applyRefreshAction ch=\(chapterIndex) newState=\(newState) contentAvailable=\(contentAvailable) currentCh=\(currentChapterIndex) → action=\(action)")

        switch action {
        case .none:
            break
        case .notifyChapterDataChanged(let visibleChapterIndex):
            guard let engine = epubRenderer.engine else {
                print("[StateDebug] notifyChapterDataChanged SKIPPED: engine is nil")
                return
            }
            print("[StateDebug] notifyChapterDataChanged ch=\(visibleChapterIndex) launching Task")
            Task {
                await engine.notifyChapterDataChanged(at: visibleChapterIndex)
                if self.savedCoreTextRestoreTarget != nil {
                    self.applyInitialProgressIfNeeded()
                }
            }
        case .rebuildPages:
            print("[StateDebug] rebuildPages()")
            rebuildPages()
        case .resetAndRefetchChapter:
            print("[StateDebug] resetAndRefetchChapter ch=\(chapterIndex) ← will clear cache and re-fetch")
            refreshCurrentChapter()
        }
    }

    private func prefetchAdjacentChapters(around chapterIndex: Int) {
        guard let b = book, b.isOnline else { return }
        readerViewModel.prefetchAround(book: b, center: chapterIndex, store: store)
    }

    /// When the user scrolls past the last 25% of the current chapter, trigger next chapter prefetch early.
    /// This provides more buffer time compared to waiting until the last page.
    private func maybeEarlyPrefetchIfNearChapterEnd() {
        guard let b = book, b.isOnline,
              let refs = b.onlineChapters else { return }
        let chIdx = currentChapterIndex
        let nextIdx = chIdx + 1
        guard refs.indices.contains(nextIdx) else { return }

        // Skip if the next chapter is already cached.
        guard !dependencies.bookSourceFetcher.isChapterCached(
            bookId: b.id, chapterIndex: nextIdx,
            expectedSourceURL: nil, expectedTOCTitle: nil) else { return }

        // Check if we're past 75% of the current chapter's pages.
        let pagesInChapter = allPages.filter { $0.chapterIndex == chIdx }
        guard !pagesInChapter.isEmpty else { return }
        let currentPageInChapter = allPages.indices.contains(currentPage)
            ? allPages[currentPage].pageInChapter : 0
        guard currentPageInChapter >= (pagesInChapter.count * 3) / 4 else { return }

        readerViewModel.prefetchAround(book: b, center: chIdx, store: store)
    }

    // MARK: - Loading & Page Building
    private func currentRenderSettings(marginH: CGFloat) -> ReaderRenderSettings {
        let topInset = ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
        let bottomInset = ReaderLayoutMetrics.bottomInset(
            safeBottom: 0,
            footerBottomPadding: readerConfig.footerBottomPadding,
            footerTextGap: readerConfig.footerTextGap
        )
        let lineHeightMultiple = max(1.0, readerConfig.lineHeightMultiple)
        return ReaderRenderSettings(
            theme: readerTheme.epubJSName,
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: readerConfig.lineSpacing,
            paragraphSpacing: readerConfig.paragraphSpacing,
            letterSpacing: readerConfig.letterSpacing,
            marginH: marginH,
            marginV: systemVerticalPadding,
            footerHeight: footerOverlayHeight,
            contentInsets: UIEdgeInsets(top: topInset, left: marginH, bottom: bottomInset, right: marginH),
            writingMode: effectiveWritingMode
        )
    }

    private func applyPublicationSession(
        _ session: PublicationSession,
        book: ReadingBook,
        settings: ReaderRenderSettings
    ) {
        let document = BookDocumentFactory.makeEPUBDocument(book: book, session: session)
        applyDocument(document)

        // Start any authored background soundtrack for the chapter we're opening on.
        activePublicationSession = session
        Task { await backgroundAudioCoordinator.update(session: session, chapterIndex: currentChapterIndex) }

        // Prefer EPUB toc.ncx / nav.xhtml entries. Only fall back to spine when TOC is missing.
        if !session.tocEntries.isEmpty {
            chapters = ReaderTOCChapterMapper.chapters(from: session.tocEntries, session: session)
        } else {
            // Fallback: spine-only
            chapters = session.chapters.map { chapter in
                BookChapter(
                    index: chapter.index,
                    title: chapter.title,
                    content: "",
                    href: chapter.href,
                    level: 0
                )
            }
        }
        if chapters.isEmpty {
            chapters = [BookChapter(index: 0, title: session.bookTitle, content: "")]
        }
        allPages = [
            PageContent(
                chapterIndex: 0,
                chapterTitle: session.bookTitle,
                content: "",
                pageInChapter: 0
            )
        ]

        epubRenderer.load(
            publicationSession: session,
            bookIdentifier: session.sourceURL.standardizedFileURL.path,
            renderSize: session.layoutMode == .prePaginated ? readerViewportSize : currentReaderRenderSize,
            settings: settings
        )
        updateFixedLayoutOrientationPreference()

        currentPage = 0
        isLoadingPipeline = false
        isRestoringPosition = false
    }

    private func loadLocalEPUB(_ book: ReadingBook, marginH: CGFloat) {
        Task {
            do {
                let session = try await EPUBBookService.shared.openSession(for: book, using: store)
                await MainActor.run {
                    guard self.book?.id == book.id else { return }
                    if session.epubWritingMode == .verticalRL {
                        self.isVerticalEPUB = true
                    }
                    let settings = self.currentRenderSettings(marginH: marginH)
                    self.applyPublicationSession(session, book: book, settings: settings)
                }
            } catch {
                await MainActor.run {
                    print("Readium parsing failed: \(error)")
                    self.applyDocument(nil)
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                }
            }
        }
    }

    private func loadOnlineCoreText(_ book: ReadingBook, marginH: CGFloat) {
        print("[StateDebug] loadOnlineCoreText enter bookId=\(book.id) chapters=\(book.onlineChapters?.count ?? -1)")
        print("[FetchTrace] loadOnlineCoreText enter bookId=\(book.id) chapters=\(book.onlineChapters?.count ?? -1)")
        guard let document = BookDocumentFactory.makeOnlineDocument(book: book, store: store) else {
            print("[FetchTrace] loadOnlineCoreText makeOnlineDocument returned nil")
            applyDocument(nil)
            isLoadingPipeline = false
            isRestoringPosition = false
            return
        }

        applyDocument(document)

        let refs = book.onlineChapters ?? []
        chapters = refs.enumerated().map { idx, ref in
            let href = RuleEngine.sanitizeExtractedURL(ref.url)
            return BookChapter(index: idx, title: ref.title, content: "", href: href)
        }
        if chapters.isEmpty {
            chapters = [BookChapter(index: 0, title: book.title, content: "")]
        }
        allPages = []

        let settings = currentRenderSettings(marginH: marginH)
        guard !refs.isEmpty else {
            applyDocument(nil)
            isLoadingPipeline = false
            isRestoringPosition = false
            return
        }
        let builder = OnlineNodeAttributedStringBuilder(
            refs: refs,
            bookId: book.id,
            fetcher: dependencies.bookSourceFetcher
        )
        epubRenderer.loadTXT(
            attributedBuilder: builder,
            bookIdentifier: "coretext-node-\(book.id.uuidString)",
            renderSize: currentReaderRenderSize,
            settings: settings
        )

        currentPage = 0
        isLoadingPipeline = false
        isRestoringPosition = false

        // Lazy loading: auto-fetch the initial chapter (saved position or chapter 0).
        let initialChapter = OnlineInitialChapterResolver.preferredInitialChapter(
            chapterCount: refs.count,
            savedPositionSnapshot: 0,
            restoreTargetChapter: savedCoreTextRestoreTarget?.chapterIndex
        )
        currentChapterIndex = initialChapter
        ensureChapterReady(chapterIndex: initialChapter)
        if initialChapter != 0 {
            ensureChapterReady(chapterIndex: 0)
        }
    }

    private func loadContent() {
        guard !isLoadingPipeline else { return }
        isLoadingPipeline = true
        isRestoringPosition = true
        refreshInitialRestoreState()

        let marginH = effectivePageMarginH
        guard let b = book else {
            applyDocument(nil)
            isRestoringPosition = false
            isLoadingPipeline = false
            return
        }

        if b.isOnline {
            loadOnlineCoreText(b, marginH: marginH)
            return
        }
        
        if b.resolvedPipelineKind == .txt {
            let bookTitle = b.title
            let settings = currentRenderSettings(marginH: marginH)
            let targetBook = b

            DispatchQueue.global(qos: .userInitiated).async {
                let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let txtURL = docsURL.appendingPathComponent(targetBook.contentFilename)
                let lowercasedFilename = targetBook.contentFilename.lowercased()
                let isMarkdownFile = lowercasedFilename.hasSuffix(".md")
                    || lowercasedFilename.hasSuffix(".markdown")

                if isMarkdownFile {
                    let markdownText: String
                    do {
                        markdownText = try TXTFileReader.readTextFile(url: txtURL)
                    } catch {
                        Task { @MainActor in
                            guard self.book?.id == targetBook.id else { return }
                            self.applyDocument(nil)
                            self.isLoadingPipeline = false
                            self.isRestoringPosition = false
                        }
                        return
                    }

                    let markdownBuilder = MarkdownAttributedStringBuilder(
                        markdown: markdownText,
                        fallbackTitle: bookTitle
                    )
                    let markdownChapters = markdownBuilder.unifiedChapters

                    Task { @MainActor in
                        guard self.book?.id == targetBook.id else {
                            self.isLoadingPipeline = false
                            self.isRestoringPosition = false
                            return
                        }

                        let document = BookDocumentFactory.makeTXTDocument(
                            book: targetBook,
                            chapters: markdownChapters
                        )
                        self.applyDocument(document)

                        self.epubRenderer.loadTXT(
                            attributedBuilder: markdownBuilder,
                            bookIdentifier: targetBook.id.uuidString,
                            renderSize: self.currentReaderRenderSize,
                            settings: settings
                        )

                        if document.tableOfContents.count > 0 {
                            self.chapters = document.tableOfContents.enumerated().map { i, chapter in
                                BookChapter(index: i, title: chapter.title, content: "")
                            }
                        } else {
                            self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
                        }

                        self.allPages = []
                        if self.savedCoreTextRestoreTarget == nil {
                            self.currentPage = 0
                        }
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                    }
                    return
                }

                let mappedTextFile: TXTMappedTextFile
                do {
                    mappedTextFile = try TXTFileReader.readMappedTextFile(url: txtURL)
                } catch {
                    Task { @MainActor in
                        guard self.book?.id == targetBook.id else { return }
                        self.applyDocument(nil)
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                    }
                    return
                }

                let bookId = targetBook.id
                let fingerprint = TXTFileReader.fileFingerprint(data: mappedTextFile.data)
                let fileSize = mappedTextFile.byteCount
                let encoding = mappedTextFile.encoding

                let mappedChapterIndexes: [TXTMappedChapterIndex]
                if let cached = TXTChapterParser.loadCachedIndexes(bookId: bookId, fileSize: fileSize, fingerprint: fingerprint, encoding: encoding) {
                    mappedChapterIndexes = cached
                } else {
                    let fresh = TXTChapterParser.parseMappedChapterIndexes(mappedTextFile, bookTitle: bookTitle)
                    TXTChapterParser.saveCachedIndexes(fresh, bookId: bookId, fileSize: fileSize, fingerprint: fingerprint, encoding: encoding)
                    mappedChapterIndexes = fresh
                }
                let lazyBuilder = TXTLazyAttributedStringBuilder(
                    mappedTextFile: mappedTextFile,
                    chapterIndexes: mappedChapterIndexes
                )

                Task { @MainActor in
                    guard self.book?.id == targetBook.id else {
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                        return
                    }

                    let document = BookDocumentFactory.makeTXTDocument(
                        book: targetBook,
                        mappedChapterIndexes: mappedChapterIndexes,
                        mappedTextFile: mappedTextFile
                    )
                    self.applyDocument(document)

                    self.epubRenderer.loadTXT(
                        attributedBuilder: lazyBuilder,
                        bookIdentifier: targetBook.id.uuidString,
                        renderSize: self.currentReaderRenderSize,
                        settings: settings
                    )

                    if document.tableOfContents.count > 0 {
                        self.chapters = document.tableOfContents.enumerated().map { i, chapter in
                            BookChapter(index: i, title: chapter.title, content: "")
                        }
                    } else {
                        self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
                    }

                    self.allPages = []
                    if self.savedCoreTextRestoreTarget == nil {
                        self.currentPage = 0
                    }
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                }
            }
            return
        }

        guard b.resolvedPipelineKind == .epub else {
            applyDocument(nil)
            isLoadingPipeline = false
            isRestoringPosition = false
            return
        }
        let bookTitle = b.title
        self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
        self.allPages = [PageContent(chapterIndex: 0, chapterTitle: bookTitle, content: "", pageInChapter: 0)]
        self.currentPage = 0
        loadLocalEPUB(b, marginH: marginH)
    }

    private func rebuildPages() {
        isLoadingPipeline = false
        loadContent()
    }

    private func applyDocument(_ document: (any BookDocument)?) {
        bookDocument = document
        if let document {
            contentProvider = BookDocumentContentProviderAdapter(document: document)
            readerCapabilities = document.capabilities
        } else {
            contentProvider = nil
            readerCapabilities = .reflowableText
        }
    }

    private func handleReaderConfigRefresh(_ kind: ReaderConfigRefreshKind) {
        switch kind {
        case .layout:
            performUnifiedRelayout()
        case .appearance:
            applyUnifiedAppearanceUpdate()
        }
    }

    private func performUnifiedRelayout(targetSize: CGSize? = nil) {
        guard let engine = epubRenderer.engine else {
            rebuildPages()
            return
        }
        let size = targetSize ?? engine.renderSize
        let newSettings = currentRenderSettings(marginH: effectivePageMarginH)
        if targetSize != nil,
           abs(size.width - engine.renderSize.width) < 0.5,
           abs(size.height - engine.renderSize.height) < 0.5 {
            print("[FlipTrace] performUnifiedRelayout skip sameSize size=\(size)")
            return
        }
        if let coreEngine = engine as? CoreTextPageEngine,
           targetSize == nil,
           newSettings == coreEngine.renderSettings {
            print("[FlipTrace] performUnifiedRelayout skip sameSettings size=\(size)")
            return
        }
        epubRenderer.updateRenderSettings(newSettings)
        Task { await engine.invalidateLayout(newSize: size) }
    }

    private func applyUnifiedAppearanceUpdate() {
        guard let engine = epubRenderer.engine else { return }
        epubRenderer.updateRenderSettings(currentRenderSettings(marginH: effectivePageMarginH))
        engine.applyThemeChange(
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor
        )
    }
}

private enum ReaderDownloadStartOption: String, CaseIterable, Identifiable {
    case currentChapter
    case firstChapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentChapter:
            return localized("從當前章開始")
        case .firstChapter:
            return localized("從第一章開始")
        }
    }
}

private struct ReaderDownloadOptionsView: View {
    let bookTitle: String
    let currentChapterIndex: Int
    let totalChapters: Int
    let onStart: (Int, Int) -> Void
    let onCancel: () -> Void

    @State private var startOption: ReaderDownloadStartOption = .currentChapter
    @State private var chapterCount: Double
    @State private var chapterCountText: String

    init(
        bookTitle: String,
        currentChapterIndex: Int,
        totalChapters: Int,
        onStart: @escaping (Int, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.bookTitle = bookTitle
        self.currentChapterIndex = max(0, currentChapterIndex)
        self.totalChapters = max(0, totalChapters)
        self.onStart = onStart
        self.onCancel = onCancel

        let safeTotal = max(1, totalChapters)
        let safeCurrent = min(max(0, currentChapterIndex), safeTotal - 1)
        let defaultCount = min(50, max(1, safeTotal - safeCurrent))
        _chapterCount = State(initialValue: Double(defaultCount))
        _chapterCountText = State(initialValue: "\(defaultCount)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(bookTitle)
                            .font(DSFont.headline)
                            .lineLimit(2)
                        Text(summaryText)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    .padding(.vertical, DSSpacing.xs)
                }

                Section(header: Text(localized("下載範圍"))) {
                    Picker(localized("開始位置"), selection: $startOption) {
                        ForEach(ReaderDownloadStartOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: startOption) { _, _ in
                        clampChapterCountToCurrentMaximum()
                    }

                    HStack {
                        Text(localized("開始章節"))
                        Spacer()
                        Text(String(format: localized("第 %d 章"), selectedStartIndex + 1))
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                Section(header: Text(localized("章數"))) {
                    Slider(
                        value: Binding(
                            get: { chapterCount },
                            set: { updateChapterCount(Int($0.rounded())) }
                        ),
                        in: 1...Double(maxSelectableCount),
                        step: 1
                    )

                    HStack {
                        Text(localized("手動輸入"))
                        Spacer()
                        TextField(localized("章數"), text: $chapterCountText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                            .onChange(of: chapterCountText) { _, newValue in
                                updateChapterCountText(newValue)
                            }
                    }

                    Text(String(format: localized("最多可下載 %d 章"), maxSelectableCount))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }

                if totalChapters <= 0 {
                    Section {
                        Label(localized("沒有可下載章節"), systemImage: "exclamationmark.triangle")
                            .foregroundColor(DSColor.textSecondary)
                    }
                }
            }
            .navigationTitle(localized("下載章節"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onStart(selectedStartIndex, Int(chapterCount.rounded()))
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(totalChapters <= 0)
                }
            }
        }
    }

    private var selectedStartIndex: Int {
        guard totalChapters > 0 else { return 0 }
        switch startOption {
        case .currentChapter:
            return min(max(currentChapterIndex, 0), totalChapters - 1)
        case .firstChapter:
            return 0
        }
    }

    private var maxSelectableCount: Int {
        max(1, totalChapters - selectedStartIndex)
    }

    private var selectedEndIndex: Int {
        min(totalChapters - 1, selectedStartIndex + Int(chapterCount.rounded()) - 1)
    }

    private var summaryText: String {
        guard totalChapters > 0 else { return localized("沒有可下載章節") }
        return String(
            format: localized("第 %d 到 %d 章，共 %d 章"),
            selectedStartIndex + 1,
            selectedEndIndex + 1,
            Int(chapterCount.rounded())
        )
    }

    private func updateChapterCount(_ value: Int) {
        let clamped = min(max(value, 1), maxSelectableCount)
        chapterCount = Double(clamped)
        chapterCountText = "\(clamped)"
    }

    private func updateChapterCountText(_ text: String) {
        let filtered = text.filter(\.isNumber)
        if filtered != text {
            chapterCountText = filtered
            return
        }
        guard let value = Int(filtered) else { return }
        let clamped = min(max(value, 1), maxSelectableCount)
        chapterCount = Double(clamped)
        if value != clamped {
            chapterCountText = "\(clamped)"
        }
    }

    private func clampChapterCountToCurrentMaximum() {
        updateChapterCount(Int(chapterCount.rounded()))
    }
}

private struct ReaderDownloadProgressPanel: View {
    let book: ReadingBook
    let readerTheme: ReaderTheme
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(statusTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(statusTitle)
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundColor(readerTheme.textColor)
                        .lineLimit(1)
                    Spacer()
                    Text(progressText)
                        .font(DSFont.caption.monospacedDigit())
                        .foregroundColor(readerTheme.textColor.opacity(0.72))
                        .lineLimit(1)
                }

                ProgressView(value: progress)
                    .tint(statusTint)

                Text(rangeText)
                    .font(DSFont.caption)
                    .foregroundColor(readerTheme.textColor.opacity(0.64))
                    .lineLimit(1)
            }

            if book.offlineDownloadState == .failed {
                Button {
                    onResume()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(statusTint)
                        .frame(width: 40, height: 48)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(localized("繼續下載"))
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusTitle)，\(progressText)，\(rangeText)")
    }

    private var task: BookOfflineDownloadTask? {
        book.offlineDownloadTask?.clamped(to: book.onlineChapters?.count ?? 0)
    }

    private var completed: Int {
        task?.clampedCompletedChapterCount ?? book.downloadedChapterCount
    }

    private var total: Int {
        max(task?.totalChapterCount ?? book.onlineChapters?.count ?? 1, 1)
    }

    private var progress: Double {
        min(max(Double(completed) / Double(total), 0), 1)
    }

    private var statusTitle: String {
        switch book.offlineDownloadState {
        case .downloading:
            return localized("下載中")
        case .available:
            return localized("下載完成")
        case .failed:
            return localized("下載失敗")
        case .none:
            return localized("未下載")
        }
    }

    private var statusIcon: String {
        switch book.offlineDownloadState {
        case .downloading:
            return "arrow.down.circle.fill"
        case .available:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .none:
            return "icloud.and.arrow.down"
        }
    }

    private var statusTint: Color {
        switch book.offlineDownloadState {
        case .downloading:
            return readerTheme.accentColor
        case .available:
            return DSColor.success
        case .failed:
            return DSColor.warning
        case .none:
            return DSColor.textSecondary
        }
    }

    private var progressText: String {
        String(format: localized("%d/%d 章"), completed, total)
    }

    private var rangeText: String {
        guard let task else { return book.title }
        return String(
            format: localized("第 %d 到 %d 章"),
            task.startChapterIndex + 1,
            task.endChapterIndex + 1
        )
    }
}
