import Combine
import SwiftUI


// MARK: - 分頁資料
struct PageContent {
    let chapterIndex: Int
    let chapterTitle: String
    let content: String
    let pageInChapter: Int
    var attributedContent: NSAttributedString? = nil
}

// MARK: - 翻頁動畫時長（TXT / EPUB 統一，對齊 Koodo/Legado）
private enum PageTurnAnimation {
    static let slideDuration: Double = 0.25  // 滑動：ease-in-out；EPUB index.html 同為 0.25s
}
/// UI 回饋動畫時長（主題、書籤、目錄高亮等）
private let uiFeedbackDuration: Double = 0.25

/// 用於把頂部 safe area 傳給閱讀器留白，避免留白最小時正文蓋住狀態列
private struct ReaderSafeAreaTopKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ReaderViewportSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct EpubVerticalPageOffsetKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

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

private final class ReaderRuntimeState {
    var systemBrightness: Double = 0.5
    var isRestoringPosition = true
    var savedPositionSnapshot: Double = 0
    var savedCoreTextRestoreTarget: (chapterIndex: Int, charOffset: Int)?
    var isApplyingCoreTextRestore = false
    var hasAppliedNonZeroRestore = false
    var isLoadingPipeline = false
    var curlStartupStartedAt: CFAbsoluteTime? = nil
    var hasLoggedCurlInteractiveReady = false
    var hasPerformedInitialLoad = false
}

