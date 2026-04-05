import Combine
import CryptoKit
import UIKit
import WebKit

// MARK: - LiveWebReader：即時 WKWebView + CSS Column 分頁

/// 取代 EPUBWebRenderer 的新閱讀引擎。
/// 用單一可見 WKWebView 直接顯示 HTML，CSS multi-column 分頁，
/// JS `translateX()` 跟手翻頁，不再截圖。
@MainActor
final class LiveWebReader: NSObject, ObservableObject {

    enum TurnCommand {
        case forward
        case backward
    }

    // MARK: - 公開狀態

    @Published var isReady = false
    @Published var totalPages = 0
    @Published var currentEpubPage = 0
    @Published var errorMessage: String?
    @Published var tocItems: [[String: Any]] = []
    @Published var tocCount: Int = 0
    @Published var bookTitle: String = ""
    @Published var percentage: Double = 0
    @Published var currentChapterIdx: Int = 0
    @Published private(set) var pipelineKind: BookPipelineKind = .epub
    @Published private(set) var renderSessionID: Int = 0
    @Published private(set) var layoutGeneration: Int = 0
    @Published private(set) var pageStatesVersion: Int = 0
    @Published var snapshotProgress: Double = 1.0
    @Published var snapshotVersion: Int = 0
    @Published var isCommitting = false
    @Published private(set) var restoredFromDisk = false

    // MARK: - 公開回調

    var onRelocated: ((String, Double) -> Void)?
    var onCommitCompleted: ((SnapshotLocator) -> Void)?
    /// JS click 事件回調：zone = "left" / "center" / "right"
    var onTapZone: ((String) -> Void)?
    let turnCommandPublisher = PassthroughSubject<TurnCommand, Never>()

    // MARK: - 翻頁狀態機

    enum PageTurnEvent: String {
        case gestureBegan
        case gestureChanged
        case gestureEndedCommit
        case gestureEndedCancel
        case transitionWillDisplay
        case transitionCommitted
        case transitionCancelled
        case programmaticJump
        case chapterLoadStarted
        case chapterLoadFinished
    }

    enum PageTurnState {
        case idle
        case gestureActive(startPage: Int, startOffset: CGFloat)
        case animatingCommit(target: Int, animator: UIViewPropertyAnimator?)
        case animatingCancel(returnPage: Int, animator: UIViewPropertyAnimator?)
        case loadingChapter(target: Int)
    }
    private(set) var turnState: PageTurnState = .idle
    @Published private(set) var turnStateVersion: Int = 0
    @Published private(set) var lastTurnEvent: PageTurnEvent?

    private func emitTurnEvent(_ event: PageTurnEvent) {
        lastTurnEvent = event
        turnStateVersion &+= 1
    }

    private func transitionTurnState(to newState: PageTurnState, event: PageTurnEvent) {
        turnState = newState
        emitTurnEvent(event)
    }

    /// 中斷當前動畫，回傳中斷時的 contentOffset.x（供新手勢接手）
    func interruptAnimation() -> CGFloat? {
        switch turnState {
        case .animatingCommit(_, let animator), .animatingCancel(_, let animator):
            animator?.stopAnimation(true)
            let currentX = webView.scrollView.layer.presentation()?.bounds.origin.x
                ?? webView.scrollView.contentOffset.x
            transitionTurnState(to: .idle, event: .transitionCancelled)
            return currentX
        default:
            return nil
        }
    }

    func beginGestureInteraction(interruptedOffset: CGFloat? = nil) {
        let startOffset = interruptedOffset ?? webView.scrollView.contentOffset.x
        transitionTurnState(
            to: .gestureActive(startPage: currentEpubPage, startOffset: startOffset),
            event: .gestureBegan
        )
    }

    func updateGestureInteraction() {
        if case .gestureActive = turnState {
            emitTurnEvent(.gestureChanged)
            return
        }
        beginGestureInteraction(interruptedOffset: nil)
        emitTurnEvent(.gestureChanged)
    }

    func endGestureInteraction(targetPage: Int) {
        if targetPage == currentEpubPage {
            transitionTurnState(to: .animatingCancel(returnPage: currentEpubPage, animator: nil), event: .gestureEndedCancel)
            return
        }
        transitionTurnState(to: .animatingCommit(target: targetPage, animator: nil), event: .gestureEndedCommit)
    }

    func cancelInteractionPage(_ page: Int, style: PageTurnStyle) {
        transitionTurnState(to: .animatingCancel(returnPage: page, animator: nil), event: .transitionCancelled)
        transitionTurnState(to: .idle, event: .gestureEndedCancel)
        prepareDisplaySnapshot(forPage: page, priority: style == .curl ? -1 : 0)
    }

    private func bumpLayoutGeneration() {
        layoutGeneration &+= 1
    }

    // MARK: - WKWebView（單一可見實例）

    private(set) var webView: WKWebView!
    private var messageHandler: LiveReaderMessageHandler?
    private let schemeHandler = ReaderSchemeHandler()

    // MARK: - 書籍資料

    private var parsedBook: EPUBParsedBook?
    private var publicationSession: PublicationSession?
    private var chapterPageCounts: [Int: Int] = [:]
    private var chapterPageOffsets: [Int: [CGFloat]] = [:]
    private(set) var globalPageMap: [(chapter: Int, page: Int)] = []
    private var currentLoadedChapter: Int = -1

    // MARK: - 渲染設定

    private var renderFontSize: CGFloat = 18
    private var renderMarginH: CGFloat = 24
    private var renderMarginV: CGFloat = 20
    private var renderTheme: String = "sepia"
    private var renderFooterHeight: CGFloat = 80
    private var renderFlowMode: String = "horizontal"
    private var currentBookIdentifier: String = ""
    private var currentViewportSize: CGSize = UIScreen.main.bounds.size
    private var currentSafeAreaInsets: UIEdgeInsets = .zero
    private var snapshotImages: [Int: UIImage] = [:]
    private var snapshotStates: [Int: PageRenderState] = [:]
    private var snapshotRevisions: [Int: Int] = [:]
    private var snapshotTasks: [Int: Task<Void, Never>] = [:]
    private var crossChapterTransitionTask: Task<Void, Never>?
    private var tapTurnLockUntil: CFAbsoluteTime = 0

    // MARK: - 上下滑動（Scroll Mode）

    /// 當前是否處於上下滑動模式（由 setTransition 設定，在 loadChapter 前就生效）
    private(set) var scrollModeEnabled: Bool = false
    /// 目前 DOM 中已載入的章節範圍（例如 2...5 表示第 2~5 章在 DOM 裡）
    private var scrollLoadedRange: ClosedRange<Int>?
    /// 防止併發注入
    private var isInjectingScrollChapter = false
    /// 上下滑動模式下當前可見的章節索引
    @Published private(set) var scrollVisibleChapterIndex: Int = 0
    /// 上下滑動模式下可見章節內的進度（0~1）
    @Published private(set) var scrollChapterProgress: Double = 0

    // MARK: - 進度

    private var progressStore: EPUBProgressStore?
    private var restoredLocatorRecord: ReaderLocator?
    private var didApplyRestoredLocator = false
    private var progressSaveWorkItem: DispatchWorkItem?

    // MARK: - 掃描狀態

    private var scanWebView: WKWebView?
    private var scanMessageHandler: LiveScanMessageHandler?
    private var isScanningComplete = false
    private var scanContinuation: CheckedContinuation<Int, Never>?

    // MARK: - WebView Pool（prev/current/next）

    enum WebViewRole { case current, prev, next }
    private var webViewPool: [WebViewRole: WKWebView] = [:]
    private var preloadedChapter: [WebViewRole: Int] = [:]
    private var preloadedReady: [WebViewRole: Bool] = [:]
    private var preloadHandlers: [WebViewRole: LivePreloadMessageHandler] = [:]
    private var preloadDebounceWork: DispatchWorkItem?
    /// 當 webView 身份改變時遞增，通知 container 重新 attach
    @Published private(set) var webViewGeneration: Int = 0

    /// 暫存 HTML 檔案追蹤（deinit / beginLoad 時統一清理，不用定時炸彈）
    private var tempHTMLFiles: Set<URL> = []

    // MARK: - Init / Deinit

    override init() {
        super.init()
        setupWebView()
        observeMemoryWarning()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let wv = webView
        let swv = scanWebView
        let poolViews = webViewPool
        progressSaveWorkItem?.cancel()
        cleanupTempFiles(tempHTMLFiles)
        Task { @MainActor in
            wv?.configuration.userContentController.removeScriptMessageHandler(forName: "readerBridge")
            wv?.removeFromSuperview()
            swv?.configuration.userContentController.removeScriptMessageHandler(forName: "scanBridge")
            swv?.removeFromSuperview()
            for (role, pv) in poolViews where role != .current {
                pv.configuration.userContentController.removeScriptMessageHandler(forName: "preload_\(role)")
                pv.removeFromSuperview()
            }
        }
    }

