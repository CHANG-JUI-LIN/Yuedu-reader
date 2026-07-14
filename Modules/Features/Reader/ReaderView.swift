import Combine
import SwiftUI
import UIKit

let uiFeedbackDuration: Double = 0.25

// MARK: - Main Reader View
struct ReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) var dependencies
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.readerNavigator) var readerNavigator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject var settings = GlobalSettings.shared
    @ObservedObject var subscriptionStore = SubscriptionStore.shared
    @StateObject var readerConfig = ReaderConfig.shared

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


    @State var chapters: [BookChapter] = []
    @State var allPages: [PageContent] = []
    @State var currentPage = 0
    // Phase-2 explicit page-turn intent channel (see ReaderPageTurnCommand).
    @State var pageTurnCommand: ReaderPageTurnCommand?
    @State var pageTurnVersion: UInt = 0
    @State var showBars = false
    @State var appleBooksActivePanel: AppleBooksReaderControlPanel?
    @State var showSettings = false
    @State var showQuickThemePanel = false
    @State var showReaderSearch = false
    @State var showTOC = false
    @State var readerMenuTab: ReaderMenuView.Tab = .toc
    @State var showTouchZoneEditor = false

    // Online chapter lazy loading
    @StateObject var readerViewModel = ReaderViewModel()
    @State var observedChapterStates: [Int: ChapterLoadState] = [:]
    @State var hasParagraphReviews = false

    /// Top safe area (points), passed to EPUB engine as minimum margin-top.
    @State var readerSafeAreaTop: CGFloat = 59
    @State var readerViewportSize: CGSize = UIScreen.main.bounds.size
    @StateObject private var volumeHandler = VolumeKeyHandler()

    @StateObject private var autoReader = AutoReadController()
    @StateObject var ttsCoordinator = TTSCoordinator()
    @StateObject var mediaOverlayCoordinator = EPUBMediaOverlayPlaybackCoordinator()
    /// Plays an EPUB chapter's authored background soundtrack (controls-less autoplay/loop `<audio>`).
    @State var backgroundAudioCoordinator = EPUBBackgroundAudioCoordinator()
    /// The active EPUB publication session, retained so the background-audio coordinator can read chapter
    /// HTML and resolve resource URLs on chapter change.
    @State var activePublicationSession: PublicationSession?

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

    @StateObject var epubRenderer = EPUBPageRenderer()

    @State var showTTSPanel = false
    @State var showDownloadOptions = false
    @State var showOnlineBookDetail = false
    @State private var showAutoReadPanel = false
    @State var ttsChapterIndex: Int? = nil
    @State var showTTSJumpPrompt = false
    @State var ttsJumpPromptChapterIndex: Int? = nil
    @State var ttsPlaybackAnchor: CoreTextReadingPosition?
    @State var isAligningReaderToTTSAnchor = false
    @State var showMediaOverlayPanel = false
    @State var activeMediaOverlayChapterIndex: Int? = nil

    @State var currentChapterIndex = 0

    // Scroll mode progress tracking
    @State var scrollVisibleChapter = 0
    @State var scrollResliceToken: UInt = 0
    @State var pendingScrollJumpTarget: CoreTextReadingPosition?

    @State var readerSessionCoordinator: ReaderSessionCoordinator?
    @State var readingStatsTracker: ReadingStatsSessionTracker?

    @State var isRestoringPosition = true
    @State var savedCoreTextRestoreTarget: (chapterIndex: Int, charOffset: Int)?
    @State private var isApplyingCoreTextRestore = false
    @State var isLoadingPipeline = false
    @State private var curlStartupStartedAt: CFAbsoluteTime?
    @State private var hasLoggedCurlInteractiveReady = false
    @State private var hasPerformedInitialLoad = false
    @State var activeFixedLayoutOrientationRequest: FixedLayoutOrientation?

    // Source change
    @State var showChangeSourceSheet = false
    @State private var replaceRuleDraft: ReplaceRule?
    @State var reviewTarget: ReaderHTMLUtilities.ReviewTarget?
    @State var footnoteItem: ReaderFootnoteItem?
    @State private var coreTextExternalTargetVersion: UInt = 0
    @State var bookDocument: (any BookDocument)? = nil
    @State var contentProvider: (any BookContentProvider)? = nil
    @State var readerCapabilities: ReaderCapabilities = .reflowableText

    /// Snapshot of the book at reader launch, so we can re-add it to the shelf
    /// if it was deleted during the reading session.
    @State var snapshotBook: ReadingBook?
    @State var showAddToShelfAlert = false

    // Source change state managed by ViewModel, exposed via computed properties to avoid duplicate state in the view.
    var changeSourceOrigins: [BookOrigin] { readerViewModel.changeSourceOrigins }
    var changeSourceLoading: Bool { readerViewModel.changeSourceLoading }
    var changeSourceError: String? { readerViewModel.changeSourceError }
    var changeSourceFailedKeys: Set<String> { readerViewModel.changeSourceFailedKeys }

    @State private var systemBrightness: Double = 0.5

    var fontSize: CGFloat {
        get { readerConfig.fontSize }
        nonmutating set { readerConfig.fontSize = newValue }
    }

    var readerTheme: ReaderTheme {
        get { readerConfig.theme }
        nonmutating set { readerConfig.theme = newValue }
    }

    /// The imported image is the reader surface itself, not a SwiftUI decoration
    /// behind an opaque CoreText page. The same URL is passed into render settings
    /// so every paged canvas draws it beneath the text.
    var activeReaderBackgroundImageURL: URL? {
        guard settings.readerCustomBackgroundMode == .image,
              let url = settings.readerCustomBackgroundImageURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private var activeReaderBackgroundImage: UIImage? {
        guard let url = activeReaderBackgroundImageURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var readerScrollBackgroundColor: UIColor {
        activeReaderBackgroundImageURL == nil ? readerTheme.uiBackgroundColor : .clear
    }

    @ViewBuilder
    var readerSurfaceBackground: some View {
        // Keep decorative pixels out of layout measurement. A tall image used
        // as a ZStack child reports its aspect-sized height and pushes reader
        // chrome beyond both viewport edges; an overlay inherits the color's
        // already-constrained reader surface instead.
        readerTheme.backgroundColor
            .overlay {
                if let image = activeReaderBackgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    /// When "follow system" theme is on, align the reader theme with the current
    /// system light/dark appearance. Setting `readerConfig.theme` triggers the
    /// `.appearance` refresh through `ReaderConfig`'s binding, so pages recolor.
    func applyFollowSystemThemeIfNeeded() {
        guard settings.readerFollowSystemTheme else { return }
        let desired = ReaderTheme.forSystem(dark: systemColorScheme == .dark)
        if readerConfig.theme != desired {
            readerConfig.theme = desired
        }
    }

    /// Applies the selected app appearance theme to the reader only when the
    /// user explicitly enables "bind reading theme" in Settings.
    func syncActiveThemePreset() {
        let preset: AppearanceThemePreset?
        if let customBackgroundPreset = settings.readerCustomBackgroundPreset {
            preset = customBackgroundPreset
        } else if settings.appearanceBindReaderTheme {
            preset = settings.appearanceTheme(
                for: systemColorScheme,
                isProActive: subscriptionStore.hasAccess(.readerThemePacks)
            )
        } else {
            preset = nil
        }
        guard AppearanceThemePreset.activeReaderTheme != preset else { return }
        AppearanceThemePreset.activeReaderTheme = preset
        readerConfig.refresh.send(.appearance)
    }

    var usesReadableReaderWidth: Bool {
        horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad
    }

    var overlayContentMaxWidth: CGFloat {
        usesReadableReaderWidth ? DSLayout.readableOverlayWidth : .infinity
    }

    var extraReaderHorizontalInset: CGFloat {
        usesReadableReaderWidth ? DSLayout.readerRegularExtraHorizontalInset : 0
    }

    var effectivePageMarginH: CGFloat {
        readerConfig.pageMarginH + extraReaderHorizontalInset
    }

    var effectiveReaderSpreadMode: ReaderSpreadMode {
        ReaderSpreadPolicy.effectiveMode(
            preferredMode: settings.readerSpreadMode,
            viewportSize: readerViewportSize,
            horizontalSizeClassIsRegular: horizontalSizeClass == .regular,
            idiom: UIDevice.current.userInterfaceIdiom,
            isScrollMode: effectiveScrollMode,
            fixedLayoutSpread: usesFixedLayoutRenderer ? epubRenderer.fixedLayoutSpread : nil,
            fixedLayoutOrientation: usesFixedLayoutRenderer ? epubRenderer.fixedLayoutOrientation : nil
        )
    }

    var isDoublePageSpreadActive: Bool {
        effectiveReaderSpreadMode == .doublePage
    }

    var readerPageStep: Int {
        isDoublePageSpreadActive ? 2 : 1
    }

    func nextReaderPage(after page: Int, maxPage: Int) -> Int {
        if isDoublePageSpreadActive,
           let pairingProvider = epubRenderer.engine as? FixedLayoutSpreadPairingProviding,
           let next = pairingProvider.nextFixedLayoutSpreadPage(after: page) {
            return min(maxPage, next)
        }
        return min(maxPage, page + readerPageStep)
    }

    func previousReaderPage(before page: Int) -> Int {
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
    var effectivePageTurnStyle: PageTurnStyle {
        isDoublePageSpreadActive && settings.pageTurnStyle == .curl ? .slide : settings.pageTurnStyle
    }

    private var readerPageViewIdentity: String {
        // Include the render size so a device rotation that keeps the same spread mode (e.g.
        // single-page portrait↔landscape) still recreates the paged view. Otherwise the existing
        // page views are reused with their old `layout.renderSize`, and CoreTextPageView scales the
        // stale CTFrame to the new bounds → text renders narrow. (Double-page rotation already
        // recreates because the spread mode toggles, which is why it never showed this bug.)
        let size = currentReaderRenderSize
        return "\(effectivePageTurnStyle.rawValue)-\(effectiveReaderSpreadMode.rawValue)-\(Int(size.width))x\(Int(size.height))"
    }

    var currentReaderRenderSize: CGSize {
        readerRenderSize(forViewport: readerViewportSize)
    }

    private func readerRenderSize(forViewport viewportSize: CGSize) -> CGSize {
        guard effectiveReaderSpreadMode == .doublePage else { return viewportSize }
        return CGSize(
            width: max(1, (viewportSize.width - DSLayout.readerSpreadGutter) / 2),
            height: max(1, viewportSize.height)
        )
    }

    var systemVerticalPadding: CGFloat {
        ReaderLayoutMetrics.minimumVerticalPadding
    }

    /// Extra offset that CoreText paginator's grid alignment adds to the bottom
    /// content inset. Footer overlay must shift up by this amount so the visual
    /// gap matches `footerTextGap + footerBottomPadding`.
    var gridAdjustment: CGFloat {
        let topInset = ReaderLayoutMetrics.topInset(
            safeTop: effectiveReaderSafeTop,
            headerVisible: readerConfig.readerHeaderVisible && !effectiveScrollMode,
            headerTopPadding: readerConfig.readerHeaderTopPadding,
            headerTextGap: readerConfig.readerHeaderTextGap
        )
        let footerVisible = readerConfig.readerFooterVisible && !effectiveScrollMode
        let bottomInset = ReaderLayoutMetrics.bottomInset(
            safeBottom: footerVisible ? 0 : windowSafeBottom,
            footerVisible: footerVisible,
            footerBottomPadding: readerConfig.footerBottomPadding,
            footerTextGap: readerConfig.footerTextGap
        )
        return ReaderLayoutMetrics.gridAdjustment(
            viewHeight: currentReaderRenderSize.height,
            topInset: topInset,
            bottomInset: bottomInset,
            fontSize: readerConfig.fontSize,
            lineSpacing: readerConfig.lineSpacing
        )
    }

    // ── Derived Properties ──
    var book: ReadingBook? { store.books.first(where: { $0.id == bookId }) }

    var onlineBookDetail: OnlineBook? {
        guard let book, book.isOnline, let sourceId = book.bookSourceId else { return nil }
        let source = BookSourceStore.shared.sources.first(where: { $0.id == sourceId })
        return OnlineBook(
            name: book.title,
            author: book.author,
            intro: "",
            coverUrl: book.coverUrl ?? "",
            bookUrl: book.bookInfoURL ?? book.source,
            tocUrl: book.tocURL ?? "",
            wordCount: "",
            lastChapter: book.latestChapterDisplayTitle ?? "",
            kind: "",
            sourceId: sourceId,
            sourceName: source?.bookSourceName ?? "",
            runtimeVariables: book.runtimeVariables
        )
    }

    var isEPUB: Bool {
        book?.resolvedPipelineKind == .epub
    }

    var isTXT: Bool {
        book?.resolvedPipelineKind == .txt
    }

    @State var isVerticalEPUB = false

    var usesCoreTextEPUB: Bool {
        epubRenderer.engine != nil
    }

    var isFixedLayoutEPUB: Bool {
        isEPUB && epubRenderer.layoutMode == .prePaginated
    }

    var usesFixedLayoutRenderer: Bool {
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

    /// Paragraph-review bubbles are detected from rendered review links as well
    /// as freshly fetched source HTML. The latter makes the setting available
    /// as soon as a review-bearing online chapter finishes loading.
    private var currentBookHasParagraphReviews: Bool {
        if hasParagraphReviews {
            return true
        }
        if let engine = epubRenderer.engine,
           engine.layouts.values.contains(where: { containsParagraphReview(in: $0.attributedString) }) {
            return true
        }
        if let scrollEngine = epubRenderer.scrollEngine,
           scrollEngine.chunks.contains(where: { containsParagraphReview(in: $0.attributedString) }) {
            return true
        }
        if let package = cachedChapterPackage(for: currentChapterIndex) {
            return containsParagraphReview(in: package.content)
        }
        return false
    }

    private func containsParagraphReview(in attributedString: NSAttributedString) -> Bool {
        guard attributedString.length > 0 else { return false }
        var containsReview = false
        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.internalLinkAttribute,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            if let link = value as? String,
               link.hasPrefix("\(ReaderHTMLUtilities.reviewURLScheme)://") {
                containsReview = true
                stop.pointee = true
            }
        }
        return containsReview
    }

    func containsParagraphReview(in content: String) -> Bool {
        content.localizedCaseInsensitiveContains("showcmt(")
            || content.localizedCaseInsensitiveContains("\(ReaderHTMLUtilities.reviewURLScheme)://")
    }

    func tocChapter(forSpineIndex spineIndex: Int, charOffset: Int) -> BookChapter? {
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

    func tocPosition(
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

    func onlineChapterRef(for chapterIndex: Int) -> OnlineChapterRef? {
        guard let refs = book?.onlineChapters, refs.indices.contains(chapterIndex) else { return nil }
        return refs[chapterIndex]
    }

    func cachedChapterPackage(for chapterIndex: Int) -> ChapterPackage? {
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

    func isChapterContentAvailable(at chapterIndex: Int) -> Bool {
        // Volume headers (作品相关 / 第N卷 …) render a divider page with no fetched content. Treat
        // them as available, otherwise the "ready but no content" path refetches them forever.
        if let refs = book?.onlineChapters,
           refs.indices.contains(chapterIndex),
           refs[chapterIndex].shouldRenderAsVolumeSeparator {
            return true
        }
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

    var currentChapterOverlayState: ReaderChapterOverlayState {
        guard book?.onlineChapters?.isEmpty == false else { return .hidden }
        return ReaderChapterPresentation.overlayState(
            isContentAvailable: isChapterContentAvailable(at: currentChapterIndex),
            loadState: readerViewModel.chapterState(for: currentChapterIndex)
        )
    }

    var telemetryPipelineKind: String {
        book?.resolvedPipelineKind.rawValue ?? "epub"
    }

    func progressTrace(_ message: String) {
        AppLogger.render("[ProgressTrace][ReaderView][\(bookId.uuidString)] \(message)")
    }

    var currentReaderPresentationState: ReaderPresentationState {
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

    /// Recomputes the reader viewport from the foreground window on a device rotation and drives the
    /// normal relayout path. Needed because SwiftUI doesn't re-evaluate the reader's geometry on
    /// rotation, so the `.background` GeometryReader preference never fires. The window's two
    /// dimensions are stable; only their order changes with orientation, and `interfaceOrientation`
    /// is already correct when this notification fires — so we order them by it (the raw
    /// `window.bounds` may still report the pre-rotation order at this instant).
    func applyRotatedViewportIfNeeded() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }
        let bounds = window.bounds.size
        let longSide = max(bounds.width, bounds.height)
        let shortSide = min(bounds.width, bounds.height)
        guard longSide > 1 else { return }
        let size = scene.interfaceOrientation.isLandscape
            ? CGSize(width: longSide, height: shortSide)
            : CGSize(width: shortSide, height: longSide)
        guard abs(size.width - readerViewportSize.width) > 0.5
            || abs(size.height - readerViewportSize.height) > 0.5
        else { return }
        handleReaderViewportSizeChange(size)
    }

    func handleReaderViewportSizeChange(_ newSize: CGSize) {
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

    func ensureReaderNavigator(initialPosition: CoreTextReadingPosition) {
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

    func moveReaderSession(
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

    func setCoreTextExternalTarget(_ position: CoreTextReadingPosition) {
        readerSessionCoordinator?.setExternalTarget(position)
        coreTextExternalTargetVersion &+= 1
    }

    func clearCoreTextExternalTarget() {
        readerSessionCoordinator?.send(.clearExternalTarget)
        coreTextExternalTargetVersion &+= 1
    }

    func applyReaderEffects(
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

    func coreTextPositionIfLayoutReady(
        engine: any PageRenderingProvider,
        page: Int
    ) -> (spineIndex: Int, charOffset: Int)? {
        let (spineIndex, charOffset) = engine.charOffset(forPage: page)
        guard engine.layouts[spineIndex] != nil else { return nil }
        return (spineIndex, charOffset)
    }

    func scheduleCoreTextPageChanged(
        _ newPage: Int,
        engine: any PageRenderingProvider,
        visiblePosition: CoreTextReadingPosition? = nil
    ) {
        DispatchQueue.main.async {
            handleCoreTextPageChanged(newPage, engine: engine, visiblePosition: visiblePosition)
        }
    }

    func handleCoreTextPageChanged(
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
    let footerOverlayHeight: CGFloat = ReaderLayoutMetrics.footerHeight

    var currentTopBarBookmarkPosition: CoreTextReadingPosition? {
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

    func bookmarkChapterTitle(for chapterIndex: Int) -> String {
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

    var coreTextTextAnnotations: [CoreTextTextAnnotation] {
        (book?.bookmarks ?? []).compactMap(\.coreTextTextAnnotation)
    }

    func syncCoreTextTextAnnotations() {
        let annotations = coreTextTextAnnotations
        epubRenderer.engine?.setTextAnnotations(annotations)
        epubRenderer.scrollEngine?.textAnnotations = annotations
    }

    func addUnderlineBookmark(_ request: CoreTextUnderlineSelectionRequest) {
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

    var activePlaybackHighlightText: String? {
        if mediaOverlayCoordinator.playbackState != .stopped {
            return currentMediaOverlayHighlightText()
        }
        return ttsCoordinator.playbackState == .stopped ? nil : ttsCoordinator.currentSegmentText
    }

    var activeTTSChapterTitle: String {
        let index = ttsChapterIndex ?? currentChapterIndex
        guard chapters.indices.contains(index) else { return currentChapterTitle }
        return chapters[index].title
    }

    var ttsNowPlayingBookTitle: String {
        let title = book?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? activeTTSChapterTitle : title
    }

    var ttsNowPlayingAuthor: String {
        book?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func ttsNowPlayingArtwork() -> UIImage? {
        if let coverPath = book?.coverImagePath,
           let image = loadTOCStyleCoverImage(filename: coverPath) {
            return image
        }
        return makeTOCStyleTitleCardArtwork(title: ttsNowPlayingBookTitle)
    }

    func loadTOCStyleCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func makeTOCStyleTitleCardArtwork(title: String) -> UIImage? {
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
        NavigationStack {
            buildBody()
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    appleBooksToolbarContent
                }
                .toolbar(showsAppleBooksToolbars ? .visible : .hidden, for: .navigationBar)
                .toolbar(showsAppleBooksBottomToolbar ? .visible : .hidden, for: .bottomBar)
                .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
        }
        .tint(readerTheme.textColor)
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
            readerSurfaceBackground
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
                    pageTurnCommand: pageTurnCommand,
                    clearExternalTargetPosition: {},
                    currentPage: $currentPage,
                    onPageChanged: { newPage, _ in
                        currentPage = newPage
                    },
                    onTapZone: handleTouchAction,
                    onSwipeUpExit: { closeReader() }
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
                        readerSurfaceBackground
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
                    pageTurnCommand: pageTurnCommand,
                    clearExternalTargetPosition: { clearCoreTextExternalTarget() },
                    currentPage: $currentPage,
                    onPageChanged: { newPage, visiblePosition in
                        scheduleCoreTextPageChanged(newPage, engine: ctEngine, visiblePosition: visiblePosition)
                    },
                    onTapZone: handleTouchAction,
                    onFootnoteTap: { text in
                        footnoteItem = ReaderFootnoteItem(text: text)
                    },
                    onSwipeUpExit: { closeReader() }
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
                if readerConfig.readerFooterVisible {
                    VStack {
                        Spacer()
                        bottomFooter
                    }
                    .padding(.bottom, gridAdjustment)
                    .ignoresSafeArea(.all, edges: .bottom)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
                topHeader
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            if showBars { readerChrome }
            if showBars,
               settings.appearanceReaderInterface == .appleBooks,
               appleBooksActivePanel != nil {
                appleBooksControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(60)
            }
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
            // Always present (even with the reader bars hidden); it self-hides when
            // nothing is playing. `barsVisible` lets it lift above the bottom toolbar
            // when the bars appear, and drop lower while they're hidden.
            NowPlayingMiniPlayer(placement: .reader, barsVisible: showBars)
                .zIndex(50)

            if showTouchZoneEditor {
                ReaderTouchZoneEditorView(
                    onCancel: { showTouchZoneEditor = false },
                    onSave: { showTouchZoneEditor = false }
                )
                .zIndex(100)
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
        // iPad rotation fix: SwiftUI does NOT re-evaluate the reader's geometry on rotation, so the
        // `.background` GeometryReader / `onPreferenceChange` above never fires and the spread mode
        // stays frozen (single/double only switches on a fresh reader entry). The device-orientation
        // notification DOES fire reliably; derive the settled viewport from the window's two
        // dimensions ordered by the (already-updated) interface orientation, and drive the same
        // relayout path the in-app single/double toggle uses.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            applyRotatedViewportIfNeeded()
        }
        .animation(.easeInOut(duration: 0.25), value: chapters.isEmpty)
        .statusBarHidden(!showBars)
        .animation(.easeInOut(duration: 0.25), value: showBars)
        .modifier(HideTabBarModifier())
        .alert(String(format: localized("將「%@」加入書架？"), snapshotBook?.title ?? ""), isPresented: $showAddToShelfAlert) {
            Button(localized("加入書架")) {
                if let snap = snapshotBook {
                    store.addOnlineBook(
                        name: snap.title,
                        author: snap.author,
                        sourceId: snap.bookSourceId ?? UUID(),
                        bookInfoURL: snap.bookInfoURL ?? "",
                        tocURL: snap.tocURL,
                        coverUrl: snap.coverUrl ?? "",
                        runtimeVariables: snap.runtimeVariables,
                        chapters: snap.onlineChapters ?? []
                    )
                }
                dismissReaderPresentation()
            }
            Button(localized("不加入"), role: .cancel) {
                dismissReaderPresentation()
            }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
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
            syncActiveThemePreset()
            applyFollowSystemThemeIfNeeded()
            if !hasPerformedInitialLoad {
                snapshotBook = book
                hasPerformedInitialLoad = true
                performInitialLoad()
            } else {
                snapshotBook = book
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
            // Allow the in-reader mini-player the whole time the reader is on screen,
            // independent of the bars — bar visibility only repositions it now.
            setTTSFloatingOverlayVisible(true)
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
        .onChanged(of: systemColorScheme) { _ in
            applyFollowSystemThemeIfNeeded()
            syncActiveThemePreset()
        }
        .onChanged(of: settings.readerFollowSystemTheme) { _ in
            applyFollowSystemThemeIfNeeded()
        }
        .onChanged(of: settings.appearanceThemeID) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.appearanceDarkThemeID) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.appearanceUsesSeparateDarkTheme) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.appearanceBindReaderTheme) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.readerCustomBackgroundMode) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.readerCustomBackgroundColorHex) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.readerCustomBackgroundImageFileName) { _ in
            syncActiveThemePreset()
        }
        .onChanged(of: settings.commentBubbleFollowsSourceSVG) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.commentBubblePresetMode) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.commentBubbleCustomStyles) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.commentBubbleSelectedCustomStyleID) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.commentBubbleScale) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.commentBubbleTextScale) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.readerTextUnderlineDecorationEnabled) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.readerTextUnderlineDecorationColorHex) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.readerDialogueHighlightEnabled) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.readerDialogueHighlightColorHex) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.readerDialogueBoxEnabled) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.readerDialogueBoxColorHex) { _ in
            forceReaderRenderableContentRefresh()
        }
        .onChanged(of: settings.customAppearanceThemes) { _ in
            syncActiveThemePreset()
        }
        .onReceive(subscriptionStore.$isProActive) { _ in
            syncActiveThemePreset()
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
        .onReceive(NotificationCenter.default.publisher(for: .coreTextReplaceSelectionRequested)) { notification in
            guard let request = notification.userInfo?["request"] as? CoreTextReplaceSelectionRequest else { return }
            let currentBook = book ?? snapshotBook
            let sourceURL = currentBook?.bookSourceId.flatMap { sourceID in
                BookSourceStore.shared.sources.first(where: { $0.id == sourceID })?.bookSourceUrl
            }
            replaceRuleDraft = ReplaceSelectionDraft.makeRule(
                selectedText: request.selectedText,
                scope: sourceURL ?? "global"
            )
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
        .onChanged(of: settings.readerWritingMode) { writingMode in
            if !isEPUB, (book ?? snapshotBook)?.allowsVerticalWritingMode == true {
                readerNavigator?.updateOpeningDirection(
                    ReaderBookOpeningDirection.resolve(
                        writingMode: writingMode,
                        pageProgressionIsRTL: false
                    )
                )
            }
            handleReaderConfigRefresh(.layout)
        }
        .onChanged(of: effectiveReaderSpreadMode) { _ in
            readerSessionCoordinator?.send(.updateSpreadMode(effectiveReaderSpreadMode))
            performUnifiedRelayout(targetSize: currentReaderRenderSize)
        }
        .onChanged(of: book?.bookmarks ?? []) { _ in
            syncCoreTextTextAnnotations()
        }
        .onChanged(of: currentChapterIndex) { _ in
            handleReaderPositionChangedForTTS()
        }
        .onChanged(of: currentPage) { _ in
            updateReadingStatsPosition()
            handleReaderPositionChangedForTTS()
        }
        .onChanged(of: ttsCoordinator.currentSegmentIndex) { _ in
            // Auto page-turn while listening: follow the spoken sentence.
            followTTSPlaybackHighlight()
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
                    isVerticalWritingMode: effectiveWritingMode.isVertical,
                    hasParagraphReviews: currentBookHasParagraphReviews,
                    onOpenTouchZoneEditor: {
                        guard subscriptionStore.isProActive, !effectiveScrollMode else { return }
                        showBars = false
                        showTouchZoneEditor = true
                    }
                )
            }
        }
        .sheet(isPresented: $showQuickThemePanel) {
            ReaderQuickThemePanelView(
                fontSize: Binding(
                    get: { fontSize },
                    set: { fontSize = $0 }
                ),
                readerTheme: Binding(
                    get: { readerTheme },
                    set: { readerTheme = $0 }
                ),
                pageTurnOption: quickPageTurnOption,
                isVerticalWritingMode: effectiveWritingMode.isVertical,
                onSelectPageTurnOption: { applyQuickPageTurnOption($0) },
                onCustomize: {
                    showQuickThemePanel = false
                    DispatchQueue.main.async {
                        showSettings = true
                    }
                },
                onClose: { showQuickThemePanel = false }
            )
            .presentationDetents([.height(DSLayout.readerQuickPanelSheetHeight)])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showReaderSearch) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                ReaderBookSearchView(
                    items: readerSearchItems,
                    onSelect: { item in
                        showReaderSearch = false
                        showBars = false
                        issuePageTurn(to: item.pageIndex)
                    },
                    onClose: { showReaderSearch = false }
                )
            }
        }
        .sheet(isPresented: $showDownloadOptions) {
            if let b = book {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                    ReaderDownloadOptionsView(
                        bookId: b.id,
                        bookTitle: b.title,
                        currentChapterIndex: currentChapterIndex,
                        totalChapters: b.onlineChapters?.count ?? chapters.count,
                        onStart: { startChapterIndex, chapterCount in
                            startOfflineDownload(
                                startChapterIndex: startChapterIndex,
                                chapterCount: chapterCount
                            )
                        },
                        onPause: { pauseOfflineDownload() },
                        onResume: { resumeOfflineDownload() },
                        onRemove: {
                            store.clearOnlineDownload(bookId: b.id)
                            showDownloadOptions = false
                        },
                        onClose: { showDownloadOptions = false }
                    )
                    .environmentObject(store)
                }
            }
        }
        .fullScreenCover(isPresented: $showOnlineBookDetail) {
            if let detail = onlineBookDetail {
                NavigationStack {
                    OnlineBookView(book: detail)
                        .environmentObject(store)
                        .navigationTitle(localized("書籍詳情"))
                        .toolbarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showOnlineBookDetail = false
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityLabel(localized("關閉"))
                            }
                        }
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
                    showsPageNumbers: book?.isOnline != true,
                    currentIndex: currentChapterIndex,
                    currentChapterID: currentTOCChapterID,
                    onSelectChapter: { jumpToTOCEntry($0) },
                    bookmarks: book?.bookmarks ?? [],
                    bookmarkPageNumber: { inChapterPageNumber(for: $0) },
                    onSelectBookmark: { bm in
                        showTOC = false
                        jumpToBookmark(bm)
                    },
                    onDeleteBookmark: { deleteBookmarkEntry($0) },
                    isPresented: $showTOC,
                    selectedTab: $readerMenuTab
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
        .sheet(item: $replaceRuleDraft) { rule in
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                ReplaceRuleEditView(rule: rule) { savedRule in
                    ReplaceRuleStore.shared.add(savedRule)
                    refreshCurrentChapter()
                }
            }
        }
        .sheet(item: $reviewTarget) { target in
            JsBridgeBrowserView(
                urlString: target.url,
                hidesToolbar: true
            ) { _ in
                reviewTarget = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $footnoteItem) { item in
            ReaderFootnotePopupView(text: item.text) { footnoteItem = nil }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChanged(of: showChangeSourceSheet) { show in
            if show { loadOtherOrigins() }
        }
        .onChanged(of: epubRenderer.isCoreTextReady) { ready in
            if ready {
                if !isVerticalEPUB && epubRenderer.cssDetectedVerticalWritingMode {
                    isVerticalEPUB = true
                    readerNavigator?.updateOpeningDirection(.rightSpine)
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

    func handleTouchAction(_ action: TouchAction) {
        switch action.readerCommand {
        case .none:
            return
        case .toggleMenu:
            withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                showBars.toggle()
                if !showBars {
                    appleBooksActivePanel = nil
                }
            }
        case .previousPage:
            guard !showBars else { return }
            goToPrevPage()
        case .nextPage:
            guard !showBars else { return }
            goToNextPage()
        case .previousChapter:
            guard canGoPrevChapter else { return }
            jumpToChapter(currentChapterIndex - 1)
        case .nextChapter:
            guard canGoNextChapter else { return }
            jumpToChapter(currentChapterIndex + 1)
        case .toggleBookmark:
            guard let position = currentTopBarBookmarkPosition else { return }
            store.toggleBookmark(
                bookId: bookId,
                chapterIndex: position.spineIndex,
                chapterTitle: bookmarkChapterTitle(for: position.spineIndex),
                position: position,
                excerpt: currentPageExcerpt
            )
        case .tableOfContents:
            readerMenuTab = .toc
            showTOC = true
        }
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

    func refreshInitialRestoreState() {
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

    func applyInitialProgressIfNeeded() {
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
                    // Phase-2: binding writes are display-only; re-issue the position
                    // command so the executor corrects any estimated-page residual
                    // (previously the binding-vs-visible reconciler picked this up).
                    self.setCoreTextExternalTarget(
                        CoreTextReadingPosition(spineIndex: spineIndex, charOffset: target.charOffset)
                    )
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

    func beginCurlStartupTrace(reason: String) {
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

    func logCurlInteractiveReadyIfNeeded(source: String) {
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

    func handleScrollModeChanged(_ enabled: Bool) {
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

    func currentPagedReadingPositionForModeSwitch() -> CoreTextReadingPosition? {
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
    // Extracted to ReaderView+Footer.swift

    // MARK: - Inline Footer (curl mode: baked into page texture, moves with the page)
    // Extracted to ReaderView+Footer.swift

    // MARK: - TXT Vertical Scroll Mode
    // Extracted to ReaderView+TXTVerticalScroll.swift

    // MARK: - Top Bar
    // Extracted to ReaderView+Toolbars.swift

    // MARK: - Bottom Bar
    // Extracted to ReaderView+Toolbars.swift

    // MARK: - Source Change Sheet
    // Extracted to ReaderView+SourceChange.swift

    // MARK: - Logic
    // Extracted to ReaderView+Logic.swift

    // MARK: - Online Chapter Lazy Loading
    // Extracted to ReaderView+OnlineChapterLoading.swift

    // MARK: - Loading & Page Building
    // Extracted to ReaderView+PageBuilding.swift
}