// MARK: - 閱讀器主視圖
struct ReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var readerConfig = ReaderConfig.shared

    // MARK: - 跨章節的極致：推測性預佈局 (Speculative Pre-Layout)
    @State private var scrollVelocity: CGFloat = 0.0
    @State private var isGhostModeActive: Bool = false
    
    private func updateScrollVelocity(_ newVelocity: CGFloat) {
        scrollVelocity = newVelocity
        // 高速滑動 > 1000：進入 Ghost Mode (不解析全章節，僅顯示標題)
        if abs(scrollVelocity) > 1000 && !isGhostModeActive {
            isGhostModeActive = true
            // 暫停 NSAttributedString 解析
        } else if abs(scrollVelocity) < 500 && isGhostModeActive {
            isGhostModeActive = false
            // 離開幽靈模式，開始優先佇列 (Priority Queue) 插隊解析當前落點章節
            // 並預佈局 (Layout) 下一章的前 3 頁
            speculativePreLayoutNextChapter()
        }
    }
    
    private func speculativePreLayoutNextChapter() {
        Task { @MainActor in
            guard currentChapterIndex + 1 < chapters.count else { return }
            // 利用 engine.warmUpNext 排版下一章
            epubRenderer.engine?.warmUpNext(currentGlobalPage: currentPage + 1)
        }
    }


    @State private var chapters: [BookChapter] = []
    @State private var allPages: [PageContent] = []
    @State private var currentPage = 0
    @State private var showBars = false
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var showBookmarkList = false

    // 線上章節懶加載
    @StateObject private var readerViewModel = ReaderViewModel()
    @State private var observedChapterStates: [Int: ChapterLoadState] = [:]

    // 亮度
    @State private var showBrightness = false

    /// 頂部 safe area（pt），傳給 EPUB 引擎讓 margin-top 至少為此值
    @State private var readerSafeAreaTop: CGFloat = 59
    @State private var readerViewportSize: CGSize = UIScreen.main.bounds.size
    // 音量翻頁
    @StateObject private var volumeHandler = VolumeKeyHandler()

    // 自動閱讀 + TTS
    @StateObject private var autoReader = AutoReadController()  // TTS
    @StateObject private var ttsCoordinator = TTSCoordinator()

    // 時間與電池已移至 ReaderFooterView.swift (ClockBatteryModel)
    // 不再作為 ReaderView 的 @State，避免每分鐘觸發整個 body 重算

    private func syncReaderBrightnessFromSystem() {
        let current = Double(UIScreen.main.brightness)
        systemBrightness = current
        settings.readerBrightness = current
    }

    private func restoreReaderDisplayStateAfterResume() {
        guard let engine = epubRenderer.engine, isEPUB, engine.totalPages > 0 else { return }
        // engine.currentPage is not updated by page turns (only set during start()),
        // so we use the already-correct currentPage @State to sync currentChapterIndex only.
        let (spineIndex, _) = engine.charOffset(forPage: currentPage)
        currentChapterIndex = spineIndex
    }

    // EPUB 渲染器（CoreText）
    @StateObject private var epubRenderer = EPUBPageRenderer()

    @State private var showTTSPanel = false
    @State private var showAutoReadPanel = false

    // EPUB 章節導航狀態
    @State private var currentChapterIndex = 0

    // 捲動模式進度追蹤
    @State private var scrollVisibleChapter = 0

    // 防止載入期間 TabView 重置 selection 導致進度被覆寫為 0

    // 換源
    @State private var showChangeSourceSheet = false
    @State private var runtimeState = ReaderRuntimeState()
    @State private var chapterSliderDraft: Double? = nil
    @State private var bookDocument: (any BookDocument)? = nil
    @State private var contentProvider: (any BookContentProvider)? = nil
    @State private var readerCapabilities: ReaderCapabilities = .reflowableText
    private let progressManager = ReaderProgressManager.shared

    // 換源狀態由 ViewModel 管理，此處透過計算屬性橋接，避免 View 持有重複狀態
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

    // ── 衍生屬性 ──
    var book: ReadingBook? { store.books.first(where: { $0.id == bookId }) }

    // 核心判斷：是否為 EPUB / TXT
    var isEPUB: Bool {
        book?.resolvedPipelineKind == .epub
    }

    var isTXT: Bool {
        book?.resolvedPipelineKind == .txt
    }

    private var usesCoreTextEPUB: Bool {
        epubRenderer.engine != nil
    }

    private var usesPagedRenderer: Bool { usesCoreTextEPUB }

    private var renderedPageCount: Int {
        if let engine = epubRenderer.engine, usesCoreTextEPUB { return engine.totalPages }
        return allPages.count
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

    /// EPUB 字型資源目錄（Documents/{uuid}_epub_assets/）
    var epubAssetsURL: URL? {
        guard let b = book, b.isLegacyParsedEPUB else { return nil }
        let assetsDir = b.contentFilename.replacingOccurrences(
            of: "_epub.json", with: "_epub_assets")
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docsDir.appendingPathComponent(assetsDir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 當前章節的 baseURL：assets 根 + 章節所在子目錄（用於解析 CSS 內的相對字型路徑）
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

    /// Footer 文字區本體高度（pt），不含 safe area bottom
    private let footerOverlayHeight: CGFloat = ReaderLayoutMetrics.footerHeight

    /// 當前頁是否有書籤
    var isCurrentPageBookmarked: Bool {
        store.isPageBookmarked(bookId: bookId, pageIndex: currentPage)
    }

    /// 當前頁摘錄（前 30 字）
    var currentPageExcerpt: String {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            return String(engine.plainText(forPage: currentPage).prefix(30))
        }
        guard !allPages.isEmpty else { return "" }
        let content = allPages[min(currentPage, allPages.count - 1)].content
        return String(content.prefix(30))
    }

    /// 閱讀總進度百分比
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

    /// 章節頁碼資訊
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

    /// 當前頁內容（給 TTS 用）
    var currentPageText: String {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            return engine.plainText(forPage: currentPage)
        }
        guard !allPages.isEmpty else { return "" }
        return allPages[min(currentPage, allPages.count - 1)].content
    }

    // ── 主體 ──
    var body: some View {
        ZStack(alignment: .top) {
            readerTheme.backgroundColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: uiFeedbackDuration), value: readerTheme)

            if chapters.isEmpty {
                VStack {
                    Spacer()
                    ProgressView(settings.t("載入中…"))
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let ctEngine = epubRenderer.engine, epubRenderer.isCoreTextReady {
                // 在 EPUB 渲染區塊，当 engine 已就緒時改用 CoreText
                let _ = { print("[ReaderView] ✅ 使用 CoreText 引擎") }()
                CoreTextPageEngineView(
                    engine: ctEngine,
                    pageTurnStyle: settings.pageTurnStyle,
                    currentPage: $currentPage,
                    onPageChanged: { newPage in
                        let newChapter = ctEngine.charOffset(forPage: newPage).spineIndex
                        let chapterChanged = newChapter != currentChapterIndex
                        currentChapterIndex = newChapter
                        progressTrace("onPageChanged page=\(newPage) chapter=\(currentChapterIndex)")
                        // Lazy loading: 翻頁換章時自動抓取
                        if chapterChanged {
                            ensureChapterReady(chapterIndex: newChapter)
                        }
                        guard ReaderProgressSyncPolicy.shouldPersistOnPageChanged(
                            isCoreTextReady: epubRenderer.isCoreTextReady,
                            totalPages: ctEngine.totalPages,
                            isRestoringPosition: isRestoringPosition
                        ) else {
                            progressTrace(
                                "onPageChanged skipPersist page=\(newPage) ready=\(epubRenderer.isCoreTextReady) totalPages=\(ctEngine.totalPages) restoring=\(isRestoringPosition)"
                            )
                            return
                        }
                        guard coreTextPositionIfLayoutReady(engine: ctEngine, page: newPage) != nil else {
                            progressTrace("onPageChanged skipPersist page=\(newPage) reason=layoutNotReady")
                            return
                        }
                        epubRenderer.updateCurrentPosition(globalPage: newPage, engine: ctEngine)
                        if let progressBookId = localEPUBBookIdentifier {
                            epubRenderer.syncProgress(bookId: progressBookId)
                        }
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
                    ProgressView(settings.t("載入中…"))
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if settings.scrollMode {
                scrollBody
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }

            // 網路抓取狀態覆蓋層已停用（使用者要求不顯示任何抓取中 / 載入失敗 UI）。
            // 業務邏輯保留在 `currentChapterOverlayState` + `refreshCurrentChapter()`，
            // 未來要恢復 UI 時把下列 switch 搬回來即可：
            //
            //   if !showBars {
            //       switch currentChapterOverlayState {
            //       case .hidden, .loading: EmptyView()
            //       case .failed(let message): /* 錯誤提示 + 點擊重試按鈕 */
            //       }
            //   }

            // 頂/底欄
            if !showBars && !settings.scrollMode && !chapters.isEmpty {
                VStack {
                    Spacer()
                    bottomFooter
                }
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            if showBars { topBar }
            if showBars { bottomBar }
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
                    "scrollMode": settings.scrollMode ? "1" : "0",
                ]
            )
            readerConfig.syncFromGlobalSettings()
            if !hasPerformedInitialLoad {
                hasPerformedInitialLoad = true
                performInitialLoad()
            } else {
                restoreReaderDisplayStateAfterResume()
            }
            systemBrightness = Double(UIScreen.main.brightness)
            if settings.followSystemBrightness {
                settings.readerBrightness = systemBrightness
            } else {
                UIScreen.main.brightness = CGFloat(settings.readerBrightness)
            }
            // 音量翻頁
            volumeHandler.onPageTurn = { dir in
                switch dir {
                case .prev: goToPrevPage()
                case .next: goToNextPage()
                }
            }
            if volumeHandler.isEnabled { volumeHandler.startListening() }
            autoReader.onNextPage = { goToNextPage() }
            ttsCoordinator.onPageFinished = {
                if !usesCoreTextEPUB, currentPage < allPages.count - 1 {
                    currentPage += 1
                    return allPages[currentPage].content
                }
                return nil
            }
        }
        .onDisappear {
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
            ttsCoordinator.stop()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
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
            // Use stored viewport size (not UIScreen) to avoid mismatch in split view.
            performUnifiedRelayout(targetSize: readerViewportSize)
        }
        .onChange(of: settings.readerBrightness) { val in
            if !settings.followSystemBrightness { UIScreen.main.brightness = CGFloat(val) }
        }
        .onChange(of: settings.followSystemBrightness) { follow in
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
        .onReceive(readerViewModel.$chapterStates) { states in
            handleChapterStateChanges(states)
        }
        .onChange(of: settings.pageTurnStyle) { _ in
            // 翻頁樣式變更不需重建頁面，body 會自動切換視圖
            if settings.pageTurnStyle == .curl {
                beginCurlStartupTrace(reason: "style_changed")
            } else {
                curlStartupStartedAt = nil
                hasLoggedCurlInteractiveReady = false
            }
        }
        .onChange(of: scrollVisibleChapter) { _ in
            autoSaveProgress()
        }
        .sheet(isPresented: $showSettings) {
            AdaptiveSheetContainer(maxWidth: 760) {
                FontSettingsView(
                    fontSize: Binding(
                        get: { readerConfig.fontSize },
                        set: { readerConfig.fontSize = $0 }
                    ),
                    theme: Binding(
                        get: { readerConfig.theme },
                        set: { readerConfig.theme = $0 }
                    ),
                    capabilities: readerCapabilities
                )
            }
        }
        .sheet(isPresented: $showTOC) {
            AdaptiveSheetContainer(maxWidth: 760) {
                TOCView(
                    chapters: chapters,
                    currentIndex: Binding(get: { currentChapterIndex }, set: { jumpToChapter($0) }),
                    isPresented: $showTOC
                )
            }
        }
        .sheet(isPresented: $showBookmarkList) {
            AdaptiveSheetContainer(maxWidth: 760) {
                BookmarkListView(
                    bookmarks: book?.bookmarks ?? [],
                    onSelect: { bookmark in
                        showBookmarkList = false
                        if bookmark.pageIndex < renderedPageCount {
                            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                                currentPage = bookmark.pageIndex
                            }
                        }
                    },
                    onDelete: { bookmark in
                        store.removeBookmark(bookId: bookId, bookmarkId: bookmark.id)
                    }
                )
            }
        }
        .sheet(isPresented: $showTTSPanel) {
            AdaptiveSheetContainer(maxWidth: 760) {
                TTSPanelView(
                    tts: ttsCoordinator, currentText: currentPageText, chapterTitle: currentChapterTitle)
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
        .onChange(of: showChangeSourceSheet) { show in
            if show { loadOtherOrigins() }
        }
        .onChange(of: epubRenderer.isCoreTextReady) { ready in
            if ready { applyInitialProgressIfNeeded() }
        }
        .onChange(of: allPages.count) { _ in
            applyInitialProgressIfNeeded()
        }
        .onChange(of: chapters.count) { _ in
            applyInitialProgressIfNeeded()
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

        // 書架有章節 → 秒開閱讀器，背景修復元資料
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
            // 無章節 → 第一頁 TOC 一到就先開書，不等完整目錄返回
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
            // 優先信任引擎（CharOffsetStore）恢復結果，不受 snapshot=0 影響。
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

        if settings.scrollMode, !chapters.isEmpty {
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

    // MARK: - 底部頁腳資訊（slide / cover / tab 模式用的 overlay）
    private var bottomFooter: some View {
        ReaderOverlayFooter(
            pageInfo: chapterPageInfo,
            progress: totalProgressPercent,
            textColor: readerTheme.textColor,
            bottomInset: windowSafeBottom
        )
    }

    private var windowSafeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top) ?? readerSafeAreaTop
    }

    /// 讀取 key window 的底部 safe area inset（全螢幕閱讀模式下手動補償）
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

    // MARK: - 頁內 footer（curl 模式：footer 烘進頁面紋理，跟隨翻頁一起移動）
    private func inlineFooter(forPage idx: Int) -> some View {
        let info = pageFooterInfo(forPage: idx)
        return ReaderInlineFooter(
            pageInfo: info.pageInfo,
            progress: info.progress,
            textColor: readerTheme.textColor,
            bottomInset: windowSafeBottom
        )
    }

    /// 計算指定頁的 footer 資訊（章節頁碼 + 進度百分比）
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

    // MARK: - TXT 上下滾動模式
    private var scrollBody: some View {
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
                                Text(settings.t("載入章節中…"))
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

    // MARK: - 頂部欄
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
                withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                    store.toggleBookmark(
                        bookId: bookId,
                        chapterIndex: currentChapterIndex,
                        chapterTitle: currentChapterTitle,
                        pageIndex: currentPage,
                        excerpt: currentPageExcerpt
                    )
                }
            }
        )
    }

    // MARK: - 底部欄
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
            onOpenSettings: { showSettings = true },
            onSyncSystemBrightness: { syncReaderBrightnessFromSystem() }
        )
    }

    // MARK: 亮度列（滑桿 + 跟隨系統）
    private var brightnessRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(settings.t("亮度")).font(.system(size: 11)).foregroundColor(
                    readerTheme.textColor.opacity(0.7))
                Slider(value: $settings.readerBrightness, in: 0.05...1.0, step: 0.05)
                    .accentColor(readerTheme.textColor.opacity(0.5))
                    .disabled(settings.followSystemBrightness)
                Text("\(Int(settings.readerBrightness * 100))%").font(
                    .system(size: 10).monospacedDigit()
                ).foregroundColor(readerTheme.textColor.opacity(0.5))
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        settings.followSystemBrightness.toggle()
                    }
                    if settings.followSystemBrightness {
                        syncReaderBrightnessFromSystem()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: settings.followSystemBrightness
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.system(size: 14))
                        Text(settings.t("跟隨系統亮度"))
                            .font(.system(size: 12))
                    }
                    .foregroundColor(
                        settings.followSystemBrightness
                            ? Color.blue : readerTheme.textColor.opacity(0.8))
                }

                Spacer()

                Button {
                    syncReaderBrightnessFromSystem()
                } label: {
                    Text(settings.t("同步系統"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.blue)
                }
                .opacity(settings.followSystemBrightness ? 1.0 : 0.7)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .background(readerTheme.barColor)
    }

    // MARK: - 換源 Sheet
    private var changeSourceSheetContent: some View {
        NavigationView {
            Group {
                if changeSourceLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(settings.t("正在搜尋其他書源…"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = changeSourceError {
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
                } else if changeSourceOrigins.isEmpty {
                    Text(settings.t("暫無其他書源"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
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
                }
            }
            .navigationTitle(settings.t("換源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(settings.t("關閉")) { showChangeSourceSheet = false }
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

    /// 根據進度值（0–1）反查對應的章節標題，用於拖動 HUD
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

    // MARK: 進度滑桿行
    private var progressSliderRow: some View {
        HStack(spacing: 4) {
            Button {
                jumpToChapter(currentChapterIndex - 1)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12))
                    Text(settings.t("上一章")).font(.system(size: 14))
                }
                .foregroundColor(
                    canGoPrevChapter ? readerTheme.textColor : readerTheme.textColor.opacity(0.22)
                )
                .padding(.leading, 14).padding(.vertical, 18)
            }.disabled(!canGoPrevChapter)

            VStack(spacing: 2) {
                Slider(
                    value: Binding<Double>(
                        get: { chapterSliderDraft ?? chapterSliderProgressValue() },
                        set: { chapterSliderDraft = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            chapterSliderDraft = chapterSliderProgressValue()
                        } else if let draft = chapterSliderDraft {
                            applyChapterSliderProgress(draft)
                            chapterSliderDraft = nil
                        }
                    }
                ).accentColor(readerTheme.textColor.opacity(0.4))

                Text("\(chapterPageInfo)  ·  \(totalProgressPercent)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(readerTheme.textColor.opacity(0.4))
            }.padding(.horizontal, 6)

            Button {
                jumpToChapter(currentChapterIndex + 1)
            } label: {
                HStack(spacing: 3) {
                    Text(settings.t(canGoNextChapter ? "下一章" : "書末頁")).font(.system(size: 14))
                    Image(systemName: "chevron.right").font(.system(size: 12))
                }
                .foregroundColor(
                    canGoNextChapter ? readerTheme.textColor : readerTheme.textColor.opacity(0.22)
                )
                .padding(.trailing, 14).padding(.vertical, 18)
            }.disabled(!canGoNextChapter)
        }
        .background(readerTheme.barColor)
        .overlay(alignment: .center) {
            if let draft = chapterSliderDraft {
                VStack(spacing: 4) {
                    Text(String(format: "%.0f%%", draft * 100))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text(chapterTitle(forProgress: draft))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.62))
                        .background(Capsule().fill(.ultraThinMaterial))
                )
                .clipShape(Capsule())
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: chapterSliderDraft == nil)
    }
    private var toolRow: some View {
        HStack(spacing: 0) {
            toolBtn(icon: "list.bullet", label: settings.t("目錄")) { showTOC = true }
            toolBtn(icon: "sun.max", label: settings.t("亮度"), active: showBrightness) {
                withAnimation(.easeOut(duration: 0.2)) { showBrightness.toggle() }
            }
            toolBtn(
                icon: readerTheme == .night ? "sun.min" : "moon",
                label: settings.t(readerTheme == .night ? "白天" : "深色"),
                active: readerTheme == .night
            ) {
                withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                    if readerTheme == .night {
                        // 恢復進入夜間模式前的主題
                        let saved = UserDefaults.standard.string(forKey: "lastLightTheme") ?? ReaderTheme.white.rawValue
                        readerTheme = ReaderTheme(rawValue: saved) ?? .white
                    } else {
                        UserDefaults.standard.set(readerTheme.rawValue, forKey: "lastLightTheme")
                        readerTheme = .night
                    }
                }
            }
            toolBtn(icon: "gearshape", label: settings.t("設置")) { showSettings = true }
        }
        .padding(.top, 4).padding(.bottom, 20)
        .background(readerTheme.barColor)
    }

    @ViewBuilder
    private func toolBtn(
        icon: String, label: String, active: Bool = false, badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 22))
                    if let count = badge, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white).padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .offset(x: 10, y: -4)
                    }
                }
                Text(label).font(.system(size: 10))
            }
            .foregroundColor(active ? Color.blue : readerTheme.textColor.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 邏輯
    private func findChapterFirstPage(_ chapterIdx: Int) -> Int? {
        return allPages.firstIndex(where: { $0.chapterIndex == chapterIdx })
    }

    private func jumpToChapter(_ idx: Int, charOffset: Int = 0) {
        guard chapters.indices.contains(idx) else { return }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            Task { @MainActor in
                engine.cancelPendingWork()
                await engine.preloadChapter(at: idx)
                // 背景預載鄰域章節，確保前後翻頁時 layout 已就緒
                if idx > 0 { Task { await engine.preloadChapter(at: idx - 1) } }
                if idx < chapters.count - 1 { Task { await engine.preloadChapter(at: idx + 1) } }
                let targetPage = engine.pageIndex(forSpine: idx, charOffset: charOffset)
                currentChapterIndex = idx
                currentPage = targetPage
                epubRenderer.currentEpubPage = targetPage
                // 在 ensureChapterReady 之前捕捉狀態：若章節已是 .ready，
                // ensureChapterReady 不會觸發 handleChapterStateChanges，
                // engine 可能持有跳頁前預讀的佔位符 layout（資料未到磁碟時建立），需強制重建。
                let alreadyReady = readerViewModel.chapterState(for: idx) == .ready
                ensureChapterReady(chapterIndex: idx, priority: .jump)
                if alreadyReady, isChapterContentAvailable(at: idx) {
                    await engine.notifyChapterDataChanged(at: idx)
                }
            }
        } else {
            currentChapterIndex = idx
            if let p = findChapterFirstPage(idx) { currentPage = p }
            ensureChapterReady(chapterIndex: idx, priority: .jump)
        }
    }

    private func autoSaveProgress() {
        guard !isRestoringPosition else { return }

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
        } else if !settings.scrollMode && !allPages.isEmpty {
            // TXT：使用 allPages
            let page = allPages[min(currentPage, allPages.count - 1)]
            currentChapterIndex = page.chapterIndex
            // 接近章節末尾時提前預加載下一章
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
            // 滾動模式
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
        // onDisappear 時強制保存，不受 isRestoringPosition 限制
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
        // 整本書清快取：因為「下一章誤判為下一頁」的 bug 會把後續多章串接到當章 cache 裡，
        // 只清當前章不夠，必須整本書一次清掉，否則跨章污染還在。
        dependencies.bookSourceFetcher.clearAllChapterCache(bookId: b.id)
        store.clearAllCachedChapterFilenames(bookId: b.id)
        for ref in refs {
            readerViewModel.resetChapterState(for: ref.index)
        }
        // 立即把當前章 layout 失效並換成 PlaceholderVC（loading UI），
        // 不要讓使用者繼續看著舊的（被 concat 過的）正文等到重抓完成。
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

    /// 換源搜尋已移至 ReaderViewModel.loadOtherOrigins，此處只負責觸發並傳入所需資料
    private func loadOtherOrigins() {
        guard let b = book, let currentSourceId = b.bookSourceId else { return }
        readerViewModel.loadOtherOrigins(
            book: b,
            currentSourceId: currentSourceId,
            enabledSources: BookSourceStore.shared.enabledSources,
            store: store
        )
    }

    // MARK: - 線上章節懶加載
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

    /// 當使用者翻到當前章節最後 25% 時，提前觸發下一章預加載，
    /// 比等到章節末頁才觸發早幾頁，讓下一章有更多緩衝時間。
    private func maybeEarlyPrefetchIfNearChapterEnd() {
        guard let b = book, b.isOnline,
              let refs = b.onlineChapters else { return }
        let chIdx = currentChapterIndex
        let nextIdx = chIdx + 1
        guard refs.indices.contains(nextIdx) else { return }

        // 下一章已快取則無需預加載
        guard !dependencies.bookSourceFetcher.isChapterCached(
            bookId: b.id, chapterIndex: nextIdx,
            expectedSourceURL: nil, expectedTOCTitle: nil) else { return }

        // 計算當前章節的頁數，判斷是否已超過 75%
        let pagesInChapter = allPages.filter { $0.chapterIndex == chIdx }
        guard !pagesInChapter.isEmpty else { return }
        let currentPageInChapter = allPages.indices.contains(currentPage)
            ? allPages[currentPage].pageInChapter : 0
        guard currentPageInChapter >= (pagesInChapter.count * 3) / 4 else { return }

        readerViewModel.prefetchAround(book: b, center: chIdx, store: store)
    }

    // MARK: - 載入 & 建頁
    private func currentRenderSettings(marginH: CGFloat) -> ReaderRenderSettings {
        let topInset = ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
        let bottomInset = max(20, ReaderLayoutMetrics.bottomInset(safeBottom: windowSafeBottom))
        let lineHeightMultiple = max(1.0, readerConfig.lineHeightMultiple)
        return ReaderRenderSettings(
            theme: readerTheme.epubJSName,
            textColor: UIColor(readerTheme.textColor),
            backgroundColor: UIColor(readerTheme.backgroundColor),
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: readerConfig.lineSpacing,
            paragraphSpacing: readerConfig.paragraphSpacing,
            letterSpacing: readerConfig.letterSpacing,
            marginH: marginH,
            marginV: systemVerticalPadding,
            footerHeight: footerOverlayHeight,
            contentInsets: UIEdgeInsets(top: topInset, left: marginH, bottom: bottomInset, right: marginH)
        )
    }

    private func applyPublicationSession(
        _ session: PublicationSession,
        book: ReadingBook,
        settings: ReaderRenderSettings
    ) {
        let document = BookDocumentFactory.makeEPUBDocument(book: book, session: session)
        applyDocument(document)

        let tocLevelMap: [String: Int] = Dictionary(
            session.tocEntries.map { ($0.href, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )

        chapters = session.chapters.map { chapter in
            let level =
                tocLevelMap[chapter.href]
                ?? tocLevelMap.first(where: {
                    chapter.href.hasSuffix($0.key) || $0.key.hasSuffix(chapter.href)
                })?.value
                ?? 0
            return BookChapter(
                index: chapter.index,
                title: chapter.title,
                content: "",
                href: chapter.href,
                level: level
            )
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
        let settings = currentRenderSettings(marginH: marginH)
        Task {
            do {
                let session = try await EPUBBookService.shared.openSession(for: book, using: store)
                await MainActor.run {
                    guard self.book?.id == book.id else { return }
                    self.applyPublicationSession(session, book: book, settings: settings)
                }
            } catch {
                await MainActor.run {
                    print("Readium 解析失敗：\(error)")
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

        // Lazy loading: 自動抓取初始章節（存檔位置或第 0 章）
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
            // HTML: temporarily disabled pending CoreText migration
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
        epubRenderer.updateRenderSettings(currentRenderSettings(marginH: effectivePageMarginH))
        let size = targetSize ?? engine.renderSize
        Task { await engine.invalidateLayout(newSize: size) }
    }

    private func applyUnifiedAppearanceUpdate() {
        guard let engine = epubRenderer.engine else { return }
        epubRenderer.updateRenderSettings(currentRenderSettings(marginH: effectivePageMarginH))
        engine.applyThemeChange(
            textColor: UIColor(readerTheme.textColor),
            backgroundColor: UIColor(readerTheme.backgroundColor)
        )
    }
}

private struct ReaderBottomControlBar: View {
    @ObservedObject private var settings = GlobalSettings.shared

    @Binding var readerTheme: ReaderTheme
    let overlayContentMaxWidth: CGFloat
    let showRefreshButton: Bool
    let showChangeSourceButton: Bool
    let showDownloadButton: Bool
    let downloadButtonIcon: String
    let canGoPrevChapter: Bool
    let canGoNextChapter: Bool
    let chapterPageInfo: String
    let totalProgressPercent: String
    let chapterSliderProgressValue: () -> Double
    let applyChapterSliderProgress: (Double) -> Void
    let chapterTitleForProgress: (Double) -> String
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onRefresh: () -> Void
    let onOpenChangeSource: () -> Void
    let onDownloadAction: () -> Void
    let onOpenTTS: () -> Void
    let onOpenTOC: () -> Void
    let onOpenSettings: () -> Void
    let onSyncSystemBrightness: () -> Void

    @State private var showBrightness = false
    @State private var chapterSliderDraft: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 12) {
                Spacer()
                if showRefreshButton {
                    circleBtn(icon: "arrow.clockwise") { onRefresh() }
                }
                if showChangeSourceButton {
                    circleBtn(icon: "arrow.left.and.right") { onOpenChangeSource() }
                }
                if showDownloadButton {
                    circleBtn(icon: downloadButtonIcon) { onDownloadAction() }
                }
                circleBtn(icon: "headphones") { onOpenTTS() }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)

            VStack {
                VStack(spacing: 0) {
                    Divider().opacity(0.18)
                    progressSliderRow
                    Divider().opacity(0.1)
                    if showBrightness {
                        brightnessRow
                        Divider().opacity(0.1)
                    }
                    toolRow
                }
                .frame(maxWidth: overlayContentMaxWidth)
            }
            .background(readerTheme.barColor)
            .overlay(alignment: .top) {
                if let draft = chapterSliderDraft {
                    VStack(spacing: 4) {
                        Text(String(format: "%.0f%%", draft * 100))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Text(chapterTitleForProgress(draft))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.62))
                            .background(Capsule().fill(.ultraThinMaterial))
                    )
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    .offset(y: -72)
                }
            }
            .animation(.easeOut(duration: 0.15), value: chapterSliderDraft == nil)
        }
        .onChange(of: showBrightness) { isVisible in
            if isVisible && settings.followSystemBrightness {
                onSyncSystemBrightness()
            }
        }
    }

    private var brightnessRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(settings.t("亮度")).font(.system(size: 11)).foregroundColor(
                    readerTheme.textColor.opacity(0.7))
                Slider(value: $settings.readerBrightness, in: 0.05...1.0, step: 0.05)
                    .accentColor(readerTheme.textColor.opacity(0.5))
                    .disabled(settings.followSystemBrightness)
                Text("\(Int(settings.readerBrightness * 100))%").font(
                    .system(size: 10).monospacedDigit()
                ).foregroundColor(readerTheme.textColor.opacity(0.5))
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        settings.followSystemBrightness.toggle()
                    }
                    if settings.followSystemBrightness {
                        onSyncSystemBrightness()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: settings.followSystemBrightness
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.system(size: 14))
                        Text(settings.t("跟隨系統亮度"))
                            .font(.system(size: 12))
                    }
                    .foregroundColor(
                        settings.followSystemBrightness
                            ? Color.blue : readerTheme.textColor.opacity(0.8))
                }

                Spacer()

                Button {
                    onSyncSystemBrightness()
                } label: {
                    Text(settings.t("同步系統"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.blue)
                }
                .opacity(settings.followSystemBrightness ? 1.0 : 0.7)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .background(readerTheme.barColor)
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

    private var progressSliderRow: some View {
        HStack(spacing: 4) {
            Button {
                onPrevChapter()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12))
                    Text(settings.t("上一章")).font(.system(size: 14))
                }
                .foregroundColor(
                    canGoPrevChapter ? readerTheme.textColor : readerTheme.textColor.opacity(0.22)
                )
                .padding(.leading, 14).padding(.vertical, 18)
            }.disabled(!canGoPrevChapter)

            VStack(spacing: 2) {
                Slider(
                    value: Binding<Double>(
                        get: { chapterSliderDraft ?? chapterSliderProgressValue() },
                        set: { chapterSliderDraft = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            chapterSliderDraft = chapterSliderProgressValue()
                        } else if let draft = chapterSliderDraft {
                            applyChapterSliderProgress(draft)
                            chapterSliderDraft = nil
                        }
                    }
                ).accentColor(readerTheme.textColor.opacity(0.4))

                Text("\(chapterPageInfo)  ·  \(totalProgressPercent)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(readerTheme.textColor.opacity(0.4))
            }.padding(.horizontal, 6)

            Button {
                onNextChapter()
            } label: {
                HStack(spacing: 3) {
                    Text(settings.t(canGoNextChapter ? "下一章" : "書末頁")).font(.system(size: 14))
                    Image(systemName: "chevron.right").font(.system(size: 12))
                }
                .foregroundColor(
                    canGoNextChapter ? readerTheme.textColor : readerTheme.textColor.opacity(0.22)
                )
                .padding(.trailing, 14).padding(.vertical, 18)
            }.disabled(!canGoNextChapter)
        }
        .background(readerTheme.barColor)
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            toolBtn(icon: "list.bullet", label: settings.t("目錄")) { onOpenTOC() }
            toolBtn(icon: "sun.max", label: settings.t("亮度"), active: showBrightness) {
                withAnimation(.easeOut(duration: 0.2)) { showBrightness.toggle() }
            }
            toolBtn(
                icon: readerTheme == .night ? "sun.min" : "moon",
                label: settings.t(readerTheme == .night ? "白天" : "深色"),
                active: readerTheme == .night
            ) {
                withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                    if readerTheme == .night {
                        let saved = UserDefaults.standard.string(forKey: "lastLightTheme") ?? ReaderTheme.white.rawValue
                        readerTheme = ReaderTheme(rawValue: saved) ?? .white
                    } else {
                        UserDefaults.standard.set(readerTheme.rawValue, forKey: "lastLightTheme")
                        readerTheme = .night
                    }
                }
            }
            toolBtn(icon: "gearshape", label: settings.t("設置")) { onOpenSettings() }
        }
        .padding(.top, 4).padding(.bottom, 20)
        .background(readerTheme.barColor)
    }

    @ViewBuilder
    private func toolBtn(
        icon: String, label: String, active: Bool = false, badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 22))
                    if let count = badge, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white).padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .offset(x: 10, y: -4)
                    }
                }
                Text(label).font(.system(size: 10))
            }
            .foregroundColor(active ? Color.blue : readerTheme.textColor.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 安全色碼轉換
extension Color {
    func toHexSafe() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02lX%02lX%02lX", lroundf(Float(r * 255)), lroundf(Float(g * 255)),
            lroundf(Float(b * 255)))
    }
}