    /// 統一清理所有暫存 HTML 檔案（nonisolated 以便 deinit 呼叫）
    private nonisolated func cleanupTempFiles(_ files: Set<URL>) {
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func observeMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.clearMemoryCache()
            }
        }
    }

    // MARK: - WebView 建立

    private func setupWebView() {
        let handler = LiveReaderMessageHandler(reader: self)
        self.messageHandler = handler

        let processPool = WKProcessPool()
        let size = UIScreen.main.bounds.size
        let bgColor = themeBackgroundUIColor()

        // 建立 current WebView（可見）
        let currentConfig = WKWebViewConfiguration()
        currentConfig.processPool = processPool
        currentConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        currentConfig.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        currentConfig.setURLSchemeHandler(schemeHandler, forURLScheme: PublicationSession.scheme)
        currentConfig.userContentController.add(handler, name: "readerBridge")

        let wv = makeWebView(frame: CGRect(origin: .zero, size: size), config: currentConfig, bgColor: bgColor)
        wv.navigationDelegate = self
        self.webView = wv
        webViewPool[.current] = wv

        // 建立 prev/next WebViews（offscreen 預載）
        for role in [WebViewRole.prev, .next] {
            let roleName = "preload_\(role)"
            let preloadHandler = LivePreloadMessageHandler(reader: self, role: role)
            preloadHandlers[role] = preloadHandler

            let cfg = WKWebViewConfiguration()
            cfg.processPool = processPool
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
            cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            cfg.setURLSchemeHandler(schemeHandler, forURLScheme: PublicationSession.scheme)
            cfg.userContentController.add(preloadHandler, name: roleName)

            let pv = makeWebView(
                frame: CGRect(x: -9999, y: 0, width: size.width, height: size.height),
                config: cfg, bgColor: bgColor
            )
            webViewPool[role] = pv
        }
    }

    private func makeWebView(frame: CGRect, config: WKWebViewConfiguration, bgColor: UIColor) -> WKWebView {
        let wv = WKWebView(frame: frame, configuration: config)
        wv.isOpaque = true
        wv.backgroundColor = bgColor
        wv.scrollView.backgroundColor = bgColor
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        return wv
    }

    // MARK: - 載入 API

    func load(package: RenderPackage, settings: ReaderRenderSettings) {
        beginLoad(
            bookIdentifier: package.originalSourceURL?.standardizedFileURL.path
                ?? package.basePath.standardizedFileURL.path,
            pipelineKind: package.pipelineKind,
            settings: settings
        )

        if package.pipelineKind == .epub,
           let originalSourceURL = package.originalSourceURL,
           originalSourceURL.pathExtension.lowercased() == "epub"
        {
            bookTitle = package.title
            Task {
                do {
                    let session = try await PublicationSession.open(sourceURL: originalSourceURL)
                    self.publicationSession = session
                    self.onPublicationSessionReady(session)
                } catch {
                    self.publicationSession = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        } else {
            parsedBook = package.parsedBook
            publicationSession = nil
            onParsed(package.parsedBook)
        }
    }

    func load(
        publicationSession session: PublicationSession,
        bookIdentifier: String,
        settings: ReaderRenderSettings
    ) {
        beginLoad(
            bookIdentifier: bookIdentifier,
            pipelineKind: .epub,
            settings: settings
        )
        publicationSession = session
        onPublicationSessionReady(session)
    }

    /// 漸進式更新（線上書追加章節用）
    func reloadWithUpdatedPackage(_ package: RenderPackage, settings: ReaderRenderSettings) {
        let savedChapter = currentChapterIdx
        let savedLocalPage = localPage(forGlobalPage: currentEpubPage)

        renderFontSize = settings.fontSize
        renderMarginH = settings.marginH
        renderMarginV = settings.marginV
        renderTheme = settings.theme
        renderFooterHeight = settings.footerHeight
        webView.backgroundColor = themeBackgroundUIColor()
        webView.scrollView.backgroundColor = themeBackgroundUIColor()
        bumpLayoutGeneration()
        clearMemoryCache()

        parsedBook = package.parsedBook
        chapterPageOffsets.removeAll()
        bookTitle = package.parsedBook.title
        buildTOC()

        // 重新掃描頁數
        for i in 0..<(parsedBook?.chapters.count ?? 0) {
            if chapterPageCounts[i] == nil { chapterPageCounts[i] = 1 }
        }
        rebuildGlobalPageMap()

        // 【死穴一修復】強制重新載入章節 HTML，不能只調 offset。
        // 舊邏輯只呼叫 goToPage()，如果 currentLoadedChapter == savedChapter
        // 就只調整 scrollOffset，導致「載入中…」佔位 HTML 永遠不被替換。
        let targetChapter = min(savedChapter, (parsedBook?.chapters.count ?? 1) - 1)
        currentLoadedChapter = -1  // 強制標記為未載入，迫使 loadChapter 執行
        preloadedChapter.removeAll()
        preloadedReady.removeAll()
        Task {
            await loadChapter(targetChapter, localPage: savedLocalPage)
            await scanRemainingChapters(startingFrom: targetChapter)
        }
    }

    // MARK: - 內部載入流程

    private func beginLoad(
        bookIdentifier: String,
        pipelineKind: BookPipelineKind,
        settings: ReaderRenderSettings
    ) {
        isReady = false
        errorMessage = nil
        totalPages = 0
        currentEpubPage = 0
        percentage = 0
        currentChapterIdx = 0
        parsedBook = nil
        publicationSession = nil
        chapterPageCounts.removeAll()
        chapterPageOffsets.removeAll()
        globalPageMap.removeAll()
        currentLoadedChapter = -1
        isScanningComplete = false
        preloadedChapter.removeAll()
        preloadedReady.removeAll()
        scrollLoadedRange = nil
        isInjectingScrollChapter = false
        restoredLocatorRecord = nil
        didApplyRestoredLocator = false
        progressSaveWorkItem?.cancel()
        renderSessionID += 1
        transitionTurnState(to: .idle, event: .programmaticJump)
        let oldTempFiles = tempHTMLFiles
        tempHTMLFiles.removeAll()
        cleanupTempFiles(oldTempFiles)
        crossChapterTransitionTask?.cancel()
        crossChapterTransitionTask = nil
        clearMemoryCache()

        renderFontSize = settings.fontSize
        renderMarginH = settings.marginH
        renderMarginV = settings.marginV
        renderTheme = settings.theme
        renderFooterHeight = settings.footerHeight
        self.pipelineKind = pipelineKind
        currentBookIdentifier = bookIdentifier

        webView.backgroundColor = themeBackgroundUIColor()
        webView.scrollView.backgroundColor = themeBackgroundUIColor()

        progressStore = EPUBProgressStore(directoryURL: progressDirectoryURL())
        restoredLocatorRecord = progressStore?.loadLastRecord()
    }

    private func onParsed(_ parsed: EPUBParsedBook) {
        self.parsedBook = parsed
        self.publicationSession = nil
        self.bookTitle = parsed.title
        buildTOC()

        // 先假設每章 1 頁，建立初始 globalPageMap
        for i in 0..<parsed.chapters.count {
            chapterPageCounts[i] = 1
        }
        rebuildGlobalPageMap()

        // 決定起始章節
        let targetChapter: Int
        let targetLocalPage: Int
        if let record = restoredLocatorRecord,
           record.chapterIndex < parsed.chapters.count
        {
            targetChapter = record.chapterIndex
            targetLocalPage = record.pageInChapter
            didApplyRestoredLocator = true
        } else {
            targetChapter = 0
            targetLocalPage = 0
        }

        Task {
            if scrollModeEnabled {
                // 上下滑動模式：用 DOM 拼接引擎
                await loadScrollMode(startChapter: targetChapter)
                isReady = true
            } else {
                // 分頁模式：CSS Column
                await loadChapter(targetChapter, localPage: targetLocalPage)
                isReady = true
                await scanRemainingChapters(startingFrom: targetChapter)
            }
        }
    }

    private func onPublicationSessionReady(_ session: PublicationSession) {
        bookTitle = session.bookTitle
        buildTOC()

        for chapter in session.chapters {
            chapterPageCounts[chapter.index] = 1
        }
        rebuildGlobalPageMap()

        Task {
            let targetChapter: Int
            let targetProgression: Double

            if let record = restoredLocatorRecord,
               let resolved = await session.resolve(locator: record)
            {
                targetChapter = resolved.chapterIndex
                targetProgression = resolved.chapterProgression
                didApplyRestoredLocator = true
            } else {
                targetChapter = 0
                targetProgression = 0
            }

            if scrollModeEnabled {
                await loadScrollMode(startChapter: targetChapter)
                isReady = true
            } else {
                await loadChapter(targetChapter, localPage: 0, restoreProgression: targetProgression)
                isReady = true
                await scanRemainingChapters(startingFrom: targetChapter)
            }
        }
    }

    private func buildTOC() {
        if let session = publicationSession {
            let tocLevelMap: [String: Int] = Dictionary(
                session.tocEntries.map { ($0.href, $0.level) },
                uniquingKeysWith: { first, _ in first }
            )
            tocItems = session.chapters.map { chapter in
                let level = tocLevelMap[chapter.href]
                    ?? tocLevelMap.first(where: { chapter.href.hasSuffix($0.key) || $0.key.hasSuffix(chapter.href) })?.value
                    ?? 0
                return ["label": chapter.title, "href": chapter.href, "index": chapter.index, "level": level] as [String: Any]
            }
            tocCount = session.chapters.count
            return
        }

        guard let parsed = parsedBook else { return }
        let tocLevelMap: [String: Int] = Dictionary(
            parsed.tocEntries.map { ($0.href, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )
        self.tocItems = parsed.chapters.enumerated().map { (i, ch) in
            let level = tocLevelMap[ch.href]
                ?? tocLevelMap.first(where: { ch.href.hasSuffix($0.key) || $0.key.hasSuffix(ch.href) })?.value
                ?? 0
            return ["label": ch.title, "href": ch.href, "index": i, "level": level] as [String: Any]
        }
        self.tocCount = parsed.chapters.count
    }

    // MARK: - 章節頁數掃描（背景漸進式）

    /// 背景掃描所有章節頁數。已載入的章節（currentLoadedChapter）的頁數
    /// 由 loadChapter 的 paginationReady 直接更新，這裡只掃描其餘章節。
    private func scanRemainingChapters(startingFrom loadedChapter: Int) async {
        let chapterCount: Int
        if let session = publicationSession {
            chapterCount = session.chapters.count
        } else if let parsed = parsedBook {
            chapterCount = parsed.chapters.count
        } else {
            return
        }
        guard chapterCount > 1 else { return }

        // 建立離屏掃描 WebView
        let scanHandler = LiveScanMessageHandler(reader: self)
        self.scanMessageHandler = scanHandler

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PublicationSession.scheme)
        config.userContentController.add(scanHandler, name: "scanBridge")

        let size = UIScreen.main.bounds.size
        let swv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        swv.isOpaque = false
        swv.scrollView.isScrollEnabled = false

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first
        {
            swv.frame = CGRect(x: -size.width * 2, y: 0, width: size.width, height: size.height)
            window.addSubview(swv)
        }
        self.scanWebView = swv

        // 逐章掃描（跳過已載入的章節，它的頁數已由 loadChapter 取得）
        for i in 0..<chapterCount {
            if i == loadedChapter { continue }
            let pageCount: Int
            if let session = publicationSession {
                pageCount = await scanReadiumChapterPageCount(webView: swv, chapterIndex: i, bridgeName: "scanBridge", session: session)
            } else if let parsed = parsedBook {
                let html = buildChapterHTML(chapter: parsed.chapters[i], bridgeName: "scanBridge")
                pageCount = await scanChapterPageCount(webView: swv, html: html, chapter: parsed.chapters[i])
            } else {
                continue
            }
            chapterPageCounts[i] = pageCount
            // 每掃一章就更新 globalPageMap，讓 UI 能即時反映正確的總頁數
            rebuildGlobalPageMap()
            snapshotProgress = Double(i + 1) / Double(chapterCount)
        }

        // 拆除掃描 WebView
        swv.configuration.userContentController.removeScriptMessageHandler(forName: "scanBridge")
        swv.removeFromSuperview()
        self.scanWebView = nil
        self.scanMessageHandler = nil

        isScanningComplete = true
    }

    private func scanReadiumChapterPageCount(
        webView: WKWebView,
        chapterIndex: Int,
        bridgeName: String,
        session: PublicationSession
    ) async -> Int {
        do {
            let html = try await session.chapterHTML(at: chapterIndex)
            let wrapped = buildChapterHTML(
                chapterHTML: html,
                chapterBaseURL: session.chapterBaseURL(at: chapterIndex),
                bridgeName: bridgeName,
                useReadiumCSS: true
            )
            webView.loadHTMLString(wrapped, baseURL: session.chapterBaseURL(at: chapterIndex))
        } catch {
            return 1
        }

        return await withCheckedContinuation { continuation in
            self.scanContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if let c = self?.scanContinuation {
                    self?.scanContinuation = nil
                    c.resume(returning: 1)
                }
            }
        }
    }

    private func scanChapterPageCount(webView: WKWebView, html: String, chapter: EPUBChapterRaw) async -> Int {
        // 寫入暫存檔讓 loadFileURL 可以存取相對資源
        let tmpHTML = chapter.baseURL.appendingPathComponent("_scan_\(UUID().uuidString).html")
        try? html.write(to: tmpHTML, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpHTML) }

        webView.loadFileURL(tmpHTML, allowingReadAccessTo: parsedBook?.basePath ?? tmpHTML.deletingLastPathComponent())

        return await withCheckedContinuation { continuation in
            self.scanContinuation = continuation
            // 超時保護
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if let c = self?.scanContinuation {
                    self?.scanContinuation = nil
                    c.resume(returning: 1)
                }
            }
        }
    }

    fileprivate func onScanPaginationReady(pageCount: Int) {
        if let c = scanContinuation {
            scanContinuation = nil
            c.resume(returning: max(1, pageCount))
        }
    }

    // MARK: - 全域頁碼映射

    private func rebuildGlobalPageMap() {
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0
        guard chapterCount > 0 else { return }
        globalPageMap.removeAll()
        for i in 0..<chapterCount {
            let count = chapterPageCounts[i] ?? 1
            for p in 0..<count {
                globalPageMap.append((chapter: i, page: p))
            }
        }
        totalPages = globalPageMap.count
    }

    // MARK: - 章節載入（載入到可見 WebView）

    private func loadChapter(_ chapterIndex: Int, localPage: Int, restoreProgression: Double? = nil) async {
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0
        guard chapterIndex >= 0, chapterIndex < chapterCount else { return }
        transitionTurnState(to: .loadingChapter(target: chapterIndex), event: .chapterLoadStarted)

        // 如果上一次 loadChapter 的 continuation 還沒被 resume，先清理掉避免 leak
        if let c = chapterLoadContinuation {
            chapterLoadContinuation = nil
            c.resume(returning: false)
        }

        // 確保 WebView 在 view hierarchy 中（首次載入時可能還沒被 SwiftUI 掛上）
        ensureWebViewInHierarchy()

        currentLoadedChapter = chapterIndex
        currentChapterIdx = chapterIndex

        if let session = publicationSession {
            do {
                let html = try await session.chapterHTML(at: chapterIndex)
                let baseURL = session.chapterBaseURL(at: chapterIndex)
                let wrapped = buildChapterHTML(
                    chapterHTML: html,
                    chapterBaseURL: baseURL,
                    bridgeName: "readerBridge",
                    useReadiumCSS: true
                )
                webView.loadHTMLString(wrapped, baseURL: baseURL)
            } catch {
                onPaginationReady(pageCount: 1)
                return
            }
        } else if let parsed = parsedBook {
            let chapter = parsed.chapters[chapterIndex]
            let html = buildChapterHTML(chapter: chapter, bridgeName: "readerBridge")

            let tmpHTML = chapter.baseURL.appendingPathComponent("_live_\(UUID().uuidString).html")
            let wrote = (try? html.write(to: tmpHTML, atomically: true, encoding: .utf8)) != nil
            if wrote { tempHTMLFiles.insert(tmpHTML) }

            if wrote {
                webView.loadFileURL(tmpHTML, allowingReadAccessTo: parsed.basePath)
            } else {
                webView.loadHTMLString(html, baseURL: chapter.baseURL)
            }
        } else {
            return
        }

        // 等待 JS paginationReady 回調
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.chapterLoadContinuation = continuation
            // 超時保護：3 秒
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if let c = self?.chapterLoadContinuation {
                    self?.chapterLoadContinuation = nil
                    c.resume(returning: false)
                }
            }
        }

        // 如果超時，手動查詢頁數
        if !success {
            if let metrics = await requestPaginationMetrics(in: webView), metrics.pageCount > 0 {
                onPaginationReady(pageCount: metrics.pageCount, pageOffsets: metrics.pageOffsets)
            } else {
                // 最後防線：確保至少有 1 頁可顯示，不卡在空白
                onPaginationReady(pageCount: 1)
            }
        }

        let resolvedLocalPage: Int
        if let restoreProgression {
            let chapterPageCount = max(chapterPageCounts[chapterIndex] ?? 1, 1)
            resolvedLocalPage = min(
                max(Int(round(restoreProgression * Double(max(chapterPageCount - 1, 0)))), 0),
                max(chapterPageCount - 1, 0)
            )
        } else {
            resolvedLocalPage = localPage
        }
        snapToLocalPage(resolvedLocalPage)
        if let gp = firstGlobalPage(forChapter: chapterIndex, preferredLocalPage: resolvedLocalPage) {
            currentEpubPage = gp
        }
        updateCurrentState()
        transitionTurnState(to: .idle, event: .chapterLoadFinished)

        // 預載鄰近章節
        preloadNeighbors()
    }

    // MARK: - Pool 預載

    /// 預載 prev/next 章節到 offscreen WebView（帶 300ms 防抖，避免快速翻頁時瘋狂觸發 loadHTML）
    private func preloadNeighbors() {
        // 【死穴三修復】立即開始預載，不再用 300ms debounce。
        // 舊邏輯的 300ms 延遲導致快速翻頁時預載未就緒，
        // 跨章翻頁被迫走同步 loadChapter 路徑，造成卡頓。
        preloadDebounceWork?.cancel()
        doPreloadNeighbors()
    }

    private func doPreloadNeighbors() {
        let ch = currentLoadedChapter
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0

        if ch - 1 >= 0 {
            if preloadedChapter[.prev] != ch - 1 {
                preloadChapter(ch - 1, role: .prev)
            }
        } else {
            preloadedChapter[.prev] = nil
            preloadedReady[.prev] = false
        }
        if ch + 1 < chapterCount {
            if preloadedChapter[.next] != ch + 1 {
                preloadChapter(ch + 1, role: .next)
            }
        } else {
            preloadedChapter[.next] = nil
            preloadedReady[.next] = false
        }
    }

    /// 在 offscreen WebView 中預載指定章節
    private func preloadChapter(_ chapterIndex: Int, role: WebViewRole) {
        guard let wv = webViewPool[role] else { return }
        preloadedChapter[role] = chapterIndex
        preloadedReady[role] = false
        let bgColor = themeBackgroundUIColor()
        wv.backgroundColor = bgColor
        wv.scrollView.backgroundColor = bgColor

        if let session = publicationSession {
            guard chapterIndex >= 0, chapterIndex < session.chapters.count else { return }
            let bridgeName = "preload_\(role)"
            Task {
                do {
                    let html = try await session.chapterHTML(at: chapterIndex)
                    let wrapped = buildChapterHTML(
                        chapterHTML: html,
                        chapterBaseURL: session.chapterBaseURL(at: chapterIndex),
                        bridgeName: bridgeName,
                        useReadiumCSS: true
                    )
                    wv.loadHTMLString(wrapped, baseURL: session.chapterBaseURL(at: chapterIndex))
                } catch {
                }
            }
            return
        }

        guard let parsed = parsedBook,
              chapterIndex >= 0, chapterIndex < parsed.chapters.count
        else { return }

        let chapter = parsed.chapters[chapterIndex]
        let bridgeName = "preload_\(role)"
        let html = buildChapterHTML(chapter: chapter, bridgeName: bridgeName)

        let tmpHTML = chapter.baseURL.appendingPathComponent("_preload_\(UUID().uuidString).html")
        if let _ = try? html.write(to: tmpHTML, atomically: true, encoding: .utf8) {
            tempHTMLFiles.insert(tmpHTML)
            wv.loadFileURL(tmpHTML, allowingReadAccessTo: parsed.basePath)
        } else {
            wv.loadHTMLString(html, baseURL: chapter.baseURL)
        }

    }

    /// 預載完成回調
    func onPreloadReady(role: WebViewRole, pageCount: Int, pageOffsets: [CGFloat]? = nil) {
        guard let ch = preloadedChapter[role] else { return }
        let oldCount = chapterPageCounts[ch] ?? 1
        let newCount = max(1, pageCount)
        chapterPageCounts[ch] = newCount
        storePageOffsets(
            pageOffsets,
            forChapter: ch,
            pageCount: newCount,
            fallbackWidth: pageRenderWidth(for: webViewPool[role] ?? webView)
        )
        if oldCount != newCount || pageOffsets != nil {
            let startPage = firstGlobalPage(forChapter: ch, preferredLocalPage: 0) ?? 0
            invalidateSnapshots(fromGlobalPage: startPage)
        }
        preloadedReady[role] = true
        rebuildGlobalPageMap()
    }

    private func roleForWebView(_ candidate: WKWebView?) -> WebViewRole? {
        guard let candidate else { return nil }
        for (role, pooled) in webViewPool where pooled === candidate {
            return role
        }
        return nil
    }

    private func routeTap(zone rawZone: String) {
        let zone = ["left", "center", "right"].contains(rawZone) ? rawZone : "center"
        if zone != "center", isTapTurnLocked {
            return
        }
        onTapZone?(zone)
    }

    fileprivate func handleBridgeMessage(
        type: String,
        payload: [String: Any],
        sourceWebView: WKWebView?,
        fallbackRole: WebViewRole?
    ) {
        switch type {
        case "paginationReady":
            let pageCount = payload["pageCount"] as? Int ?? 1
            let pageOffsets = decodePageOffsets(from: payload["pageOffsets"])
            if sourceWebView === webView {
                onPaginationReady(pageCount: pageCount, pageOffsets: pageOffsets)
                return
            }

            let resolvedRole = roleForWebView(sourceWebView) ?? fallbackRole
            if let resolvedRole {
                onPreloadReady(role: resolvedRole, pageCount: pageCount, pageOffsets: pageOffsets)
            }
        case "relayout":
            guard sourceWebView === webView else { return }
            let pageCount = payload["pageCount"] as? Int ?? 1
            onPaginationReady(pageCount: pageCount)
        case "tap":
            guard sourceWebView === webView else { return }
            let zone = payload["zone"] as? String ?? "center"
            routeTap(zone: zone)
        default:
            break
        }
    }

    /// 嘗試用預載的 WebView swap 到目標章節（成功回傳 true）
    func swapToPreloadedChapter(_ targetChapter: Int, direction: Int) -> Bool {
        let role: WebViewRole = direction > 0 ? .next : .prev
        guard preloadedChapter[role] == targetChapter,
              preloadedReady[role] == true,
              let preloadedWV = webViewPool[role]
        else { return false }

        guard let oldCurrent = webViewPool[.current],
              let oldPrev = webViewPool[.prev],
              let oldNext = webViewPool[.next]
        else { return false }
        let oldChapter = currentLoadedChapter

        if direction > 0 {
            webViewPool[.current] = preloadedWV
            webViewPool[.prev] = oldCurrent
            webViewPool[.next] = oldPrev
            preloadedChapter[.prev] = oldChapter
            preloadedReady[.prev] = true
            preloadedChapter[.next] = nil
            preloadedReady[.next] = false
        } else {
            webViewPool[.current] = preloadedWV
            webViewPool[.next] = oldCurrent
            webViewPool[.prev] = oldNext
            preloadedChapter[.next] = oldChapter
            preloadedReady[.next] = true
            preloadedChapter[.prev] = nil
            preloadedReady[.prev] = false
        }
        self.webView = preloadedWV

        currentLoadedChapter = targetChapter
        currentChapterIdx = targetChapter

        // 通知 container 重新 attach WebView
        webViewGeneration += 1

        // 預載新的鄰居
        preloadNeighbors()

        return true
    }

    /// 取得 pool 中指定角色的 WebView（供 cover snapshot 用）
    func poolWebView(for role: WebViewRole) -> WKWebView? {
        webViewPool[role]
    }

    /// 取得 pool 中指定角色已預載的章節 index
    func preloadedChapterIndex(for role: WebViewRole) -> Int? {
        preloadedChapter[role]
    }

    func isPreloadedChapterReady(for role: WebViewRole) -> Bool {
        preloadedReady[role] == true
    }

    /// 確保 WebView 已加入 window（SwiftUI 可能還沒把它掛上去）
    private func ensureWebViewInHierarchy() {
        guard webView.superview == nil else { return }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first
        {
            let size = UIScreen.main.bounds.size
            // 暫時放在螢幕外，等 LiveWebReaderView 接手後會移到正確位置
            webView.frame = CGRect(x: -size.width * 2, y: 0, width: size.width, height: size.height)
            window.addSubview(webView)
        }
    }

    // MARK: - 上下滑動模式（Scroll Mode）載入

    /// 上下滑動模式的初始載入：建構 scroll HTML，載入起始章節
    private func loadScrollMode(startChapter: Int) async {
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0
        guard chapterCount > 0 else { return }
        let chapter = min(max(startChapter, 0), chapterCount - 1)

        // 清理遺留的 continuation 避免 leak
        if let c = chapterLoadContinuation {
            chapterLoadContinuation = nil
            c.resume(returning: false)
        }

        ensureWebViewInHierarchy()
        currentLoadedChapter = chapter
        currentChapterIdx = chapter
        scrollLoadedRange = chapter...chapter
        scrollVisibleChapterIndex = chapter

        // 設定 WebView 為上下滑動
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.isPagingEnabled = false
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.bounces = true

        // 取得起始章節內容
        let chapterContent: (bodyHTML: String, title: String, baseURL: URL, headHTML: String, bodyAttributes: String)
        if let session = publicationSession {
            do {
                let html = try await session.chapterHTML(at: chapter)
                let body = extractBodyContent(html)
                chapterContent = (
                    body,
                    session.chapters[chapter].title,
                    session.chapterBaseURL(at: chapter),
                    extractHeadContent(html),
                    extractBodyAttributes(html)
                )
            } catch {
                onPaginationReady(pageCount: 1)
                return
            }
        } else if let parsed = parsedBook {
            let ch = parsed.chapters[chapter]
            chapterContent = (
                extractBodyContent(ch.html),
                ch.title,
                ch.baseURL,
                extractHeadContent(ch.html),
                extractBodyAttributes(ch.html)
            )
        } else {
            return
        }

        // 建構 book CSS（從第一章取）
        let inlineBookCSS: String
        if let parsed = parsedBook, chapter < parsed.chapters.count {
            inlineBookCSS = parsed.chapters[chapter].cssEntries.map { entry in
                rewriteCSSURLs(entry.content, cssBaseDir: entry.baseDir)
            }.joined(separator: "\n")
        } else {
            inlineBookCSS = ""
        }

        let html = buildScrollModeHTML(
            startChapterIndex: chapter,
            chapterBodyHTML: chapterContent.bodyHTML,
            chapterTitle: chapterContent.title,
            chapterBaseURL: chapterContent.baseURL,
            chapterHeadHTML: chapterContent.headHTML,
            bodyAttributes: chapterContent.bodyAttributes,
            bridgeName: "readerBridge",
            inlineBookCSS: inlineBookCSS,
            useReadiumCSS: pipelineKind == .epub
        )

        // 載入 HTML
        if publicationSession != nil {
            webView.loadHTMLString(html, baseURL: chapterContent.baseURL)
        } else if let parsed = parsedBook {
            let tmpHTML = chapterContent.baseURL.appendingPathComponent("_scroll_\(UUID().uuidString).html")
            let wrote = (try? html.write(to: tmpHTML, atomically: true, encoding: .utf8)) != nil
            if wrote { tempHTMLFiles.insert(tmpHTML) }
            if wrote {
                webView.loadFileURL(tmpHTML, allowingReadAccessTo: parsed.basePath)
            } else {
                webView.loadHTMLString(html, baseURL: chapterContent.baseURL)
            }
        }

        // 等待 JS paginationReady 回調
        let _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.chapterLoadContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if let c = self?.chapterLoadContinuation {
                    self?.chapterLoadContinuation = nil
                    c.resume(returning: false)
                }
            }
        }

        // 在 scroll mode 下，totalPages = 章節數，currentEpubPage = 章節 index
        totalPages = chapterCount
        currentEpubPage = chapter
        updateScrollState()

        // 恢復上次閱讀位置
        if let record = restoredLocatorRecord,
           record.chapterIndex == chapter,
           let progress = record.chapterProgression, progress > 0 {
            let js = "_scrollToChapter(\(chapter), \(progress))"
            webView.evaluateJavaScript(js) { _, _ in }
        }

        // 預注入鄰近章節
        await injectAdjacentScrollChapters()
    }

    /// 注入下一章（往下滑動時觸發）
    func injectNextScrollChapter() {
        guard scrollModeEnabled, !isInjectingScrollChapter else { return }
        guard let range = scrollLoadedRange else { return }
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0
        let nextIdx = range.upperBound + 1
        guard nextIdx < chapterCount else { return }

        isInjectingScrollChapter = true
        Task {
            await injectScrollChapter(index: nextIdx, position: "after")
            isInjectingScrollChapter = false

            // 清理遠端章節（保留可見 ±3 章）
            cleanupDistantScrollChapters()
        }
    }

    /// 注入上一章（往上滑動時觸發）
    func injectPrevScrollChapter() {
        guard scrollModeEnabled, !isInjectingScrollChapter else { return }
        guard let range = scrollLoadedRange else { return }
        let prevIdx = range.lowerBound - 1
        guard prevIdx >= 0 else { return }

        isInjectingScrollChapter = true
        Task {
            await injectScrollChapter(index: prevIdx, position: "before")
            isInjectingScrollChapter = false

            cleanupDistantScrollChapters()
        }
    }

    /// 注入指定章節到 DOM
    private func injectScrollChapter(index: Int, position: String) async {
        guard let content = await scrollChapterBodyHTML(at: index) else { return }

        let base64 = Data(content.bodyHTML.utf8).base64EncodedString()
        let escapedTitle = content.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let js = "_injectChapter(\(index), '\(base64)', '\(escapedTitle)', '\(position)')"
        let _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(js) { _, _ in
                cont.resume(returning: true)
            }
        }

        // 更新已載入範圍
        if let range = scrollLoadedRange {
            let newLower = min(range.lowerBound, index)
            let newUpper = max(range.upperBound, index)
            scrollLoadedRange = newLower...newUpper
        } else {
            scrollLoadedRange = index...index
        }
    }

    /// 預注入鄰近章節（初始載入後呼叫）
    private func injectAdjacentScrollChapters() async {
        guard let range = scrollLoadedRange else { return }
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0

        // 向下注入 1 章
        if range.upperBound + 1 < chapterCount {
            await injectScrollChapter(index: range.upperBound + 1, position: "after")
        }
        // 向上注入 1 章
        if range.lowerBound - 1 >= 0 {
            await injectScrollChapter(index: range.lowerBound - 1, position: "before")
        }
    }

    /// 清理 DOM 中距離當前可見章節太遠的章節（防止 OOM）
    private func cleanupDistantScrollChapters() {
        guard let range = scrollLoadedRange else { return }
        let visible = scrollVisibleChapterIndex
        let keepRange = max(0, visible - 3)...min(
            (publicationSession?.chapters.count ?? parsedBook?.chapters.count ?? 1) - 1,
            visible + 3
        )

        var chaptersToRemove: [Int] = []
        for i in range.lowerBound...range.upperBound {
            if !keepRange.contains(i) {
                chaptersToRemove.append(i)
            }
        }

        guard !chaptersToRemove.isEmpty else { return }

        for idx in chaptersToRemove {
            webView.evaluateJavaScript("_removeChapter(\(idx))") { _, _ in }
        }

        // 更新 range
        let remaining = (range.lowerBound...range.upperBound).filter { keepRange.contains($0) }
        if let first = remaining.first, let last = remaining.last {
            scrollLoadedRange = first...last
        }
    }

    /// 查詢 JS 端當前可見章節並更新狀態
    func queryScrollProgress() {
        guard scrollModeEnabled else { return }
        webView.evaluateJavaScript("JSON.stringify(_getVisibleChapter())") { [weak self] result, _ in
            guard let self, let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let chapterIdx = dict["chapter"] as? Int ?? 0
            let progress = dict["progress"] as? Double ?? 0
            let oldChapter = self.scrollVisibleChapterIndex
            self.scrollVisibleChapterIndex = chapterIdx
            self.scrollChapterProgress = progress
            self.currentChapterIdx = chapterIdx
            self.currentEpubPage = chapterIdx
            self.updateScrollState()
            // 章節變化時儲存進度
            if chapterIdx != oldChapter {
                self.saveScrollProgress()
            }
        }
    }

    /// 更新 scroll mode 下的全局狀態
    private func updateScrollState() {
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0
        guard chapterCount > 0 else { return }
        percentage = (Double(scrollVisibleChapterIndex) + scrollChapterProgress) / Double(chapterCount)

        let idx = scrollVisibleChapterIndex
        let href: String?
        if let session = publicationSession, idx >= 0, idx < session.chapters.count {
            href = session.chapters[idx].href
        } else if let parsed = parsedBook, idx >= 0, idx < parsed.chapters.count {
            href = parsed.chapters[idx].href
        } else {
            href = nil
        }
        if let href {
            onRelocated?(href, percentage)
        }
    }

    private var chapterLoadContinuation: CheckedContinuation<Bool, Never>?

    fileprivate func onPaginationReady(pageCount: Int, pageOffsets: [CGFloat]? = nil) {
        // 更新當前章節頁數（以可見 WebView 為準）
        if currentLoadedChapter >= 0 {
            let chapter = currentLoadedChapter
            let oldCount = chapterPageCounts[chapter] ?? 1
            let newCount = max(1, pageCount)
            chapterPageCounts[chapter] = newCount
            storePageOffsets(
                pageOffsets,
                forChapter: chapter,
                pageCount: newCount,
                fallbackWidth: pageRenderWidth(for: webView)
            )
            if oldCount != newCount || pageOffsets != nil {
                let startPage = firstGlobalPage(forChapter: chapter, preferredLocalPage: 0) ?? 0
                invalidateSnapshots(fromGlobalPage: startPage)
            }
            rebuildGlobalPageMap()
        }
        if let c = chapterLoadContinuation {
            chapterLoadContinuation = nil
            c.resume(returning: true)
        }
    }

    // MARK: - 翻頁

    func nextPage() {
        let newPage = currentEpubPage + 1
        guard newPage < totalPages else { return }
        goToPage(newPage)
    }

    func prevPage() {
        let newPage = currentEpubPage - 1
        guard newPage >= 0 else { return }
        goToPage(newPage)
    }

    func turnPageProgrammatically(forward: Bool) {
        let targetPage = currentEpubPage + (forward ? 1 : -1)
        guard targetPage >= 0, targetPage < totalPages else { return }
        turnCommandPublisher.send(forward ? .forward : .backward)
        settlePageTransition(toGlobalPage: targetPage, style: .slide)
    }

    func turnPageProgrammatically(forward: Bool, style: PageTurnStyle) {
        let targetPage = currentEpubPage + (forward ? 1 : -1)
        guard targetPage >= 0, targetPage < totalPages else { return }
        turnCommandPublisher.send(forward ? .forward : .backward)
        settlePageTransition(toGlobalPage: targetPage, style: style)
    }

    private func animationDuration(for style: PageTurnStyle) -> Int {
        switch style {
        case .none:
            return 0
        case .curl:
            return 260
        case .cover:
            return 220
        case .slide:
            return 220
        }
    }

    private func settlePageTransition(toGlobalPage page: Int, style: PageTurnStyle) {
        guard page >= 0, page < totalPages, page < globalPageMap.count else { return }
        let oldPage = currentEpubPage
        if page == oldPage {
            if oldPage >= 0, oldPage < globalPageMap.count {
                let target = globalPageMap[oldPage]
                guard target.chapter == currentLoadedChapter else {
                    saveProgress()
                    return
                }
                if style == .none {
                    snapToLocalPage(target.page)
                } else {
                    animateToLocalPage(target.page, duration: animationDuration(for: style)) { [weak self] in
                        self?.updateCurrentState()
                    }
                }
            }
            saveProgress()
            return
        }

        let target = globalPageMap[page]
        transitionTurnState(to: .animatingCommit(target: page, animator: nil), event: .programmaticJump)

        guard target.chapter == currentLoadedChapter else {
            if style == .none {
                goToPage(page)
                return
            }
            let fromPage = oldPage
            crossChapterTransitionTask?.cancel()
            crossChapterTransitionTask = Task { @MainActor [weak self] in
                await self?.animateCrossChapterTransition(
                    fromGlobalPage: fromPage,
                    toGlobalPage: page,
                    style: style
                )
            }
            return
        }

        currentEpubPage = page
        lockTapTurns()
        webView.layer.transform = CATransform3DIdentity

        let finalize: () -> Void = { [weak self] in
            guard let self else { return }
            self.updateCurrentState()
            self.transitionTurnState(to: .idle, event: .transitionCommitted)
            self.saveProgress()
        }

        if style == .none {
            snapToLocalPage(target.page)
            finalize()
        } else {
            animateToLocalPage(target.page, duration: animationDuration(for: style), completion: finalize)
        }
    }

    func settleDrag(toGlobalPage page: Int, style: PageTurnStyle) {
        settlePageTransition(toGlobalPage: page, style: style)
    }

    private func animateCrossChapterTransition(
        fromGlobalPage: Int,
        toGlobalPage: Int,
        style: PageTurnStyle
    ) async {
        defer { crossChapterTransitionTask = nil }

        guard fromGlobalPage >= 0, fromGlobalPage < totalPages else {
            goToPage(toGlobalPage)
            return
        }
        guard toGlobalPage >= 0, toGlobalPage < totalPages else { return }
        guard currentEpubPage == fromGlobalPage else {
            goToPage(toGlobalPage)
            return
        }

        let fromImage = await captureSnapshot(forGlobalPage: fromGlobalPage)
        let toImage = await captureSnapshot(forGlobalPage: toGlobalPage)

        guard !Task.isCancelled else { return }
        guard let hostView = webView.superview,
              let fromImage,
              let toImage
        else {
            goToPage(toGlobalPage)
            return
        }

        let frame = webView.frame
        let bounds = CGRect(origin: .zero, size: frame.size)
        let width = max(bounds.width, 1)
        let isForward = toGlobalPage > fromGlobalPage
        let direction: CGFloat = isForward ? 1 : -1

        let overlay = UIView(frame: frame)
        overlay.backgroundColor = themeBackgroundUIColor()
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false

        let fromView = UIImageView(image: fromImage)
        fromView.contentMode = .scaleAspectFill
        fromView.clipsToBounds = true
        fromView.frame = bounds

        let toView = UIImageView(image: toImage)
        toView.contentMode = .scaleAspectFill
        toView.clipsToBounds = true
        toView.frame = bounds.offsetBy(dx: direction * width, dy: 0)

        let shadowView = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: bounds.height))
        shadowView.autoresizingMask = [.flexibleHeight]
        shadowView.backgroundColor = UIColor.black.withAlphaComponent(style == .cover ? 0.2 : 0.1)
        shadowView.alpha = 0
        toView.addSubview(shadowView)

        overlay.addSubview(fromView)
        overlay.addSubview(toView)
        hostView.addSubview(overlay)

        lockTapTurns(for: 0.36)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: Double(animationDuration(for: style)) / 1000.0, delay: 0, options: [.curveEaseOut]) {
                switch style {
                case .cover:
                    toView.frame = bounds
                    shadowView.alpha = 0.18
                    fromView.alpha = 1
                case .slide, .curl:
                    toView.frame = bounds
                    fromView.frame = bounds.offsetBy(dx: -direction * width * 0.35, dy: 0)
                    fromView.alpha = 0.82
                    shadowView.alpha = 0.08
                case .none:
                    toView.frame = bounds
                }
            } completion: { _ in
                continuation.resume()
            }
        }

        overlay.removeFromSuperview()
        goToPage(toGlobalPage)
    }

    func goToPage(_ page: Int, completion: (() -> Void)? = nil) {
        crossChapterTransitionTask?.cancel()
        crossChapterTransitionTask = nil
        guard page >= 0, page < totalPages, page < globalPageMap.count else { return }
        let target = globalPageMap[page]
        transitionTurnState(to: .animatingCommit(target: page, animator: nil), event: .programmaticJump)

        if target.chapter == currentLoadedChapter {
            currentEpubPage = page
            lockTapTurns()
            webView.layer.transform = CATransform3DIdentity
            snapToLocalPage(target.page)
            updateCurrentState()
            transitionTurnState(to: .idle, event: .transitionCommitted)
            completion?()
        } else {
            // 跨章：嘗試 pool swap（瞬時），否則直接載入目標章節。
            let oldPage = currentEpubPage
            currentEpubPage = page
            let isForward = page > oldPage
            let direction = isForward ? 1 : -1

            if swapToPreloadedChapter(target.chapter, direction: direction) {
                lockTapTurns()
                webView.layer.transform = CATransform3DIdentity
                snapToLocalPage(target.page)
                updateCurrentState()
                transitionTurnState(to: .idle, event: .transitionCommitted)
                completion?()
            } else {
                lockTapTurns()
                webView.layer.transform = CATransform3DIdentity
                Task {
                    await self.loadChapter(target.chapter, localPage: target.page)
                    self.transitionTurnState(to: .idle, event: .transitionCommitted)
                    completion?()
                }
            }
        }
        saveProgress()
    }

    func jumpToChapter(_ chapterIdx: Int, preferredLocalPage: Int? = nil) {
        guard let gp = firstGlobalPage(forChapter: chapterIdx, preferredLocalPage: preferredLocalPage) else { return }
        goToPage(gp)
    }

    func jumpToHref(_ href: String) {
        if let session = publicationSession,
           let idx = session.chapterIndex(for: href)
        {
            jumpToChapter(idx)
            return
        }
        guard let parsed = parsedBook else { return }
        if let idx = parsed.chapters.firstIndex(where: {
            $0.href == href || href.hasSuffix($0.href) || $0.href.hasSuffix(href)
        }) {
            jumpToChapter(idx)
        }
    }

    // MARK: - 跟手翻頁（供手勢層呼叫）

    /// 拖曳基準 scrollOffset（第一次呼叫 dragOffset 時自動記錄）
    private var nativeDragBaseX: CGFloat?

    /// 純 UIKit 跟手：直接操控 scrollView.contentOffset，零 IPC
    func dragOffset(_ dx: CGFloat) {
        guard let wv = webView else { return }
        let sv = wv.scrollView

        // 第一次拖曳：記錄起點
        if nativeDragBaseX == nil {
            nativeDragBaseX = sv.contentOffset.x
        }
        let baseX = nativeDragBaseX!

        // 計算目標 offset（與 JS setPageOffset 相同邏輯：base - dx）
        let maxOffset = max(sv.contentSize.width - sv.bounds.width, 0)
        let targetX = max(0, min(baseX - dx, maxOffset))
        sv.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
    }

    /// 結束拖曳時重置基準值
    func resetDragBase() {
        nativeDragBaseX = nil
    }

    func commitDrag(toPage targetGlobalPage: Int) {
        // 現在由 LiveReaderContainerView.handlePan 直接處理動畫
        // 這個方法保留做為 fallback
        goToPage(targetGlobalPage)
    }

    /// 取得當前章節的本地頁數（給手勢層判斷邊界用）
    var currentChapterPageCount: Int {
        chapterPageCounts[currentLoadedChapter] ?? 1
    }

    /// 取得當前本地頁碼
    var currentLocalPage: Int {
        guard currentEpubPage >= 0, currentEpubPage < globalPageMap.count else { return 0 }
        return globalPageMap[currentEpubPage].page
    }

    /// 跨章翻頁：由手勢層在動畫完成後呼叫，載入目標頁所在章節
    func loadChapterForPage(_ globalPage: Int, completion: (() -> Void)? = nil) {
        guard globalPage >= 0, globalPage < totalPages, globalPage < globalPageMap.count else { return }
        let target = globalPageMap[globalPage]
        let direction = globalPage > currentEpubPage ? 1 : -1
        currentEpubPage = globalPage

        // 嘗試 pool swap（瞬時），否則 loadChapter
        if swapToPreloadedChapter(target.chapter, direction: direction) {
            lockTapTurns()
            snapToLocalPage(target.page)
            updateCurrentState()
            completion?()
        } else {
            lockTapTurns()
            Task {
                await loadChapter(target.chapter, localPage: target.page)
                completion?()
            }
        }
        saveProgress()
    }

    /// 翻頁完成後通知狀態更新（供手勢層呼叫）
    func notifyPageChanged() {
        updateCurrentState()
        saveProgress()
    }

    // MARK: - 跟手 JS 呼叫

    func snapToLocalPage(_ page: Int, in targetWebView: WKWebView? = nil) {
        guard let resolvedWebView = targetWebView ?? webView else { return }
        let pageCount = resolvedPageCount(for: resolvedWebView)
        let targetX = resolvedPageOffset(for: page, in: resolvedWebView, pageCount: pageCount)
        resolvedWebView.scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        // 同步 JS 內部狀態（_currentLocalPage），但不做動畫
        resolvedWebView.evaluateJavaScript("if(typeof snapToPage==='function')snapToPage(\(page))") { _, _ in }
    }

    func animateToLocalPage(
        _ page: Int,
        duration: Int,
        in targetWebView: WKWebView? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let resolvedWebView = targetWebView ?? webView else { return }
        let pageCount = resolvedPageCount(for: resolvedWebView)
        let targetX = resolvedPageOffset(for: page, in: resolvedWebView, pageCount: pageCount)

        // 純 UIKit 動畫：直接操控 scrollView，零 IPC 延遲
        UIView.animate(withDuration: Double(duration) / 1000.0, delay: 0, options: .curveEaseOut) {
            resolvedWebView.scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        } completion: { _ in
            // 動畫結束後同步 JS 內部狀態（不做動畫，只更新 _currentLocalPage）
            resolvedWebView.evaluateJavaScript("if(typeof snapToPage==='function')snapToPage(\(page))") { _, _ in }
            completion?()
        }
    }

    var isTapTurnLocked: Bool {
        CFAbsoluteTimeGetCurrent() < tapTurnLockUntil
    }

    func lockTapTurns(for duration: CFTimeInterval = 0.28) {
        tapTurnLockUntil = CFAbsoluteTimeGetCurrent() + max(duration, 0)
    }

    private func resolvedPageCount(for targetWebView: WKWebView) -> Int {
        if targetWebView === webView {
            return max(currentChapterPageCount, 1)
        }
        if let role = webViewPool.first(where: { $0.value === targetWebView })?.key,
           let chapter = preloadedChapter[role] {
            return max(chapterPageCounts[chapter] ?? 1, 1)
        }
        return 1
    }

    private func chapterIndex(for targetWebView: WKWebView) -> Int? {
        if targetWebView === webView {
            return currentLoadedChapter >= 0 ? currentLoadedChapter : nil
        }
        if let role = webViewPool.first(where: { $0.value === targetWebView })?.key {
            return preloadedChapter[role]
        }
        return nil
    }

    private func resolvedPageOffset(for localPage: Int, in targetWebView: WKWebView, pageCount: Int) -> CGFloat {
        let boundedPage = max(0, min(localPage, max(pageCount - 1, 0)))
        if let chapter = chapterIndex(for: targetWebView),
           let offsets = chapterPageOffsets[chapter],
           offsets.indices.contains(boundedPage)
        {
            return offsets[boundedPage]
        }
        let boundsWidth = max(targetWebView.scrollView.bounds.width, targetWebView.bounds.width, 1)
        let expectedWidth = CGFloat(max(pageCount, 1)) * boundsWidth
        let contentWidth = max(targetWebView.scrollView.contentSize.width, expectedWidth, boundsWidth)
        let pageSpan = pageCount > 1 ? max(contentWidth / CGFloat(pageCount), boundsWidth) : boundsWidth
        let maxOffset = max(contentWidth - boundsWidth, 0)
        return min(CGFloat(boundedPage) * pageSpan, maxOffset)
    }

    private func normalizedPageOffsets(
        _ offsets: [CGFloat]?,
        pageCount: Int,
        fallbackWidth: CGFloat
    ) -> [CGFloat]? {
        guard let offsets, !offsets.isEmpty else { return nil }
        let expectedCount = max(pageCount, 1)
        var cleaned: [CGFloat] = []
        cleaned.reserveCapacity(offsets.count)

        for value in offsets {
            guard value.isFinite else { continue }
            let normalized = max(value.rounded(.toNearestOrAwayFromZero), 0)
            if let last = cleaned.last, abs(last - normalized) < 1 {
                continue
            }
            cleaned.append(normalized)
        }

        if cleaned.isEmpty {
            return nil
        }
        if cleaned.count > expectedCount {
            cleaned = Array(cleaned.prefix(expectedCount))
        }
        if cleaned.count < expectedCount {
            let start = cleaned.last ?? 0
            let initialCount = cleaned.count
            for index in initialCount..<expectedCount {
                cleaned.append(start + CGFloat(index - initialCount + 1) * max(fallbackWidth, 1))
            }
        }
        return cleaned
    }

    private func storePageOffsets(
        _ offsets: [CGFloat]?,
        forChapter chapter: Int,
        pageCount: Int,
        fallbackWidth: CGFloat
    ) {
        guard chapter >= 0 else { return }
        if let normalized = normalizedPageOffsets(offsets, pageCount: pageCount, fallbackWidth: fallbackWidth) {
            chapterPageOffsets[chapter] = normalized
        } else {
            chapterPageOffsets.removeValue(forKey: chapter)
        }
    }

    // MARK: - 設定變更

    func setFontSize(_ size: CGFloat) {
        renderFontSize = size
        bumpLayoutGeneration()
        if publicationSession != nil {
            relayoutAroundCurrentLocation()
            return
        }
        let js = """
        document.body.style.fontSize = '\(Int(size))px';
        var p = recalcPages();
        window.webkit.messageHandlers.readerBridge.postMessage({type:'relayout', pageCount: p});
        """
        webView.evaluateJavaScript(js) { _, _ in }
    }

    func setTheme(_ theme: String) {
        renderTheme = theme
        bumpLayoutGeneration()
        let (bg, text) = themeColors(theme)
        webView.backgroundColor = themeBackgroundUIColor()
        clearMemoryCache()
        let js = """
        document.documentElement.style.background = '\(bg)';
        document.body.style.background = '\(bg)';
        document.body.style.color = '\(text)';
        """
        webView.evaluateJavaScript(js) { _, _ in }
    }

    func setTransition(_ mode: String) {
        let wasScrollMode = scrollModeEnabled
        renderFlowMode = mode
        scrollModeEnabled = (mode == "vertical")
        bumpLayoutGeneration()

        if scrollModeEnabled {
            webView.scrollView.isScrollEnabled = true
            webView.scrollView.isPagingEnabled = false
            webView.scrollView.showsVerticalScrollIndicator = true
            webView.scrollView.bounces = true

            // 如果是執行時切換（已載入內容），重新載入為 scroll mode
            if !wasScrollMode && isReady {
                let savedChapter = currentChapterIdx
                scrollLoadedRange = nil
                isInjectingScrollChapter = false
                Task {
                    isReady = false
                    await loadScrollMode(startChapter: savedChapter)
                    isReady = true
                }
            }
        } else {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.showsVerticalScrollIndicator = false
            webView.scrollView.bounces = false

            // 從 scroll mode 切回分頁：重新載入當前章節
            if wasScrollMode && isReady {
                let savedChapter = scrollVisibleChapterIndex
                scrollLoadedRange = nil
                isInjectingScrollChapter = false
                Task {
                    isReady = false
                    currentLoadedChapter = -1
                    await loadChapter(savedChapter, localPage: 0)
                    isReady = true
                    await scanRemainingChapters(startingFrom: savedChapter)
                }
            } else if !wasScrollMode {
                relayoutAroundCurrentLocation()
            }
        }
    }

    func setFooterHeight(_ height: CGFloat) {
        renderFooterHeight = height
        bumpLayoutGeneration()
        clearMemoryCache()
        if publicationSession != nil || parsedBook != nil {
            reloadCurrentLocationForLayoutChange()
        }
    }

    func setPageMargins(horizontal: CGFloat, vertical: CGFloat) {
        renderMarginH = horizontal
        renderMarginV = vertical
        bumpLayoutGeneration()
        clearMemoryCache()
        if publicationSession != nil || parsedBook != nil {
            reloadCurrentLocationForLayoutChange()
        }
    }

    private func resolvedTopPadding(safeTop: CGFloat) -> Int {
        Int(ReaderLayoutMetrics.topInset(safeTop: safeTop).rounded(.up))
    }

    private func resolvedBottomPadding(safeBottom: CGFloat) -> Int {
        Int(
            ReaderLayoutMetrics
                .bottomInset(safeBottom: safeBottom, footerHeight: renderFooterHeight)
                .rounded(.up)
        )
    }

    func setViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) {
        let sizeChanged = abs(currentViewportSize.width - size.width) > 1 || abs(currentViewportSize.height - size.height) > 1
        let safeAreaChanged =
            abs(currentSafeAreaInsets.top - safeAreaInsets.top) > 1
            || abs(currentSafeAreaInsets.bottom - safeAreaInsets.bottom) > 1
        guard sizeChanged || safeAreaChanged else { return }
        currentViewportSize = size
        currentSafeAreaInsets = safeAreaInsets
        bumpLayoutGeneration()
        clearMemoryCache()

        // 先嘗試用 JS 注入 CSS 變數 + 重新分頁（不需重載 HTML，更流暢）
        // 如果目前章節未載入或 webView 不可用，才 fallback 到整章重載
        if currentLoadedChapter >= 0, webView != nil, !scrollModeEnabled {
            injectViewportAndRepaginate()
        } else if publicationSession != nil {
            relayoutAroundCurrentLocation()
        }
    }

    /// 透過 JS 注入新的 viewport/safe-area/padding CSS 變數，觸發 reflow + 重新分頁。
    /// 不需重載 HTML，旋轉/改設定時大幅減少卡頓。
    private func injectViewportAndRepaginate() {
        let marginH = Int(renderMarginH)
        let marginV = Int(renderMarginV)
        let viewportWidth = max(Int(currentViewportSize.width.rounded(.down)), 1)
        let viewportHeight = max(Int(currentViewportSize.height.rounded(.down)), 1)
        let safeTop = Int(currentSafeAreaInsets.top.rounded(.up))
        let safeBottom = Int(currentSafeAreaInsets.bottom.rounded(.up))
        let footerHeight = Int(renderFooterHeight.rounded(.up))
        let topPadding = resolvedTopPadding(safeTop: currentSafeAreaInsets.top)
        let bottomPadding = resolvedBottomPadding(safeBottom: currentSafeAreaInsets.bottom)

        // 記住當前閱讀位置（用 chapter progression 比 pageIndex 更穩定）
        let savedChapter = currentLoadedChapter
        let savedProgression = currentChapterPageCount > 1
            ? Double(currentLocalPage) / Double(max(currentChapterPageCount - 1, 1))
            : 0.0

        // 更新 WebView frame
        webView.frame = CGRect(origin: webView.frame.origin, size: currentViewportSize)

        let js = """
        (function() {
            var result = _updateViewportVars({
                safeTop: \(safeTop),
                safeBottom: \(safeBottom),
                footerHeight: \(footerHeight),
                userPaddingTop: \(marginV),
                userPaddingBottom: \(marginV),
                userPaddingLeft: \(marginH),
                userPaddingRight: \(marginH),
                viewportWidth: \(viewportWidth),
                viewportHeight: \(viewportHeight),
                contentPaddingTop: \(topPadding),
                contentPaddingBottom: \(bottomPadding)
            });
            return JSON.stringify(result);
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageCount = dict["pageCount"] as? Int
            else {
                // JS 注入失敗，fallback 到整章重載
                if self.publicationSession != nil {
                    self.relayoutAroundCurrentLocation()
                }
                return
            }

            let pageOffsets = self.decodePageOffsets(from: dict["pageOffsets"])
            self.onPaginationReady(pageCount: pageCount, pageOffsets: pageOffsets)

            // 用 progression 還原到最接近的頁碼
            if savedChapter == self.currentLoadedChapter {
                let localPage = min(
                    max(Int(round(savedProgression * Double(max(pageCount - 1, 0)))), 0),
                    max(pageCount - 1, 0)
                )
                self.snapToLocalPage(localPage)
                if let gp = self.firstGlobalPage(forChapter: savedChapter, preferredLocalPage: localPage) {
                    self.currentEpubPage = gp
                }
                self.updateCurrentState()
            }

            // 預載鄰居也需要刷新
            self.preloadedChapter.removeAll()
            self.preloadedReady.removeAll()
            self.preloadNeighbors()
        }
    }

    private func relayoutAroundCurrentLocation() {
        guard let session = publicationSession else { return }
        let current = locator(forPage: currentEpubPage)
        Task {
            let fallback = (
                chapterIndex: self.chapterIndex(forGlobalPage: self.currentEpubPage),
                chapterProgression: self.currentChapterPageCount > 1
                    ? Double(self.currentLocalPage) / Double(max(self.currentChapterPageCount - 1, 1))
                    : 0
            )
            let resolved: (chapterIndex: Int, chapterProgression: Double)?
            if let current {
                resolved = await session.resolve(locator: current)
            } else {
                resolved = nil
            }
            let target = resolved ?? fallback
            await self.loadChapter(
                target.chapterIndex,
                localPage: 0,
                restoreProgression: target.chapterProgression
            )
        }
    }

    private func reloadCurrentLocationForLayoutChange() {
        if publicationSession != nil {
            relayoutAroundCurrentLocation()
            return
        }

        guard parsedBook != nil else { return }
        let fallbackChapter = max(currentLoadedChapter, 0)

        if scrollModeEnabled {
            let targetChapter = max(scrollVisibleChapterIndex, fallbackChapter)
            Task {
                await self.loadScrollMode(startChapter: targetChapter)
            }
            return
        }

        let chapterPageCount = max(currentChapterPageCount, 1)
        let progression = chapterPageCount > 1
            ? Double(currentLocalPage) / Double(max(chapterPageCount - 1, 1))
            : 0

        Task {
            await self.loadChapter(
                fallbackChapter,
                localPage: 0,
                restoreProgression: progression
            )
        }
    }

    // MARK: - 頁碼映射

    func chapterIndex(forGlobalPage page: Int) -> Int {
        guard page >= 0, page < globalPageMap.count else { return 0 }
        return globalPageMap[page].chapter
    }

    func localPage(forGlobalPage page: Int) -> Int {
        guard page >= 0, page < globalPageMap.count else { return 0 }
        return globalPageMap[page].page
    }

    func pageCount(forChapter idx: Int) -> Int {
        chapterPageCounts[idx] ?? 1
    }

    func firstGlobalPage(forChapter idx: Int, preferredLocalPage: Int? = nil) -> Int? {
        let localPg = min(preferredLocalPage ?? 0, (chapterPageCounts[idx] ?? 1) - 1)
        return globalPageMap.firstIndex(where: { $0.chapter == idx && $0.page == localPg })
    }

    // MARK: - 進度 Locator

    func locator(forPage page: Int) -> SnapshotLocator? {
        guard page >= 0, page < globalPageMap.count else { return nil }
        let entry = globalPageMap[page]
        let chapPages = chapterPageCounts[entry.chapter] ?? 1
        let prog = totalPages > 1 ? Double(page) / Double(totalPages - 1) : 0
        let href =
            publicationSession?.chapters[entry.chapter].href
            ?? parsedBook?.chapters[entry.chapter].href
            ?? ""
        let title =
            publicationSession?.chapters[entry.chapter].title
            ?? parsedBook?.chapters[entry.chapter].title
        return SnapshotLocator(
            spineHref: href,
            chapterIndex: entry.chapter,
            pageInChapter: entry.page,
            totalPagesInChapter: chapPages,
            globalPage: page,
            progression: prog,
            generationId: renderSessionID,
            layoutGeneration: layoutGeneration,
            title: title,
            chapterProgression: chapPages > 1 ? Double(entry.page) / Double(max(chapPages - 1, 1)) : 0,
            totalProgression: prog
        )
    }

    func currentLocator() -> SnapshotLocator? {
        locator(forPage: currentEpubPage)
    }

    func open(locator: SnapshotLocator) {
        if let session = publicationSession {
            Task {
                if let resolved = await session.resolve(locator: locator),
                   let gp = self.firstGlobalPage(forChapter: resolved.chapterIndex, preferredLocalPage: 0)
                {
                    self.goToPage(gp)
                    await self.loadChapter(resolved.chapterIndex, localPage: 0, restoreProgression: resolved.chapterProgression)
                }
            }
            return
        }
        if let gp = firstGlobalPage(forChapter: locator.chapterIndex, preferredLocalPage: locator.pageInChapter) {
            goToPage(gp)
        }
    }

    // MARK: - 進度儲存/恢復

    func flushProgress() {
        progressStore?.flushSync()
    }

    func syncProgressToPage(_ page: Int, flush: Bool = false) {
        guard let record = locator(forPage: page) else { return }
        progressStore?.save(record: record)
        if flush { progressStore?.flushSync() }
    }

    private func saveProgress() {
        if scrollModeEnabled {
            saveScrollProgress()
        } else {
            syncProgressToPage(currentEpubPage)
        }
    }

    private func saveScrollProgress() {
        let chIdx = scrollVisibleChapterIndex
        let chapterCount =
            publicationSession?.chapters.count
            ?? parsedBook?.chapters.count
            ?? 0
        guard chIdx >= 0, chIdx < chapterCount else { return }

        let href: String
        let title: String?
        if let session = publicationSession, chIdx < session.chapters.count {
            href = session.chapters[chIdx].href
            title = session.chapters[chIdx].title
        } else if let parsed = parsedBook, chIdx < parsed.chapters.count {
            href = parsed.chapters[chIdx].href
            title = parsed.chapters[chIdx].title
        } else { return }

        let totalProg = chapterCount > 1
            ? (Double(chIdx) + scrollChapterProgress) / Double(chapterCount)
            : scrollChapterProgress

        let record = SnapshotLocator(
            spineHref: href,
            chapterIndex: chIdx,
            pageInChapter: 0,
            totalPagesInChapter: 1,
            globalPage: chIdx,
            progression: totalProg,
            generationId: renderSessionID,
            layoutGeneration: layoutGeneration,
            title: title,
            chapterProgression: scrollChapterProgress,
            totalProgression: totalProg
        )
        progressStore?.save(record: record)
    }

    private func updateCurrentState() {
        guard currentEpubPage >= 0, currentEpubPage < globalPageMap.count else { return }
        let entry = globalPageMap[currentEpubPage]
        currentChapterIdx = entry.chapter
        percentage = totalPages > 1 ? Double(currentEpubPage) / Double(totalPages - 1) : 0

        let href =
            publicationSession?.chapters[entry.chapter].href
            ?? parsedBook?.chapters[entry.chapter].href
        if let href {
            onRelocated?(href, percentage)
        }
    }

    private func progressDirectoryURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let digest = Insecure.SHA1.hash(data: Data(currentBookIdentifier.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("epub_progress_v2/\(hash)")
    }

    // MARK: - 相容 API（讓 ReaderView 遷移更平滑）

    func snapshot(forPage page: Int) -> UIImage? {
        snapshotImages[page]
    }

    func pageSnapshotState(forPage page: Int) -> PageRenderState {
        snapshotStates[page] ?? (isReady ? .missing : .loading)
    }

    func snapshotRevision(forPage page: Int) -> Int {
        snapshotRevisions[page] ?? renderSessionID
    }

    func willDisplayPage(_ page: Int, style: PageTurnStyle) {
        transitionTurnState(to: .animatingCommit(target: page, animator: nil), event: .transitionWillDisplay)
        prepareDisplaySnapshot(forPage: page, priority: -1)
        if style == .curl || style == .cover {
            preloadSnapshots(around: page, radius: 1)
        }
    }

    func preloadSnapshots(around page: Int, radius: Int = 2) {
        guard totalPages > 0 else { return }
        let lower = max(0, page - radius)
        let upper = min(totalPages - 1, page + radius)
        for candidate in lower...upper {
            prepareDisplaySnapshot(forPage: candidate, priority: candidate == page ? -1 : 0)
        }
    }

    func settleInteractionPage(_ page: Int, style: PageTurnStyle) {
        prepareDisplaySnapshot(forPage: page, priority: -1)
        transitionTurnState(to: .idle, event: .transitionCommitted)
    }

    func hasDisplayableSnapshot(forPage page: Int) -> Bool {
        snapshotImages[page] != nil
    }

    func prepareDisplaySnapshot(forPage page: Int, priority: Int = 0) {
        guard page >= 0, page < totalPages else { return }
        if snapshotImages[page] != nil || snapshotTasks[page] != nil {
            return
        }

        snapshotStates[page] = .loading
        snapshotVersion += 1
        let revision = renderSessionID

        snapshotTasks[page] = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.captureSnapshot(forGlobalPage: page)
            self.snapshotTasks[page] = nil
            guard revision == self.renderSessionID else { return }
            if let image {
                self.snapshotImages[page] = image
                self.snapshotStates[page] = .full
            } else {
                self.snapshotStates[page] = .failed
            }
            self.snapshotRevisions[page] = revision
            self.snapshotVersion += 1
        }
    }

    func clearMemoryCache() {
        snapshotTasks.values.forEach { $0.cancel() }
        snapshotTasks.removeAll()
        snapshotImages.removeAll()
        snapshotStates.removeAll()
        snapshotRevisions.removeAll()
        snapshotVersion += 1
    }

    func cancelSnapshot(forPage page: Int) {
        snapshotTasks[page]?.cancel()
        snapshotTasks.removeValue(forKey: page)
        if snapshotImages[page] == nil {
            snapshotStates[page] = .missing
        }
        snapshotVersion += 1
    }

    private func invalidateSnapshots(fromGlobalPage startPage: Int) {
        guard startPage > 0 else {
            clearMemoryCache()
            return
        }

        for (page, task) in snapshotTasks where page >= startPage {
            task.cancel()
            snapshotTasks.removeValue(forKey: page)
        }
        snapshotImages = snapshotImages.filter { $0.key < startPage }
        snapshotStates = snapshotStates.filter { $0.key < startPage }
        snapshotRevisions = snapshotRevisions.filter { $0.key < startPage }
        snapshotVersion += 1
    }

    func captureSnapshot(forGlobalPage page: Int) async -> UIImage? {
        guard page >= 0, page < totalPages, page < globalPageMap.count else { return nil }
        let target = globalPageMap[page]

        if target.chapter == currentLoadedChapter {
            return await snapshotImage(of: webView, localPage: target.page)
        }

        if let pooled = pooledWebView(forChapter: target.chapter) {
            return await snapshotImage(of: pooled, localPage: target.page)
        }

        return nil
    }

    /// 提供按需截圖（僅 curl 模式使用）
    func takePageSnapshot(localPage: Int) async -> UIImage? {
        await snapshotImage(of: webView, localPage: localPage)
    }

    private func pooledWebView(forChapter chapter: Int) -> WKWebView? {
        if preloadedChapter[.next] == chapter, preloadedReady[.next] == true {
            return webViewPool[.next]
        }
        if preloadedChapter[.prev] == chapter, preloadedReady[.prev] == true {
            return webViewPool[.prev]
        }
        return nil
    }

    private func snapshotImage(of sourceWebView: WKWebView, localPage: Int) async -> UIImage? {
        let pageCount = resolvedPageCount(for: sourceWebView)
        let targetOffset = resolvedPageOffset(for: localPage, in: sourceWebView, pageCount: pageCount)
        let originalOffset = sourceWebView.scrollView.contentOffset
        let wasCurrentWebView = sourceWebView === webView
        let currentPageAtStart = currentEpubPage
        let currentChapterAtStart = currentLoadedChapter
        let originalRole = webViewPool.first(where: { $0.value === sourceWebView })?.key
        let originalPreloadedChapter = originalRole.flatMap { preloadedChapter[$0] }

        sourceWebView.scrollView.setContentOffset(CGPoint(x: targetOffset, y: 0), animated: false)
        let jsTarget = Double(targetOffset)
        sourceWebView.evaluateJavaScript(
            "if(typeof _scrollTo==='function'){_scrollTo(\(jsTarget));}else{window.scrollTo(\(jsTarget),0);}"
        ) { _, _ in }

        try? await Task.sleep(nanoseconds: 35_000_000)

        let rect = CGRect(
            x: 0,
            y: 0,
            width: max(pageRenderWidth(for: sourceWebView), 1),
            height: max(pageRenderHeight(for: sourceWebView), 1)
        )

        let image: UIImage? = await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = rect
            config.snapshotWidth = NSNumber(value: Double(rect.width))
            sourceWebView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }

        let canRestore: Bool
        if wasCurrentWebView {
            canRestore = sourceWebView === webView
                && currentLoadedChapter == currentChapterAtStart
                && currentEpubPage == currentPageAtStart
        } else if let originalRole {
            canRestore = webViewPool[originalRole] === sourceWebView
                && preloadedChapter[originalRole] == originalPreloadedChapter
        } else {
            canRestore = false
        }

        if canRestore {
            sourceWebView.scrollView.setContentOffset(originalOffset, animated: false)
            let restoreTarget = Double(originalOffset.x)
            sourceWebView.evaluateJavaScript(
                "if(typeof _scrollTo==='function'){_scrollTo(\(restoreTarget));}else{window.scrollTo(\(restoreTarget),0);}"
            ) { _, _ in }
        }
        return image
    }

    private func pageRenderWidth(for webView: WKWebView) -> CGFloat {
        max(currentViewportSize.width, webView.bounds.width, 1)
    }

    private func pageRenderHeight(for webView: WKWebView) -> CGFloat {
        max(currentViewportSize.height, webView.bounds.height, 1)
    }

    private func requestPaginationMetrics(
        in targetWebView: WKWebView
    ) async -> (pageCount: Int, pageOffsets: [CGFloat]?)? {
        let script = """
        (function() {
            if (typeof getPaginationMetrics === 'function') {
                return JSON.stringify(getPaginationMetrics());
            }
            if (typeof initLiveReader === 'function') {
                return JSON.stringify({ pageCount: initLiveReader() });
            }
            return JSON.stringify({ pageCount: 1 });
        })();
        """

        let result: String? = await withCheckedContinuation { continuation in
            targetWebView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }

        guard let result, let data = result.data(using: .utf8) else {
            return nil
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let pageCount = max(1, (object["pageCount"] as? Int) ?? 1)
        return (
            pageCount: pageCount,
            pageOffsets: decodePageOffsets(from: object["pageOffsets"])
        )
    }

    fileprivate func decodePageOffsets(from rawValue: Any?) -> [CGFloat]? {
        guard let rawArray = rawValue as? [Any], !rawArray.isEmpty else { return nil }
        let offsets = rawArray.compactMap { value -> CGFloat? in
            if let number = value as? NSNumber {
                return CGFloat(truncating: number)
            }
            if let double = value as? Double {
                return CGFloat(double)
            }
            if let int = value as? Int {
                return CGFloat(int)
            }
            return nil
        }
        return offsets.isEmpty ? nil : offsets
    }

    // MARK: - HTML 建構

    private func buildChapterHTML(chapter: EPUBChapterRaw, bridgeName: String) -> String {
        let bookCSS = chapter.cssEntries.map { entry in
            rewriteCSSURLs(entry.content, cssBaseDir: entry.baseDir)
        }.joined(separator: "\n")
        return buildChapterHTML(
            chapterHTML: chapter.html,
            chapterBaseURL: chapter.baseURL,
            bridgeName: bridgeName,
            inlineBookCSS: bookCSS,
            useReadiumCSS: pipelineKind == .epub
        )
    }

    private func buildChapterHTML(
        chapterHTML: String,
        chapterBaseURL: URL,
        bridgeName: String,
        inlineBookCSS: String = "",
        useReadiumCSS: Bool = false
    ) -> String {
        let size = currentViewportSize == .zero ? UIScreen.main.bounds.size : currentViewportSize
        let marginH = Int(renderMarginH)
        let marginV = Int(renderMarginV)
        let (bgColor, textColor) = themeColors(renderTheme)
        let adapterCSS = useReadiumCSS ? "" : ReaderAdapterAssets.css()
        let adapterJS = useReadiumCSS ? "" : ReaderAdapterAssets.javaScript()
        let adapterCSSBlock = adapterCSS.isEmpty ? "" : "<style>\(adapterCSS)</style>"
        let adapterJSBlock = adapterJS.isEmpty ? "" : "<script>\(adapterJS)</script>"

        let bodyContent = extractBodyContent(chapterHTML)
        let headContent = extractHeadContent(chapterHTML)
        let bodyAttributes = useReadiumCSS ? extractBodyAttributes(chapterHTML) : ""
        let bodyTagAttributes = bodyAttributes.isEmpty ? "" : " \(bodyAttributes)"
        let wrappedBodyContent: String
        if useReadiumCSS {
            wrappedBodyContent = bodyContent
        } else if bodyContent.contains("id=\"reader-content\"") {
            wrappedBodyContent = bodyContent
        } else {
            wrappedBodyContent = "<div id=\"reader-content\">\(bodyContent)</div>"
        }

        let layoutConfigJS = layoutConfigJSLiteral(marginH: marginH, marginV: marginV)
        let layoutBootstrapJS = useReadiumCSS ? "" : "applyReaderLayoutConfig(\(layoutConfigJS));"

        let viewportWidth = max(Int(size.width.rounded(.down)), 1)
        let safeTop = Int(currentSafeAreaInsets.top.rounded(.up))
        let safeBottom = Int(currentSafeAreaInsets.bottom.rounded(.up))
        let footerHeight = Int(renderFooterHeight.rounded(.up))
        let topPadding = resolvedTopPadding(safeTop: currentSafeAreaInsets.top)
        let bottomPadding = resolvedBottomPadding(safeBottom: currentSafeAreaInsets.bottom)

        // Readium CSS 注入（EPUB 專用，提供頂級排版品質）
        // 三明治順序：before → 出版 CSS → default → adapter/inline → after
        let readiumBeforeCSS: String
        let readiumDefaultCSS: String
        let readiumAfterCSS: String
        let htmlAttrs: String
        if useReadiumCSS {
            let fontSizePct = "\(Int(renderFontSize / 16.0 * 100))%"
            let readiumTheme: String
            switch renderTheme {
            case "night": readiumTheme = "readium-night-on"
            case "sepia": readiumTheme = "readium-sepia-on"
            default: readiumTheme = "readium-default-on"
            }
            let bundle = ReadiumCSSLoader.bundle(
                configuration: ReadiumCSSConfiguration(
                    fontSize: fontSizePct,
                    lineHeight: "1.6",
                    theme: readiumTheme,
                    colWidth: viewportWidth,
                    pageGutter: marginH,
                    scroll: scrollModeEnabled
                )
            )
            readiumBeforeCSS = bundle.beforeStyleTag
            readiumDefaultCSS = bundle.defaultStyleTag
            readiumAfterCSS = bundle.afterStyleTag
            htmlAttrs = bundle.htmlAttributes
        } else {
            readiumBeforeCSS = ""
            readiumDefaultCSS = ""
            readiumAfterCSS = ""
            htmlAttrs = ""
        }

        // EPUB 只保留 Readium CSS，避免和自訂排版規則互相覆蓋。
        // 非 EPUB 仍使用原本的 inline CSS 控制排版。
        let inlineLayoutCSS: String
        if useReadiumCSS {
            inlineLayoutCSS = """
            :root {
                --rv-safe-top: \(safeTop)px;
                --rv-safe-bottom: \(safeBottom)px;
                --rv-header-height: 0px;
                --rv-footer-height: \(footerHeight)px;
                --rv-user-padding-top: \(marginV)px;
                --rv-user-padding-bottom: \(marginV)px;
                --rv-user-padding-left: \(marginH)px;
                --rv-user-padding-right: \(marginH)px;
                --rv-viewport-width: \(viewportWidth)px;
                --rv-viewport-height: \(Int(size.height))px;
                --rv-content-padding-top: \(topPadding)px;
                --rv-content-padding-bottom: \(bottomPadding)px;
            }
            html {
                height: 100%;
                margin: 0;
                padding: 0;
                overflow: hidden;
                background: \(bgColor);
                color: \(textColor);
            }
            body {
                height: 100vh;
                margin: 0;
                overflow: visible;
                padding-top: var(--rv-content-padding-top) !important;
                padding-bottom: var(--rv-content-padding-bottom) !important;
                box-sizing: border-box;
            }
            img, video, audio, object, svg {
                max-width: 100% !important;
                height: auto;
                display: block;
                break-inside: avoid;
                margin-left: auto;
                margin-right: auto;
            }
            @page { margin: 0 !important; }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important;
                min-height: 0 !important;
                max-height: none !important;
            }
            """
        } else {
            // 非 EPUB（TXT 等）：完整 inline CSS 控制所有排版
            inlineLayoutCSS = """
            :root {
                --rv-safe-top: \(safeTop)px;
                --rv-safe-bottom: \(safeBottom)px;
                --rv-header-height: 0px;
                --rv-footer-height: \(footerHeight)px;
                --rv-user-padding-top: \(marginV)px;
                --rv-user-padding-bottom: \(marginV)px;
                --rv-user-padding-left: \(marginH)px;
                --rv-user-padding-right: \(marginH)px;
                --rv-viewport-width: \(viewportWidth)px;
                --rv-viewport-height: \(Int(size.height))px;
                --rv-content-padding-top: \(topPadding)px;
                --rv-content-padding-bottom: \(bottomPadding)px;
            }
            html {
                height: 100%; margin: 0; padding: 0; overflow: hidden;
                background: \(bgColor);
            }
            body {
                height: 100%;
                margin: 0 !important;
                overflow: visible !important;
                background: \(bgColor);
                -webkit-column-width: \(viewportWidth)px !important;
                column-width: \(viewportWidth)px !important;
                -webkit-column-gap: 0 !important;
                column-gap: 0 !important;
                column-fill: auto !important;
                -webkit-column-fill: auto !important;
                padding-top: var(--rv-content-padding-top) !important;
                padding-bottom: var(--rv-content-padding-bottom) !important;
                padding-left: 0 !important;
                padding-right: 0 !important;
                box-sizing: border-box !important;
                color: \(textColor);
                font-size: \(Int(renderFontSize))px;
                line-height: 1.6;
                text-align: justify;
                text-justify: inter-ideograph;
                -webkit-text-size-adjust: none;
                word-break: break-word;
                overflow-wrap: break-word;
                hyphens: none;
                line-break: strict;
                text-rendering: optimizeLegibility;
            }
            img {
                max-width: 100% !important; height: auto; display: block;
                break-inside: avoid; page-break-inside: avoid; -webkit-column-break-inside: avoid;
            }
            svg { max-width: 100% !important; }
            @page { margin: 0 !important; }
            p, p[class], blockquote, blockquote[class], pre, pre[class],
            li, li[class], dd, dd[class], dt, dt[class], figcaption, figcaption[class] {
                line-height: 1.6 !important;
                margin-block-start: 0 !important; margin-block-end: 0.5em !important;
                padding-block-start: 0 !important; padding-block-end: 0 !important;
                height: auto !important; min-height: 0 !important; max-height: none !important;
                break-inside: auto !important; page-break-inside: auto !important;
                -webkit-column-break-inside: auto !important;
                widows: 1 !important; orphans: 1 !important;
                word-break: normal !important; overflow-wrap: anywhere !important;
                white-space: normal !important;
            }
            p, p[class] {
                text-indent: 2em !important;
                text-align: justify !important;
                text-justify: inter-ideograph !important;
            }
            p.lk, p.dibian, p[class~="lk"], p[class~="dibian"],
            p.normaltext2, p[class~="normaltext2"] {
                text-indent: 0 !important; text-align: right !important;
            }
            p.yingwen, p[class~="yingwen"] {
                text-indent: 0 !important; text-align: center !important;
            }
            div, div[class], section, section[class], article, article[class], figure, figure[class] {
                margin-block-start: 0 !important; margin-block-end: 0 !important;
                padding-block-start: 0 !important; padding-block-end: 0 !important;
                height: auto !important; min-height: 0 !important; max-height: none !important;
            }
            h1, h1[class], h2, h2[class], h3, h3[class],
            h4, h4[class], h5, h5[class], h6, h6[class] {
                break-after: avoid !important; break-inside: auto !important;
                page-break-inside: auto !important; -webkit-column-break-inside: auto !important;
                margin-block-start: 0.8em !important; margin-block-end: 0.4em !important;
                line-height: 1.4 !important; text-indent: 0 !important;
            }
            h1.title, h2.title, h3.title, h1.title1, h2.title1, h3.title1,
            h1.title2, h2.title2, h3.title2, h1.title3, h2.title3, h3.title3,
            h1.bqbt, h2.bqbt, h3.bqbt, .title, .title1, .title2, .title3, .bqbt {
                margin-block-start: 0 !important; margin-block-end: 0.6em !important;
            }
            body > *:first-child, #reader-content > *:first-child { margin-block-start: 0 !important; }
            body > *:last-child, #reader-content > *:last-child { margin-block-end: 0 !important; }
            body, html { max-width: none !important; max-height: none !important; position: static !important; }
            body > div, body > section, body > article,
            #reader-content > div, #reader-content > section {
                height: auto !important; min-height: 0 !important; max-height: none !important;
                width: auto !important; max-width: 100% !important;
                margin: 0 !important; position: static !important; float: none !important;
            }
            #reader-content {
                padding-left: \(marginH)px !important; padding-right: \(marginH)px !important;
                padding-top: 0 !important; padding-bottom: 0 !important;
                box-sizing: border-box !important;
            }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important; min-height: 0 !important; max-height: none !important;
                margin: 0 !important; padding: 0 !important; position: static !important;
            }
            """
        }

        return """
        <!DOCTYPE html>
        <html \(htmlAttrs)>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=\(viewportWidth), initial-scale=1.0, maximum-scale=1.0, user-scalable=no, shrink-to-fit=no, viewport-fit=cover">
        <base href="\(chapterBaseURL.absoluteString)">
        \(readiumBeforeCSS)
        \(headContent)
        \(inlineBookCSS.isEmpty ? "" : "<style>\(inlineBookCSS)</style>")
        \(readiumDefaultCSS)
        \(adapterCSSBlock)
        <style>\(inlineLayoutCSS)</style>
        \(readiumAfterCSS)
        \(adapterJSBlock)
        </head>
        <body\(bodyTagAttributes)>
        \(wrappedBodyContent)
        <script>
        \(layoutBootstrapJS)

        // 動態更新 viewport / safe area / padding CSS 變數（native 在旋轉或改設定時呼叫）
        // 回傳新的 { pageCount, pageOffsets } 供 native 更新 mapping
        function _updateViewportVars(vars) {
            var root = document.documentElement;
            if (vars.safeTop !== undefined) root.style.setProperty('--rv-safe-top', vars.safeTop + 'px');
            if (vars.safeBottom !== undefined) root.style.setProperty('--rv-safe-bottom', vars.safeBottom + 'px');
            if (vars.headerHeight !== undefined) root.style.setProperty('--rv-header-height', vars.headerHeight + 'px');
            if (vars.footerHeight !== undefined) root.style.setProperty('--rv-footer-height', vars.footerHeight + 'px');
            if (vars.userPaddingTop !== undefined) root.style.setProperty('--rv-user-padding-top', vars.userPaddingTop + 'px');
            if (vars.userPaddingBottom !== undefined) root.style.setProperty('--rv-user-padding-bottom', vars.userPaddingBottom + 'px');
            if (vars.userPaddingLeft !== undefined) root.style.setProperty('--rv-user-padding-left', vars.userPaddingLeft + 'px');
            if (vars.userPaddingRight !== undefined) root.style.setProperty('--rv-user-padding-right', vars.userPaddingRight + 'px');
            if (vars.viewportWidth !== undefined) root.style.setProperty('--rv-viewport-width', vars.viewportWidth + 'px');
            if (vars.viewportHeight !== undefined) root.style.setProperty('--rv-viewport-height', vars.viewportHeight + 'px');
            if (vars.contentPaddingTop !== undefined) root.style.setProperty('--rv-content-padding-top', vars.contentPaddingTop + 'px');
            if (vars.contentPaddingBottom !== undefined) root.style.setProperty('--rv-content-padding-bottom', vars.contentPaddingBottom + 'px');
            // 更新 column-width（影響分頁計算）
            if (vars.viewportWidth !== undefined) {
                _pageSpan = Math.max(vars.viewportWidth, 1);
                if (document.body) {
                    document.body.style.setProperty('-webkit-column-width', _pageSpan + 'px', 'important');
                    document.body.style.setProperty('column-width', _pageSpan + 'px', 'important');
                }
            }
            // 重新計算分頁
            return getPaginationMetrics();
        }

        // 跟手翻頁全域狀態
        var _currentLocalPage = 0;
        var _pageSpan = \(viewportWidth);
        var _totalPages = 1;
        var _pageOffsets = [0];
        var _isDragging = false;
        var _dragBaseScroll = 0;

        function _pageOffsetAt(n) {
            if (!_pageOffsets.length) return 0;
            if (n <= 0) return _pageOffsets[0] || 0;
            if (n >= _pageOffsets.length) return _pageOffsets[_pageOffsets.length - 1] || 0;
            return _pageOffsets[n] || 0;
        }

        function _markPagesForNodes(nodes, pageMap) {
            var currentScroll = window.scrollX || document.documentElement.scrollLeft || document.body.scrollLeft || 0;
            Array.from(nodes || []).forEach(function(el) {
                if (!el || !el.tagName) return;
                var tag = el.tagName.toLowerCase();
                if (['script', 'style', 'link', 'meta', 'br'].indexOf(tag) !== -1) return;
                var style = window.getComputedStyle(el);
                if (!style || style.display === 'none' || style.visibility === 'hidden') return;

                var rect = el.getBoundingClientRect();
                if (!rect || rect.height < 2 || rect.width < 2) return;

                var text = (el.innerText || el.textContent || '').replace(/\\s+/g, '');
                var isContentTag =
                    /^h[1-6]$/.test(tag)
                    || ['p', 'li', 'dt', 'dd', 'blockquote', 'pre', 'figcaption', 'address', 'img', 'svg', 'video', 'audio', 'object', 'canvas', 'figure', 'table', 'hr'].indexOf(tag) !== -1;
                if (!isContentTag && text.length === 0) return;

                var left = rect.left + currentScroll;
                var right = rect.right + currentScroll;
                var firstPage = Math.max(0, Math.floor(left / _pageSpan));
                var lastPage = Math.max(firstPage, Math.floor((Math.max(right - 1, left)) / _pageSpan));
                for (var page = firstPage; page <= lastPage; page += 1) {
                    pageMap[page] = true;
                }
            });
        }

        function _collectPageOffsets() {
            var pages = Object.create(null);
            _markPagesForNodes(
                document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,dt,dd,blockquote,pre,figcaption,address,img,svg,video,audio,object,canvas,figure,table,hr'),
                pages
            );

            if (Object.keys(pages).length === 0 && document.body) {
                _markPagesForNodes(document.body.children, pages);
            }

            var pageIndexes = Object.keys(pages)
                .map(function(value) { return parseInt(value, 10); })
                .filter(function(value) { return !isNaN(value) && value >= 0; })
                .sort(function(a, b) { return a - b; });

            if (pageIndexes.length === 0) {
                var sw = Math.max(document.body.scrollWidth, document.documentElement.scrollWidth, _pageSpan);
                var fallbackCount = Math.max(1, Math.ceil(sw / _pageSpan));
                for (var i = 0; i < fallbackCount; i += 1) {
                    pageIndexes.push(i);
                }
            }

            return pageIndexes.map(function(index) { return index * _pageSpan; });
        }

        function getPaginationMetrics() {
            \(useReadiumCSS ? "" : "updateColumnWidth(\(Int(renderFooterHeight)));")
            _pageSpan = Math.max(window.innerWidth, 1);
            _pageOffsets = _collectPageOffsets();
            _totalPages = Math.max(1, _pageOffsets.length);
            if (_currentLocalPage >= _totalPages) {
                _currentLocalPage = _totalPages - 1;
            }
            return { pageCount: _totalPages, pageOffsets: _pageOffsets };
        }

        function initLiveReader() {
            return getPaginationMetrics().pageCount;
        }

        function _scrollTo(x) {
            document.documentElement.scrollLeft = x;
            document.body.scrollLeft = x;
            window.scrollTo(x, 0);
        }

        function setPageOffset(dx) {
            if (!_isDragging) {
                _isDragging = true;
                _dragBaseScroll = _pageOffsetAt(_currentLocalPage);
            }
            var raw = _dragBaseScroll - dx;
            var maxScroll = _pageOffsetAt(_totalPages - 1);
            var clamped = Math.max(0, Math.min(raw, maxScroll));
            _scrollTo(clamped);

            // 超出邊界的部分用 translateX 跟手（跨章預覽）
            var overflow = clamped - raw;
            if (Math.abs(overflow) > 1) {
                document.body.style.transition = 'none';
                document.body.style.transform = 'translateX(' + overflow + 'px)';
            } else {
                document.body.style.transform = 'none';
            }
        }

        function animateToPage(n, ms) {
            _isDragging = false;
            // 重置跨章拖動的 translateX
            if (ms > 0) {
                document.body.style.transition = 'transform ' + ms + 'ms ease-out';
            } else {
                document.body.style.transition = 'none';
            }
            document.body.style.transform = 'none';

            if (n >= 0 && n < _totalPages) _currentLocalPage = n;
            var target = _pageOffsetAt(n);
            if (ms > 0) {
                var start = document.documentElement.scrollLeft || document.body.scrollLeft || 0;
                var distance = target - start;
                if (Math.abs(distance) < 1) { _scrollTo(target); return; }
                var startTime = performance.now();
                function step(now) {
                    var elapsed = now - startTime;
                    var progress = Math.min(elapsed / ms, 1);
                    var eased = 1 - Math.pow(1 - progress, 3);
                    _scrollTo(start + distance * eased);
                    if (progress < 1) requestAnimationFrame(step);
                }
                requestAnimationFrame(step);
            } else {
                _scrollTo(target);
            }
        }

        function snapToPage(n) { animateToPage(n, 0); }

        function recalcPages() {
            return getPaginationMetrics().pageCount;
        }

        document.addEventListener('click', function(e) {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.\(bridgeName)) {
                return;
            }
            if (_isDragging) {
                return;
            }
            var interactive = e.target && e.target.closest
                ? e.target.closest('a, button, input, textarea, select, summary, label')
                : null;
            if (interactive) {
                return;
            }

            var x = e.clientX || 0;
            var w = Math.max(window.innerWidth, 1);

            var zone = 'center';
            if (x < w / 3) {
                zone = 'left';
            } else if (x > w * 2 / 3) {
                zone = 'right';
            }

            window.webkit.messageHandlers.\(bridgeName).postMessage({
                type: 'tap',
                payload: { zone: zone }
            });
        }, true);

        // 初始化：等 fonts + images 載入後計算分頁
        (function() {
            var done = false;
            var timer = setTimeout(function() {
                if (!done) { done = true; calculate(); }
            }, 3000);

            function calculate() {
                var metrics = getPaginationMetrics();
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: 'paginationReady',
                    payload: {
                        pageCount: metrics.pageCount,
                        pageOffsets: metrics.pageOffsets
                    }
                });
            }

            function finishReady() {
                if (done) return;
                done = true;
                clearTimeout(timer);
                setTimeout(calculate, 80);
            }

            function waitForWindowLoad() {
                return new Promise(function(resolve) {
                    if (document.readyState === 'complete') {
                        resolve();
                        return;
                    }
                    window.addEventListener('load', function() { setTimeout(resolve, 40); }, { once: true });
                });
            }

            function waitForFonts() {
                if (document.fonts && document.fonts.ready) {
                    return document.fonts.ready.catch(function() {});
                }
                return Promise.resolve();
            }

            function waitForImages() {
                var imgs = Array.from(document.images);
                if (imgs.length === 0) {
                    return Promise.resolve();
                }
                return new Promise(function(resolve) {
                    var loaded = 0;
                    function markDone() {
                        loaded += 1;
                        if (loaded >= imgs.length) {
                            resolve();
                        }
                    }
                    imgs.forEach(function(img) {
                        if (img.complete) {
                            markDone();
                        } else {
                            img.addEventListener('load', markDone, { once: true });
                            img.addEventListener('error', markDone, { once: true });
                        }
                    });
                });
            }

            Promise.allSettled([waitForWindowLoad(), waitForFonts(), waitForImages()]).then(finishReady);
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Scroll Mode HTML（上下滑動專用，無 CSS Column）

    /// 為上下滑動模式建構 HTML：自然垂直流、章節容器、JS 注入 API
    private func buildScrollModeHTML(
        startChapterIndex: Int,
        chapterBodyHTML: String,
        chapterTitle: String,
        chapterBaseURL: URL,
        chapterHeadHTML: String = "",
        bodyAttributes: String = "",
        bridgeName: String,
        inlineBookCSS: String = "",
        useReadiumCSS: Bool = false
    ) -> String {
        let size = currentViewportSize == .zero ? UIScreen.main.bounds.size : currentViewportSize
        let marginH = Int(renderMarginH)
        let marginV = Int(renderMarginV)
        let (bgColor, textColor) = themeColors(renderTheme)
        let adapterCSS = useReadiumCSS ? "" : ReaderAdapterAssets.css()
        let adapterCSSBlock = adapterCSS.isEmpty ? "" : "<style>\(adapterCSS)</style>"

        let viewportWidth = max(Int(size.width.rounded(.down)), 1)
        let topPadding = resolvedTopPadding(safeTop: currentSafeAreaInsets.top)
        let bottomPadding = resolvedBottomPadding(safeBottom: currentSafeAreaInsets.bottom)

        // Readium CSS 三明治注入（EPUB 專用）
        let readiumBeforeCSS: String
        let readiumDefaultCSS: String
        let readiumAfterCSS: String
        let htmlAttrs: String
        if useReadiumCSS {
            let fontSizePct = "\(Int(renderFontSize / 16.0 * 100))%"
            let readiumTheme: String
            switch renderTheme {
            case "night": readiumTheme = "readium-night-on"
            case "sepia": readiumTheme = "readium-sepia-on"
            default: readiumTheme = "readium-default-on"
            }
            let bundle = ReadiumCSSLoader.bundle(
                configuration: ReadiumCSSConfiguration(
                    fontSize: fontSizePct,
                    lineHeight: "1.6",
                    theme: readiumTheme,
                    colWidth: viewportWidth,
                    pageGutter: marginH,
                    scroll: true
                )
            )
            readiumBeforeCSS = bundle.beforeStyleTag
            readiumDefaultCSS = bundle.defaultStyleTag
            readiumAfterCSS = bundle.afterStyleTag
            htmlAttrs = bundle.htmlAttributes
        } else {
            readiumBeforeCSS = ""
            readiumDefaultCSS = ""
            readiumAfterCSS = ""
            htmlAttrs = ""
        }

        let bodyContent: String
        if useReadiumCSS {
            bodyContent = chapterBodyHTML
        } else if chapterBodyHTML.contains("id=\"reader-content\"") {
            bodyContent = chapterBodyHTML
        } else {
            bodyContent = "<div id=\"reader-content\">\(chapterBodyHTML)</div>"
        }
        let bodyTagAttributes = bodyAttributes.isEmpty ? "" : " \(bodyAttributes)"

        // 滾動模式：EPUB 不再疊加自訂排版，只保留最小容器與安全邊界。
        let scrollInlineCSS: String
        if useReadiumCSS {
            scrollInlineCSS = """
            html {
                height: auto;
                margin: 0;
                padding: 0;
                overflow-x: hidden;
                overflow-y: auto;
                background: \(bgColor);
                color: \(textColor);
            }
            body {
                min-height: 100vh;
                margin: 0;
                padding-top: \(topPadding)px;
                padding-bottom: \(bottomPadding)px;
                box-sizing: border-box;
            }
            img, video, audio, object, svg {
                max-width: 100% !important;
                height: auto;
                display: block;
                break-inside: avoid;
                margin-left: auto;
                margin-right: auto;
            }
            @page { margin: 0 !important; }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important;
                min-height: 0 !important;
                max-height: none !important;
            }
            #scroll-content { min-height: 100vh; }
            .chapter-container { box-sizing: border-box; }
            """
        } else {
            scrollInlineCSS = """
            html {
                height: auto !important; margin: 0; padding: 0;
                overflow-x: hidden !important; overflow-y: auto !important;
                background: \(bgColor);
            }
            body {
                height: auto !important; margin: 0 !important; overflow: visible !important;
                background: \(bgColor);
                column-width: auto !important; -webkit-column-width: auto !important;
                column-count: auto !important; -webkit-column-count: auto !important;
                padding-top: \(topPadding)px !important;
                padding-bottom: \(bottomPadding)px !important;
                padding-left: 0 !important; padding-right: 0 !important;
                box-sizing: border-box !important;
                color: \(textColor);
                font-size: \(Int(renderFontSize))px;
                line-height: 1.6; text-align: justify; text-justify: inter-ideograph;
                -webkit-text-size-adjust: none;
                word-break: break-word; overflow-wrap: break-word;
                hyphens: none; line-break: strict; text-rendering: optimizeLegibility;
            }
            #scroll-content { min-height: 100vh; }
            .chapter-container { padding-left: \(marginH)px; padding-right: \(marginH)px; box-sizing: border-box; }
            .chapter-title-bar {
                font-size: \(Int(renderFontSize) + 2)px; font-weight: bold;
                color: \(textColor); opacity: 0.5; padding: 1.5em 0 0.8em 0;
                text-align: center; text-indent: 0 !important;
            }
            .chapter-separator {
                border: none;
                border-top: 1px solid \(renderTheme == "night" ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.1)");
                margin: 0 \(marginH)px;
            }
            img { max-width: 100% !important; height: auto; display: block; }
            svg { max-width: 100% !important; }
            p, p[class] {
                line-height: 1.6 !important; margin-block-start: 0 !important;
                margin-block-end: 0.5em !important;
                text-indent: 2em !important; text-align: justify !important;
            }
            h1, h2, h3, h4, h5, h6 {
                margin-block-start: 0.8em !important; margin-block-end: 0.4em !important;
                line-height: 1.4 !important; text-indent: 0 !important;
            }
            body > *:first-child, #reader-content > *:first-child,
            .chapter-body > *:first-child { margin-block-start: 0 !important; }
            body > *:last-child, #reader-content > *:last-child,
            .chapter-body > *:last-child { margin-block-end: 0 !important; }
            body, html { max-width: none !important; max-height: none !important; position: static !important; }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important; min-height: 0 !important; max-height: none !important;
                margin: 0 !important; padding: 0 !important; position: static !important;
            }
            """
        }

        return """
        <!DOCTYPE html>
        <html \(htmlAttrs)>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=\(viewportWidth), initial-scale=1.0, maximum-scale=1.0, user-scalable=no, shrink-to-fit=no, viewport-fit=cover">
        <base href="\(chapterBaseURL.absoluteString)">
        \(readiumBeforeCSS)
        \(chapterHeadHTML)
        \(inlineBookCSS.isEmpty ? "" : "<style>\(inlineBookCSS)</style>")
        \(readiumDefaultCSS)
        \(adapterCSSBlock)
        <style>\(scrollInlineCSS)</style>
        \(readiumAfterCSS)
        </head>
        <body\(bodyTagAttributes)>
        <div id="scroll-content">
            <div class="chapter-container" data-chapter="\(startChapterIndex)" id="ch-\(startChapterIndex)">
                <div class="chapter-body">\(bodyContent)</div>
            </div>
        </div>
        <script>
        // ===== 上下滑動模式 JS Bridge =====
        var _scrollChapters = [\(startChapterIndex)];
        var _bridgeName = '\(bridgeName)';
        var _showChapterChrome = \(useReadiumCSS ? "false" : "true");

        function _postMessage(msg) {
            try { window.webkit.messageHandlers[_bridgeName].postMessage(msg); } catch(e) {}
        }

        // 注入章節到 DOM
        function _injectChapter(index, base64html, title, position) {
            if (document.getElementById('ch-' + index)) return -1; // 已存在

            var div = document.createElement('div');
            div.className = 'chapter-container';
            div.dataset.chapter = String(index);
            div.id = 'ch-' + index;

            var bodyDiv = document.createElement('div');
            bodyDiv.className = 'chapter-body';
            bodyDiv.innerHTML = decodeURIComponent(escape(window.atob(base64html)));

            if (_showChapterChrome) {
                var titleBar = document.createElement('div');
                titleBar.className = 'chapter-title-bar';
                titleBar.textContent = title;
                div.appendChild(titleBar);
            }
            div.appendChild(bodyDiv);

            var content = document.getElementById('scroll-content');
            var sep = null;
            if (_showChapterChrome) {
                sep = document.createElement('hr');
                sep.className = 'chapter-separator';
            }

            if (position === 'before') {
                var oldHeight = document.documentElement.scrollHeight;
                var oldScroll = window.scrollY || window.pageYOffset;
                content.insertBefore(div, content.firstChild);
                if (sep) content.insertBefore(sep, div.nextSibling);
                // 補償滾動位置，讓畫面不跳
                var newHeight = document.documentElement.scrollHeight;
                window.scrollTo(0, oldScroll + (newHeight - oldHeight));
            } else {
                if (sep) content.appendChild(sep);
                content.appendChild(div);
            }

            _scrollChapters.push(index);
            _scrollChapters.sort(function(a, b) { return a - b; });
            return document.documentElement.scrollHeight;
        }

        // 移除遠端章節（虛擬 DOM）
        function _removeChapter(index) {
            var el = document.getElementById('ch-' + index);
            if (!el) return;
            var isAbove = (el.offsetTop + el.offsetHeight) < (window.scrollY || 0);
            var removedHeight = el.offsetHeight;

            // 移除分隔線
            if (_showChapterChrome) {
                var prev = el.previousElementSibling;
                var next = el.nextElementSibling;
                if (next && next.className === 'chapter-separator') next.remove();
                else if (prev && prev.className === 'chapter-separator') prev.remove();
            }
            el.remove();

            // 如果移除的是上方章節，補償滾動位置
            if (isAbove) {
                window.scrollTo(0, Math.max(0, (window.scrollY || 0) - removedHeight));
            }

            _scrollChapters = _scrollChapters.filter(function(c) { return c !== index; });
        }

        // 回傳當前可見章節及進度
        function _getVisibleChapter() {
            var chapters = document.querySelectorAll('.chapter-container');
            var anchor = (window.scrollY || 0) + window.innerHeight * 0.3;
            var best = null;
            for (var i = 0; i < chapters.length; i++) {
                var ch = chapters[i];
                var top = ch.offsetTop;
                var bottom = top + ch.offsetHeight;
                if (anchor >= top && anchor <= bottom) {
                    var progress = Math.min(1, Math.max(0, (anchor - top) / Math.max(ch.offsetHeight, 1)));
                    best = { chapter: parseInt(ch.dataset.chapter), progress: progress };
                    break;
                }
            }
            if (!best && chapters.length > 0) {
                var last = chapters[chapters.length - 1];
                best = { chapter: parseInt(last.dataset.chapter), progress: 1.0 };
            }
            return best || { chapter: \(startChapterIndex), progress: 0 };
        }

        // 跳到指定章節
        function _scrollToChapter(index, progressInChapter) {
            var el = document.getElementById('ch-' + index);
            if (!el) return;
            var targetY = el.offsetTop;
            if (progressInChapter > 0) {
                targetY += el.offsetHeight * Math.min(1, progressInChapter);
            }
            window.scrollTo(0, targetY);
        }

        // 點擊區域偵測（上下滑動也需要點中間呼出工具列）
        document.addEventListener('click', function(e) {
            var interactive = e.target && e.target.closest
                ? e.target.closest('a, button, input, textarea, select, summary, label')
                : null;
            if (interactive) {
                return;
            }

            var x = e.clientX || 0;
            var w = Math.max(window.innerWidth, 1);

            var zone = 'center';
            if (x < w / 3) {
                zone = 'left';
            } else if (x > w * 2 / 3) {
                zone = 'right';
            }

            _postMessage({ type: 'tap', payload: { zone: zone } });
        }, true);

        // 通知 Swift ready
        (function() {
            function notifyReady() {
                _postMessage({
                    type: 'paginationReady',
                    payload: { pageCount: 1, scrollMode: true }
                });
            }
            if (document.fonts && document.fonts.ready) {
                document.fonts.ready.then(function() { setTimeout(notifyReady, 30); }).catch(notifyReady);
            } else {
                window.addEventListener('load', function() { setTimeout(notifyReady, 50); });
            }
        })();
        </script>
        </body>
        </html>
        """
    }

    /// 取得章節的 body HTML（供 scroll mode 注入用）
    private func scrollChapterBodyHTML(at index: Int) async -> (bodyHTML: String, title: String, baseURL: URL)? {
        if let session = publicationSession {
            guard index >= 0, index < session.chapters.count else { return nil }
            do {
                let html = try await session.chapterHTML(at: index)
                let body = extractBodyContent(html)
                return (body, session.chapters[index].title, session.chapterBaseURL(at: index))
            } catch { return nil }
        } else if let parsed = parsedBook {
            guard index >= 0, index < parsed.chapters.count else { return nil }
            let chapter = parsed.chapters[index]
            let body = extractBodyContent(chapter.html)
            return (body, chapter.title, chapter.baseURL)
        }
        return nil
    }

    // MARK: - Layout Config JS

    private func layoutConfigJSLiteral(marginH: Int, marginV: Int) -> String {
        let size = currentViewportSize == .zero ? UIScreen.main.bounds.size : currentViewportSize
        let viewportWidth = Int(size.width)
        let viewportHeight = Int(size.height)
        // SO 最佳實踐：pageWidth = viewportWidth（CSS box-sizing 處理 padding）
        // column-gap = 0，pageSpan = viewportWidth
        let pageWidth = viewportWidth
        let pageHeight = viewportHeight
        let pageSpan = viewportWidth

        return """
        {
            flow: '\(renderFlowMode == "vertical" ? "vertical" : "horizontal")',
            paginated: true,
            fontSize: \(Int(renderFontSize)),
            horizontalProfile: {
                geometry: {
                    strategy: 'paged-columns',
                    writingMode: 'horizontal-tb',
                    pageAxis: 'x',
                    pageProgression: 'ltr',
                    viewportWidth: \(viewportWidth),
                    viewportHeight: \(viewportHeight),
                    pageWidth: \(pageWidth),
                    pageHeight: \(pageHeight),
                    pageSpan: \(pageSpan),
                    pageInsetBlockStart: 0,
                    pageInsetBlockEnd: 0,
                    pageInsetInlineStart: 0,
                    pageInsetInlineEnd: 0,
                    columnGap: 0
                },
                typography: {
                    lineHeight: 1.6,
                    paddingVertical: \(marginV),
                    paddingHorizontal: \(marginH),
                    paragraphIndent: '2em',
                    paragraphSpacing: 0.9,
                    headingTop: 0.75,
                    headingBottom: 0.42
                }
            },
            verticalProfile: {
                geometry: {
                    strategy: 'stacked-pages',
                    writingMode: 'horizontal-tb',
                    pageAxis: 'y',
                    pageProgression: 'ltr',
                    viewportWidth: \(viewportWidth),
                    viewportHeight: \(viewportHeight),
                    pageWidth: \(pageWidth),
                    pageHeight: \(pageHeight),
                    pageSpan: \(viewportHeight),
                    pageInsetBlockStart: 0,
                    pageInsetBlockEnd: 0,
                    pageInsetInlineStart: 0,
                    pageInsetInlineEnd: 0,
                    columnGap: 0
                },
                typography: {
                    lineHeight: 1.6,
                    paddingVertical: \(marginV),
                    paddingHorizontal: \(marginH),
                    paragraphIndent: '2em',
                    paragraphSpacing: 0.82,
                    headingTop: 0.58,
                    headingBottom: 0.35
                }
            }
        }
        """
    }

    // MARK: - HTML 工具

    private func extractBodyContent(_ html: String) -> String {
        let lower = html.lowercased()
        if let bodyStart = lower.range(of: "<body"),
           let tagEnd = lower[bodyStart.upperBound...].range(of: ">")
        {
            let contentStart = tagEnd.upperBound
            if let bodyEnd = lower.range(of: "</body>") {
                let startIdx = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: contentStart))
                let endIdx = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: bodyEnd.lowerBound))
                return String(html[startIdx..<endIdx])
            }
        }
        return html
    }

    private func extractBodyAttributes(_ html: String) -> String {
        let lower = html.lowercased()
        guard let bodyStart = lower.range(of: "<body"),
              let tagEnd = lower[bodyStart.upperBound...].range(of: ">")
        else {
            return ""
        }

        let attrStart = html.index(
            html.startIndex,
            offsetBy: lower.distance(from: lower.startIndex, to: bodyStart.upperBound)
        )
        let attrEnd = html.index(
            html.startIndex,
            offsetBy: lower.distance(from: lower.startIndex, to: tagEnd.lowerBound)
        )
        return String(html[attrStart..<attrEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractHeadContent(_ html: String) -> String {
        let lower = html.lowercased()
        guard let headStart = lower.range(of: "<head"),
              let headTagEnd = lower[headStart.upperBound...].range(of: ">"),
              let headEnd = lower.range(of: "</head>")
        else {
            return ""
        }

        let contentStart = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: headTagEnd.upperBound))
        let contentEnd = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: headEnd.lowerBound))
        return String(html[contentStart..<contentEnd])
    }

    private func extractHeadStyles(_ html: String, chapterBaseURL: URL) -> String {
        var styles: [String] = []
        let pattern = #"<style[^>]*>([\s\S]*?)</style>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return "" }
        let ns = html as NSString
        let lower = html.lowercased()
        let searchRange: NSRange
        if let headStart = lower.range(of: "<head"),
           let headEnd = lower.range(of: "</head>")
        {
            let start = lower.distance(from: lower.startIndex, to: headStart.lowerBound)
            let end = lower.distance(from: lower.startIndex, to: headEnd.upperBound)
            searchRange = NSRange(location: start, length: end - start)
        } else {
            searchRange = NSRange(location: 0, length: ns.length)
        }
        for m in regex.matches(in: html, range: searchRange) {
            if m.numberOfRanges >= 2 {
                let cssContent = ns.substring(with: m.range(at: 1))
                let rewritten = rewriteCSSURLs(cssContent, cssBaseDir: chapterBaseURL)
                styles.append("<style>\(rewritten)</style>")
            } else {
                styles.append(ns.substring(with: m.range))
            }
        }
        return styles.joined(separator: "\n")
    }

    private func rewriteCSSURLs(_ css: String, cssBaseDir: URL) -> String {
        let pattern = #"url\(\s*(['"]?)([^)'"]+)\1\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return css }
        let ns = css as NSString
        var result = css
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let quoteRange = m.range(at: 1)
            let pathRange = m.range(at: 2)
            let fullRange = m.range
            let quote = ns.substring(with: quoteRange)
            let rawPath = ns.substring(with: pathRange)
            if rawPath.hasPrefix("data:") || rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") || rawPath.hasPrefix("file://") {
                continue
            }
            let resolved = cssBaseDir.appendingPathComponent(rawPath).standardized
            let replacement = "url(\(quote)\(resolved.absoluteString)\(quote))"
            let start = result.index(result.startIndex, offsetBy: fullRange.location)
            let end = result.index(start, offsetBy: fullRange.length)
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }

    // MARK: - 主題工具

    private func themeColors(_ theme: String) -> (bg: String, text: String) {
        switch theme {
        case "white": return ("#ffffff", "#333333")
        case "sepia": return ("#f4ecd8", "#5b4636")
        case "night": return ("#1a1a1a", "#d9d9d9")
        default: return ("#f4ecd8", "#5b4636")
        }
    }

    func themeBackgroundUIColor() -> UIColor {
        switch renderTheme {
        case "white": return .white
        case "night": return UIColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1)
        default: return UIColor(red: 244/255, green: 236/255, blue: 216/255, alpha: 1)
        }
    }
}

