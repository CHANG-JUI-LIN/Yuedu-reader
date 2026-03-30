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

// MARK: - 閱讀位置（與字體/螢幕尺寸無關，Koodo Reader BookLocation 對應設計）
private struct ReadingPosition: Codable {
    /// 章節索引（0 起始）
    var chapterIndex: Int
    /// 章節內字符偏移量（pageInChapter × charsPerPage）
    var charOffsetInChapter: Int
    /// 整體進度百分比（0.0 – 1.0），供書架進度條快速讀取
    var percentage: Double
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

// MARK: - 閱讀器主視圖
struct ReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var settings = GlobalSettings.shared

    @State private var chapters: [BookChapter] = []
    @State private var allPages: [PageContent] = []
    @State private var currentPage = 0
    @State private var showBars = false
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var showBookmarkList = false
    @State private var fontSize: CGFloat = CGFloat(GlobalSettings.shared.readerFontSize)
    @State private var readerTheme: ReaderTheme = ReaderTheme.loadPersisted()

    // 線上章節懶加載
    @State private var fetchingChapters: Set<Int> = []
    @State private var failedChapters: Set<Int> = []
    @State private var lastChapterError: String = ""

    // 亮度
    @State private var systemBrightness: Double = 0.5
    @State private var showBrightness = false

    /// 頂部 safe area（pt），傳給 EPUB 引擎讓 margin-top 至少為此值
    @State private var readerSafeAreaTop: CGFloat = 59
    @State private var readerViewportSize: CGSize = UIScreen.main.bounds.size
    // 音量翻頁
    @StateObject private var volumeHandler = VolumeKeyHandler()

    // 自動閱讀 + TTS
    @StateObject private var autoReader = AutoReadController()  // TTS
    @StateObject private var tts = TTSManager()

    // 時間與電池已移至 ReaderFooterView.swift (ClockBatteryModel)
    // 不再作為 ReaderView 的 @State，避免每分鐘觸發整個 body 重算

    private func syncReaderBrightnessFromSystem() {
        let current = Double(UIScreen.main.brightness)
        systemBrightness = current
        settings.readerBrightness = current
    }

    private func restoreReaderDisplayStateAfterResume() {
        guard useWebRenderer else { return }
        guard epubRenderer.totalPages > 0 else { return }
        let targetPage = max(0, min(epubRenderer.currentEpubPage, epubRenderer.totalPages - 1))
        currentPage = targetPage
        currentChapterIndex = epubRenderer.chapterIndex(forGlobalPage: targetPage)
    }

    // EPUB 渲染器（直接 WKWebView 呈現）
    @StateObject private var epubRenderer = EPUBPageRenderer()
    @State private var useWebRenderer = false  // true = EPUB/TXT 用 EPUBPageRenderer + 直接 WKWebView
    @State private var isWebRenderReady = false // WebView 真正畫好第一頁才為 true（消除白屏閃爍）


    // TXT → XHTML 暫存路徑（離開時清理）
    @State private var txtXHTMLBasePath: URL? = nil

    @State private var showTTSPanel = false
    @State private var showAutoReadPanel = false

    private let onlineCoordinator = OnlineBookCoordinator.shared

    // EPUB 章節導航狀態
    @State private var currentChapterIndex = 0

    // 捲動模式進度追蹤
    @State private var scrollVisibleChapter = 0

    // 防止載入期間 TabView 重置 selection 導致進度被覆寫為 0
    @State private var isRestoringPosition = true
    @State private var savedPositionSnapshot: Double = 0
    @State private var isLoadingPipeline = false

    // 換源
    @State private var showChangeSourceSheet = false
    @State private var changeSourceOrigins: [BookOrigin] = []
    @State private var changeSourceLoading = false
    @State private var changeSourceError: String?
    @State private var refreshTrigger = 0
    @State private var curlStartupStartedAt: CFAbsoluteTime? = nil
    @State private var hasLoggedCurlInteractiveReady = false
    @State private var hasPerformedInitialLoad = false
    @State private var chapterSliderDraft: Double? = nil
    @State private var epubVerticalVisiblePage = 0
    @State private var epubVerticalScrollTargetPage: Int? = nil
    @State private var epubVerticalScrollTargetAnimated = false
    @State private var epubVerticalIgnoreVisibleUpdatesUntil: CFAbsoluteTime = 0
    @State private var epubVerticalSettleWorkItem: DispatchWorkItem? = nil

    // Progressive ingest debounce（避免每個章節到達都 full reload）
    @State private var reloadOnlineGeneration = 0
    @State private var reloadOnlineDebounceWorkItem: DispatchWorkItem? = nil
    /// 是否已成功初始化過 web package（用於判斷是否可以走增量路徑）
    @State private var hasInitializedWebPackage = false

