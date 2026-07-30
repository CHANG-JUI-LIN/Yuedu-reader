import Combine
import UIKit

/// CoreText-only EPUB renderer adapter.
/// WebView rendering path has been removed; all functionality routes to CoreTextPageEngine.
@MainActor
final class EPUBPageRenderer: ObservableObject {

    // MARK: - CoreText engine

    private(set) var engine: (any PageRenderingProvider)?
    @Published private(set) var layoutMode: EPUBLayoutMode = .reflowable
    @Published private(set) var pageProgressionDirection: EPUBPageProgressionDirection = .default
    @Published private(set) var fixedLayoutSpread: FixedLayoutSpread = .auto
    @Published private(set) var fixedLayoutOrientation: FixedLayoutOrientation = .auto
    @Published private(set) var fixedLayoutViewport: FixedLayoutViewport?
    @Published private(set) var mediaOverlaysByChapter: [Int: EPUBMediaOverlay] = [:]
    /// Holds the EPUB builder so notifyViewportSize can update renderSize.
    private var epubBuilder: EPUBAttributedStringBuilder?
    private var onlineBuilder: OnlineProviderAttributedStringBuilder?
    private var publicationSession: PublicationSession?

    /// Scroll-mode-specific engine (alongside the page engine). Created automatically when builder is available.
    @Published private(set) var scrollEngine: CoreTextScrollEngine? {
        didSet {
            // Bridge the nested engine's isReady into a property the view observes
            // directly, so the scroll body can gate on a ready engine without a
            // white/blank flash. SwiftUI does not observe nested ObservableObjects.
            guard oldValue !== scrollEngine else { return }
            scrollEngineReady = scrollEngine?.isReady ?? false
            scrollReadyCancellable = scrollEngine?.$isReady
                .receive(on: DispatchQueue.main)
                .sink { [weak self] ready in self?.scrollEngineReady = ready }
        }
    }

    /// Mirrors `scrollEngine?.isReady` reactively for the SwiftUI body.
    @Published private(set) var scrollEngineReady: Bool = false
    private var scrollReadyCancellable: AnyCancellable?

    @Published var isCoreTextReady: Bool = false
    @Published private(set) var pendingVisibleRefreshCommit: ReaderVisibleRefreshCommit?

    private var nextRefreshTransactionID: UInt64 = 0
    private var currentRefreshTransactionID: UInt64 = 0
    private var visibleRefreshContinuations:
        [UInt64: CheckedContinuation<ReaderRenderRefreshResult, Never>] = [:]
    private var visibleRefreshRequests: [UInt64: ReaderRenderRefreshRequest] = [:]
    private var latestRenderSettings: ReaderRenderSettings?
    private var settingsRevision: UInt64 = 0
    private var contentRevision: UInt64 = 0
    private var pagedAppliedSettingsRevision: UInt64 = 0
    private var scrollAppliedSettingsRevision: UInt64 = 0
    private var pagedAppliedContentRevision: UInt64 = 0
    private var scrollAppliedContentRevision: UInt64 = 0

    var isFixedLayout: Bool {
        layoutMode == .prePaginated
    }

    /// True when CSS writing-mode: vertical-rl is detected from EPUB stylesheets.
    var cssDetectedVerticalWritingMode: Bool {
        epubBuilder?.cssDetectedVerticalWritingMode ?? false
    }

    func resourceURL(for href: String) -> URL? {
        publicationSession?.resourceURL(for: href)
    }

    /// Tracks the current global page index (kept in sync by ReaderView / CoreTextPageEngineView).
    var currentEpubPage: Int = 0

    /// Last non-zero viewport size reported by ReaderView via notifyViewportSize().
    private var lastViewportSize: CGSize = UIScreen.main.bounds.size
    /// bookId waiting for a valid viewport size before CoreTextPageEngine.start() can run.
    private var pendingStartBookId: String?

    private func logProgress(_ message: String) {
        let line = "[ProgressTrace][EPUBPageRenderer] \(message)"
        print(line)
        NSLog("%@", line)
    }