// MARK: - 書籤列表視圖
struct BookmarkListView: View {
    let bookmarks: [Bookmark]
    let onSelect: (Bookmark) -> Void
    let onDelete: (Bookmark) -> Void
    @Environment(\.presentationMode) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            Group {
                if bookmarks.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bookmark").font(.system(size: 48)).foregroundColor(
                            Color.secondary.opacity(0.3))
                        Text(gs.t("尚無書籤")).font(.headline).foregroundColor(.secondary)
                        Text(gs.t("在閱讀時點擊右上角書籤按鈕添加")).font(.subheadline).foregroundColor(
                            Color.secondary.opacity(0.7))
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(bookmarks) { bm in
                            Button {
                                onSelect(bm)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(bm.chapterTitle).font(
                                            .system(size: 15, weight: .medium)
                                        ).foregroundColor(.primary).lineLimit(1)
                                        Spacer()
                                        Text(bm.date, style: .date).font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    if !bm.excerpt.isEmpty {
                                        Text(bm.excerpt + "…").font(.system(size: 13))
                                            .foregroundColor(.secondary).lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }.onDelete { idxs in
                            for idx in idxs {
                                if idx < bookmarks.count { onDelete(bookmarks[idx]) }
                            }
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle(gs.t("書籤") + "（\(bookmarks.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(gs.t("關閉")) { dismiss.wrappedValue.dismiss() }
                }
            }
        }.navigationViewStyle(.stack)
    }
}