// MARK: - WKNavigationDelegate

extension LiveWebReader: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 安全網：如果 JS paginationReady 訊息未發送，在導航完成後再嘗試一次
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // 等一幀讓 JS 有機會先觸發
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if self.chapterLoadContinuation != nil {
                if let metrics = await self.requestPaginationMetrics(in: self.webView),
                   metrics.pageCount > 0
                {
                    self.onPaginationReady(pageCount: metrics.pageCount, pageOffsets: metrics.pageOffsets)
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.errorMessage = "載入失敗: \(error.localizedDescription)"
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.errorMessage = "載入失敗: \(error.localizedDescription)"
        }
    }
}

// MARK: - JS Message Handler（可見 WebView 通道）

private class LiveReaderMessageHandler: NSObject, WKScriptMessageHandler {
    weak var reader: LiveWebReader?
    init(reader: LiveWebReader) { self.reader = reader }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }
        Task { @MainActor in
            var payload = body["payload"] as? [String: Any] ?? [:]
            if payload["pageCount"] == nil, let pageCount = body["pageCount"] as? Int {
                payload["pageCount"] = pageCount
            }
            self.reader?.handleBridgeMessage(
                type: type,
                payload: payload,
                sourceWebView: message.webView,
                fallbackRole: nil
            )
        }
    }
}

// MARK: - Scan Message Handler（離屏掃描通道）

private class LiveScanMessageHandler: NSObject, WKScriptMessageHandler {
    weak var reader: LiveWebReader?
    init(reader: LiveWebReader) { self.reader = reader }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "paginationReady"
        else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        let pageCount = payload["pageCount"] as? Int ?? 1
        Task { @MainActor in
            self.reader?.onScanPaginationReady(pageCount: pageCount)
        }
    }
}

// MARK: - Preload Message Handler（pool prev/next 的 JS 回調）

private class LivePreloadMessageHandler: NSObject, WKScriptMessageHandler {
    weak var reader: LiveWebReader?
    let role: LiveWebReader.WebViewRole

    init(reader: LiveWebReader, role: LiveWebReader.WebViewRole) {
        self.reader = reader
        self.role = role
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }
        Task { @MainActor in
            var payload = body["payload"] as? [String: Any] ?? [:]
            if payload["pageCount"] == nil, let pageCount = body["pageCount"] as? Int {
                payload["pageCount"] = pageCount
            }
            self.reader?.handleBridgeMessage(
                type: type,
                payload: payload,
                sourceWebView: message.webView,
                fallbackRole: self.role
            )
        }
    }
}
