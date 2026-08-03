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

    private struct RefreshRevisionSnapshot {
        let layout: UInt64
        let appearance: UInt64
        let content: UInt64
    }

    private struct RefreshRevisionCoverage {
        let layout: UInt64?
        let appearance: UInt64?
        let content: UInt64?

        static let none = RefreshRevisionCoverage(
            layout: nil,
            appearance: nil,
            content: nil
        )
    }

    private struct RefreshAppliedRevisionSnapshot {
        let pagedLayout: UInt64
        let pagedAppearance: UInt64
        let pagedContent: UInt64
        let scrollLayout: UInt64
        let scrollAppearance: UInt64
        let scrollContent: UInt64
    }

    private struct RefreshTransactionContext {
        let request: ReaderRenderRefreshRequest
        let revisions: RefreshRevisionSnapshot
        /// Resumed exactly once, then cleared. A superseded transaction answers its
        /// caller immediately but stays registered while its visible commit is still
        /// outstanding, so the host's acknowledgement can still record the coverage.
        var continuation: CheckedContinuation<ReaderRenderRefreshResult, Never>?
        var coverage: RefreshRevisionCoverage = .none
    }

    private enum RefreshPreparationResult {
        case requiresVisibleCommit(RefreshRevisionCoverage)
        case completed(RefreshRevisionCoverage)
        case failed(ReaderRenderRefreshFailure)
    }

    @MainActor
    private struct RefreshPreparation {
        let request: ReaderRenderRefreshRequest
        let revisions: RefreshRevisionSnapshot
        let applied: RefreshAppliedRevisionSnapshot
        let engine: (any PageRenderingProvider)?
        let scrollEngine: CoreTextScrollEngine?

        func run() async -> RefreshPreparationResult {
            switch request.mode {
            case .paged:
                return await preparePaged()
            case .scroll:
                return await prepareScroll()
            }
        }

        private func preparePaged() async -> RefreshPreparationResult {
            guard let engine else {
                return .failed(.engineUnavailable(.paged))
            }

            let coverage: RefreshRevisionCoverage
            switch request.intent {
            case .layout:
                await invalidatePagedLayout(
                    engine,
                    newSize: request.viewportSize,
                    ensuringSpine: request.position.spineIndex
                )
                coverage = RefreshRevisionCoverage(
                    layout: revisions.layout,
                    appearance: nil,
                    content: nil
                )
            case .appearance:
                engine.applyThemeChange(
                    textColor: request.settings.textColor,
                    backgroundColor: request.settings.backgroundColor
                )
                coverage = RefreshRevisionCoverage(
                    layout: nil,
                    appearance: revisions.appearance,
                    content: nil
                )
            case .chapterContent(let chapterIndex):
                await engine.notifyChapterDataChanged(at: chapterIndex)
                coverage = RefreshRevisionCoverage(
                    layout: nil,
                    appearance: nil,
                    content: revisions.content
                )
                if chapterIndex != request.position.spineIndex {
                    return .completed(coverage)
                }
            case .modeActivation:
                let needsLayout = applied.pagedLayout < revisions.layout
                let needsAppearance =
                    applied.pagedAppearance < revisions.appearance
                let needsContent = applied.pagedContent < revisions.content
                guard needsLayout || needsAppearance || needsContent else {
                    return .completed(.none)
                }
                await invalidatePagedLayout(
                    engine,
                    newSize: request.viewportSize,
                    ensuringSpine: request.position.spineIndex
                )
                coverage = RefreshRevisionCoverage(
                    layout: needsLayout ? revisions.layout : nil,
                    appearance: needsAppearance ? revisions.appearance : nil,
                    content: needsContent ? revisions.content : nil
                )
            }

            guard hasPagedLayout(
                for: request.position,
                engine: engine
            ) else {
                return .failed(
                    .layoutUnavailable(request.position.spineIndex)
                )
            }
            return .requiresVisibleCommit(coverage)
        }

        private func prepareScroll() async -> RefreshPreparationResult {
            guard let scrollEngine else {
                return .failed(.engineUnavailable(.scroll))
            }

            switch request.intent {
            case .layout:
                return .requiresVisibleCommit(
                    RefreshRevisionCoverage(
                        layout: revisions.layout,
                        appearance: nil,
                        content: nil
                    )
                )
            case .appearance:
                return .requiresVisibleCommit(
                    RefreshRevisionCoverage(
                        layout: nil,
                        appearance: revisions.appearance,
                        content: nil
                    )
                )
            case .chapterContent(let chapterIndex):
                // Chapter *supply* deliberately does not happen here. A refresh
                // transaction is latest-wins and cancels the preparation task of the
                // one before it, so loading a chapter from inside this closure let one
                // chapter's arrival cancel another's mid-load and strand it on its
                // placeholder forever. `ReaderView` drives `retryChapterIfNeeded` from
                // the chapter-ready event instead, and only asks for a refresh here
                // when the engine still has nothing for the visible chapter.
                if chapterIndex == request.position.spineIndex {
                    scrollEngine.invalidateChapterDocument(at: chapterIndex)
                    return .requiresVisibleCommit(
                        RefreshRevisionCoverage(
                            layout: nil,
                            appearance: nil,
                            content: revisions.content
                        )
                    )
                }
                return .completed(
                    RefreshRevisionCoverage(
                        layout: nil,
                        appearance: nil,
                        content: nil
                    )
                )
            case .modeActivation:
                let needsLayout = applied.scrollLayout < revisions.layout
                let needsAppearance =
                    applied.scrollAppearance < revisions.appearance
                let needsContent = applied.scrollContent < revisions.content
                guard needsLayout || needsAppearance || needsContent else {
                    return .completed(.none)
                }
                return .requiresVisibleCommit(
                    RefreshRevisionCoverage(
                        layout: needsLayout ? revisions.layout : nil,
                        appearance: needsAppearance
                            ? revisions.appearance
                            : nil,
                        content: needsContent ? revisions.content : nil
                    )
                )
            }
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

        private func hasPagedLayout(
            for position: CoreTextReadingPosition,
            engine: any PageRenderingProvider
        ) -> Bool {
            if engine is FixedLayoutPageEngine {
                return engine.pageIndex(for: position) != nil
            }
            return engine.layouts[position.spineIndex] != nil
        }
    }

    private var nextRefreshTransactionID: UInt64 = 0
    private var currentRefreshTransactionID: UInt64 = 0
    private var refreshTransactions: [UInt64: RefreshTransactionContext] = [:]
    private var refreshPreparationTasks: [UInt64: Task<Void, Never>] = [:]
    private var latestLayoutRenderSettings: ReaderRenderSettings?
    private var latestAppearanceRenderSettings: ReaderRenderSettings?
    // Revision 1 is the initial loaded snapshot. Applied revisions start at 0
    // so a mode's first activation remains stale until its host acknowledges it.
    private var layoutRevision: UInt64 = 1
    private var appearanceRevision: UInt64 = 1
    private var contentRevision: UInt64 = 1
    private var pagedAppliedLayoutRevision: UInt64 = 0
    private var pagedAppliedAppearanceRevision: UInt64 = 0
    private var pagedAppliedContentRevision: UInt64 = 0
    private var scrollAppliedLayoutRevision: UInt64 = 0
    private var scrollAppliedAppearanceRevision: UInt64 = 0
    private var scrollAppliedContentRevision: UInt64 = 0

    var activeRefreshPreparationCount: Int {
        refreshPreparationTasks.count
    }
    private(set) var refreshPreparationCompletionCount: UInt64 = 0

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
        await withCheckedContinuation { continuation in
            beginRefreshTransaction(
                request: request,
                continuation: continuation
            )
        }
    }

    func finishVisibleRefresh(
        transactionID: UInt64,
        outcome: ReaderVisibleRefreshOutcome
    ) {
        guard pendingVisibleRefreshCommit?.transactionID == transactionID,
              let context = refreshTransactions.removeValue(forKey: transactionID)
        else { return }

        pendingVisibleRefreshCommit = nil
        switch outcome {
        case .applied:
            apply(
                context.coverage,
                to: context.request.mode
            )
            context.continuation?.resume(
                returning: .completed(transactionID: transactionID)
            )
        case .failed(let failure):
            context.continuation?.resume(
                returning: .failed(
                    transactionID: transactionID,
                    failure: failure
                )
            )
        }
    }

    private func beginRefreshTransaction(
        request: ReaderRenderRefreshRequest,
        continuation: CheckedContinuation<ReaderRenderRefreshResult, Never>
    ) {
        nextRefreshTransactionID &+= 1
        currentRefreshTransactionID = nextRefreshTransactionID
        let transactionID = currentRefreshTransactionID

        // A published visible commit is a command the host may not have consumed yet:
        // SwiftUI applies `pendingVisibleRefreshCommit` on its own update pass, so
        // clearing it here dropped the scroll reslice outright whenever a second
        // refresh arrived first. Changing an online chapter always does that —
        // `handleChapterStateChanges` prefetches the adjacent chapters on the same
        // `.ready` transition, and each of those completions submits its own refresh —
        // which left the chapter blank forever. Keep the commit outstanding instead;
        // a newer commit replaces it in `completeRefreshPreparation`, and only the
        // host's acknowledgement clears it.
        let outstandingCommitID = pendingVisibleRefreshCommit?.transactionID
        let supersededTransactions = refreshTransactions
        refreshTransactions.removeAll(keepingCapacity: true)
        let supersededPreparationTasks = refreshPreparationTasks
        refreshPreparationTasks.removeAll(keepingCapacity: true)
        supersededPreparationTasks.values.forEach { $0.cancel() }
        for (supersededID, context) in supersededTransactions {
            context.continuation?.resume(
                returning: .superseded(transactionID: supersededID)
            )
            // The caller is answered, but the host still owes this commit an
            // acknowledgement — keep the coverage so `finishVisibleRefresh` can
            // record which revisions the mode ended up applying.
            guard supersededID == outstandingCommitID else { continue }
            var retained = context
            retained.continuation = nil
            refreshTransactions[supersededID] = retained
        }
        engine?.cancelPendingWork()

        switch request.intent {
        case .layout:
            if latestLayoutRenderSettings != request.settings {
                latestLayoutRenderSettings = request.settings
                layoutRevision &+= 1
            }
        case .appearance:
            if latestAppearanceRenderSettings != request.settings {
                latestAppearanceRenderSettings = request.settings
                appearanceRevision &+= 1
            }
        case .chapterContent:
            contentRevision &+= 1
        case .modeActivation:
            break
        }
        updateRenderSettings(request.settings)

        let revisions = RefreshRevisionSnapshot(
            layout: layoutRevision,
            appearance: appearanceRevision,
            content: contentRevision
        )
        refreshTransactions[transactionID] = RefreshTransactionContext(
            request: request,
            revisions: revisions,
            continuation: continuation
        )
        let preparation = RefreshPreparation(
            request: request,
            revisions: revisions,
            applied: RefreshAppliedRevisionSnapshot(
                pagedLayout: pagedAppliedLayoutRevision,
                pagedAppearance: pagedAppliedAppearanceRevision,
                pagedContent: pagedAppliedContentRevision,
                scrollLayout: scrollAppliedLayoutRevision,
                scrollAppearance: scrollAppliedAppearanceRevision,
                scrollContent: scrollAppliedContentRevision
            ),
            engine: engine,
            scrollEngine: scrollEngine
        )
        refreshPreparationTasks[transactionID] = Task {
            @MainActor [weak self] in
            let result = await preparation.run()
            self?.completeRefreshPreparation(
                transactionID: transactionID,
                result: result
            )
        }
    }

    private func completeRefreshPreparation(
        transactionID: UInt64,
        result: RefreshPreparationResult
    ) {
        refreshPreparationCompletionCount &+= 1
        refreshPreparationTasks.removeValue(forKey: transactionID)
        guard transactionID == currentRefreshTransactionID,
              var currentContext = refreshTransactions[transactionID]
        else { return }

        switch result {
        case .requiresVisibleCommit(let coverage):
            currentContext.coverage = coverage
            // This commit replaces any still-outstanding one, so the transaction that
            // owned the previous commit is now unreachable — drop its retained context.
            if let previousCommitID = pendingVisibleRefreshCommit?.transactionID,
               previousCommitID != transactionID {
                refreshTransactions.removeValue(forKey: previousCommitID)
            }
            refreshTransactions[transactionID] = currentContext
            pendingVisibleRefreshCommit = ReaderVisibleRefreshCommit(
                transactionID: transactionID,
                mode: currentContext.request.mode,
                position: currentContext.request.position
            )
        case .completed(let coverage):
            refreshTransactions.removeValue(forKey: transactionID)
            apply(coverage, to: currentContext.request.mode)
            currentContext.continuation?.resume(
                returning: .completed(transactionID: transactionID)
            )
        case .failed(let failure):
            refreshTransactions.removeValue(forKey: transactionID)
            currentContext.continuation?.resume(
                returning: .failed(
                    transactionID: transactionID,
                    failure: failure
                )
            )
        }
    }

    private func apply(
        _ coverage: RefreshRevisionCoverage,
        to mode: ReaderDisplayMode
    ) {
        switch mode {
        case .paged:
            if let revision = coverage.layout {
                pagedAppliedLayoutRevision = max(
                    pagedAppliedLayoutRevision,
                    revision
                )
            }
            if let revision = coverage.appearance {
                pagedAppliedAppearanceRevision = max(
                    pagedAppliedAppearanceRevision,
                    revision
                )
            }
            if let revision = coverage.content {
                pagedAppliedContentRevision = max(
                    pagedAppliedContentRevision,
                    revision
                )
            }
        case .scroll:
            if let revision = coverage.layout {
                scrollAppliedLayoutRevision = max(
                    scrollAppliedLayoutRevision,
                    revision
                )
            }
            if let revision = coverage.appearance {
                scrollAppliedAppearanceRevision = max(
                    scrollAppliedAppearanceRevision,
                    revision
                )
            }
            if let revision = coverage.content {
                scrollAppliedContentRevision = max(
                    scrollAppliedContentRevision,
                    revision
                )
            }
        }
    }
}
