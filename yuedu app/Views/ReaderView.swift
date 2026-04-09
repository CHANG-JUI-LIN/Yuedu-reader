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
    var isLoadingPipeline = false
    var curlStartupStartedAt: CFAbsoluteTime? = nil
    var hasLoggedCurlInteractiveReady = false
    var hasPerformedInitialLoad = false
}

// MARK: - 閱讀器主視圖
struct ReaderView: View {
    let bookId: UUID
    @EnvironmentObject var store: BookStore
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var readerConfig = ReaderConfig.shared

    @State private var chapters: [BookChapter] = []
    @State private var allPages: [PageContent] = []
    @State private var currentPage = 0
    @State private var showBars = false
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var showBookmarkList = false

    // 線上章節懶加載
    @State private var fetchingChapters: Set<Int> = []
    @State private var failedChapters: Set<Int> = []
    @State private var lastChapterError: String = ""

    // 亮度
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
    @State private var changeSourceOrigins: [BookOrigin] = []
    @State private var changeSourceLoading = false
    @State private var changeSourceError: String?
    @State private var runtimeState = ReaderRuntimeState()
    @State private var chapterSliderDraft: Double? = nil
    @State private var bookDocument: (any BookDocument)? = nil
    @State private var contentProvider: (any BookContentProvider)? = nil
    @State private var readerCapabilities: ReaderCapabilities = .reflowableText
    private let progressManager = ReaderProgressManager.shared

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
        (isEPUB || isTXT) && epubRenderer.engine != nil
    }

    private var usesPagedRenderer: Bool { usesCoreTextEPUB }

    private var renderedPageCount: Int {
        if let engine = epubRenderer.engine, (isEPUB || isTXT) { return engine.totalPages }
        return allPages.count
    }

    private var localEPUBBookIdentifier: String? {
        guard let currentBook = book, isEPUB else { return nil }
        return store.localEPUBURL(for: currentBook).standardizedFileURL.path
    }

    private var telemetryPipelineKind: String {
        book?.resolvedPipelineKind.rawValue ?? "epub"
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
        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
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
        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
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
        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
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
                        currentChapterIndex = ctEngine.charOffset(forPage: newPage).spineIndex
                        epubRenderer.updateCurrentPosition(globalPage: newPage, engine: ctEngine)
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
            tts.onPageFinished = {
                if !(isEPUB || isTXT), currentPage < allPages.count - 1 {
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
                    await ChapterFetchManager.shared.cancelAll(for: b.id)
                }
            }
            volumeHandler.stopListening()
            autoReader.pause()
            tts.stop()
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
        savedPositionSnapshot = initialProgressSnapshot()
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

    private func initialProgressSnapshot() -> Double {
        if let snapshot = progressManager.loadSnapshot(bookId: bookId) {
            return min(1.0, max(0.0, snapshot.percentage))
        }
        return min(1.0, max(0.0, book?.currentPosition ?? 0))
    }

    private func applyInitialProgressIfNeeded() {
        let progress = min(1.0, max(0.0, savedPositionSnapshot))
        guard progress > 0 else { return }

        if let engine = epubRenderer.engine {
            guard engine.totalPages > 1 else { return }
            let target = max(0, min(Int(round(progress * Double(engine.totalPages - 1))), engine.totalPages - 1))
            if target > 0 {
                currentPage = target
                let (spineIndex, _) = engine.charOffset(forPage: target)
                currentChapterIndex = spineIndex
                epubRenderer.updateCurrentPosition(globalPage: target, engine: engine)
            }
            savedPositionSnapshot = 0
            return
        }

        if !allPages.isEmpty {
            let maxIndex = allPages.count - 1
            guard maxIndex > 0 else { return }
            let target = max(0, min(Int(round(progress * Double(maxIndex))), maxIndex))
            if target > 0 {
                currentPage = target
                currentChapterIndex = allPages[target].chapterIndex
            }
            savedPositionSnapshot = 0
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
        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
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
                            .onAppear { fetchChapterIfNeeded(chapterIndex: ci) }
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
        case .slide, .cover:
            withAnimation(.easeInOut(duration: PageTurnAnimation.slideDuration)) {
                currentPage -= 1
            }
        case .curl:
            currentPage -= 1
        }
    }

    private func goToNextPage() {
        let maxPage: Int
        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
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
        ReaderBottomControlBar(
            readerTheme: Binding(
                get: { readerTheme },
                set: { readerTheme = $0 }
            ),
            overlayContentMaxWidth: overlayContentMaxWidth,
            showChangeSourceButton: book?.isOnline == true && book?.bookSourceId != nil,
            showDownloadButton: book?.isOnline == true,
            downloadButtonIcon: downloadButtonIcon,
            canGoPrevChapter: canGoPrevChapter,
            canGoNextChapter: canGoNextChapter,
            chapterPageInfo: chapterPageInfo,
            totalProgressPercent: totalProgressPercent,
            chapterSliderProgressValue: { chapterSliderProgressValue() },
            applyChapterSliderProgress: { applyChapterSliderProgress($0) },
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
        if (isEPUB || isTXT) {
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

    private func jumpToChapter(_ idx: Int) {
        guard chapters.indices.contains(idx) else { return }
        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
            Task { @MainActor in
                engine.cancelPendingWork()
                await engine.preloadChapter(at: idx)
                // 背景預載鄰域章節，確保前後翻頁時 layout 已就緒
                if idx > 0 { Task { await engine.preloadChapter(at: idx - 1) } }
                if idx < chapters.count - 1 { Task { await engine.preloadChapter(at: idx + 1) } }
                let targetPage = engine.pageIndex(forSpine: idx, charOffset: 0)
                currentChapterIndex = idx
                currentPage = targetPage
                epubRenderer.currentEpubPage = targetPage
            }
        } else {
            currentChapterIndex = idx
            if let p = findChapterFirstPage(idx) { currentPage = p }
            if !isEPUB { fetchChapterIfNeeded(chapterIndex: idx) }
        }
    }

    private func autoSaveProgress() {
        guard !isRestoringPosition else { return }

        if let engine = epubRenderer.engine, (isEPUB || isTXT) {
            let total = engine.totalPages
            guard total > 0 else { return }
            if let progressBookId = localEPUBBookIdentifier {
                epubRenderer.syncProgress(bookId: progressBookId)
            }
            let (spineIndex, charOffset) = engine.charOffset(forPage: currentPage)
            currentChapterIndex = spineIndex
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset)
            let normalized = min(1.0, max(0.0, pct))
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
            let progress = Double(currentPage) / Double(max(allPages.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
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
        isRestoringPosition = false
        autoSaveProgress()
        isRestoringPosition = wasRestoring
        if let bookId = localEPUBBookIdentifier {
            epubRenderer.flushProgress(bookId: bookId)
        }
    }

    private func refreshCurrentChapter() {
        guard let b = book, b.isOnline else { return }
        let idx = currentChapterIndex
        BookSourceFetcher.shared.clearChapterCache(bookId: b.id, chapterIndex: idx)
        store.clearCachedChapter(bookId: b.id, chapterIndex: idx)
        fetchingChapters.remove(idx)
        failedChapters.remove(idx)
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
            OnlineBookCoordinator.shared.downloadBook(b, store: store)
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
            rebuildPages()
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
                    if pkg.state == .cached && !pkg.content.isEmpty {
                        failedChapters.remove(chapterIndex)
                    } else {
                        failedChapters.insert(chapterIndex)
                        lastChapterError = "ch\(chapterIndex): \(pkg.failureReason ?? "內容為空")"
                    }
                    rebuildPages()
                    prefetchAdjacentChapters(around: chapterIndex)
                }
            } catch {
                await MainActor.run {
                    fetchingChapters.remove(chapterIndex)
                    failedChapters.insert(chapterIndex)
                    lastChapterError = "ch\(chapterIndex): \(error.localizedDescription)"
                    rebuildPages()
                }
            }
        }
    }

    private func prefetchAdjacentChapters(around chapterIndex: Int) {
        guard let b = book, b.isOnline else { return }
        Task {
            await OnlineBookCoordinator.shared.prefetchAround(book: b, center: chapterIndex, store: store)
        }
    }

    // MARK: - 載入 & 建頁
    private func currentRenderSettings(marginH: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: readerTheme.epubJSName,
            textColor: UIColor(readerTheme.textColor),
            backgroundColor: UIColor(readerTheme.backgroundColor),
            fontSize: fontSize,
            marginH: marginH,
            marginV: systemVerticalPadding,
            footerHeight: footerOverlayHeight
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

    private func loadContent() {
        guard !isLoadingPipeline else { return }
        isLoadingPipeline = true
        isRestoringPosition = true
        savedPositionSnapshot = initialProgressSnapshot()

        let marginH = effectivePageMarginH
        guard let b = book else {
            applyDocument(nil)
            isRestoringPosition = false
            isLoadingPipeline = false
            return
        }
        // Online books: temporarily disabled
        if b.isOnline {
            let document = BookDocumentFactory.makeOnlineDocument(book: b, store: store)
            applyDocument(document)
            isLoadingPipeline = false
            isRestoringPosition = false
            return
        }
        
        if b.resolvedPipelineKind == .txt {
            let bookTitle = b.title
            let text = store.content(for: b)
            let settings = currentRenderSettings(marginH: marginH)
            let document = BookDocumentFactory.makeTXTDocument(book: b, store: store)
            applyDocument(document)
            
            epubRenderer.loadTXT(
                text: text,
                title: bookTitle,
                bookIdentifier: b.id.uuidString,
                renderSize: readerViewportSize,
                settings: settings
            )
            
            if document.tableOfContents.count > 0 {
                self.chapters = document.tableOfContents.enumerated().map { i, chapter in
                    BookChapter(index: i, title: chapter.title, content: "")
                }
            } else if let txtEngine = epubRenderer.engine as? TXTPageEngine {
                self.chapters = txtEngine.chapterTitles.enumerated().map { i, t in
                    BookChapter(index: i, title: t, content: "")
                }
            } else {
                self.chapters = [BookChapter(index: 0, title: bookTitle, content: "")]
            }
            
            self.allPages = []
            currentPage = 0
            isLoadingPipeline = false
            isRestoringPosition = false
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
        let size = targetSize ?? engine.renderSize
        Task { await engine.invalidateLayout(newSize: size) }
    }

    private func applyUnifiedAppearanceUpdate() {
        guard let engine = epubRenderer.engine else { return }
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
    let showChangeSourceButton: Bool
    let showDownloadButton: Bool
    let downloadButtonIcon: String
    let canGoPrevChapter: Bool
    let canGoNextChapter: Bool
    let chapterPageInfo: String
    let totalProgressPercent: String
    let chapterSliderProgressValue: () -> Double
    let applyChapterSliderProgress: (Double) -> Void
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
                circleBtn(icon: "arrow.clockwise") { onRefresh() }
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

        // 優先用 engine.currentPage（已從 CharOffsetStore 恢復的絕對座標換算而來）
        let initialPage = engine.totalPages > 0
            ? max(0, min(engine.currentPage, engine.totalPages - 1))
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

            // 消耗 makeUIViewController 設置的抑制 flag，跳過多餘的初始動畫
            if context.coordinator.suppressNextTransition {
                context.coordinator.suppressNextTransition = false
                return
            }

            if pageTurnStyle == .cover {
                context.coordinator.animateCoverTransition(
                    from: visible.globalPageIndex,
                    to: clampedPage,
                    direction: direction,
                    on: uiViewController
                )
                return
            }

            let shouldAnimate = pageTurnStyle != .none
            let targetVC = engine.pageViewController(at: clampedPage)
            if shouldAnimate && direction == .reverse {
                // UIPageViewController .scroll 的已知 bug：programmatic reverse 動畫方向錯誤。
                // 暫時移除 dataSource 讓 UIKit 走正確的反向動畫路徑，完成後恢復。
                let savedDS = uiViewController.dataSource
                uiViewController.dataSource = nil
                uiViewController.setViewControllers([targetVC], direction: .reverse, animated: true) { _ in
                    uiViewController.dataSource = savedDS
                }
            } else {
                uiViewController.setViewControllers([targetVC], direction: direction, animated: shouldAnimate)
            }
            _ = context.coordinator.syncStablePosition(afterShowing: targetVC, notifyFallback: true)
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

            let direction: UIPageViewController.NavigationDirection
            if let first = pageViewController.viewControllers?.first as? (any PageIndexProviding & UIViewController) {
                direction = targetPage >= first.globalPageIndex ? .forward : .reverse
            } else {
                direction = .forward
            }

            pageViewController.setViewControllers([freshVC], direction: direction, animated: false)
            _ = syncStablePosition(afterShowing: freshVC, notifyFallback: false)
        }

        private func handleNavigate(to page: Int) {
            let clamped = max(0, min(page, max(currentEngine.totalPages - 1, 0)))
            currentPage = clamped
            onPageChanged(clamped)
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
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed else { return }

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
                }
                return
            }

            guard let vc = pvc.viewControllers?.first as? any PageIndexProviding & UIViewController else { return }
            if let resolvedPage = syncStablePosition(afterShowing: vc, notifyFallback: false) {
                Task { @MainActor in
                    currentEngine.warmUpNext(currentGlobalPage: resolvedPage)
                }
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

        @objc func handleCoverPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
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
                    if translationX < -18, currentPage < currentEngine.totalPages - 1 {
                        // Forward uncover：當前頁往左滑走，新頁在底下
                        coverDirection = 1
                        let target = currentPage + 1
                        coverTargetPage = target
                        coverOverlayView.frame = view.bounds
                        coverCurrentImageView.frame = view.bounds
                        coverOverlayView.isHidden = false
                        setupForwardOutgoing(currentPageSnapshot: currentPage, newPage: target, in: view)
                    } else if translationX > 18, currentPage > 0 {
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
                    coverDimView.alpha = rawProgress * 0.35
                } else if coverDirection == 1 {
                    coverDimView.frame = coverCurrentImageView.bounds
                    coverDimView.alpha = (1 - rawProgress) * 0.35
                }

            case .ended, .cancelled, .failed:
                guard let targetPage = coverTargetPage else {
                    resetCoverOverlay()
                    return
                }
                let progress = min(max(abs(translationX) / width, 0), 1)
                let shouldCommit = progress > 0.34 || abs(velocityX) > 560

                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                    let destX: CGFloat = self.coverDirection == 1
                        ? (shouldCommit ? -width : 0)
                        : (shouldCommit ? 0 : -width)
                    self.coverIncomingImageView.frame.origin.x = destX
                    self.coverShadowView.frame.origin.x = destX
                    if self.coverDirection == -1 {
                        self.coverDimView.alpha = shouldCommit ? 0.35 : 0
                    } else if self.coverDirection == 1 {
                        self.coverDimView.alpha = shouldCommit ? 0 : 0.35
                    }
                } completion: { _ in
                    if shouldCommit {
                        // 先把真正的 VC 設上去，讓 updateUIViewController 進來時早返回，避免二次動畫
                        if let pvc = self.coverPageViewController {
                            let realVC = self.currentEngine.pageViewController(at: targetPage)
                            pvc.setViewControllers([realVC], direction: .forward, animated: false)
                            self.captureStablePosition(from: realVC)
                        }
                        self.currentPage = targetPage
                        self.onPageChanged(targetPage)
                        Task { @MainActor in
                            self.currentEngine.warmUpNext(currentGlobalPage: targetPage)
                        }
                    }
                    self.resetCoverOverlay()
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
            guard let view = pvc.view else { return }
            // 邊界保護：第一頁不能往前翻、最後一頁不能往後翻
            let total = currentEngine.totalPages
            guard targetPage >= 0, total == 0 || targetPage < total else {
                resetCoverOverlay()
                return
            }
            let width = max(view.bounds.width, 1)

            coverOverlayView.frame = view.bounds
            coverCurrentImageView.frame = view.bounds
            coverOverlayView.isHidden = false

            if direction == .forward {
                // Forward uncover：當前頁往左滑走，新頁在底下
                setupForwardOutgoing(currentPageSnapshot: oldPage, newPage: targetPage, in: view)
                coverDimView.alpha = 0.35  // tap 動畫：新頁初始最暗，動畫中漸亮
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    self.coverIncomingImageView.frame.origin.x = -width
                    self.coverShadowView.frame.origin.x = -width
                    self.coverDimView.alpha = 0
                } completion: { _ in
                    let realVC = self.currentEngine.pageViewController(at: targetPage)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    self.captureStablePosition(from: realVC)
                    self.onPageChanged(targetPage)
                    Task { @MainActor in self.currentEngine.warmUpNext(currentGlobalPage: targetPage) }
                    self.resetCoverOverlay()
                }
            } else {
                // Backward cover：上一頁從左滑入
                coverCurrentImageView.image = currentEngine.renderSnapshot(forPage: oldPage)
                setupIncomingView(for: targetPage, snapshot: currentEngine.renderSnapshot(forPage: targetPage), in: view)
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    self.coverIncomingImageView.frame.origin.x = 0
                    self.coverShadowView.frame.origin.x = 0
                    self.coverDimView.alpha = 0.3
                } completion: { _ in
                    let realVC = self.currentEngine.pageViewController(at: targetPage)
                    pvc.setViewControllers([realVC], direction: direction, animated: false)
                    self.captureStablePosition(from: realVC)
                    self.onPageChanged(targetPage)
                    Task { @MainActor in self.currentEngine.warmUpNext(currentGlobalPage: targetPage) }
                    self.resetCoverOverlay()
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