    private func elapsedMs(since start: TimeInterval) -> String {
        let value = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.1f", value)
    }

    // MARK: - Load

    /// CoreText path — creates a CoreTextPageEngine and kicks off async loading.
    /// If renderSize is zero (view not yet laid out), start is deferred until
    /// notifyViewportSize() is called with a valid size.
    func load(
        publicationSession session: PublicationSession,
        bookIdentifier: String,
        renderSize: CGSize,
        settings: ReaderRenderSettings
    ) {
        layoutMode = session.layoutMode
        pageProgressionDirection = session.pageProgressionDirection
        fixedLayoutSpread = session.fixedLayoutSpread
        fixedLayoutOrientation = session.fixedLayoutOrientation
        fixedLayoutViewport = session.fixedLayoutViewport
        mediaOverlaysByChapter = session.mediaOverlaysByChapter
        publicationSession = session

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        guard session.layoutMode != .prePaginated else {
            let fixedEngine = FixedLayoutPageEngine(session: session, renderSize: effectiveSize)
            self.engine = fixedEngine
            isCoreTextReady = true
            Task {
                await fixedEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
            }
            return
        }

        let progressDir = StorageLocations.epubCharOffsets.appendingPathComponent(bookIdentifier)
        let store = CharOffsetStore(directoryURL: progressDir)

        self.onlineBuilder = nil
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: effectiveSize
        )
        let chapterDocumentStore = ChapterDocumentStore(builder: builder)
        self.epubBuilder = builder
        let newEngine = CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: settings,
            chapterDocumentStore: chapterDocumentStore,
            offsetStore: store
        )
        self.scrollEngine = CoreTextScrollEngine(
            builder: builder,
            renderSettings: settings,
            chapterDocumentStore: chapterDocumentStore
        )

        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        isCoreTextReady = false

        if effectiveSize.width > 0 {
            let startUptime = ProcessInfo.processInfo.systemUptime
            logProgress("load start bookId=\(bookIdentifier) renderSize=\(effectiveSize)")
            Task {
                await newEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
                self.isCoreTextReady = true
                self.logProgress(
                    "load ready bookId=\(bookIdentifier) totalPages=\(newEngine.totalPages) elapsedMs=\(self.elapsedMs(since: startUptime))"
                )
            }
        } else {
            pendingStartBookId = bookIdentifier
            logProgress("load deferred bookId=\(bookIdentifier) reason=invalidRenderSize size=\(renderSize)")
        }
    }

    func loadTXT(
        text: String,
        title: String,
        bookIdentifier: String,
        renderSize: CGSize,
        settings: ReaderRenderSettings,
        preparedChapters: [UnifiedChapter]? = nil
    ) {
        let chapters = preparedChapters ?? TXTChapterParser.parseUnifiedChapters(text, bookTitle: title)
        let builder = NodeAttributedStringBuilder(chapters: chapters)
        loadTXT(
            attributedBuilder: builder,
            bookIdentifier: bookIdentifier,
            renderSize: renderSize,
            settings: settings
        )
    }

    func loadTXT(
        attributedBuilder: any AttributedStringBuilding,
        bookIdentifier: String,
        renderSize: CGSize,
        settings: ReaderRenderSettings
    ) {
        mediaOverlaysByChapter = [:]
        fixedLayoutViewport = nil
        fixedLayoutSpread = .auto
        fixedLayoutOrientation = .auto
        pageProgressionDirection = .default
        layoutMode = .reflowable
        publicationSession = nil
        let progressDir = StorageLocations.epubCharOffsets.appendingPathComponent(bookIdentifier)
        let store = CharOffsetStore(directoryURL: progressDir)
        let chapterDocumentStore = ChapterDocumentStore(builder: attributedBuilder)
        let newEngine = CoreTextPageEngine(
            attributedBuilder: attributedBuilder,
            renderSettings: settings,
            chapterDocumentStore: chapterDocumentStore,
            offsetStore: store
        )
        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        self.epubBuilder = nil
        self.onlineBuilder = nil
        self.scrollEngine = CoreTextScrollEngine(
            builder: attributedBuilder,
            renderSettings: settings,
            chapterDocumentStore: chapterDocumentStore
        )
        isCoreTextReady = false

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        if effectiveSize.width > 0 {
            let startUptime = ProcessInfo.processInfo.systemUptime
            logProgress("loadTXT start bookId=\(bookIdentifier) renderSize=\(effectiveSize)")
            Task {
                await newEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
                guard self.engine === newEngine else { return }
                self.isCoreTextReady = true
                self.logProgress(
                    "loadTXT ready bookId=\(bookIdentifier) totalPages=\(newEngine.totalPages) elapsedMs=\(self.elapsedMs(since: startUptime))"
                )
            }
        } else {
            pendingStartBookId = bookIdentifier
            logProgress("loadTXT deferred bookId=\(bookIdentifier) reason=invalidRenderSize size=\(renderSize)")
        }
    }

    func loadWithProvider(
        contentProvider: any BookContentProvider,
        chapterSourceHrefs: [String?],
        bookIdentifier: String,
        renderSize: CGSize,
        settings: ReaderRenderSettings,
        customScheme: String = "reader-online",
        imageDecode: (@Sendable (Data, String) -> Data?)? = nil
    ) {
        let progressDir = StorageLocations.epubCharOffsets.appendingPathComponent(bookIdentifier)
        let store = CharOffsetStore(directoryURL: progressDir)
        let resourceAdapter = UniversalBookResourceAdapter(
            contentProvider: contentProvider,
            chapterSourceHrefs: chapterSourceHrefs,
            customScheme: customScheme
        )
        let effectiveSizeForBuilder = renderSize.width > 0 ? renderSize : lastViewportSize
        let onlineBuilder = OnlineProviderAttributedStringBuilder(
            provider: contentProvider,
            renderSize: effectiveSizeForBuilder,
            resourceProvider: resourceAdapter,
            chapterSourceHrefs: chapterSourceHrefs,
            imageDecode: imageDecode
        )
        let chapterDocumentStore = ChapterDocumentStore(builder: onlineBuilder)
        let newEngine = CoreTextPageEngine(
            attributedBuilder: onlineBuilder,
            renderSettings: settings,
            chapterDocumentStore: chapterDocumentStore,
            offsetStore: store
        )
        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        self.onlineBuilder = onlineBuilder
        self.scrollEngine = CoreTextScrollEngine(
            builder: onlineBuilder,
            renderSettings: settings,
            chapterDocumentStore: chapterDocumentStore
        )
        isCoreTextReady = false

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        if effectiveSize.width > 0 {
            let startUptime = ProcessInfo.processInfo.systemUptime
            logProgress("loadWithProvider start bookId=\(bookIdentifier) renderSize=\(effectiveSize)")
            Task {
                await newEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
                self.isCoreTextReady = true
                self.logProgress(
                    "loadWithProvider ready bookId=\(bookIdentifier) totalPages=\(newEngine.totalPages) elapsedMs=\(self.elapsedMs(since: startUptime))"
                )
            }
        } else {
            pendingStartBookId = bookIdentifier
            logProgress("loadWithProvider deferred bookId=\(bookIdentifier) reason=invalidRenderSize size=\(renderSize)")
        }
    }

    /// Called by ReaderView whenever the viewport size changes.
    /// Stores the size and starts the CoreText engine if load() was called before layout.
    func notifyViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastViewportSize = size
        // Update renderSize for EPUB builder created before deferred start
        epubBuilder?.renderSize = size
        onlineBuilder?.updateRenderSize(size)
        guard let bookId = pendingStartBookId, let eng = engine else { return }
        pendingStartBookId = nil
        let startUptime = ProcessInfo.processInfo.systemUptime
        logProgress("notifyViewportSize start deferred bookId=\(bookId) size=\(size)")
        Task {
            await eng.start(renderSize: size, bookId: bookId)
            self.isCoreTextReady = true
            self.logProgress(
                "notifyViewportSize ready deferred bookId=\(bookId) totalPages=\(eng.totalPages) elapsedMs=\(self.elapsedMs(since: startUptime))"
            )
        }
    }

    // MARK: - Progress presentation

    /// Called at page-turn time so the renderer can expose the current page for UI.
    /// Position persistence is owned by ReaderNavigator/ReadingPositionStore.
    func updateCurrentPosition(globalPage: Int, engine eng: any PageRenderingProvider) {
        currentEpubPage = globalPage
        let (spine, offset) = eng.charOffset(forPage: globalPage)
        logProgress("updateCurrentPosition globalPage=\(globalPage) spine=\(spine) charOffset=\(offset)")
    }

    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? {
        await engine?.resolveInternalLink(href, fromSpineIndex: spineIndex)
    }

    // MARK: - Layout / settings

    func setFontSize(_ size: CGFloat) {
        guard let eng = engine else { return }
        Task { await eng.invalidateLayout(newSize: eng.renderSize) }
    }

    func setTheme(_ theme: String) {
        let textColor: UIColor
        let bgColor: UIColor
        switch theme {
        case "dark", "night":
            textColor = .white
            bgColor = .black
        case "sepia":
            textColor = UIColor(red: 0.3, green: 0.2, blue: 0.1, alpha: 1)
            bgColor = UIColor(red: 0.97, green: 0.93, blue: 0.84, alpha: 1)
        case "green":
            textColor = UIColor(red: 47 / 255, green: 61 / 255, blue: 47 / 255, alpha: 1)
            bgColor = UIColor(red: 207 / 255, green: 232 / 255, blue: 204 / 255, alpha: 1)
        default:
            textColor = .label
            bgColor = .systemBackground
        }
        engine?.applyThemeChange(textColor: textColor, backgroundColor: bgColor)
    }

    func setPageMargins(horizontal: CGFloat, vertical: CGFloat) {
        guard let eng = engine else { return }
        Task { await eng.invalidateLayout(newSize: eng.renderSize) }
    }

    func invalidateCoreTextLayout() {
        guard let eng = engine else { return }
        Task { await eng.invalidateLayout(newSize: eng.renderSize) }
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        engine?.updateRenderSettings(settings)
        scrollEngine?.updateRenderSettings(settings)
    }

    // MARK: - Refresh transactions

    func refresh(
        _ request: ReaderRenderRefreshRequest
    ) async -> ReaderRenderRefreshResult {
        let transactionID = beginRefreshTransaction()

        if latestRenderSettings != request.settings {
            latestRenderSettings = request.settings
            settingsRevision &+= 1
        }
        updateRenderSettings(request.settings)
        if case .chapterContent = request.intent {
            contentRevision &+= 1
        }
        visibleRefreshRequests[transactionID] = request

        let failure = await prepareRefresh(request)
        guard transactionID == currentRefreshTransactionID else {
            visibleRefreshRequests.removeValue(forKey: transactionID)
            return .superseded(transactionID: transactionID)
        }
        if let failure {
            visibleRefreshRequests.removeValue(forKey: transactionID)
            return .failed(transactionID: transactionID, failure: failure)
        }

        return await withCheckedContinuation { continuation in
            visibleRefreshContinuations[transactionID] = continuation
            pendingVisibleRefreshCommit = ReaderVisibleRefreshCommit(
                transactionID: transactionID,
                mode: request.mode,
                position: request.position
            )
        }
    }

    func finishVisibleRefresh(
        transactionID: UInt64,
        outcome: ReaderVisibleRefreshOutcome
    ) {
        guard pendingVisibleRefreshCommit?.transactionID == transactionID,
              let continuation = visibleRefreshContinuations[
                  transactionID
              ],
              let request = visibleRefreshRequests[
                  transactionID
              ]
        else { return }

        visibleRefreshContinuations.removeValue(
            forKey: transactionID
        )
        visibleRefreshRequests.removeValue(
            forKey: transactionID
        )
        pendingVisibleRefreshCommit = nil
        switch outcome {
        case .applied:
            markAppliedRevisions(for: request.mode)
            continuation.resume(
                returning: .completed(transactionID: transactionID)
            )
        case .failed(let failure):
            continuation.resume(
                returning: .failed(
                    transactionID: transactionID,
                    failure: failure
                )
            )
        }
    }

    private func beginRefreshTransaction() -> UInt64 {
        nextRefreshTransactionID &+= 1
        currentRefreshTransactionID = nextRefreshTransactionID

        let supersededContinuations = visibleRefreshContinuations
        visibleRefreshContinuations.removeAll(keepingCapacity: true)
        visibleRefreshRequests.removeAll(keepingCapacity: true)
        pendingVisibleRefreshCommit = nil
        for (transactionID, continuation) in supersededContinuations {
            continuation.resume(
                returning: .superseded(transactionID: transactionID)
            )
        }

        engine?.cancelPendingWork()
        return currentRefreshTransactionID
    }

    private func prepareRefresh(
        _ request: ReaderRenderRefreshRequest
    ) async -> ReaderRenderRefreshFailure? {
        switch request.mode {
        case .paged:
            return await preparePagedRefresh(request)
        case .scroll:
            return await prepareScrollRefresh(request)
        }
    }

    private func preparePagedRefresh(
        _ request: ReaderRenderRefreshRequest
    ) async -> ReaderRenderRefreshFailure? {
        guard let engine else {
            return .engineUnavailable(.paged)
        }

        switch request.intent {
        case .layout:
            await invalidatePagedLayout(
                engine,
                newSize: request.viewportSize,
                ensuringSpine: request.position.spineIndex
            )
        case .appearance:
            engine.applyThemeChange(
                textColor: request.settings.textColor,
                backgroundColor: request.settings.backgroundColor
            )
        case .chapterContent(let chapterIndex):
            await engine.notifyChapterDataChanged(at: chapterIndex)
        case .modeActivation:
            let needsPreparation =
                pagedAppliedSettingsRevision < settingsRevision
                || pagedAppliedContentRevision < contentRevision
            if needsPreparation {
                await invalidatePagedLayout(
                    engine,
                    newSize: request.viewportSize,
                    ensuringSpine: request.position.spineIndex
                )
            }
        }

        guard hasPagedLayout(
            for: request.position,
            engine: engine
        ) else {
            return .layoutUnavailable(request.position.spineIndex)
        }
        return nil
    }

    private func invalidatePagedLayout(
        _ engine: any PageRenderingProvider,
        newSize: CGSize,
        ensuringSpine spineIndex: Int
    ) async {
        if let coreTextEngine = engine as? CoreTextPageEngine {
            await coreTextEngine.invalidateLayout(
                newSize: newSize,
                ensuringSpine: spineIndex
            )
        } else {
            await engine.invalidateLayout(newSize: newSize)
        }
    }

    private func prepareScrollRefresh(
        _ request: ReaderRenderRefreshRequest
    ) async -> ReaderRenderRefreshFailure? {
        guard let scrollEngine else {
            return .engineUnavailable(.scroll)
        }

        switch request.intent {
        case .layout, .appearance:
            break
        case .chapterContent(let chapterIndex):
            if chapterIndex == request.position.spineIndex {
                scrollEngine.invalidateChapterDocument(at: chapterIndex)
            } else {
                _ = await scrollEngine.retryChapterIfNeeded(chapterIndex)
            }
        case .modeActivation:
            _ = scrollAppliedSettingsRevision < settingsRevision
                || scrollAppliedContentRevision < contentRevision
        }
        return nil
    }

    private func hasPagedLayout(
        for position: CoreTextReadingPosition,
        engine: any PageRenderingProvider
    ) -> Bool {
        if engine is FixedLayoutPageEngine {
            return engine.pageIndex(for: position) != nil
        }
        return engine.layouts[position.spineIndex] != nil
    }

    private func markAppliedRevisions(for mode: ReaderDisplayMode) {
        switch mode {
        case .paged:
            pagedAppliedSettingsRevision = settingsRevision
            pagedAppliedContentRevision = contentRevision
        case .scroll:
            scrollAppliedSettingsRevision = settingsRevision
            scrollAppliedContentRevision = contentRevision
        }
    }
}
