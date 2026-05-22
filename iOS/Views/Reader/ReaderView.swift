import Combine
import SwiftUI

private let uiFeedbackDuration: Double = 0.25

private struct RoundedCornerShape: Shape {
    var radius: CGFloat = 28
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

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
            epubRenderer.engine?.warmUpNext(currentGlobalPage: currentPage + 1)
        }
    }


    @State private var chapters: [BookChapter] = []
    @State private var allPages: [PageContent] = []
    @State private var currentPage = 0
    @State private var showBars = false
    @State private var showSettings = false
    @State private var showTOC = false

    // Online chapter lazy loading
    @StateObject private var readerViewModel = ReaderViewModel()
    @State private var observedChapterStates: [Int: ChapterLoadState] = [:]

    /// Top safe area (points), passed to EPUB engine as minimum margin-top.
    @State private var readerSafeAreaTop: CGFloat = 59
    @State private var readerViewportSize: CGSize = UIScreen.main.bounds.size
    @StateObject private var volumeHandler = VolumeKeyHandler()

    @StateObject private var autoReader = AutoReadController()
    @StateObject private var ttsCoordinator = TTSCoordinator()

    private func syncReaderBrightnessFromSystem() {
        let current = Double(UIScreen.main.brightness)
        systemBrightness = current
        settings.readerBrightness = current
    }

    private func restoreReaderDisplayStateAfterResume() {
        guard let engine = epubRenderer.engine, isEPUB, engine.totalPages > 0 else { return }
        let (spineIndex, _) = engine.charOffset(forPage: currentPage)
        currentChapterIndex = spineIndex
    }

    @StateObject private var epubRenderer = EPUBPageRenderer()

    @State private var showTTSPanel = false
    @State private var showAutoReadPanel = false
    @State private var ttsChapterIndex: Int? = nil
    @State private var showTTSJumpPrompt = false
    @State private var ttsJumpPromptChapterIndex: Int? = nil

    @State private var currentChapterIndex = 0

    // Scroll mode progress tracking
    @State private var scrollVisibleChapter = 0
    @State private var scrollResliceToken: UInt = 0

    // Source change
    @State private var showChangeSourceSheet = false
    @State private var runtimeState = ReaderRuntimeState()
    @State private var pendingCoreTextJumpTarget: CoreTextReadingPosition?
    @State private var bookDocument: (any BookDocument)? = nil
    @State private var contentProvider: (any BookContentProvider)? = nil
    @State private var readerCapabilities: ReaderCapabilities = .reflowableText
    private let progressManager = ReaderProgressManager.shared

    // Source change state managed by ViewModel, exposed via computed properties to avoid duplicate state in the view.
    private var changeSourceOrigins: [BookOrigin] { readerViewModel.changeSourceOrigins }
    private var changeSourceLoading: Bool { readerViewModel.changeSourceLoading }
    private var changeSourceError: String? { readerViewModel.changeSourceError }

    private var systemBrightness: Double {
        get { runtimeState.systemBrightness }
        nonmutating set { runtimeState.systemBrightness = newValue }
    }

    private var isRestoringPosition: Bool {
        get { runtimeState.isRestoringPosition }
        nonmutating set { runtimeState.isRestoringPosition = newValue }
    }

    private var savedPositionSnapshot: Double {
        get { runtimeState.savedPositionSnapshot }
        nonmutating set { runtimeState.savedPositionSnapshot = newValue }
    }

    private var savedCoreTextRestoreTarget: (chapterIndex: Int, charOffset: Int)? {
        get { runtimeState.savedCoreTextRestoreTarget }
        nonmutating set { runtimeState.savedCoreTextRestoreTarget = newValue }
    }

    private var isApplyingCoreTextRestore: Bool {
        get { runtimeState.isApplyingCoreTextRestore }
        nonmutating set { runtimeState.isApplyingCoreTextRestore = newValue }
    }

    private var hasAppliedNonZeroRestore: Bool {
        get { runtimeState.hasAppliedNonZeroRestore }
        nonmutating set { runtimeState.hasAppliedNonZeroRestore = newValue }
    }

    private var isLoadingPipeline: Bool {
        get { runtimeState.isLoadingPipeline }
        nonmutating set { runtimeState.isLoadingPipeline = newValue }
    }

    private var curlStartupStartedAt: CFAbsoluteTime? {
        get { runtimeState.curlStartupStartedAt }
        nonmutating set { runtimeState.curlStartupStartedAt = newValue }
    }

    private var hasLoggedCurlInteractiveReady: Bool {
        get { runtimeState.hasLoggedCurlInteractiveReady }
        nonmutating set { runtimeState.hasLoggedCurlInteractiveReady = newValue }
    }

    private var hasPerformedInitialLoad: Bool {
        get { runtimeState.hasPerformedInitialLoad }
        nonmutating set { runtimeState.hasPerformedInitialLoad = newValue }
    }

    private var fontSize: CGFloat {
        get { readerConfig.fontSize }
        nonmutating set { readerConfig.fontSize = newValue }
    }

    private var readerTheme: ReaderTheme {
        get { readerConfig.theme }
        nonmutating set { readerConfig.theme = newValue }
    }


    private var overlayContentMaxWidth: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 960 : .infinity
    }

    private var extraReaderHorizontalInset: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 28 : 0
    }

    private var effectivePageMarginH: CGFloat {
        readerConfig.pageMarginH + extraReaderHorizontalInset
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

    private var tocPageOffsets: [Int: Int] {
        guard let engine = epubRenderer.engine, usesCoreTextEPUB else { return [:] }
        var offsets: [Int: Int] = [:]
        for chapter in chapters {
            if offsets[chapter.index] == nil {
                offsets[chapter.index] = engine.pageIndex(forSpine: chapter.index, charOffset: 0)
            }
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

        progressTrace("onPageChanged page=\(newPage) chapter=\(currentChapterIndex) visiblePosition=\(String(describing: visiblePosition))")

        if chapterChanged {
            ensureChapterReady(chapterIndex: newChapter)
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

        if let progressBookId = localEPUBBookIdentifier {
            epubRenderer.syncProgress(bookId: progressBookId)
        }
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
            if chapters.indices.contains(currentChapterIndex) {
                return chapters[currentChapterIndex].title
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
        epubRenderer.engine?.setTextAnnotations(coreTextTextAnnotations)
    }

    private func addUnderlineBookmark(_ request: CoreTextUnderlineSelectionRequest) {
        let position = request.position
        guard chapters.indices.contains(position.spineIndex) else { return }
        if request.removesExistingUnderline {
            store.removeUnderlineBookmark(
                bookId: bookId,
                position: position,
                length: request.length
            )
            syncCoreTextTextAnnotations()
            return
        }
        store.addUnderlineBookmark(
            bookId: bookId,
            chapterIndex: position.spineIndex,
            chapterTitle: bookmarkChapterTitle(for: position.spineIndex),
            position: position,
            length: request.length,
            excerpt: request.excerpt.isEmpty ? currentPageExcerpt : String(request.excerpt.prefix(80))
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

    private var activeTTSChapterTitle: String {
        let index = ttsChapterIndex ?? currentChapterIndex
        guard chapters.indices.contains(index) else { return currentChapterTitle }
        return chapters[index].title
    }

    // ── Body ──
    var body: some View {
        buildBody()
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
                    pageTurnStyle: settings.pageTurnStyle,
                    theme: readerTheme,
                    playbackHighlightText: nil,
                    isRTL: false,
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
                .id(settings.pageTurnStyle)
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if effectiveScrollMode {
                scrollBody
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if let ctEngine = epubRenderer.engine, epubRenderer.isCoreTextReady {
                let _ = { print("[ReaderView] Using CoreText engine") }()
                CoreTextPageEngineView(
                    engine: ctEngine,
                    pageTurnStyle: settings.pageTurnStyle,
                    theme: readerTheme,
                    playbackHighlightText: ttsCoordinator.playbackState == .stopped
                        ? nil
                        : ttsCoordinator.currentSegmentText,
                    isRTL: effectiveWritingMode.isVertical,
                    externalTargetPosition: pendingCoreTextJumpTarget,
                    clearExternalTargetPosition: { pendingCoreTextJumpTarget = nil },
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
                .id(settings.pageTurnStyle)
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
                    .zIndex(40)
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
        .onPreferenceChange(ReaderViewportSizeKey.self) {
            readerViewportSize = $0
            epubRenderer.notifyViewportSize($0)
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
            ttsCoordinator.onPageFinished = {
                ttsLog("[TTS][Reader] onChapterFinished ttsChapter=\(ttsChapterIndex.map(String.init) ?? "nil") currentChapter=\(currentChapterIndex)")
                return advanceTTSChapterFromEngine()
            }
            ttsCoordinator.onNextTrackRequested = {
                startAdjacentTTSChapter(delta: 1)
            }
            ttsCoordinator.onPreviousTrackRequested = {
                startAdjacentTTSChapter(delta: -1)
            }
            ttsCoordinator.onStop = {
                ttsChapterIndex = nil
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
            if let b = book, b.isOnline {
                Task {
                    await readerViewModel.cancelAll(for: b.id)
                }
            }
            volumeHandler.stopListening()
            autoReader.pause()
            setTTSFloatingOverlayVisible(false)
        }
        .onChanged(of: scenePhase) { phase in
            ttsLog("[TTS][Reader] scenePhase=\(String(describing: phase)) ttsPlaying=\(ttsCoordinator.isPlaying)")
            if phase == .background || phase == .inactive {
                ttsCoordinator.refreshNowPlayingForSystemSurfaces()
                epubRenderer.engine?.cancelPendingWork()
                saveProgress()
                if let bookId = localEPUBBookIdentifier {
                    epubRenderer.flushProgress(bookId: bookId)
                }
            } else if phase == .active {
                restoreReaderDisplayStateAfterResume()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in
            epubRenderer.engine?.cancelPendingWork()
            saveProgress()
            if let bookId = localEPUBBookIdentifier {
                epubRenderer.flushProgress(bookId: bookId)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            performUnifiedRelayout(targetSize: readerViewportSize)
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
        .onChanged(of: settings.readerWritingMode) { _ in
            handleReaderConfigRefresh(.layout)
        }
        .onChanged(of: book?.bookmarks ?? []) { _ in
            syncCoreTextTextAnnotations()
        }
        .onChanged(of: showBars) { visible in
            setTTSFloatingOverlayVisible(visible)
        }
        .onChanged(of: currentChapterIndex) { newChapter in
            handleReaderChapterChangedForTTS(newChapter)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsFloatingPlayerOpenPanel)) { _ in
            showTTSPanel = true
        }
        .onChanged(of: scrollVisibleChapter) { _ in
            autoSaveProgress()
        }
        .sheet(isPresented: $showSettings) {
            AdaptiveSheetContainer(maxWidth: 760) {
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
        .sheet(isPresented: $showTOC) {
            AdaptiveSheetContainer(maxWidth: 760) {
                ReaderMenuView(
                    chapters: chapters,
                    coverImagePath: book?.coverImagePath,
                    bookTitle: book?.title ?? "",
                    currentPage: currentPage,
                    totalPages: renderedPageCount,
                    tocLayoutMode: .from(writingMode: effectiveWritingMode),
                    pageOffsets: tocPageOffsets,
                    currentIndex: Binding(
                        get: { currentChapterIndex },
                        set: { jumpToChapter($0) }
                    ),
                    isPresented: $showTOC
                )
            }
        }
        .sheet(isPresented: $showTTSPanel) {
            AdaptiveSheetContainer(maxWidth: 760) {
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
        .sheet(isPresented: $showAutoReadPanel) {
            AdaptiveSheetContainer(maxWidth: 760) {
                AutoReadPanelView(autoReader: autoReader)
            }
        }
        .sheet(isPresented: $showChangeSourceSheet) {
            AdaptiveSheetContainer(maxWidth: 900) {
                changeSourceSheetContent
            }
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
            }
        }
        .onChanged(of: allPages.count) { _ in
            applyInitialProgressIfNeeded()
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

    private func initialProgressSnapshot() -> Double {
        if let snapshot = progressManager.loadSnapshot(bookId: bookId) {
            return min(1.0, max(0.0, snapshot.percentage))
        }
        return min(1.0, max(0.0, book?.currentPosition ?? 0))
    }

    private func refreshInitialRestoreState() {
        let snapshot = progressManager.loadSnapshot(bookId: bookId)
        savedPositionSnapshot = min(1.0, max(0.0, snapshot?.percentage ?? book?.currentPosition ?? 0))
        if let snapshot,
           snapshot.mode == .coreText,
           let charOffset = snapshot.charOffset {
            savedCoreTextRestoreTarget = (snapshot.chapterIndex, max(0, charOffset))
        } else {
            savedCoreTextRestoreTarget = nil
        }
        isApplyingCoreTextRestore = false
        hasAppliedNonZeroRestore = false
        progressTrace(
            "refreshInitialRestoreState snapshotMode=\(snapshot?.mode.rawValue ?? "nil") snapshotChapter=\(snapshot.map { String($0.chapterIndex) } ?? "nil") snapshotOffset=\(snapshot?.charOffset.map(String.init) ?? "nil") pct=\(String(format: "%.6f", savedPositionSnapshot)) target=\(savedCoreTextRestoreTarget.map { "(\($0.chapterIndex),\($0.charOffset))" } ?? "nil")"
        )
    }

    private func applyInitialProgressIfNeeded() {
        if let engine = epubRenderer.engine {
            let currentEnginePage = engine.currentPage
            progressTrace(
                "applyInitialProgress start enginePage=\(currentEnginePage) totalPages=\(engine.totalPages) savedPct=\(String(format: "%.6f", savedPositionSnapshot)) target=\(savedCoreTextRestoreTarget.map { "(\($0.chapterIndex),\($0.charOffset))" } ?? "nil")"
            )
            // Prefer the engine (CharOffsetStore) restore result, unaffected by snapshot=0.
            if ReaderProgressSyncPolicy.shouldUseEnginePageDirectly(
                enginePage: currentEnginePage,
                totalPages: engine.totalPages,
                savedPositionSnapshot: savedPositionSnapshot,
                hasRestoreTarget: savedCoreTextRestoreTarget != nil
            ), !(currentEnginePage == 0 && hasAppliedNonZeroRestore) {
                if currentPage != currentEnginePage {
                    currentPage = currentEnginePage
                    currentChapterIndex = engine.charOffset(forPage: currentEnginePage).spineIndex
                }
                ensureChapterReady(chapterIndex: currentChapterIndex)
                if engine.totalPages > 0 {
                    epubRenderer.updateCurrentPosition(globalPage: currentEnginePage, engine: engine)
                }
                if currentEnginePage > 0 {
                    hasAppliedNonZeroRestore = true
                }
                progressTrace("applyInitialProgress useEnginePage resolvedPage=\(currentEnginePage)")
                savedPositionSnapshot = 0
                savedCoreTextRestoreTarget = nil
                return
            }

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
                    self.ensureChapterReady(chapterIndex: spineIndex)
                    self.epubRenderer.updateCurrentPosition(globalPage: resolvedPage, engine: engine)
                    if resolvedPage > 0 {
                        self.hasAppliedNonZeroRestore = true
                    }
                    self.savedCoreTextRestoreTarget = nil
                    self.savedPositionSnapshot = 0
                }
                return
            }

            let progress = min(1.0, max(0.0, savedPositionSnapshot))
            guard progress > 0 else { return }

            guard engine.totalPages > 1 else { return }
            let target = max(0, min(Int(round(progress * Double(engine.totalPages - 1))), engine.totalPages - 1))
            if target > 0 {
                currentPage = target
                let (spineIndex, _) = engine.charOffset(forPage: target)
                currentChapterIndex = spineIndex
                ensureChapterReady(chapterIndex: spineIndex)
                epubRenderer.updateCurrentPosition(globalPage: target, engine: engine)
                hasAppliedNonZeroRestore = true
                progressTrace("applyInitialProgress fallbackByPercentage targetPage=\(target) fromPct=\(String(format: "%.6f", progress))")
            }
            savedPositionSnapshot = 0
            savedCoreTextRestoreTarget = nil
            return
        }

        let progress = min(1.0, max(0.0, savedPositionSnapshot))
        guard progress > 0 else { return }

        if !allPages.isEmpty {
            let maxIndex = allPages.count - 1
            guard maxIndex > 0 else { return }
            let target = max(0, min(Int(round(progress * Double(maxIndex))), maxIndex))
            if target > 0 {
                currentPage = target
                currentChapterIndex = allPages[target].chapterIndex
            }
            savedPositionSnapshot = 0
            savedCoreTextRestoreTarget = nil
            return
        }

        if effectiveScrollMode, !chapters.isEmpty {
            let maxIndex = chapters.count - 1
            guard maxIndex > 0 else { return }
            let target = max(0, min(Int(round(progress * Double(maxIndex))), maxIndex))
            if target > 0 {
                scrollVisibleChapter = target
                currentChapterIndex = target
            }
            savedPositionSnapshot = 0
            savedCoreTextRestoreTarget = nil
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
                verticalInset: readerConfig.pageMarginV,
                backgroundColor: readerTheme.uiBackgroundColor,
                initialChapter: initialPos.chapter,
                initialCharOffset: initialPos.charOffset,
                resliceToken: scrollResliceToken,
                playbackHighlightText: ttsCoordinator.playbackState == .stopped
                    ? nil : ttsCoordinator.currentSegmentText,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                },
                onProgressCommit: { pos in
                    scrollVisibleChapter = pos.chapter
                    currentChapterIndex = pos.chapter
                    progressManager.saveScroll(
                        bookId: bookId,
                        chapterIndex: pos.chapter,
                        charOffset: pos.charOffset,
                        percentage: pos.percentage
                    )
                    store.updatePosition(bookId: bookId, position: pos.percentage)
                    // Sync the paged engine's current page so switching back to paged mode preserves position.
                    if let pagedEngine = epubRenderer.engine, epubRenderer.isCoreTextReady {
                        let page = pagedEngine.pageIndex(forSpine: pos.chapter, charOffset: pos.charOffset)
                        if page >= 0 { currentPage = page }
                    }
                },
                onInternalLinkTap: { href in
                    Task {
                        guard let targetPage = await epubRenderer.resolveInternalLink(href, fromSpineIndex: currentChapterIndex),
                              let pagedEngine = epubRenderer.engine else { return }
                        let (spine, charOffset) = pagedEngine.charOffset(forPage: targetPage)
                        await MainActor.run {
                            currentChapterIndex = spine
                            scrollVisibleChapter = spine
                            savedCoreTextRestoreTarget = (spine, charOffset)
                            scrollResliceToken &+= 1
                        }
                    }
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
        if let pagedEngine = epubRenderer.engine, epubRenderer.isCoreTextReady {
            let (spine, offset) = pagedEngine.charOffset(forPage: currentPage)
            return (max(0, spine), max(0, offset))
        }
        if let snap = progressManager.loadSnapshot(bookId: bookId), snap.mode == .scroll {
            return (max(0, snap.chapterIndex), max(0, snap.charOffset ?? 0))
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
        switch settings.pageTurnStyle {
        case .none:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { currentPage -= 1 }
        case .slide:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage -= 1
            }
        case .cover, .curl:
            currentPage -= 1
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
        switch settings.pageTurnStyle {
        case .none:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { currentPage += 1 }
        case .slide:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage += 1
            }
        case .cover, .curl:
            currentPage += 1
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
            onOpenTTS: { showTTSPanel = true },
            onOpenTOC: { showTOC = true },
            onOpenSettings: { showSettings = true }
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
                startTTSFromCurrentReadingPosition()
            } label: {
                Label(localized("從本頁聽"), systemImage: "headphones")
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
        AnyView(NavigationView {
            Group {
                if changeSourceLoading {
                    AnyView(
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(localized("正在搜尋其他書源…"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                } else if let err = changeSourceError {
                    AnyView(
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title)
                                .foregroundColor(.orange)
                            Text(err)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                } else if changeSourceOrigins.isEmpty {
                    AnyView(
                        Text(localized("暫無其他書源"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                } else {
                    AnyView(
                        List(changeSourceOrigins) { origin in
                            Button {
                                Task {
                                    do {
                                        try await store.updateOnlineBookSource(
                                            bookId: bookId, origin: origin)
                                        await MainActor.run {
                                            showChangeSourceSheet = false
                                            loadContent()
                                        }
                                    } catch {
                                        await MainActor.run {
                                            readerViewModel.reportChangeSourceError(error.localizedDescription)
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(origin.sourceName)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    )
                }
            }
            .navigationTitle(localized("換源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("關閉")) { showChangeSourceSheet = false }
                }
            }
        })
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
            if chapters.indices.contains(pos.spineIndex) {
                return chapters[pos.spineIndex].title
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

    private func setTTSFloatingOverlayVisible(_ visible: Bool) {
        Task { @MainActor in
            TTSFloatingPlayerState.shared.setReaderOverlayVisible(visible)
        }
    }

    @discardableResult
    private func startTTSChapter(_ chapterIndex: Int, syncReader: Bool) -> Bool {
        guard chapters.indices.contains(chapterIndex) else { return false }
        let text = textForTTSChapter(chapterIndex)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ttsLog("[TTS][Reader] startTTSChapter ignored empty chapter=\(chapterIndex)")
            if syncReader {
                jumpToChapter(chapterIndex)
            }
            ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
            return false
        }

        ttsChapterIndex = chapterIndex
        showTTSJumpPrompt = false
        ttsJumpPromptChapterIndex = nil
        ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
        if syncReader {
            jumpToChapter(chapterIndex)
        }
        ttsCoordinator.speak(text: text, title: chapters[chapterIndex].title)
        return true
    }

    @discardableResult
    private func startAdjacentTTSChapter(delta: Int) -> Bool {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        let target = baseChapter + delta
        guard chapters.indices.contains(target) else { return false }
        return startTTSChapter(target, syncReader: true)
    }

    private func advanceTTSChapterFromEngine() -> String? {
        let baseChapter = ttsChapterIndex ?? currentChapterIndex
        let target = baseChapter + 1
        guard chapters.indices.contains(target) else {
            ttsChapterIndex = nil
            return nil
        }
        let text = textForTTSChapter(target)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ensureChapterReady(chapterIndex: target, priority: .jump)
            return nil
        }
        ttsChapterIndex = target
        showTTSJumpPrompt = false
        ttsJumpPromptChapterIndex = nil
        ttsCoordinator.updateNowPlayingTitle(chapters[target].title)
        jumpToChapter(target)
        return text
    }

    private func handleReaderChapterChangedForTTS(_ chapterIndex: Int) {
        guard ttsCoordinator.playbackState != .stopped,
              let ttsChapterIndex,
              chapterIndex != ttsChapterIndex
        else {
            if chapterIndex == ttsChapterIndex {
                showTTSJumpPrompt = false
                ttsJumpPromptChapterIndex = nil
            }
            return
        }
        ttsJumpPromptChapterIndex = chapterIndex
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = true
        }
    }

    private func jumpBackToTTSChapter() {
        guard let ttsChapterIndex, chapters.indices.contains(ttsChapterIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showTTSJumpPrompt = false
            ttsJumpPromptChapterIndex = nil
        }
        jumpToChapter(ttsChapterIndex)
    }

    private func startTTSFromCurrentReadingPosition() {
        let target = ttsJumpPromptChapterIndex ?? currentChapterIndex
        guard chapters.indices.contains(target) else { return }
        let text = textForTTSCurrentReadingPosition(chapterIndex: target)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = startTTSChapter(target, syncReader: false)
            return
        }

        ttsChapterIndex = target
        showTTSJumpPrompt = false
        ttsJumpPromptChapterIndex = nil
        ensureChapterReady(chapterIndex: target, priority: .jump)
        ttsCoordinator.speak(text: text, title: chapters[target].title)
    }

    private func textForTTSChapter(_ chapterIndex: Int) -> String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        if let engine = epubRenderer.engine,
           usesCoreTextEPUB,
           let layout = engine.layouts[chapterIndex],
           layout.attributedString.length > 0 {
            return layout.attributedString.string
        }
        let pageText = allPages
            .filter { $0.chapterIndex == chapterIndex }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageText.isEmpty { return pageText }
        return chapters[chapterIndex].content
    }

    private func textForTTSCurrentReadingPosition(chapterIndex: Int) -> String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        if let engine = epubRenderer.engine,
           usesCoreTextEPUB,
           let layout = engine.layouts[chapterIndex],
           layout.attributedString.length > 0 {
            let position = engine.charOffset(forPage: currentPage)
            guard position.spineIndex == chapterIndex else {
                return textForTTSChapter(chapterIndex)
            }
            let start = max(0, min(position.charOffset, layout.attributedString.length))
            let range = NSRange(location: start, length: layout.attributedString.length - start)
            return layout.attributedString.attributedSubstring(from: range).string
        }

        if !effectiveScrollMode, !allPages.isEmpty {
            let startPage = max(0, min(currentPage, max(allPages.count - 1, 0)))
            let text = allPages
                .enumerated()
                .filter { index, page in
                    index >= startPage && page.chapterIndex == chapterIndex
                }
                .map { $0.element.content }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        return textForTTSChapter(chapterIndex)
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
            savedCoreTextRestoreTarget = (position.spineIndex, position.charOffset)
            scrollResliceToken &+= 1
            return
        }
        jumpToChapter(position.spineIndex, charOffset: position.charOffset)
    }

    private func jumpToChapter(_ idx: Int, charOffset: Int = 0) {
        guard chapters.indices.contains(idx) else { return }
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            currentChapterIndex = idx
            scrollVisibleChapter = idx
            savedCoreTextRestoreTarget = (idx, charOffset)
            scrollResliceToken &+= 1
            ensureChapterReady(chapterIndex: idx, priority: .jump)
            return
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let position = CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset)
            print("[FlipTrace] ReaderView.jumpToChapter request spine=\(idx) charOffset=\(charOffset) layoutReady=\(engine.layouts[idx] != nil)")
            pendingCoreTextJumpTarget = position
            _ = engine.pageViewController(for: position)
            currentChapterIndex = idx
            if let exactPage = engine.pageIndex(for: position) {
                currentPage = exactPage
                print("[FlipTrace] ReaderView.jumpToChapter exact spine=\(idx) page=\(exactPage)")
            } else if let estimatedPage = engine.estimatedGlobalPage(for: position) {
                currentPage = estimatedPage
                print("[FlipTrace] ReaderView.jumpToChapter placeholder spine=\(idx) page=\(estimatedPage)")
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
            ensureChapterReady(chapterIndex: idx, priority: .jump)
        }
    }

    private func autoSaveProgress() {
        guard !isRestoringPosition else { return }

        if effectiveScrollMode {
            progressTrace("autoSave scroll visibleChapter=\(scrollVisibleChapter)")
            progressManager.saveScroll(
                bookId: bookId,
                chapterIndex: scrollVisibleChapter,
                percentage: Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1))
            )
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
            if let progressBookId = localEPUBBookIdentifier {
                epubRenderer.updateCurrentPosition(globalPage: candidatePage, engine: engine)
                epubRenderer.syncProgress(bookId: progressBookId)
            }
            currentChapterIndex = spineIndex
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset)
            let normalized = min(1.0, max(0.0, pct))
            progressTrace(
                "autoSave coreText page=\(candidatePage) spine=\(spineIndex) charOffset=\(charOffset) pct=\(String(format: "%.6f", normalized))"
            )
            progressManager.saveCoreText(
                bookId: bookId,
                chapterIndex: spineIndex,
                charOffset: charOffset,
                percentage: normalized
            )
            store.updatePosition(bookId: bookId, position: normalized)
        } else if !effectiveScrollMode && !allPages.isEmpty {
            // TXT: use allPages
            let page = allPages[min(currentPage, allPages.count - 1)]
            currentChapterIndex = page.chapterIndex
            // Prefetch the next chapter early when near the end of the current chapter.
            maybeEarlyPrefetchIfNearChapterEnd()
            let progress = Double(currentPage) / Double(max(allPages.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
            progressTrace(
                "autoSave paged currentPage=\(currentPage) chapter=\(page.chapterIndex) pageInChapter=\(page.pageInChapter) pct=\(String(format: "%.6f", normalized))"
            )
            progressManager.savePaged(
                bookId: bookId,
                chapterIndex: page.chapterIndex,
                pageInChapter: page.pageInChapter,
                percentage: normalized
            )
            store.updatePosition(bookId: bookId, position: normalized)
        } else {
            // Scroll mode
            let progress = Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
            progressTrace(
                "autoSave scroll visibleChapter=\(scrollVisibleChapter) pct=\(String(format: "%.6f", normalized))"
            )
            progressManager.saveScroll(
                bookId: bookId,
                chapterIndex: scrollVisibleChapter,
                percentage: normalized
            )
            store.updatePosition(bookId: bookId, position: normalized)
        }
    }

    private func saveProgress() {
        // Force save on onDisappear, bypassing isRestoringPosition.
        let wasRestoring = isRestoringPosition
        progressTrace("saveProgress begin wasRestoring=\(wasRestoring)")
        isRestoringPosition = false
        autoSaveProgress()
        isRestoringPosition = wasRestoring
        if let bookId = localEPUBBookIdentifier {
            epubRenderer.flushProgress(bookId: bookId)
            progressTrace("saveProgress flushed charOffsetStore bookId=\(bookId)")
        } else {
            progressTrace("saveProgress noCoreTextBookIdentifier")
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
        readerViewModel.handleDownloadAction(book: b, store: store)
    }

    /// Source change search has been moved to ReaderViewModel.loadOtherOrigins. This method only triggers it and passes required data.
    private func loadOtherOrigins() {
        guard let b = book, let currentSourceId = b.bookSourceId else { return }
        readerViewModel.loadOtherOrigins(
            book: b,
            currentSourceId: currentSourceId,
            enabledSources: BookSourceStore.shared.enabledSources,
            store: store
        )
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

        // Prefer EPUB toc.ncx / nav.xhtml entries. Only fall back to spine when TOC is missing.
        if !session.tocEntries.isEmpty {
            let spineIndexByHref: [String: Int] = Dictionary(
                session.chapters.map { ($0.href, $0.index) },
                uniquingKeysWith: { first, _ in first }
            )

            var seenTitles: Set<String> = []
            chapters = session.tocEntries.compactMap { entry -> BookChapter? in
                // Strip fragment from TOC href for spine matching (e.g. "part0005.html#anchor" → "part0005.html")
                let hrefWithoutFragment: String
                if let hashIndex = entry.href.firstIndex(of: "#") {
                    hrefWithoutFragment = String(entry.href[..<hashIndex])
                } else {
                    hrefWithoutFragment = entry.href
                }

                let resolvedIndex = spineIndexByHref[hrefWithoutFragment]
                    ?? spineIndexByHref.first(where: {
                        hrefWithoutFragment.hasSuffix($0.key) || $0.key.hasSuffix(hrefWithoutFragment)
                    })?.value
                    ?? 0

                // Dedupe consecutive identically-titled entries (e.g. multiple Contents pages)
                let normalizedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedTitle.isEmpty { return nil }
                let dedupeKey = "\(resolvedIndex):\(normalizedTitle)"
                if seenTitles.contains(dedupeKey) { return nil }
                seenTitles.insert(dedupeKey)

                return BookChapter(
                    index: resolvedIndex,
                    title: entry.title,
                    content: "",
                    href: hrefWithoutFragment,
                    level: entry.level
                )
            }
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
            renderSize: readerViewportSize,
            settings: settings
        )

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
            renderSize: readerViewportSize,
            settings: settings
        )

        currentPage = 0
        isLoadingPipeline = false
        isRestoringPosition = false

        // Lazy loading: auto-fetch the initial chapter (saved position or chapter 0).
        let initialChapter = OnlineInitialChapterResolver.preferredInitialChapter(
            chapterCount: refs.count,
            savedPositionSnapshot: savedPositionSnapshot,
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

                        if GlobalSettings.shared.useRenderableNodePipeline {
                            self.epubRenderer.loadTXT(
                                attributedBuilder: markdownBuilder,
                                bookIdentifier: targetBook.id.uuidString,
                                renderSize: self.readerViewportSize,
                                settings: settings
                            )
                        } else {
                            let legacyBuilder = TXTAttributedStringBuilder(chapters: markdownChapters)
                            self.epubRenderer.loadTXT(
                                attributedBuilder: legacyBuilder,
                                bookIdentifier: targetBook.id.uuidString,
                                renderSize: self.readerViewportSize,
                                settings: settings
                            )
                        }

                        if document.tableOfContents.count > 0 {
                            self.chapters = document.tableOfContents.enumerated().map { i, chapter in
                                BookChapter(index: i, title: chapter.title, content: "")
                            }
                        } else {
                            self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
                        }

                        self.allPages = []
                        if self.savedPositionSnapshot == 0 {
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
                        renderSize: self.readerViewportSize,
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
                    if self.savedPositionSnapshot == 0 {
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

private struct TOCBookHeader: View {
    let coverImagePath: String?
    let bookTitle: String
    let currentPage: Int
    let totalPages: Int
    let tocLayoutMode: TOCLayoutMode
    let onClose: () -> Void

    private var isVertical: Bool { tocLayoutMode == .verticalRTLColumns }

    private var coverSize: CGSize {
        CGSize(width: 48, height: 72)
    }

    private var titleFont: Font {
        .system(size: 16, weight: .semibold)
    }

    private var progressFont: Font {
        .system(size: 14, weight: .regular)
    }

    private var headerBottomPadding: CGFloat {
        28
    }

    private var closeButtonSize: CGFloat {
        50
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let coverPath = coverImagePath,
               let image = loadCoverImage(filename: coverPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: coverSize.width, height: coverSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: coverSize.width, height: coverSize.height)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(bookTitle)
                    .font(titleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if totalPages > 0 {
                    HStack(spacing: 6) {
                        Text(localized("頁面"))
                            .foregroundColor(.secondary)

                        Text(String(format: localized("第 %d 頁（共 %d 頁）"), currentPage + 1, totalPages))
                            .foregroundColor(.primary)
                    }
                    .font(progressFont)
                }
            }
            
            Spacer(minLength: 12)

            Button(role: .cancel, action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(uiColor: .systemGray))
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("關閉"))
        }
        .padding(.horizontal, 30)
        .padding(.bottom, headerBottomPadding)
        .padding(.top,15)

    }

    private func loadCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Combined Bookmarks & TOC Panel

private enum VerticalTOCLayout {
    static let columnWidth: CGFloat = 46
    static let textWidth: CGFloat = 24
    static let fontSize: CGFloat = 17
    static let glyphHeight: CGFloat = 21
    static let glyphSpacing: CGFloat = 0
    static let columnSpacing: CGFloat = 3
    static let topPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 18
    static let selectedCornerRadius: CGFloat = 8
    static let selectedBarWidth: CGFloat = 3
}

private struct VerticalTOCText: View {
    let text: String
    var isSelected: Bool = false
    var maxCharacters: Int = 24

    private var chars: [String] {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")

        let raw = Array(cleaned)
        let limited = raw.count > maxCharacters
            ? Array(raw.prefix(maxCharacters - 1)) + ["\u{2026}"]
            : raw

        return limited.map(String.init)
    }

    var body: some View {
        VStack(spacing: VerticalTOCLayout.glyphSpacing) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, ch in
                glyph(ch)
            }
        }
        .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
    }

    @ViewBuilder
    private func glyph(_ ch: String) -> some View {
        switch VerticalGlyphClassifier.classify(Character(ch)) {
        case .cjk(let s),
             .verticalPunctuation(let s):
            cjkGlyph(s)
        case .compressedPunctuation(let s):
            compressedGlyph(s)
        case .rotatedLatin(let s):
            rotatedLatinGlyph(s)
        case .uprightLatin(let s):
            cjkGlyph(s)
        }
    }

    private func cjkGlyph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: VerticalTOCLayout.fontSize, weight: .semibold))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }

    private func compressedGlyph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: VerticalTOCLayout.fontSize * 0.82, weight: .semibold))
            .frame(
                width: VerticalTOCLayout.textWidth,
                height: VerticalTOCLayout.glyphHeight * 0.55,
                alignment: .topTrailing
            )
            .offset(x: 3, y: -2)
    }

    private func rotatedLatinGlyph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .rotationEffect(.degrees(90))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }
}

private struct VerticalTOCColumn: View {
    let title: String
    let page: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                VerticalTOCText(
                    text: title,
                    isSelected: isSelected,
                    maxCharacters: 24
                )
                .foregroundStyle(isSelected ? Color.blue : Color.primary)
                .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 8)

                Text("\(page)")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .frame(width: VerticalTOCLayout.columnWidth, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, VerticalTOCLayout.topPadding)
            .padding(.bottom, VerticalTOCLayout.bottomPadding)
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: VerticalTOCLayout.selectedCornerRadius,
                        style: .continuous
                    )
                    .fill(isSelected ? Color.primary.opacity(0.07) : Color.clear)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: VerticalTOCLayout.selectedBarWidth)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: VerticalTOCLayout.selectedCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct VerticalTOCView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let pageOffsets: [Int: Int]
    let onSelectChapter: (Int) -> Void

    @State private var didInitialTOCScroll = false

    private var reversedChapters: [BookChapter] {
        Array(chapters.reversed())
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: VerticalTOCLayout.columnSpacing) {
                    ForEach(Array(reversedChapters.enumerated()), id: \.element.id) { _, chapter in
                        let pageNumber: Int = {
                            if let offset = pageOffsets[chapter.index] {
                                return offset + 1
                            }
                            return chapter.index + 1
                        }()
                        VerticalTOCColumn(
                            title: chapter.title,
                            page: pageNumber,
                            isSelected: chapter.index == currentIndex
                        ) {
                            onSelectChapter(chapter.index)
                        }
                        .id(chapter.index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
            }
            .onAppear {
                guard !didInitialTOCScroll else { return }
                didInitialTOCScroll = true

                if chapters.first(where: { $0.index == currentIndex }) != nil {
                    proxy.scrollTo(currentIndex, anchor: .trailing)
                }
            }
        }
    }
}

struct ReaderMenuView: View {
    let chapters: [BookChapter]
    let coverImagePath: String?
    let bookTitle: String
    let currentPage: Int
    let totalPages: Int
    let tocLayoutMode: TOCLayoutMode
    let pageOffsets: [Int: Int]

    @Binding var currentIndex: Int
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            TOCBookHeader(
                coverImagePath: coverImagePath,
                bookTitle: bookTitle,
                currentPage: currentPage,
                totalPages: totalPages,
                tocLayoutMode: tocLayoutMode,
                onClose: { isPresented = false }
            )

            if tocLayoutMode == .verticalRTLColumns {
                VerticalTOCView(
                    chapters: chapters,
                    currentIndex: currentIndex,
                    pageOffsets: pageOffsets,
                    onSelectChapter: { idx in
                        currentIndex = idx
                        isPresented = false
                    }
                )
            } else {
                tocContent
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func pageNumber(for chapter: BookChapter) -> Int {
        if let offset = pageOffsets[chapter.index] {
            return offset + 1
        }
        return chapter.index + 1
    }

    private var tocContent: some View {
        ScrollViewReader { proxy in
            List(chapters) { chapter in
                Button {
                    currentIndex = chapter.index
                    isPresented = false
                } label: {
                    HStack(spacing: 0) {
                        if chapter.level > 0 {
                            Color.clear
                                .frame(width: CGFloat(chapter.level) * 16)
                        }

                        Text(chapter.title)
                            .font(
                                chapter.level == 0
                                ? .system(size: 14, weight: .semibold)
                                : .system(size: 12, weight: .regular)
                            )
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        Spacer()

                        Text("\(pageNumber(for: chapter))")
                            .font(.system(size: 18, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 48)
                    .padding(.horizontal, 30)
                    .background {
                        if chapter.index == currentIndex {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden, edges: chapter.id == chapters.first?.id ? .top : [])
                .listRowSeparator(.visible, edges: .bottom)
                .listRowSeparatorTint(Color.secondary.opacity(0.18))
                .id(chapter.index)
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if chapters.first(where: { $0.index == currentIndex }) != nil {
                        withAnimation {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

#Preview("Reader Menu - Horizontal TOC") {
    ReaderMenuView(
        chapters: ReaderMenuPreviewData.chapters,
        coverImagePath: nil,
        bookTitle: "紅樓夢脂評匯校本",
        currentPage: 12,
        totalPages: 860,
        tocLayoutMode: .horizontalList,
        pageOffsets: ReaderMenuPreviewData.pageOffsets,
        currentIndex: .constant(2),
        isPresented: .constant(true)
    )
}

#Preview("Reader Menu - Vertical TOC") {
    ReaderMenuView(
        chapters: ReaderMenuPreviewData.chapters,
        coverImagePath: nil,
        bookTitle: "紅樓夢脂評匯校本",
        currentPage: 12,
        totalPages: 860,
        tocLayoutMode: .verticalRTLColumns,
        pageOffsets: ReaderMenuPreviewData.pageOffsets,
        currentIndex: .constant(2),
        isPresented: .constant(true)
    )
}

private enum ReaderMenuPreviewData {
    static let chapters: [BookChapter] = [
        BookChapter(index: 0, title: "書名頁", content: ""),
        BookChapter(index: 1, title: "整理說明", content: ""),
        BookChapter(index: 2, title: "凡例", content: ""),
        BookChapter(index: 3, title: "第一回 甄士隱夢幻識通靈", content: ""),
        BookChapter(index: 4, title: "第二回 賈夫人仙逝揚州城", content: ""),
        BookChapter(index: 5, title: "脂硯齋重評石頭記校注", content: "", level: 1),
    ]

    static let pageOffsets: [Int: Int] = [
        0: 0,
        1: 2,
        2: 12,
        3: 24,
        4: 48,
        5: 76,
    ]
}
// MARK: - Scroll Config Observer

private struct ScrollConfigObserver: ViewModifier {
    let readerConfig: ReaderConfig
    let readerTheme: ReaderTheme
    let onChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChanged(of: readerConfig.fontSize) { _ in onChanged() }
            .onChanged(of: readerConfig.lineHeightMultiple) { _ in onChanged() }
            .onChanged(of: readerConfig.letterSpacing) { _ in onChanged() }
            .onChanged(of: readerConfig.paragraphSpacingMultiplier) { _ in onChanged() }
            .onChanged(of: readerConfig.pageMarginH) { _ in onChanged() }
            .onChanged(of: readerConfig.pageMarginV) { _ in onChanged() }
            .onChanged(of: readerConfig.footerBottomPadding) { _ in onChanged() }
            .onChanged(of: readerConfig.footerTextGap) { _ in onChanged() }
            .onChanged(of: readerTheme) { _ in onChanged() }
    }
}

// MARK: - Hide TabBar
private struct HideTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbar(.hidden, for: .tabBar)
        } else {
            content
                .onAppear {
                    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                        let window = scene.windows.first,
                        let tabBar = window.rootViewController as? UITabBarController
                    else { return }
                    tabBar.tabBar.isHidden = true
                }
                .onDisappear {
                    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                        let window = scene.windows.first,
                        let tabBar = window.rootViewController as? UITabBarController
                    else { return }
                    tabBar.tabBar.isHidden = false
                }
        }
    }
}

// MARK: - CoreText UIPageViewController Bridge

private struct CoreTextPageEngineView: UIViewControllerRepresentable {
    let engine: any PageRenderingProvider
    let pageTurnStyle: PageTurnStyle
    let theme: ReaderTheme
    let playbackHighlightText: String?
    let isRTL: Bool
    let externalTargetPosition: CoreTextReadingPosition?
    let clearExternalTargetPosition: () -> Void
    @Binding var currentPage: Int
    let onPageChanged: (Int, CoreTextReadingPosition?) -> Void
    let onTapZone: (String) -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let transitionStyle: UIPageViewController.TransitionStyle
        switch pageTurnStyle {
        case .curl:              transitionStyle = .pageCurl
        case .slide, .cover, .none: transitionStyle = .scroll
        }
        let options: [UIPageViewController.OptionsKey: Any] = [
            .spineLocation: isRTL && pageTurnStyle == .curl
                ? UIPageViewController.SpineLocation.max.rawValue
                : UIPageViewController.SpineLocation.min.rawValue
        ]
        let pvc = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: options
        )
        // cover / none mode: disable built-in swipe gesture (use custom pan or tap for page turns).
        if pageTurnStyle == .cover || pageTurnStyle == .none {
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
        let initialVC = engine.pageViewController(at: initialPage)
        context.coordinator.applyPlaybackHighlight(to: initialVC)
        context.coordinator.captureStablePosition(from: initialVC)
        pvc.setViewControllers([initialVC], direction: .forward, animated: false)
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
        if pageTurnStyle == .cover {
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
        context.coordinator.currentPlaybackHighlightText = playbackHighlightText
        context.coordinator.externalTargetPosition = externalTargetPosition
        context.coordinator.bindEngineCallbacks(to: engine, pageViewController: uiViewController)
        let clampedPage = max(0, min(currentPage, max(engine.totalPages - 1, 0)))
        print("[CurlTrace] updateUIViewController binding=\(currentPage) visible=\((uiViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
        let targetViewController = {
            if let externalTargetPosition {
                return engine.pageViewController(for: externalTargetPosition)
            }
            return engine.pageViewController(at: clampedPage)
        }
        if context.coordinator.currentTheme != theme {
            context.coordinator.currentTheme = theme
            engine.applyThemeChange(
                textColor: UIColor(theme.textColor),
                backgroundColor: UIColor(theme.backgroundColor)
            )
            let targetVC = targetViewController()
            context.coordinator.applyPlaybackHighlight(to: targetVC)
            uiViewController.setViewControllers([targetVC], direction: .forward, animated: false)
            _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
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
                uiViewController.setViewControllers([targetVC], direction: direction, animated: false)
                _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                return
            }

            if externalTargetPosition != nil, !context.coordinator.isTransitioning {
                let targetVC = targetViewController()
                context.coordinator.applyPlaybackHighlight(to: targetVC)
                uiViewController.setViewControllers([targetVC], direction: direction, animated: false)
                uiViewController.view.layoutIfNeeded()
                _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                return
            }

            // Non-adjacent page jumps (TOC navigation, offset recalculation) use instant transition to avoid cover chain reverse.
            let isAdjacent = abs(clampedPage - visible.globalPageIndex) == 1
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
                    uiViewController.setViewControllers([targetVC], direction: direction, animated: false)
                    uiViewController.view.layoutIfNeeded()
                    _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                }
                return
            }

            if shouldAnimate {
                let decision = context.coordinator.transitionQueue.requestTransition(
                    to: clampedPage,
                    visiblePage: visible.globalPageIndex
                )
                guard decision == .startImmediately else { return }
            } else if context.coordinator.transitionQueue.isTransitioning {
                _ = context.coordinator.transitionQueue.requestTransition(
                    to: clampedPage,
                    visiblePage: visible.globalPageIndex
                )
                return
            }

            context.coordinator.performProgrammaticTransition(
                on: uiViewController,
                to: clampedPage,
                direction: direction,
                animated: shouldAnimate
            )
            return
        }

        let targetVC = targetViewController()
        context.coordinator.applyPlaybackHighlight(to: targetVC)
        uiViewController.setViewControllers([targetVC], direction: .forward, animated: false)
        _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            engine: engine,
            pageTurnStyle: pageTurnStyle,
            theme: theme,
            playbackHighlightText: playbackHighlightText,
            isRTL: isRTL,
            externalTargetPosition: externalTargetPosition,
            clearExternalTargetPosition: clearExternalTargetPosition,
            currentPage: $currentPage,
            onPageChanged: onPageChanged,
            onTapZone: onTapZone
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
        @Binding var currentPage: Int
        let onPageChanged: (Int, CoreTextReadingPosition?) -> Void
        let onTapZone: (String) -> Void
        let isRTL: Bool
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

        // Cover animation overlay components
        private let coverOverlayView = UIView()
        private let coverCurrentImageView = UIImageView()
        private let coverDimView = UIView()
        private let coverShadowView = UIView()
        private let coverIncomingImageView = UIImageView()
        private var coverTargetPage: Int?
        private var coverDirection: Int = 0  // 1 = forward, -1 = backward
        /// Set to true after makeUIViewController has set the initial page,
        /// so the subsequent updateUIViewController skips redundant backward animation (binding not yet synced).
        fileprivate var suppressNextTransition = false
        fileprivate var currentCoreTextPosition: CoreTextReadingPosition?
        private var pendingNavigation: PendingNavigation?
        weak var coverPageViewController: UIPageViewController?
        private weak var callbackEngineObject: AnyObject?
        private var callbackEngineIdentifier: ObjectIdentifier?
        fileprivate var isTransitioning = false
        fileprivate var transitionQueue = ReaderPageTransitionQueue()
        private var isCurlTransitionActive = false
        private var pendingCurlRefresh = false

        init(engine: any PageRenderingProvider,
             pageTurnStyle: PageTurnStyle,
             theme: ReaderTheme,
             playbackHighlightText: String?,
             isRTL: Bool,
             externalTargetPosition: CoreTextReadingPosition?,
             clearExternalTargetPosition: @escaping () -> Void,
             currentPage: Binding<Int>,
             onPageChanged: @escaping (Int, CoreTextReadingPosition?) -> Void,
             onTapZone: @escaping (String) -> Void) {
            self.currentEngine = engine
            self.pageTurnStyle = pageTurnStyle
            self.currentTheme = theme
            self.currentPlaybackHighlightText = playbackHighlightText
            self.isRTL = isRTL
            self.externalTargetPosition = externalTargetPosition
            self.clearExternalTargetPosition = clearExternalTargetPosition
            self._currentPage = currentPage
            self.onPageChanged = onPageChanged
            self.onTapZone = onTapZone
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
                    print(line)
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

            if engine.currentPage > 0, currentPage == 0 {
                handleNavigate(to: engine.currentPage)
            }
        }

        private func clearEngineCallbacks() {
            if let engine = callbackEngineObject as? any PageRenderingProvider {
                engine.onChapterReady = nil
                engine.onNavigateToPage = nil
            }
            callbackEngineObject = nil
            callbackEngineIdentifier = nil
        }


        private func handleChapterReady(on pageViewController: UIPageViewController) {
            if pageTurnStyle == .curl && isCurlTransitionActive {
                pendingCurlRefresh = true
                print("[CurlTrace] defer handleChapterReady during curl transition")
                return
            }
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
                freshVC = engine.pageViewController(for: position)
                targetPage = engine.pageIndex(for: position)
                    ?? (freshVC as? any PageIndexProviding)?.globalPageIndex
                    ?? fallbackPage
            } else {
                targetPage = fallbackPage
                freshVC = engine.pageViewController(at: targetPage)
            }
            let prepareLine =
                "[StartupTrace][ReaderView.Coordinator] handleChapterReady targetPage=\(targetPage) fallbackPage=\(fallbackPage)"
            print(prepareLine)
            NSLog("%@", prepareLine)

            var direction: UIPageViewController.NavigationDirection
            if let first = pageViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) {
                direction = targetPage >= first.globalPageIndex ? .forward : .reverse
            } else {
                direction = .forward
            }
            if isRTL { direction = direction == .forward ? .reverse : .forward }

            pageViewController.setViewControllers([freshVC], direction: direction, animated: false)
            applyPlaybackHighlight(to: freshVC)
            let resolved = syncStablePosition(afterShowing: freshVC, notifyFallback: false)
            let resolvedLine =
                "[StartupTrace][ReaderView.Coordinator] handleChapterReady syncedPage=\(resolved ?? -1)"
            print(resolvedLine)
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

        private func continueQueuedTransitionIfNeeded(
            on pageViewController: UIPageViewController,
            showing visiblePage: Int
        ) {
            guard let queuedPage = transitionQueue.transitionFinished(showing: visiblePage) else { return }
            var direction: UIPageViewController.NavigationDirection =
                queuedPage >= visiblePage ? .forward : .reverse
            if isRTL { direction = direction == .forward ? .reverse : .forward }
            let shouldAnimate = (pageTurnStyle != .none) && abs(queuedPage - visiblePage) == 1
            performProgrammaticTransition(
                on: pageViewController,
                to: queuedPage,
                direction: direction,
                animated: shouldAnimate
            )
        }

        fileprivate func performProgrammaticTransition(
            on pageViewController: UIPageViewController,
            to targetPage: Int,
            direction: UIPageViewController.NavigationDirection,
            animated: Bool
        ) {
            let targetViewController = currentEngine.pageViewController(at: targetPage)
            applyPlaybackHighlight(to: targetViewController)
            let finishTransition: (UIViewController) -> Void = { shownViewController in
                if let resolvedPage = self.syncStablePosition(afterShowing: shownViewController, notifyFallback: true) {
                    Task { @MainActor in
                        self.currentEngine.warmUpNext(currentGlobalPage: resolvedPage)
                    }
                    self.continueQueuedTransitionIfNeeded(on: pageViewController, showing: resolvedPage)
                } else {
                    self.continueQueuedTransitionIfNeeded(on: pageViewController, showing: targetPage)
                }
            }

            ProgrammaticPageTransitionPerformer(pageTurnStyle: pageTurnStyle).perform(
                on: pageViewController,
                targetViewController: targetViewController,
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
            // Mirror the data source swap: swipe left-to-right = "before" = next page.
            // Tap left side → same as swiping left → next page.  Tap right → prev page.
            if isRTL {
                zone = rawZone == "left" ? "right" : rawZone == "right" ? "left" : "center"
            } else {
                zone = rawZone
            }
            DispatchQueue.main.async { self.onTapZone(zone) }
        }

        func captureStablePosition(from viewController: UIViewController) {
            currentCoreTextPosition = readingPosition(from: viewController)
        }

        func applyPlaybackHighlight(to viewController: UIViewController) {
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
                let viewController = currentEngine.pageViewController(for: position)
                guard !(viewController is PlaceholderPageViewController) else { return nil }
                return (viewController, page)
            case .page(let page):
                guard page >= 0, page < currentEngine.totalPages else { return nil }
                let viewController = currentEngine.pageViewController(at: page)
                guard !(viewController is PlaceholderPageViewController) else { return nil }
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
                viewController = currentEngine.pageViewController(for: position)
                pageDescription = "\(position)"
            case .page(let page):
                viewController = currentEngine.pageViewController(at: page)
                pageDescription = "page=\(page)"
            }

            if viewController is PlaceholderPageViewController {
                pendingNavigation = PendingNavigation(target: target)
                print("[FlipTrace] navigation \(mode) placeholder target=\(pageDescription)")
                return mode.allowsPlaceholder ? viewController : nil
            }

            pendingNavigation = nil
            applyPlaybackHighlight(to: viewController)
            return viewController
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
            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex > 0 else { return nil }
            let (currentSpine, currentLocal) = currentEngine.localPosition(for: vc.globalPageIndex)
            if currentLocal == 0 && currentSpine > 0 {
                print("[FlipTrace] pageBackward crossing chapter fromSpine=\(currentSpine) page=\(vc.globalPageIndex) toSpine=\(currentSpine - 1)")
                let targetPosition = CoreTextReadingPosition.chapterEnd(currentSpine - 1)
                let previousVC = navigationViewController(
                    for: .position(targetPosition),
                    mode: .interactiveTurn
                )
                print("[FlipTrace] pageBackward landing type=\(previousVC.map { "\(type(of: $0))" } ?? "nil") page=\((previousVC as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
                return previousVC
            }
            let previousVC = navigationViewController(
                for: .page(vc.globalPageIndex - 1),
                mode: .interactiveTurn
            )
            print("[FlipTrace] pageBackward sameChapter fromPage=\(vc.globalPageIndex) landingType=\(previousVC.map { "\(type(of: $0))" } ?? "nil") page=\(vc.globalPageIndex - 1)")
            return previousVC
        }

        private func pageForward(from viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex < currentEngine.totalPages - 1 else { return nil }
            let (currentSpine, _) = currentEngine.localPosition(for: vc.globalPageIndex)
            if let lastPage = currentEngine.lastPageIndex(ofChapter: currentSpine),
               vc.globalPageIndex == lastPage {
                print("[FlipTrace] pageForward crossing chapter fromSpine=\(currentSpine) page=\(vc.globalPageIndex) toSpine=\(currentSpine + 1)")
                let nextPosition = CoreTextReadingPosition.chapterStart(currentSpine + 1)
                if pageTurnStyle != .curl,
                   let targetPage = currentEngine.pageIndex(for: nextPosition),
                   let snapVC = currentEngine.snapshotViewController(at: targetPage) {
                    print("[FlipTrace] pageForward snapshot landing page=\(targetPage) type=\(type(of: snapVC))")
                    return snapVC
                }
                let nextVC = navigationViewController(
                    for: .position(nextPosition),
                    mode: .interactiveTurn
                )
                print("[FlipTrace] pageForward realOrPlaceholder landing type=\(nextVC.map { "\(type(of: $0))" } ?? "nil") page=\((nextVC as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
                return nextVC
            }
            let nextIndex = vc.globalPageIndex + 1
            if pageTurnStyle != .curl,
               let snapVC = currentEngine.snapshotViewController(at: nextIndex) {
                print("[FlipTrace] pageForward snapshot landing page=\(nextIndex) type=\(type(of: snapVC))")
                return snapVC
            }
            let nextVC = navigationViewController(for: .page(nextIndex), mode: .interactiveTurn)
            print("[FlipTrace] pageForward sameChapter fromPage=\(vc.globalPageIndex) landingType=\(nextVC.map { "\(type(of: $0))" } ?? "nil") page=\(nextIndex)")
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
                    pvc.setViewControllers([current], direction: .forward, animated: false)
                }
                return .max
            }
            return .min
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            transitionQueue.beginInteractiveTransition()
            if pageTurnStyle == .curl {
                isCurlTransitionActive = true
            }
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            print("[CurlTrace] didFinish completed=\(completed) visible=\((pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1) binding=\(currentPage)")

            defer {
                if pageTurnStyle == .curl {
                    isCurlTransitionActive = false
                }
                if pendingCurlRefresh {
                    pendingCurlRefresh = false
                    handleChapterReady(on: pvc)
                }
            }

            guard completed else {
                let settledPage = (pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex
                    ?? currentPage
                continueQueuedTransitionIfNeeded(on: pvc, showing: settledPage)
                return
            }

            // Snapshot replacement is unsafe for curl: the page curl animation internally
            // uses current/target/back side/under-page views, and replacing during or
            // immediately after curl can corrupt the transition state.
            if pageTurnStyle != .curl,
               let snapVC = pvc.viewControllers?.first as? SnapshotPageViewController {
                print("[FlipTrace] didFinish landing SNAPSHOT page=\(snapVC.globalPageIndex)")
                let realVC: UIViewController
                if let position = snapVC.coreTextReadingPosition {
                    realVC = currentEngine.pageViewController(for: position)
                } else {
                    realVC = currentEngine.pageViewController(at: snapVC.globalPageIndex)
                }
                print("[FlipTrace] didFinish replaceSnapshot realType=\(type(of: realVC)) page=\((realVC as? (any PageIndexProviding & UIViewController))?.globalPageIndex ?? -1)")
                applyPlaybackHighlight(to: realVC)
                pvc.setViewControllers([realVC], direction: .forward, animated: false)
                if let resolvedPage = syncStablePosition(afterShowing: realVC, notifyFallback: false) {
                    Task { @MainActor in
                        currentEngine.warmUpNext(currentGlobalPage: resolvedPage)
                    }
                    continueQueuedTransitionIfNeeded(on: pvc, showing: resolvedPage)
                } else {
                    continueQueuedTransitionIfNeeded(on: pvc, showing: snapVC.globalPageIndex)
                }
                return
            }

            guard let vc = pvc.viewControllers?.first as? any PageIndexProviding & UIViewController else { return }
            print("[FlipTrace] didFinish landing type=\(type(of: vc)) page=\(vc.globalPageIndex)")
            if let resolvedPage = syncStablePosition(afterShowing: vc, notifyFallback: false) {
                Task { @MainActor in
                    currentEngine.warmUpNext(currentGlobalPage: resolvedPage)
                }
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
                coverDirection = 0
                // Cancel any previous in-flight animation; don't show overlay until direction is confirmed.
                coverOverlayView.layer.removeAllAnimations()
                coverIncomingImageView.layer.removeAllAnimations()
                coverDimView.layer.removeAllAnimations()
                coverDimView.alpha = 0

            case .changed:
                if coverTargetPage == nil {
                    if translationX < -GestureConstants.initialTranslationThreshold, currentPage < currentEngine.totalPages - 1 {
                        // Forward uncover: current page slides left, new page underneath.
                        coverDirection = 1
                        let target = currentPage + 1
                        guard currentEngine.renderSnapshot(forPage: target) != nil else {
                            let targetVC = currentEngine.pageViewController(at: target)
                            if targetVC is PlaceholderPageViewController {
                                pendingNavigation = PendingNavigation(target: .page(target))
                                print("[FlipTrace] coverInteractive forward blocked placeholder targetPage=\(target)")
                            }
                            return
                        }
                        coverTargetPage = target
                        coverOverlayView.frame = view.bounds
                        coverCurrentImageView.frame = view.bounds
                        coverOverlayView.isHidden = false
                        setupForwardOutgoing(currentPageSnapshot: currentPage, newPage: target, in: view)
                    } else if translationX > GestureConstants.initialTranslationThreshold, currentPage > 0 {
                        // Backward cover: previous page covers in from the left.
                        let target = currentPage - 1
                        // Don't start animation if snapshot is not ready (chapter not loaded).
                        guard let targetSnapshot = currentEngine.renderSnapshot(forPage: target) else { return }
                        coverDirection = -1
                        coverTargetPage = target
                        coverOverlayView.frame = view.bounds
                        coverCurrentImageView.frame = view.bounds
                        coverCurrentImageView.image = currentEngine.renderSnapshot(forPage: currentPage)
                        coverOverlayView.isHidden = false
                        setupIncomingView(for: target, snapshot: targetSnapshot, in: view)
                    }
                }
                guard coverTargetPage != nil else { return }
                let rawProgress = min(max(abs(translationX) / width, 0), 0.999)
                let newX: CGFloat = coverDirection == 1
                    ? -rawProgress * width
                    : -width * (1 - rawProgress)
                coverIncomingImageView.frame.origin.x = newX
                coverShadowView.frame.origin.x = newX
                if coverDirection == -1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = rawProgress * GestureConstants.maxDimmingAlpha
                } else if coverDirection == 1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = (1 - rawProgress) * GestureConstants.maxDimmingAlpha
                }

            case .ended, .cancelled, .failed:
                guard let targetPage = coverTargetPage else {
                    resetCoverOverlay()
                    return
                }
                let progress = min(max(abs(translationX) / width, 0), 1)
                let shouldCommit = progress > GestureConstants.commitProgressRatio || abs(velocityX) > GestureConstants.commitVelocityThreshold
                isTransitioning = true

                UIView.animate(withDuration: GestureConstants.settleAnimationDuration, delay: 0, options: [.curveEaseOut]) {
                    let destX: CGFloat = self.coverDirection == 1
                        ? (shouldCommit ? -width : 0)
                        : (shouldCommit ? 0 : -width)
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    if self.coverDirection == -1 {
                        self.coverDimView.alpha = shouldCommit ? GestureConstants.maxDimmingAlpha : 0
                    } else if self.coverDirection == 1 {
                        self.coverDimView.alpha = shouldCommit ? 0 : GestureConstants.maxDimmingAlpha
                    }
                } completion: { _ in
                    if shouldCommit {
                        var settledPosition: CoreTextReadingPosition?
                        // Set the real VC immediately so updateUIViewController returns early, avoiding double animation.
                        if let pvc = self.coverPageViewController {
                            let realVC = self.currentEngine.pageViewController(at: targetPage)
                            print("[FlipTrace] coverInteractive commit targetPage=\(targetPage) realType=\(type(of: realVC))")
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
                        Task { @MainActor in
                            self.currentEngine.warmUpNext(currentGlobalPage: targetPage)
                        }
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
            if currentEngine.renderSnapshot(forPage: targetPage) == nil {
                let targetVC = currentEngine.pageViewController(at: targetPage)
                if targetVC is PlaceholderPageViewController {
                    pendingNavigation = PendingNavigation(target: .page(targetPage))
                    print("[FlipTrace] coverProgrammatic blocked placeholder targetPage=\(targetPage)")
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

            if direction == .forward {
                setupForwardOutgoing(currentPageSnapshot: oldPage, newPage: targetPage, in: view)
                coverDimView.alpha = 0.35
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    self.coverIncomingImageView.frame.origin.x = -width
                    self.coverShadowView.frame.origin.x = -width
                    self.coverDimView.alpha = 0
                } completion: { _ in
                    // Capture the latest binding value.
                    let latestPage = self.currentPage
                    let realVC = self.currentEngine.pageViewController(at: latestPage)
                    print("[FlipTrace] coverProgrammatic forward latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    Task { @MainActor in self.currentEngine.warmUpNext(currentGlobalPage: latestPage) }

                    self.resetCoverOverlay()
                    self.isTransitioning = false
                }
            } else {
                // Backward cover: previous page covers in from the left, right rounded corners, shadow falls left onto the old page.
                guard let targetSnapshot = currentEngine.renderSnapshot(forPage: targetPage) else {
                    let latestPage = self.currentPage
                    let realVC = currentEngine.pageViewController(at: latestPage)
                    print("[FlipTrace] coverProgrammatic backward snapshotMiss targetPage=\(targetPage) latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    self.captureStablePosition(from: realVC)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    Task { @MainActor in self.currentEngine.warmUpNext(currentGlobalPage: latestPage) }
                    self.resetCoverOverlay()
                    self.isTransitioning = false
                    return
                }
                coverCurrentImageView.image = currentEngine.renderSnapshot(forPage: oldPage)
                setupIncomingView(for: targetPage, snapshot: targetSnapshot, in: view)
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    self.coverIncomingImageView.frame.origin.x = 0
                    self.coverShadowView.frame.origin.x = 0
                    self.coverDimView.alpha = 0.3
                } completion: { _ in
                    let latestPage = self.currentPage
                    let realVC = self.currentEngine.pageViewController(at: latestPage)
                    print("[FlipTrace] coverProgrammatic backward latestPage=\(latestPage) realType=\(type(of: realVC))")
                    self.applyPlaybackHighlight(to: realVC)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC)
                    self.publishCurrentPage(
                        latestPage,
                        position: self.readingPosition(from: realVC),
                        notify: true
                    )
                    Task { @MainActor in self.currentEngine.warmUpNext(currentGlobalPage: latestPage) }

                    self.resetCoverOverlay()
                    self.isTransitioning = false
                }
            }
        }

        private func showCurrentSnapshot(page: Int, on view: UIView) {
            coverOverlayView.frame = view.bounds
            coverCurrentImageView.frame = view.bounds
            coverCurrentImageView.image = currentEngine.renderSnapshot(forPage: page)
            coverOverlayView.isHidden = false
        }

        private func setupForwardOutgoing(currentPageSnapshot: Int, newPage: Int, in view: UIView) {
            let width = max(view.bounds.width, 1)
            let h = view.bounds.height
            // New page as static background.
            coverCurrentImageView.image = currentEngine.renderSnapshot(forPage: newPage)
            coverCurrentImageView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            // Current page slides left from x=0, right rounded corners (the last visible edge), shadow falls right onto new page.
            coverIncomingImageView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            coverIncomingImageView.image = currentEngine.renderSnapshot(forPage: currentPageSnapshot)
            coverIncomingImageView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            coverShadowView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            coverShadowView.layer.shadowOffset = CGSize(width: 10, height: 0)
            coverShadowView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            coverShadowView.layer.shadowPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: h)).cgPath
            coverDimView.frame = CGRect(x: 0, y: 0, width: width, height: h)
        }

        private func setupIncomingView(for targetPage: Int, snapshot: UIImage?, in view: UIView) {
            let width = max(view.bounds.width, 1)
            let h = view.bounds.height
            coverIncomingImageView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            coverIncomingImageView.image = snapshot
            coverIncomingImageView.frame = CGRect(x: -width, y: 0, width: width, height: h)
            coverShadowView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            coverShadowView.layer.shadowOffset = CGSize(width: -10, height: 0)
            coverShadowView.frame = CGRect(x: -width, y: 0, width: width, height: h)
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
            coverDirection = 0
        }
    }
}

// MARK: - onChange helper

extension View {
    func onChanged<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        self.onChange(of: value) { _, newValue in action(newValue) }
    }
}