    private var overlayContentMaxWidth: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 960 : .infinity
    }

    private var extraReaderHorizontalInset: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 28 : 0
    }

    private var effectivePageMarginH: CGFloat {
        CGFloat(settings.pageMarginH) + extraReaderHorizontalInset
    }

    private var effectivePageMarginV: CGFloat {
        CGFloat(settings.pageMarginV)
    }

    // ── 衍生屬性 ──
    var book: ReadingBook? { store.books.first(where: { $0.id == bookId }) }

    // 核心判斷：是否為 EPUB
    var isEPUB: Bool {
        book?.resolvedPipelineKind == .epub
    }

    private var telemetryPipelineKind: String {
        if let b = book {
            if b.isOnline { return "online" }
            switch b.resolvedPipelineKind {
            case .epub:
                return "epub"
            case .html:
                return useWebRenderer ? "html_web" : "html"
            case .txt:
                return useWebRenderer ? "txt_web" : "txt"
            }
        }
        return "txt"
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
        if useWebRenderer {
            let chIdx = epubRenderer.chapterIndex(forGlobalPage: currentPage)
            if chIdx >= 0, chIdx < chapters.count { return chapters[chIdx].title }
            return epubRenderer.bookTitle.isEmpty ? "EPUB" : epubRenderer.bookTitle
        }
        guard !allPages.isEmpty else { return "" }
        return allPages[min(currentPage, allPages.count - 1)].chapterTitle
    }

    var canGoPrevChapter: Bool { currentChapterIndex > 0 }
    var canGoNextChapter: Bool { currentChapterIndex < chapters.count - 1 }

    /// Footer 文字區本體高度（pt），不含 safe area bottom
    private let footerOverlayHeight: CGFloat = 24

    /// 當前頁是否有書籤
    var isCurrentPageBookmarked: Bool {
        store.isPageBookmarked(bookId: bookId, pageIndex: currentPage)
    }

    /// 當前頁摘錄（前 30 字）
    var currentPageExcerpt: String {
        guard !allPages.isEmpty else { return "" }
        let content = allPages[min(currentPage, allPages.count - 1)].content
        return String(content.prefix(30))
    }

    /// 閱讀總進度百分比
    var totalProgressPercent: String {
        if useWebRenderer {
            return String(format: "%.2f%%", epubRenderer.percentage * 100)
        }
        guard !allPages.isEmpty else { return "0.00%" }
        let pct = Double(currentPage) / Double(max(allPages.count - 1, 1)) * 100
        return String(format: "%.2f%%", pct)
    }

    /// 章節頁碼資訊
    var chapterPageInfo: String {
        if useWebRenderer {
            if epubRenderer.totalPages > 0 {
                let localP = epubRenderer.localPage(forGlobalPage: epubRenderer.currentEpubPage) + 1
                let chIdx = epubRenderer.currentChapterIdx
                let chTotal = epubRenderer.pageCount(forChapter: chIdx)
                return "\(localP)/\(chTotal)"
            }
            return ""
        }
        guard !allPages.isEmpty else { return "" }
        let page = allPages[min(currentPage, allPages.count - 1)]
        let total = allPages.filter { $0.chapterIndex == page.chapterIndex }.count
        return "\(page.pageInChapter + 1)/\(total)"
    }

    /// 當前頁內容（給 TTS 用）
    var currentPageText: String {
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
                    currentPage: $currentPage,
                    onPageChanged: { newPage in
                        currentChapterIndex = ctEngine.charOffset(forPage: newPage).spineIndex
                        epubRenderer.currentEpubPage = newPage
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
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if useWebRenderer {
                let _ = { print("[ReaderView] ⚠️ 使用 WKWebView 引擎（CoreText 未就緒：engine=\(epubRenderer.engine == nil ? "nil" : "有"), isCoreTextReady=\(epubRenderer.isCoreTextReady)）") }()
                webReaderBody
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if settings.scrollMode {
                scrollBody
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }

            // 章節載入失敗時顯示錯誤訊息（刷新功能已整合至工具列的刷新 icon）
            if book?.isOnline == true && !showBars && failedChapters.contains(currentChapterIndex) && !fetchingChapters.contains(currentChapterIndex) {
                VStack(spacing: 8) {
                    Spacer()
                    if !lastChapterError.isEmpty {
                        Text(lastChapterError)
                            .font(.system(size: 12))
                            .foregroundColor(readerTheme.textColor.opacity(0.6))
                            .lineLimit(3)
                            .padding(.horizontal, 24)
                            .multilineTextAlignment(.center)
                    }
                    Spacer().frame(height: 60)
                }
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }

            // 頂/底欄
            if !showBars && (!settings.scrollMode || useWebRenderer) && !chapters.isEmpty {
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
            if useWebRenderer {
                epubRenderer.setViewport(
                    size: readerViewportSize,
                    safeAreaInsets: UIEdgeInsets(top: effectiveReaderSafeTop, left: 0, bottom: windowSafeBottom, right: 0)
                )
            }
        }
        .onPreferenceChange(ReaderViewportSizeKey.self) {
            readerViewportSize = $0
            if useWebRenderer {
                epubRenderer.setViewport(
                    size: $0,
                    safeAreaInsets: UIEdgeInsets(top: effectiveReaderSafeTop, left: 0, bottom: windowSafeBottom, right: 0)
                )
            }
            epubRenderer.notifyViewportSize($0)
        }
        .animation(.easeInOut(duration: 0.25), value: chapters.isEmpty)
        .statusBarHidden(!showBars)
        .animation(.easeInOut(duration: 0.25), value: showBars)
        .modifier(HideTabBarModifier())
        .onAppear {
            ReaderTelemetry.shared.log(
                "reader_load_start",
                attributes: [
                    "bookId": bookId.uuidString,
                    "pipelineKind": telemetryPipelineKind,
                    "turnStyle": settings.pageTurnStyle.rawValue,
                    "scrollMode": settings.scrollMode ? "1" : "0",
                ]
            )
            // 先同步字體大小（必須在 loadContent 之前）
            fontSize = CGFloat(settings.readerFontSize)
            readerTheme = ReaderTheme.loadPersisted()
            if useWebRenderer {
                epubRenderer.setViewport(
                    size: readerViewportSize,
                    safeAreaInsets: UIEdgeInsets(top: effectiveReaderSafeTop, left: 0, bottom: windowSafeBottom, right: 0)
                )
                epubRenderer.setTransition(settings.scrollMode ? "vertical" : "horizontal")
            }
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
            tts.onPageFinished = {
                if !isEPUB, currentPage < allPages.count - 1 {
                    currentPage += 1
                    return allPages[currentPage].content
                }
                return nil
            }
        }
        .onDisappear {
            if !settings.followSystemBrightness {
                UIScreen.main.brightness = CGFloat(systemBrightness)
            }
            saveProgress()
            if let b = book, b.isOnline {
                Task {
                    await ChapterFetchManager.shared.cancelAll(for: b.id)
                }
            }
            volumeHandler.stopListening()
            autoReader.pause()
            tts.stop()
            // 取消 progressive reload debounce
            reloadOnlineDebounceWorkItem?.cancel()
            reloadOnlineDebounceWorkItem = nil
            // 清理 TXT → XHTML 暫存檔
            if let basePath = txtXHTMLBasePath {
                TXTToXHTMLConverter.cleanup(basePath: basePath)
                txtXHTMLBasePath = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                saveProgress()
                if useWebRenderer { epubRenderer.flushProgress() }
            } else if phase == .active {
                restoreReaderDisplayStateAfterResume()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in
            saveProgress()
            if useWebRenderer { epubRenderer.flushProgress() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            guard let engine = epubRenderer.engine else { return }
            let size = readerViewportSize  // use stored size, not UIScreen
            Task {
                await engine.invalidateLayout(newSize: size)
            }
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
        .onChange(of: showBrightness) { isVisible in
            if isVisible && settings.followSystemBrightness {
                syncReaderBrightnessFromSystem()
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
        .onChange(of: fontSize) { val in
            settings.readerFontSize = Double(val)
            if useWebRenderer { epubRenderer.setFontSize(val) } else { rebuildPages() }
        }
        .onChange(of: settings.pageMarginH) { _ in
            if useWebRenderer {
                epubRenderer.setPageMargins(horizontal: effectivePageMarginH, vertical: effectivePageMarginV)
            } else {
                rebuildPages()
            }
        }
        .onChange(of: settings.pageMarginV) { _ in
            if useWebRenderer {
                epubRenderer.setPageMargins(horizontal: effectivePageMarginH, vertical: effectivePageMarginV)
            } else {
                rebuildPages()
            }
        }
        .onChange(of: settings.lineSpacing) { _ in if !useWebRenderer { rebuildPages() } }
        .onChange(of: settings.letterSpacing) { _ in if !useWebRenderer { rebuildPages() } }
        .onChange(of: readerTheme) { _ in
            readerTheme.persist()
            if useWebRenderer {
                epubRenderer.setTheme(readerTheme.epubJSName)
            } else if isEPUB {
                rebuildPages()
            }
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
        .onChange(of: settings.scrollMode) { enabled in
            guard useWebRenderer else { return }
            epubRenderer.setTransition(enabled ? "vertical" : "horizontal")
        }
        .onChange(of: scrollVisibleChapter) { _ in
            autoSaveProgress()
        }
        .sheet(isPresented: $showSettings) {
            AdaptiveSheetContainer(maxWidth: 760) {
                FontSettingsView(fontSize: $fontSize, theme: $readerTheme)
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
                        if bookmark.pageIndex < (isEPUB ? chapters.count : allPages.count) {
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
                    tts: tts, currentText: currentPageText, chapterTitle: currentChapterTitle)
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
        .onChange(of: refreshTrigger) { _ in
            if refreshTrigger > 0 { loadContent() }
        }
        .modifier(
            EPUBRendererModifier(
                useWebRenderer: useWebRenderer,
                epubRenderer: epubRenderer,
                allPages: $allPages,
                chapters: $chapters,
                currentPage: $currentPage,
                isRestoringPosition: $isRestoringPosition,
                isWebRenderReady: $isWebRenderReady,
                book: book
            ))
    }

    private func performInitialLoad() {
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

        Task {
            _ = try? await store.refreshOnlineBookMetadata(
                bookId: currentBook.id,
                forceInfoRefresh: true
            )
            await MainActor.run {
                loadContent()
            }
        }
    }

    // MARK: - EPUB 方案 D 渲染器狀態監聽（snapshot + pageCurl）
    private struct EPUBRendererModifier: ViewModifier {
        let useWebRenderer: Bool
        @ObservedObject var epubRenderer: EPUBPageRenderer
        @Binding var allPages: [PageContent]
        @Binding var chapters: [BookChapter]
        @Binding var currentPage: Int
        @Binding var isRestoringPosition: Bool
        @Binding var isWebRenderReady: Bool
        let book: ReadingBook?
        /// 記錄上次同步到 allPages 的頁數，避免每次 totalPages 變化都重建整個陣列
        @State private var lastSyncedTotal = 0
        /// 是否已完成掃描並恢復過進度
        @State private var hasRestoredPosition = false

        func body(content: Content) -> some View {
            content
                .onChange(of: epubRenderer.totalPages) { newTotal in
                    guard useWebRenderer, newTotal > 0 else { return }

                    if lastSyncedTotal == 0 {
                        // 首次：建立已掃描的頁面，在背景線程計算
                        rebuildPageArrayAsync(total: newTotal)
                        lastSyncedTotal = newTotal
                        if epubRenderer.currentEpubPage < newTotal {
                            currentPage = epubRenderer.currentEpubPage
                        }
                        isRestoringPosition = false

                        // totalPages > 0 代表 DOM + CSS column 排版完成
                        // 給 GPU 100ms 緩衝把紋理推到螢幕，然後解除 Loading
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isWebRenderReady = true
                        }
                    }
        // 掃描期間不再逐章重建 allPages，避免互動層反覆重建卡 UI
                    // 最終重建在 snapshotProgress >= 1.0 時執行
                }
                .onChange(of: epubRenderer.tocCount) { _ in
                    let toc = epubRenderer.tocItems
                    guard useWebRenderer, !toc.isEmpty else { return }
                    chapters = toc.enumerated().map { (i, item) in
                        BookChapter(
                            index: i,
                            title: item["label"] as? String ?? "Chapter \(i + 1)",
                            content: "",
                            href: item["href"] as? String ?? "",
                            level: item["level"] as? Int ?? 0
                        )
                    }
                }
                // currentEpubPage 變化不再即時同步到 @State currentPage
                // 避免在快速翻頁時觸發整個 ReaderView body 重建
                // currentPage 由 webReaderBody 控制同步時機
                .onChange(of: epubRenderer.snapshotProgress) { progress in
                    guard useWebRenderer, progress >= 1.0, !hasRestoredPosition else { return }
                    hasRestoredPosition = true

                    // 所有章節掃描完成，在背景線程重建 allPages（避免主線程尖刺）
                    let total = epubRenderer.totalPages
                    guard total > 0 else { return }
                    rebuildPageArrayAsync(total: total)
                    lastSyncedTotal = total
                    if epubRenderer.currentEpubPage < total {
                        currentPage = epubRenderer.currentEpubPage
                    }
                }
        }

        /// 在背景線程計算 allPages，避免 1000+ 頁時阻塞主線程造成掉幀
        private func rebuildPageArrayAsync(total: Int) {
            let renderer = epubRenderer
            let currentChapters = chapters
            Task { @MainActor in
                // 先在主線程一次性把 globalPageMap 快照出來（陣列 copy，O(1) COW）
                let mapSnapshot: [(chapter: Int, page: Int)] = (0..<total).map { i in
                    (renderer.chapterIndex(forGlobalPage: i), renderer.localPage(forGlobalPage: i))
                }
                let bookTitle = renderer.bookTitle

                // 搬到背景線程做字串拼接
                let pages = await Task.detached(priority: .userInitiated) {
                    mapSnapshot.enumerated().map { (i, entry) in
                        let chTitle: String
                        if entry.chapter >= 0, entry.chapter < currentChapters.count {
                            chTitle = currentChapters[entry.chapter].title
                        } else {
                            chTitle = bookTitle.isEmpty ? "EPUB" : bookTitle
                        }
                        return PageContent(
                            chapterIndex: entry.chapter, chapterTitle: chTitle, content: "",
                            pageInChapter: entry.page)
                    }
                }.value

                allPages = pages
            }
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
                "useWebRenderer": useWebRenderer ? "1" : "0",
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

    private func makeEpubPageView(_ idx: Int, style: PageTurnStyle) -> AnyView {
        epubRenderer.willDisplayPage(idx, style: style)
        if style == .curl {
            epubRenderer.prepareDisplaySnapshot(forPage: idx, priority: -1)
        }
        return AnyView(epubSnapshotPage(idx))
    }

    private func epubSnapshotImage(_ idx: Int) -> some View {
        let pageState = epubRenderer.pageSnapshotState(forPage: idx)
        return ZStack {
            if let snapshot = epubRenderer.snapshot(forPage: idx) {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    readerTheme.backgroundColor
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(pageState == .loading ? settings.t("準備中…") : settings.t("渲染中…"))
                            .font(.system(size: 14))
                            .foregroundColor(readerTheme.textColor.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .ignoresSafeArea()
    }

    private func epubSnapshotPage(_ idx: Int, showsFooter: Bool = true) -> some View {
        return ZStack {
            epubSnapshotImage(idx)
            if showsFooter {
                inlineFooter(forPage: idx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .ignoresSafeArea()
    }


    private func requestEpubVerticalScroll(to page: Int, animated: Bool) {
        guard epubRenderer.totalPages > 0 else { return }
        let clamped = max(0, min(page, epubRenderer.totalPages - 1))
        epubVerticalScrollTargetAnimated = animated
        epubVerticalIgnoreVisibleUpdatesUntil = CFAbsoluteTimeGetCurrent() + (animated ? 0.35 : 0.15)
        epubVerticalScrollTargetPage = clamped
    }

    private func scheduleEpubVerticalSettle(for page: Int) {
        epubVerticalSettleWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard page == currentPage else { return }
            epubRenderer.goToPage(page)
            currentChapterIndex = epubRenderer.currentChapterIdx
            autoSaveProgress()
        }
        epubVerticalSettleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func handleEpubVerticalOffsets(_ offsets: [Int: CGFloat], viewportHeight: CGFloat) {
        guard !offsets.isEmpty, epubRenderer.totalPages > 0 else { return }
        let anchorY = viewportHeight * 0.22
        guard
            let visible = offsets.min(by: {
                abs($0.value - anchorY) < abs($1.value - anchorY)
            })?.key
        else { return }

        epubVerticalVisiblePage = visible
        guard CFAbsoluteTimeGetCurrent() >= epubVerticalIgnoreVisibleUpdatesUntil else { return }
        guard visible != currentPage else {
            scheduleEpubVerticalSettle(for: visible)
            return
        }

        currentPage = visible
        currentChapterIndex = epubRenderer.chapterIndex(forGlobalPage: visible)
        autoSaveProgress()
        scheduleEpubVerticalSettle(for: visible)
    }


    // MARK: - EPUB Live WebView 閱讀體

    private var webReaderBody: some View {
        ZStack(alignment: .bottom) {
            ReaderWebContainerView(
                renderer: epubRenderer,
                pageTurnStyle: settings.pageTurnStyle,
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
            .ignoresSafeArea()
            .onChange(of: epubRenderer.currentEpubPage) { page in
                if page != currentPage {
                    currentPage = page
                }
                currentChapterIndex = epubRenderer.chapterIndex(forGlobalPage: page)
                autoSaveProgress()
            }
            .onChange(of: showBars) { visible in
                // 打開工具列時同步（slider 需要 currentPage）
                if visible {
                    currentPage = epubRenderer.currentEpubPage
                }
            }
            .onChange(of: currentPage) { newPage in
                if newPage != epubRenderer.currentEpubPage {
                    epubRenderer.goToPage(newPage)
                }
                currentChapterIndex = epubRenderer.chapterIndex(forGlobalPage: newPage)
                autoSaveProgress()
            }
            .onAppear {
                if epubRenderer.isReady {
                    currentPage = epubRenderer.currentEpubPage
                    currentChapterIndex = epubRenderer.chapterIndex(forGlobalPage: currentPage)
                }
            }

        }
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
        if useWebRenderer {
            guard epubRenderer.totalPages > 0 else { return ("", "0.00%") }
            let localP = epubRenderer.localPage(forGlobalPage: idx) + 1
            let chIdx = epubRenderer.chapterIndex(forGlobalPage: idx)
            let chTotal = epubRenderer.pageCount(forChapter: chIdx)
            let pct = Double(idx) / Double(max(epubRenderer.totalPages - 1, 1)) * 100
            return ("\(localP)/\(chTotal)", String(format: "%.2f%%", pct))
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
                            .onAppear { fetchChapterIfNeeded(chapterIndex: ci) }
                        } else {
                            let cleaned = chapter.content
                            let paragraphs = cleaned.converted(to: settings.textConversion)
                                .components(separatedBy: "\n").filter { !$0.isEmpty }
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                                Text(para)
                                    .font(.system(size: fontSize, design: .serif))
                                    .foregroundColor(readerTheme.textColor)
                                    .kerning(settings.letterSpacing)
                                    .lineSpacing(settings.lineSpacing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, settings.paragraphSpacing)
                            }
                            Color.clear.frame(height: 48 - settings.paragraphSpacing).clipped()
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
        if useWebRenderer {
            epubRenderer.turnPageProgrammatically(forward: false, style: settings.pageTurnStyle)
            return
        }
        switch settings.pageTurnStyle {
        case .none:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { currentPage -= 1 }
        case .slide, .cover:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage -= 1
            }
        case .curl:
            currentPage -= 1
        }
    }

    private func goToNextPage() {
        let maxPage = useWebRenderer ? epubRenderer.totalPages - 1 : allPages.count - 1
        guard currentPage < maxPage else { return }
        if useWebRenderer {
            epubRenderer.turnPageProgrammatically(forward: true, style: settings.pageTurnStyle)
            return
        }
        switch settings.pageTurnStyle {
        case .none:
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { currentPage += 1 }
        case .slide, .cover:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage += 1
            }
        case .curl:
            currentPage += 1
        }
    }

    // MARK: - 頂部欄
    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Button {
                        saveProgress()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .accessibilityIdentifier("reader_back_button")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(readerTheme.textColor)
                            .frame(width: 36, height: 36)
                    }
                    Text(currentChapterTitle.converted(to: settings.textConversion))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(readerTheme.textColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Button {
                        withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                            store.toggleBookmark(
                                bookId: bookId,
                                chapterIndex: currentChapterIndex,
                                chapterTitle: currentChapterTitle,
                                pageIndex: currentPage,
                                excerpt: currentPageExcerpt
                            )
                        }
                    } label: {
                        Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(isCurrentPageBookmarked ? .orange : readerTheme.textColor)
                            .scaleEffect(isCurrentPageBookmarked ? 1.15 : 1.0)
                            .frame(width: 36, height: 36)
                    }
                    .animation(.easeInOut(duration: uiFeedbackDuration), value: isCurrentPageBookmarked)
                }
                .frame(maxWidth: overlayContentMaxWidth)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(readerTheme.barColor)
            Divider().opacity(0.18)
            Spacer()
        }
    }

    // MARK: - 底部欄
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Spacer()

            // 四個懸浮按鈕
            HStack(spacing: 12) {
                Spacer()
                circleBtn(icon: "arrow.clockwise") { refreshCurrentChapter() }
                if book?.isOnline == true && book?.bookSourceId != nil {
                    circleBtn(icon: "arrow.left.and.right") { showChangeSourceSheet = true }
                }
                if book?.isOnline == true {
                    circleBtn(icon: downloadButtonIcon) { handleDownloadAction() }
                }
                circleBtn(icon: "headphones") { showTTSPanel = true }
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
        }
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
                                        refreshTrigger += 1
                                        showChangeSourceSheet = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        changeSourceError = error.localizedDescription
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

    private func chapterSliderProgressValue() -> Double {
        if isEPUB {
            guard chapters.count > 1 else { return 0 }
            return Double(currentChapterIndex) / Double(chapters.count - 1)
        }
        guard allPages.count > 1 else { return 0 }
        return Double(currentPage) / Double(allPages.count - 1)
    }

    private func applyChapterSliderProgress(_ value: Double) {
        if isEPUB {
            let idx = Int(value * Double(max(chapters.count - 1, 1)))
            jumpToChapter(max(0, min(idx, chapters.count - 1)))
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
    }

    // MARK: 工具列
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
                    readerTheme = readerTheme == .night ? .sepia : .night
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

    private func jumpToChapter(_ idx: Int) {
        guard chapters.indices.contains(idx) else { return }
        if let b = book, b.isOnline, useWebRenderer {
            currentChapterIndex = idx
            Task {
                if let package = await onlineCoordinator.fetchJumpTarget(
                    for: b,
                    chapterIndex: idx,
                    store: store
                ) {
                    let marginH = effectivePageMarginH
                    let marginV = effectivePageMarginV
                    let settings = currentRenderSettings(marginH: marginH, marginV: marginV)
                    await MainActor.run {
                        if hasInitializedWebPackage {
                            epubRenderer.reloadWithUpdatedPackage(package, settings: settings)
                        } else {
                            applyWebPackage(
                                package,
                                settings: settings,
                                deferCurrentPageSync: true
                            )
                        }
                        epubRenderer.jumpToChapter(idx, preferredLocalPage: 0)
                    }
                } else {
                    await MainActor.run {
                        epubRenderer.jumpToChapter(idx, preferredLocalPage: 0)
                    }
                }
            }
            return
        }
        if isEPUB && useWebRenderer {
            epubRenderer.jumpToChapter(idx, preferredLocalPage: 0)
            currentChapterIndex = idx
        } else {
            currentChapterIndex = idx
            if let p = findChapterFirstPage(idx) { currentPage = p }
            if !isEPUB { fetchChapterIfNeeded(chapterIndex: idx) }
        }
    }

    private func autoSaveProgress() {
        guard !isRestoringPosition else { return }

        // 儲存 ReadingPosition（章節索引 + 頁碼偏移，與字體/螢幕無關）
        if useWebRenderer {
            // EPUB：使用 epubRenderer 的確切頁數（allPages 可能滯後於掃描進度）
            let total = epubRenderer.totalPages
            guard total > 0 else { return }
            epubRenderer.syncProgressToPage(currentPage, flush: false)
            let chIdx = epubRenderer.chapterIndex(forGlobalPage: currentPage)
            let pct = Double(currentPage) / Double(max(total - 1, 1))
            currentChapterIndex = chIdx
            store.updatePosition(bookId: bookId, position: min(1.0, max(0.0, pct)))
        } else if !settings.scrollMode && !allPages.isEmpty {
            // TXT：使用 allPages
            let page = allPages[min(currentPage, allPages.count - 1)]
            let pos = ReadingPosition(
                chapterIndex: page.chapterIndex,
                charOffsetInChapter: page.pageInChapter,
                percentage: Double(currentPage) / Double(max(allPages.count - 1, 1))
            )
            if let data = try? JSONEncoder().encode(pos) {
                UserDefaults.standard.set(data, forKey: "readerPos_\(bookId.uuidString)")
            }
            currentChapterIndex = page.chapterIndex
            let progress = Double(currentPage) / Double(max(allPages.count - 1, 1))
            store.updatePosition(bookId: bookId, position: min(1.0, max(0.0, progress)))
        } else {
            // 滾動模式
            let progress = Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1))
            store.updatePosition(bookId: bookId, position: min(1.0, max(0.0, progress)))
        }
    }

    private func saveProgress() {
        // onDisappear 時強制保存，不受 isRestoringPosition 限制
        let wasRestoring = isRestoringPosition
        isRestoringPosition = false
        autoSaveProgress()
        isRestoringPosition = wasRestoring
        // EPUB: 立即 flush debounced 進度到磁碟
        if useWebRenderer {
            epubRenderer.syncProgressToPage(currentPage, flush: true)
        }
    }

    private func refreshCurrentChapter() {
        guard let b = book, b.isOnline else { return }
        let idx = currentChapterIndex
        BookSourceFetcher.shared.clearChapterCache(bookId: b.id, chapterIndex: idx)
        store.clearCachedChapter(bookId: b.id, chapterIndex: idx)
        fetchingChapters.remove(idx)
        failedChapters.remove(idx)
        if useWebRenderer {
            reloadOnlinePackage(
                for: b,
                focusChapter: idx,
                marginH: effectivePageMarginH,
                marginV: effectivePageMarginV
            )
        }
        fetchChapterIfNeeded(chapterIndex: idx)
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
        switch b.offlineDownloadState {
        case .none, .failed:
            onlineCoordinator.downloadBook(b, store: store)
        case .downloading:
            break
        case .available:
            store.clearOnlineDownload(bookId: b.id)
        }
    }

    private func loadOtherOrigins() {
        guard let b = book, let currentSourceId = b.bookSourceId else { return }
        let key = SearchBook.makeKey(name: b.title, author: b.author)
        let sources = BookSourceStore.shared.enabledSources.filter { $0.id != currentSourceId }
        changeSourceLoading = true
        changeSourceError = nil
        changeSourceOrigins = []
        Task {
            var byKey: [String: [OnlineBook]] = [:]
            for source in sources {
                do {
                    let list = try await BookSourceFetcher.shared.search(query: b.title, in: source)
                    for ob in list {
                        let k = SearchBook.makeKey(name: ob.name, author: ob.author)
                        if byKey[k] == nil { byKey[k] = [] }
                        byKey[k]?.append(ob)
                    }
                } catch { continue }
            }
            let candidates = byKey[key] ?? []
            let origins: [BookOrigin] =
                candidates
                .filter { $0.sourceId != currentSourceId }
                .map { ob in
                    BookOrigin(
                        sourceId: ob.sourceId,
                        sourceName: ob.sourceName,
                        bookUrl: ob.bookUrl,
                        tocUrl: ob.tocUrl,
                        coverUrl: ob.coverUrl,
                        intro: ob.intro,
                        lastChapter: ob.lastChapter,
                        wordCount: ob.wordCount,
                        kind: ob.kind,
                        runtimeVariables: ob.runtimeVariables
                    )
                }
            await MainActor.run {
                changeSourceOrigins = origins
                changeSourceLoading = false
            }
        }
    }

    // MARK: - 線上章節懶加載
    private func fetchChapterIfNeeded(chapterIndex: Int) {
        guard let b = book, b.isOnline, let refs = b.onlineChapters, chapterIndex < refs.count,
            !fetchingChapters.contains(chapterIndex)
        else {
            return
        }

        if BookSourceFetcher.shared.isChapterCached(bookId: b.id, chapterIndex: chapterIndex) {
            if useWebRenderer {
                let marginH = effectivePageMarginH
                let marginV = effectivePageMarginV
                reloadOnlinePackage(
                    for: b,
                    focusChapter: chapterIndex,
                    marginH: marginH,
                    marginV: marginV,
                    immediate: chapterIndex == currentChapterIndex
                )
            } else {
                rebuildPages()
            }
            prefetchAdjacentChapters(around: chapterIndex)
            return
        }

        fetchingChapters.insert(chapterIndex)

        Task {
            let isCurrentChapter = chapterIndex == currentChapterIndex
            do {
                let pkg = try await ChapterFetchManager.shared.fetchChapter(
                    book: b,
                    chapterIndex: chapterIndex,
                    priority: .immediate,
                    store: store
                )
                await MainActor.run {
                    fetchingChapters.remove(chapterIndex)
                    // 檢查返回的 package 是否真正成功（有內容且狀態為 cached）
                    if pkg.state == .cached && !pkg.content.isEmpty {
                        failedChapters.remove(chapterIndex)
                    } else {
                        // fetchChapter 沒有 throw 但實際內容為空或狀態為 failed
                        failedChapters.insert(chapterIndex)
                        lastChapterError = "ch\(chapterIndex): \(pkg.failureReason ?? "內容為空")"
                    }
                    if useWebRenderer {
                        let marginH = effectivePageMarginH
                        let marginV = effectivePageMarginV
                        reloadOnlinePackage(
                            for: b,
                            focusChapter: chapterIndex,
                            marginH: marginH,
                            marginV: marginV,
                            immediate: isCurrentChapter
                        )
                    } else {
                        rebuildPages()
                    }
                    prefetchAdjacentChapters(around: chapterIndex)
                }
            } catch {
                await MainActor.run {
                    fetchingChapters.remove(chapterIndex)
                    failedChapters.insert(chapterIndex)
                    lastChapterError = "ch\(chapterIndex): \(error.localizedDescription)"
                    if useWebRenderer {
                        let marginH = effectivePageMarginH
                        let marginV = effectivePageMarginV
                        reloadOnlinePackage(
                            for: b,
                            focusChapter: chapterIndex,
                            marginH: marginH,
                            marginV: marginV,
                            immediate: isCurrentChapter
                        )
                    } else {
                        rebuildPages()
                    }
                }
            }
        }
    }

    private func prefetchAdjacentChapters(around chapterIndex: Int) {
        guard let b = book, b.isOnline else { return }
        Task {
            await onlineCoordinator.prefetchAround(book: b, center: chapterIndex, store: store)
        }
    }

    // MARK: - 載入 & 建頁
    private func currentRenderSettings(marginH: CGFloat, marginV: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: readerTheme.epubJSName,
            fontSize: fontSize,
            marginH: marginH,
            marginV: marginV,
            footerHeight: footerOverlayHeight
        )
    }

    private func applyWebPackage(
        _ package: BookPackage,
        settings: ReaderRenderSettings,
        deferCurrentPageSync: Bool = false
    ) {
        let tocLevelMap: [String: Int] = Dictionary(
            package.manifest.toc.map { ($0.href, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )

        useWebRenderer = true
        txtXHTMLBasePath = package.pipelineKind == .epub ? nil : package.basePath
        if let onlineRefs = book?.onlineChapters, !onlineRefs.isEmpty, book?.isOnline == true {
            chapters = onlineRefs.enumerated().map { (i, ref) in
                let href = "chapter_\(i).xhtml"
                let level =
                    tocLevelMap[href]
                    ?? tocLevelMap.first(where: {
                        href.hasSuffix($0.key) || $0.key.hasSuffix(href)
                    })?.value
                    ?? 0
                return BookChapter(
                    index: i,
                    title: ref.title,
                    content: "",
                    href: href,
                    level: level
                )
            }
        } else if package.pipelineKind == .epub {
            chapters = [BookChapter(index: 0, title: package.title, content: "")]
        } else {
            chapters = package.parsedBook.chapters.enumerated().map { (i, ch) in
                let level =
                    tocLevelMap[ch.href]
                    ?? tocLevelMap.first(where: {
                        ch.href.hasSuffix($0.key) || $0.key.hasSuffix(ch.href)
                    })?.value
                    ?? 0
                return BookChapter(
                    index: i,
                    title: ch.title,
                    content: "",
                    href: ch.href,
                    level: level
                )
            }
        }
        if chapters.isEmpty {
            chapters = [BookChapter(index: 0, title: package.title, content: "")]
        }
        allPages = [
            PageContent(
                chapterIndex: 0,
                chapterTitle: package.title,
                content: "",
                pageInChapter: 0
            )
        ]

        epubRenderer.setTransition("horizontal")
        epubRenderer.setViewport(
            size: readerViewportSize,
            safeAreaInsets: UIEdgeInsets(top: effectiveReaderSafeTop, left: 0, bottom: windowSafeBottom, right: 0)
        )
        epubRenderer.load(package: package, settings: settings)
        epubRenderer.onRelocated = { [weak store] _, pct in
            store?.updatePosition(bookId: bookId, position: pct)
        }

        if deferCurrentPageSync {
            currentPage = 0
        } else {
            currentPage = epubRenderer.currentEpubPage
        }
        isLoadingPipeline = false
        isRestoringPosition = false
        hasInitializedWebPackage = true
    }

    private func applyPublicationSession(
        _ session: PublicationSession,
        book: ReadingBook,
        settings: ReaderRenderSettings
    ) {
        let tocLevelMap: [String: Int] = Dictionary(
            session.tocEntries.map { ($0.href, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )

        useWebRenderer = true
        txtXHTMLBasePath = nil
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

        epubRenderer.setTransition("horizontal")
        epubRenderer.setViewport(
            size: readerViewportSize,
            safeAreaInsets: UIEdgeInsets(top: effectiveReaderSafeTop, left: 0, bottom: windowSafeBottom, right: 0)
        )
        epubRenderer.load(
            publicationSession: session,
            bookIdentifier: session.sourceURL.standardizedFileURL.path,
            renderSize: readerViewportSize,
            settings: settings
        )
        epubRenderer.onRelocated = { [weak store] _, pct in
            store?.updatePosition(bookId: book.id, position: pct)
        }

        currentPage = epubRenderer.currentEpubPage
        isLoadingPipeline = false
        isRestoringPosition = false
        hasInitializedWebPackage = true
    }

    private func currentWebLocalPage(preferredChapter: Int) -> Int {
        guard useWebRenderer, epubRenderer.totalPages > 0 else { return 0 }
        let activePage = min(max(currentPage, 0), max(epubRenderer.totalPages - 1, 0))
        let activeChapter = epubRenderer.chapterIndex(forGlobalPage: activePage)
        guard activeChapter == preferredChapter else { return 0 }
        return epubRenderer.localPage(forGlobalPage: activePage)
    }

    private func applyLegacyPackage(_ package: BookPackage, pageMarginH: CGFloat, pageMarginV: CGFloat)
    {
        let tocLevelMap: [String: Int] = Dictionary(
            package.manifest.toc.map { ($0.href, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )
        let targetPercentage = book?.currentPosition ?? 0
        let textColor = UIColor(readerTheme.textColor)
        let pageSize = NativePageBuilder.computePageSize(
            pageMarginH: pageMarginH,
            pageMarginV: pageMarginV,
            fontSize: self.fontSize,
            lineSpacing: self.settings.lineSpacing
        )

        // 預先建構章節資料和 legacyChapters（在背景線程，但只做字串處理，很快）
        DispatchQueue.global(qos: .userInitiated).async {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = self.settings.lineSpacing
            paragraphStyle.paragraphSpacing = self.settings.paragraphSpacing

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: self.fontSize),
                .foregroundColor: textColor,
                .kern: self.settings.letterSpacing,
                .paragraphStyle: paragraphStyle,
            ]

            let chapterPairs = package.parsedBook.chapters.map { chapter in
                let text = chapter.html.strippedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = text.isEmpty ? chapter.title : text
                return (
                    title: chapter.title,
                    attributed: NSAttributedString(string: normalized, attributes: attributes)
                )
            }

            let legacyChapters = package.parsedBook.chapters.enumerated().map { (i, ch) in
                let level =
                    tocLevelMap[ch.href]
                    ?? tocLevelMap.first(where: {
                        ch.href.hasSuffix($0.key) || $0.key.hasSuffix(ch.href)
                    })?.value
                    ?? 0
                return BookChapter(
                    index: i,
                    title: ch.title,
                    content: ch.html.strippedHTML,
                    href: ch.href,
                    level: level
                )
            }

            // 估算焦點章節（根據上次閱讀進度）
            let estimatedFocus = max(0, min(
                Int(targetPercentage * Double(max(chapterPairs.count - 1, 1))),
                chapterPairs.count - 1
            ))

            // 漸進式分頁：先分頁焦點區域 → 立刻顯示 UI → 背景繼續分頁剩餘章節
            NativePageBuilder.paginateProgressively(
                focusChapter: estimatedFocus,
                chapters: chapterPairs,
                pageSize: pageSize,
                fontSize: self.fontSize,
                lineSpacing: self.settings.lineSpacing,
                textColor: textColor,
                onReady: { initialSlices, _ in
                    let pages = initialSlices.map {
                        PageContent(
                            chapterIndex: $0.chapterIndex,
                            chapterTitle: $0.chapterTitle,
                            content: "",
                            pageInChapter: $0.pageInChapter,
                            attributedContent: $0.attributedContent
                        )
                    }

                    DispatchQueue.main.async {
                        self.useWebRenderer = false
                        self.chapters =
                            legacyChapters.isEmpty
                            ? [BookChapter(index: 0, title: package.title, content: "")]
                            : legacyChapters
                        self.allPages =
                            pages.isEmpty
                            ? [PageContent(
                                chapterIndex: 0,
                                chapterTitle: package.title,
                                content: "",
                                pageInChapter: 0
                            )]
                            : pages

                        let maxPage = max(self.allPages.count - 1, 0)
                        let desiredPage = min(
                            max(Int(round(targetPercentage * Double(max(maxPage, 1)))), 0),
                            maxPage
                        )
                        self.currentPage = desiredPage
                        self.currentChapterIndex = self.allPages[min(desiredPage, maxPage)].chapterIndex
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                    }
                },
                onProgress: { updatedSlices in
                    let pages = updatedSlices.map {
                        PageContent(
                            chapterIndex: $0.chapterIndex,
                            chapterTitle: $0.chapterTitle,
                            content: "",
                            pageInChapter: $0.pageInChapter,
                            attributedContent: $0.attributedContent
                        )
                    }

                    DispatchQueue.main.async {
                        // 保留當前閱讀的章節和頁碼不變，只更新 allPages
                        let currentChIdx = self.currentChapterIndex
                        let currentPageInChapter = self.allPages.isEmpty
                            ? 0
                            : self.allPages[min(self.currentPage, self.allPages.count - 1)].pageInChapter

                        self.allPages = pages

                        // 重新定位：找到當前章節+頁碼在新 allPages 中的位置
                        if let newIdx = pages.firstIndex(where: {
                            $0.chapterIndex == currentChIdx && $0.pageInChapter == currentPageInChapter
                        }) {
                            self.currentPage = newIdx
                        }
                    }
                }
            )
        }
    }

    private func loadOnlineContent(_ b: ReadingBook, marginH: CGFloat, marginV: CGFloat) {
        let initialFocusChapter = 0
        currentChapterIndex = initialFocusChapter
        chapters =
            b.onlineChapters?.map {
                BookChapter(index: $0.index, title: $0.title, content: "", href: "chapter_\($0.index).xhtml")
            } ?? [BookChapter(index: 0, title: b.title, content: "")]
        allPages = [
            PageContent(
                chapterIndex: 0,
                chapterTitle: b.title,
                content: "",
                pageInChapter: 0
            )
        ]
        currentPage = 0

        // 若書籍的章節列表為空，先重新拉取目錄再繼續
        if b.onlineChapters == nil || b.onlineChapters!.isEmpty {
            Task {
                do {
                    _ = try await store.refreshOnlineBookMetadata(
                        bookId: b.id, forceInfoRefresh: true
                    )
                    await MainActor.run {
                        // book 是 computed property，refreshOnlineBookMetadata 已更新 store.books
                        if let updatedBook = self.book {
                            if updatedBook.onlineChapters?.isEmpty == false {
                                self.loadOnlineContent(updatedBook, marginH: marginH, marginV: marginV)
                            } else {
                                self.isLoadingPipeline = false
                                self.isRestoringPosition = false
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isLoadingPipeline = false
                        self.isRestoringPosition = false
                    }
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let package = try self.onlineCoordinator.buildPackage(
                    for: b,
                    preferredChapter: initialFocusChapter
                )
                let settings = self.currentRenderSettings(marginH: marginH, marginV: marginV)
                let shouldUseWeb =
                    ReaderFeatureFlags.shared.useProgressiveOnlineReading
                    && ReaderFeatureFlags.shared.shouldUseWebPipeline(
                        for: b,
                        kind: package.pipelineKind
                    )

                DispatchQueue.main.async {
                    if shouldUseWeb {
                        self.applyWebPackage(package, settings: settings)
                        Task {
                            let restoredChapter = min(
                                max(self.epubRenderer.currentChapterIdx, 0),
                                max((b.onlineChapters?.count ?? 1) - 1, 0)
                            )
                            if let refreshed = await self.onlineCoordinator.warmCurrentWindow(
                                for: b,
                                chapterIndex: restoredChapter,
                                store: self.store
                            ) {
                                await MainActor.run {
                                    let preferredLocalPage = self.currentWebLocalPage(
                                        preferredChapter: restoredChapter
                                    )
                                    // 用增量更新，不重建 curl controller
                                    self.epubRenderer.reloadWithUpdatedPackage(
                                        refreshed,
                                        settings: settings
                                    )
                                    self.epubRenderer.jumpToChapter(
                                        restoredChapter,
                                        preferredLocalPage: preferredLocalPage
                                    )
                                }
                            } else {
                                // warmCurrentWindow 失敗時，嘗試直接觸發 fetchChapterIfNeeded
                                await MainActor.run {
                                    self.fetchChapterIfNeeded(chapterIndex: restoredChapter)
                                }
                            }
                        }
                    } else {
                        ReaderTelemetry.shared.log(
                            "fallback_triggered",
                            attributes: [
                                "bookId": b.id.uuidString,
                                "pipelineKind": "online",
                                "reason": "feature_flag_or_compatibility"
                            ]
                        )
                        self.applyLegacyPackage(package, pageMarginH: marginH, pageMarginV: marginV)
                        // Legacy pipeline: 初始建立的 pages 全是 placeholder，需要手動觸發首章節載入
                        self.fetchChapterIfNeeded(chapterIndex: initialFocusChapter)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                    // buildPackage 失敗時，觸發首章節載入作為 fallback
                    self.fetchChapterIfNeeded(chapterIndex: initialFocusChapter)
                }
            }
        }
    }

    private func reloadOnlinePackage(
        for book: ReadingBook,
        focusChapter: Int,
        marginH: CGFloat,
        marginV: CGFloat,
        immediate: Bool = false
    ) {
        // 遞增 generation，取消之前排程的 debounce reload
        reloadOnlineGeneration += 1
        let gen = reloadOnlineGeneration
        reloadOnlineDebounceWorkItem?.cancel()

        let work = DispatchWorkItem { [gen] in
            guard self.reloadOnlineGeneration == gen else { return }
            self.executeReloadOnlinePackage(
                for: book,
                focusChapter: focusChapter,
                marginH: marginH,
                marginV: marginV,
                generation: gen
            )
        }
        reloadOnlineDebounceWorkItem = work
        // 若為當前章節（immediate），不延遲直接執行；否則 debounce 250ms 避免連續多章節到達時頻繁重建
        let delay: Double = immediate ? 0 : 0.25
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.perform()
        }
    }

    private func executeReloadOnlinePackage(
        for book: ReadingBook,
        focusChapter: Int,
        marginH: CGFloat,
        marginV: CGFloat,
        generation: Int
    ) {
        let settings = currentRenderSettings(marginH: marginH, marginV: marginV)
        let canDoIncremental = hasInitializedWebPackage && useWebRenderer

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let package = try self.onlineCoordinator.buildPackage(for: book, preferredChapter: focusChapter)
                DispatchQueue.main.async {
                    // generation guard：如果已被更新的 reload 取代，丟棄
                    guard self.reloadOnlineGeneration == generation else {
                        ReaderTelemetry.shared.log(
                            "progressive_reload_dropped",
                            attributes: [
                                "bookId": book.id.uuidString,
                                "pipelineKind": "online",
                                "reason": "gen_mismatch",
                                "jobGen": "\(generation)",
                                "currentGen": "\(self.reloadOnlineGeneration)",
                            ]
                        )
                        return
                    }

                    if canDoIncremental {
                        // 走增量路徑：不重建 curl controller
                        self.epubRenderer.reloadWithUpdatedPackage(package, settings: settings)
                    } else {
                        // 首次載入或未初始化，走完整路徑
                        let preferredLocalPage = self.currentWebLocalPage(preferredChapter: focusChapter)
                        self.applyWebPackage(
                            package,
                            settings: settings,
                            deferCurrentPageSync: true
                        )
                        self.epubRenderer.jumpToChapter(
                            focusChapter,
                            preferredLocalPage: preferredLocalPage
                        )
                    }
                }
            } catch {
            }
        }
    }

    private func loadLocalEPUB(_ book: ReadingBook, marginH: CGFloat, marginV: CGFloat) {
        let settings = currentRenderSettings(marginH: marginH, marginV: marginV)
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
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                }
            }
        }
    }

    private func loadContent() {
        guard !isLoadingPipeline else { return }
        isLoadingPipeline = true
        isRestoringPosition = true
        isWebRenderReady = false
        // 在主線程先捕捉排版參數（依賴 UIScreen，不能在背景線程）

        let marginH = effectivePageMarginH
        let marginV = effectivePageMarginV

        guard let b = book else {
            isRestoringPosition = false
            return
        }
        if b.isOnline {
            loadOnlineContent(b, marginH: marginH, marginV: marginV)
            return
        }
        if b.resolvedPipelineKind == .epub {
            let bookTitle = b.title
            self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
            self.allPages = [
                PageContent(
                    chapterIndex: 0,
                    chapterTitle: bookTitle,
                    content: "",
                    pageInChapter: 0
                )
            ]
            self.currentPage = 0
            loadLocalEPUB(b, marginH: marginH, marginV: marginV)
            return
        }
        let bookTitle = b.title
        self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
        self.allPages = [
            PageContent(
                chapterIndex: 0,
                chapterTitle: bookTitle,
                content: "",
                pageInChapter: 0
            )
        ]
        self.currentPage = 0

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let package = try store.package(forLocalBook: b)
                let settings = self.currentRenderSettings(marginH: marginH, marginV: marginV)
                let shouldUseWeb = ReaderFeatureFlags.shared.shouldUseWebPipeline(
                    for: b,
                    kind: package.pipelineKind
                )

                DispatchQueue.main.async {
                    if shouldUseWeb {
                        self.applyWebPackage(package, settings: settings)
                    } else {
                        ReaderTelemetry.shared.log(
                            "fallback_triggered",
                            attributes: [
                                "bookId": b.id.uuidString,
                                "pipelineKind": package.pipelineKind.rawValue,
                                "reason": "feature_flag_or_compatibility"
                            ]
                        )
                        self.applyLegacyPackage(
                            package,
                            pageMarginH: marginH,
                            pageMarginV: marginV
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoadingPipeline = false
                    self.isRestoringPosition = false
                }
            }
        }
    }

    private func rebuildPages() {
        guard !chapters.isEmpty else { return }
        // 統一走 WebRenderer 重新渲染
        useWebRenderer = false
        isLoadingPipeline = false
        hasInitializedWebPackage = false
        isWebRenderReady = false
        reloadOnlineDebounceWorkItem?.cancel()
        reloadOnlineDebounceWorkItem = nil
        if let oldPath = txtXHTMLBasePath {
            TXTToXHTMLConverter.cleanup(basePath: oldPath)
            txtXHTMLBasePath = nil
        }
        loadContent()
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

// MARK: - 閱讀主題

enum ReaderTheme: String, CaseIterable {
    case white = "白天"
    case sepia = "護眼"
    case night = "夜間"

    private static let userDefaultsKey = "yd_reader_theme"

    static func loadPersisted() -> ReaderTheme {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return ReaderTheme(rawValue: raw) ?? .sepia
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }

    var backgroundColor: Color {
        switch self {
        case .white: return .white
        case .sepia: return Color(red: 244 / 255, green: 236 / 255, blue: 216 / 255)  // #f4ecd8
        case .night: return Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)  // #1a1a1a
        }
    }
    var textColor: Color {
        switch self {
        case .white: return Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)  // #333333
        case .sepia: return Color(red: 91 / 255, green: 70 / 255, blue: 54 / 255)  // #5b4636
        case .night: return Color(red: 217 / 255, green: 217 / 255, blue: 217 / 255)  // #d9d9d9
        }
    }
    var barColor: Color {
        switch self {
        case .white: return Color(UIColor.systemBackground)
        case .sepia: return Color(red: 0.93, green: 0.91, blue: 0.83)
        case .night: return Color(red: 0.12, green: 0.12, blue: 0.12)
        }
    }
    /// epub.js theme name registered in index.html
    var epubJSName: String {
        switch self {
        case .white: return "white"
        case .sepia: return "sepia"
        case .night: return "night"
        }
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

// EPUBWebViewWrapper 已移除（正式路徑使用 LiveWebReader，不再直接顯示舊 wrapper）

// MARK: - CoreText UIPageViewController 橋接

private struct CoreTextPageEngineView: UIViewControllerRepresentable {
    let engine: any PageRenderingProvider
    @Binding var currentPage: Int
    let onPageChanged: (Int) -> Void
    let onTapZone: (String) -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        let initialVC = engine.pageViewController(at: max(0, currentPage))
        pvc.setViewControllers([initialVC], direction: .forward, animated: false)

        // Tap zone recognizer: left 30% → prev, right 30% → next, center → menu
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        pvc.view.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            forName: .coreTextEngineChapterReady,
            object: engine as AnyObject,
            queue: .main
        ) { [weak pvc] _ in
            guard let pvc else { return }
            // Force UIPageViewController to re-fetch current VC from datasource
            if let first = pvc.viewControllers?.first {
                pvc.setViewControllers([first], direction: .forward, animated: false)
            }
        }

        return pvc
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.currentEngine = engine
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine, currentPage: $currentPage, onPageChanged: onPageChanged, onTapZone: onTapZone)
    }

    final class Coordinator: NSObject,
        UIPageViewControllerDataSource,
        UIPageViewControllerDelegate
    {
        var currentEngine: any PageRenderingProvider
        @Binding var currentPage: Int
        let onPageChanged: (Int) -> Void
        let onTapZone: (String) -> Void

        init(engine: any PageRenderingProvider,
             currentPage: Binding<Int>,
             onPageChanged: @escaping (Int) -> Void,
             onTapZone: @escaping (String) -> Void) {
            self.currentEngine = engine
            self._currentPage = currentPage
            self.onPageChanged = onPageChanged
            self.onTapZone = onTapZone
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            let w = view.bounds.width
            let zone = x < w * 0.3 ? "left" : x > w * 0.7 ? "right" : "center"
            DispatchQueue.main.async { self.onTapZone(zone) }
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex > 0 else { return nil }
            return currentEngine.pageViewController(at: vc.globalPageIndex - 1)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? any PageIndexProviding & UIViewController,
                  vc.globalPageIndex < currentEngine.totalPages - 1 else { return nil }
            let nextIndex = vc.globalPageIndex + 1
            // 快照接力：若下一頁是新章節且快照已就緒，回傳靜態圖 VC 供動畫用
            if let snapVC = currentEngine.snapshotViewController(at: nextIndex) {
                return snapVC
            }
            return currentEngine.pageViewController(at: nextIndex)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed else { return }

            // 若落地的是快照 VC，立即換成真正的渲染 VC（佈局已就緒，視覺上無縫）
            if let snapVC = pvc.viewControllers?.first as? SnapshotPageViewController {
                let realVC = currentEngine.pageViewController(at: snapVC.globalPageIndex)
                pvc.setViewControllers([realVC], direction: .forward, animated: false)
                currentPage = snapVC.globalPageIndex
                onPageChanged(snapVC.globalPageIndex)
                Task { @MainActor in
                    currentEngine.warmUpNext(currentGlobalPage: snapVC.globalPageIndex)
                }
                return
            }

            guard let vc = pvc.viewControllers?.first as? any PageIndexProviding & UIViewController else { return }
            currentPage = vc.globalPageIndex
            onPageChanged(vc.globalPageIndex)
            Task { @MainActor in
                currentEngine.warmUpNext(currentGlobalPage: vc.globalPageIndex)
            }
        }
    }
}