// MARK: - 目錄視圖
struct TOCView: View {
    let chapters: [BookChapter]
    @Binding var currentIndex: Int
    @Binding var isPresented: Bool
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    Button {
                        currentIndex = chapter.index
                        isPresented = false
                    } label: {
                        HStack(spacing: 0) {
                            // 子章節縮排：每層 16pt
                            if chapter.level > 0 {
                                Color.clear.frame(width: CGFloat(chapter.level) * 16)
                            }
                            Text(chapter.title)
                                .font(
                                    chapter.level == 0
                                        ? .system(size: 15, weight: .medium)
                                        : .system(size: 13)
                                )
                                .foregroundColor(chapter.level == 0 ? .primary : .secondary)
                                .lineLimit(2)
                            Spacer()
                            if chapter.index == currentIndex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, chapter.level == 0 ? 2 : 0)
                    }
                    .listRowBackground(
                        chapter.index == currentIndex ? Color.blue.opacity(0.08) : Color.clear
                    )
                    .animation(.easeInOut(duration: 0.2), value: currentIndex)
                    .id(chapter.index)
                }
                .listStyle(.plain)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if chapters.first(where: { $0.index == currentIndex }) != nil {
                            withAnimation { proxy.scrollTo(currentIndex, anchor: .center) }
                        }
                    }
                }
            }
            .navigationTitle(gs.t("目錄"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(gs.t("關閉")) { isPresented = false }
                }
            }
        }.navigationViewStyle(.stack)
    }
}

// MARK: - 隱藏 TabBar（iOS 15 / 16 相容）
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

// 舊 WebView 閱讀橋接已移除，正式路徑統一由 CoreText 引擎負責。

// MARK: - CoreText UIPageViewController 橋接

private struct CoreTextPageEngineView: UIViewControllerRepresentable {
    let engine: any PageRenderingProvider
    let pageTurnStyle: PageTurnStyle
    @Binding var currentPage: Int
    let onPageChanged: (Int) -> Void
    let onTapZone: (String) -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let transitionStyle: UIPageViewController.TransitionStyle
        switch pageTurnStyle {
        case .curl:              transitionStyle = .pageCurl
        case .slide, .cover, .none: transitionStyle = .scroll
        }
        let pvc = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal
        )

        // cover / none 模式：停用內建滑動手勢（靠自訂 pan 或 tap 翻頁）
        if pageTurnStyle == .cover || pageTurnStyle == .none {
            pvc.dataSource = nil
            for case let sv as UIScrollView in pvc.view.subviews {
                sv.isScrollEnabled = false
            }
        } else {
            pvc.dataSource = context.coordinator
        }
        pvc.delegate = context.coordinator

        // 優先用 SwiftUI binding 的 currentPage，避免切換翻頁樣式重建時跳回舊座標。
        let initialPage = engine.totalPages > 0
            ? max(0, min(currentPage, engine.totalPages - 1))
            : 0
        let initialVC = engine.pageViewController(at: initialPage)
        context.coordinator.captureStablePosition(from: initialVC)
        pvc.setViewControllers([initialVC], direction: .forward, animated: false)
        // 同步 binding，讓 ReaderView.currentPage 對齊 engine 恢復的位置
        if initialPage != currentPage {
            context.coordinator.suppressNextTransition = true
            DispatchQueue.main.async {
                self.currentPage = initialPage
                self.onPageChanged(initialPage)
            }
        }

        // Tap zone recognizer: left 30% → prev, right 30% → next, center → menu
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        pvc.view.addGestureRecognizer(tap)

        // cover 模式：加自訂 pan gesture + overlay
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
        context.coordinator.bindEngineCallbacks(to: engine, pageViewController: uiViewController)
        let clampedPage = max(0, min(currentPage, max(engine.totalPages - 1, 0)))

        if let visible = uiViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) {
            guard visible.globalPageIndex != clampedPage else { return }
            let direction: UIPageViewController.NavigationDirection =
                clampedPage >= visible.globalPageIndex ? .forward : .reverse

            // 消耗 makeUIViewController 設置的抑制 flag：首次對齊時強制瞬切
            if context.coordinator.suppressNextTransition {
                context.coordinator.suppressNextTransition = false
                let targetVC = engine.pageViewController(at: clampedPage)
                uiViewController.setViewControllers([targetVC], direction: direction, animated: false)
                _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
                return
            }

            // 核心修復：非相鄰跳頁（目錄跳轉、offset 重算）一律瞬切，避免 cover 連環 reverse。
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
                    let targetVC = engine.pageViewController(at: clampedPage)
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

        let targetVC = engine.pageViewController(at: clampedPage)
        uiViewController.setViewControllers([targetVC], direction: .forward, animated: false)
        _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            engine: engine,
            pageTurnStyle: pageTurnStyle,
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
        @Binding var currentPage: Int
        let onPageChanged: (Int) -> Void
        let onTapZone: (String) -> Void

        // cover 動畫 overlay 元件
        private let coverOverlayView = UIView()
        private let coverCurrentImageView = UIImageView()
        private let coverDimView = UIView()          // backward：舊頁漸暗遮罩
        private let coverShadowView = UIView()        // 滑動頁邊緣投影
        private let coverIncomingImageView = UIImageView()
        private var coverTargetPage: Int?
        private var coverDirection: Int = 0  // 1 = forward, -1 = backward
        /// makeUIViewController 已設定初始頁後，suppressNextTransition = true
        /// 讓緊跟的 updateUIViewController 跳過多餘的 backward 動畫（binding 尚未同步）
        fileprivate var suppressNextTransition = false
        fileprivate var currentCoreTextPosition: CoreTextReadingPosition?
        weak var coverPageViewController: UIPageViewController?
        private weak var callbackEngineObject: AnyObject?
        private var callbackEngineIdentifier: ObjectIdentifier?
        fileprivate var isTransitioning = false
        fileprivate var transitionQueue = ReaderPageTransitionQueue()

        init(engine: any PageRenderingProvider,
             pageTurnStyle: PageTurnStyle,
             currentPage: Binding<Int>,
             onPageChanged: @escaping (Int) -> Void,
             onTapZone: @escaping (String) -> Void) {
            self.currentEngine = engine
            self.pageTurnStyle = pageTurnStyle
            self._currentPage = currentPage
            self.onPageChanged = onPageChanged
            self.onTapZone = onTapZone
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
            let engine = currentEngine
            let fallbackPage = max(0, min(currentPage, max(engine.totalPages - 1, 0)))
            let freshVC: UIViewController
            let targetPage: Int

            if let position = currentCoreTextPosition {
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

            let direction: UIPageViewController.NavigationDirection
            if let first = pageViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) {
                direction = targetPage >= first.globalPageIndex ? .forward : .reverse
            } else {
                direction = .forward
            }

            pageViewController.setViewControllers([freshVC], direction: direction, animated: false)
            let resolved = syncStablePosition(afterShowing: freshVC, notifyFallback: false)
            let resolvedLine =
                "[StartupTrace][ReaderView.Coordinator] handleChapterReady syncedPage=\(resolved ?? -1)"
            print(resolvedLine)
            NSLog("%@", resolvedLine)
        }

        private func handleNavigate(to page: Int) {
            let clamped = max(0, min(page, max(currentEngine.totalPages - 1, 0)))
            currentPage = clamped
            onPageChanged(clamped)
        }

        private func continueQueuedTransitionIfNeeded(
            on pageViewController: UIPageViewController,
            showing visiblePage: Int
        ) {
            guard let queuedPage = transitionQueue.transitionFinished(showing: visiblePage) else { return }
            let direction: UIPageViewController.NavigationDirection =
                queuedPage >= visiblePage ? .forward : .reverse
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
            let zone = x < w * 0.3 ? "left" : x > w * 0.7 ? "right" : "center"
            DispatchQueue.main.async { self.onTapZone(zone) }
        }

        func captureStablePosition(from viewController: UIViewController) {
            currentCoreTextPosition = readingPosition(from: viewController)
        }

        @discardableResult
        func syncStablePosition(afterShowing viewController: UIViewController, notifyFallback: Bool) -> Int? {
            let fallbackPage = (viewController as? any PageIndexProviding)?.globalPageIndex ?? currentPage
            if let position = readingPosition(from: viewController) {
                currentCoreTextPosition = position
                if let resolvedPage = currentEngine.pageIndex(for: position) {
                    currentPage = resolvedPage
                    onPageChanged(resolvedPage)
                    return resolvedPage
                }
                currentPage = fallbackPage
                if notifyFallback {
                    onPageChanged(fallbackPage)
                    return fallbackPage
                }
                return nil
            }

            currentPage = fallbackPage
            if notifyFallback {
                onPageChanged(fallbackPage)
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

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex > 0 else { return nil }
            let (currentSpine, currentLocal) = currentEngine.localPosition(for: vc.globalPageIndex)
            if currentLocal == 0 && currentSpine > 0 {
                return currentEngine.pageViewController(for: .chapterEnd(currentSpine - 1))
            }
            return currentEngine.pageViewController(at: vc.globalPageIndex - 1)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex < currentEngine.totalPages - 1 else { return nil }
            let (currentSpine, _) = currentEngine.localPosition(for: vc.globalPageIndex)
            if let lastPage = currentEngine.lastPageIndex(ofChapter: currentSpine),
               vc.globalPageIndex == lastPage {
                let nextPosition = CoreTextReadingPosition.chapterStart(currentSpine + 1)
                if let targetPage = currentEngine.pageIndex(for: nextPosition),
                   let snapVC = currentEngine.snapshotViewController(at: targetPage) {
                    return snapVC
                }
                return currentEngine.pageViewController(for: nextPosition)
            }
            let nextIndex = vc.globalPageIndex + 1
            // 快照接力：若下一頁是新章節且快照已就緒，回傳靜態圖 VC 供動畫用
            if let snapVC = currentEngine.snapshotViewController(at: nextIndex) {
                return snapVC
            }
            return currentEngine.pageViewController(at: nextIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(
            _ pvc: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            transitionQueue.beginInteractiveTransition()
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed else {
                let settledPage = (pvc.viewControllers?.first as? (any PageIndexProviding & UIViewController))?.globalPageIndex
                    ?? currentPage
                continueQueuedTransitionIfNeeded(on: pvc, showing: settledPage)
                return
            }

            // 若落地的是快照 VC，立即換成真正的渲染 VC（佈局已就緒，視覺上無縫）
            if let snapVC = pvc.viewControllers?.first as? SnapshotPageViewController {
                let realVC: UIViewController
                if let position = snapVC.coreTextReadingPosition {
                    realVC = currentEngine.pageViewController(for: position)
                } else {
                    realVC = currentEngine.pageViewController(at: snapVC.globalPageIndex)
                }
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

            // 投影 view：在 incoming 下方，不 clip，讓陰影能溢出
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

            // 暗色遮罩（backward 用）：疊在舊頁上，隨上一頁蓋入漸暗
            coverDimView.backgroundColor = .black
            coverDimView.alpha = 0
            coverDimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            coverCurrentImageView.addSubview(coverDimView)
        }

        // MARK: - Cover pan gesture
        
        private enum GestureConstants {
            /// The minimum horizontal translation (in points) required to trigger the cover animation.
            static let initialTranslationThreshold: CGFloat = 18.0
            /// The threshold ratio (0.0 to 1.0) of the screen width that must be crossed to commit the page turn.
            static let commitProgressRatio: CGFloat = 0.34
            /// The minimum flick velocity (in points per second) to commit the page turn even if the progress ratio is not reached.
            static let commitVelocityThreshold: CGFloat = 560.0
            /// The duration (in seconds) of the settling animation when the user releases their finger.
            static let settleAnimationDuration: TimeInterval = 0.22
            /// The maximum alpha value for the dimming overlay during the cover animation.
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
                // 取消前一次可能還在播的動畫，不在此顯示 overlay（等方向確認後才顯示）
                coverOverlayView.layer.removeAllAnimations()
                coverIncomingImageView.layer.removeAllAnimations()
                coverDimView.layer.removeAllAnimations()
                coverDimView.alpha = 0

            case .changed:
                if coverTargetPage == nil {
                    if translationX < -GestureConstants.initialTranslationThreshold, currentPage < currentEngine.totalPages - 1 {
                        // Forward uncover：當前頁往左滑走，新頁在底下
                        coverDirection = 1
                        let target = currentPage + 1
                        coverTargetPage = target
                        coverOverlayView.frame = view.bounds
                        coverCurrentImageView.frame = view.bounds
                        coverOverlayView.isHidden = false
                        setupForwardOutgoing(currentPageSnapshot: currentPage, newPage: target, in: view)
                    } else if translationX > GestureConstants.initialTranslationThreshold, currentPage > 0 {
                        // Backward cover：上一頁從左側蓋入
                        let target = currentPage - 1
                        // 若 snapshot 尚未就緒（章節未載入），不啟動動畫
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
                        // 先把真正的 VC 設上去，讓 updateUIViewController 進來時早返回，避免二次動畫
                        if let pvc = self.coverPageViewController {
                            let realVC = self.currentEngine.pageViewController(at: targetPage)
                            pvc.setViewControllers([realVC], direction: .forward, animated: false)
                            pvc.view.layoutIfNeeded()
                            self.captureStablePosition(from: realVC)
                        }
                        self.currentPage = targetPage
                        self.onPageChanged(targetPage)
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
            
            // 邊界保護
            let total = currentEngine.totalPages
            guard targetPage >= 0, total == 0 || targetPage < total else {
                resetCoverOverlay()
                return
            }
            
            isTransitioning = true
            let width = max(view.bounds.width, 1)

            // 清理可能殘留的動畫狀態
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
                    let latestPage = self.currentPage // 抓取最新的 binding 值
                    let realVC = self.currentEngine.pageViewController(at: latestPage)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded() // 強制佈局，避免 scroll 偏移殘留
                    
                    self.captureStablePosition(from: realVC)
                    self.onPageChanged(latestPage)
                    Task { @MainActor in self.currentEngine.warmUpNext(currentGlobalPage: latestPage) }
                    
                    self.resetCoverOverlay()
                    self.isTransitioning = false
                }
            } else {
                // Backward cover
                guard let targetSnapshot = currentEngine.renderSnapshot(forPage: targetPage) else {
                    let latestPage = self.currentPage
                    let realVC = currentEngine.pageViewController(at: latestPage)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    self.captureStablePosition(from: realVC)
                    self.onPageChanged(latestPage)
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
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    pvc.view.layoutIfNeeded()
                    
                    self.captureStablePosition(from: realVC)
                    self.onPageChanged(latestPage)
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
            // 新頁作為靜態背景
            coverCurrentImageView.image = currentEngine.renderSnapshot(forPage: newPage)
            coverCurrentImageView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            // 當前頁從 x=0 往左滑走，右側圓角（最後消失的邊緣），投影往右落在新頁
            coverIncomingImageView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            coverIncomingImageView.image = currentEngine.renderSnapshot(forPage: currentPageSnapshot)
            coverIncomingImageView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            coverShadowView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            coverShadowView.layer.shadowOffset = CGSize(width: 10, height: 0)
            coverShadowView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            coverShadowView.layer.shadowPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: h)).cgPath
            coverDimView.frame = CGRect(x: 0, y: 0, width: width, height: h)
            // alpha 不在此設定，由呼叫方依 context 決定（pan 從 rawProgress 算，tap 由動畫起點設）
        }

        private func setupIncomingView(for targetPage: Int, snapshot: UIImage?, in view: UIView) {
            let width = max(view.bounds.width, 1)
            let h = view.bounds.height
            // Backward cover：上一頁從左滑入，右側圓角，投影往左落在舊頁
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
