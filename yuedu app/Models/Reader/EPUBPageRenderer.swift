import Combine
import UIKit

/// CoreText-only EPUB renderer adapter.
/// WebView rendering path has been removed; all functionality routes to CoreTextPageEngine.
@MainActor
final class EPUBPageRenderer: ObservableObject {

    // MARK: - CoreText engine

    private(set) var engine: (any PageRenderingProvider)?
    /// Phase 7：當 useRenderableNodePipeline 開啟時持有 EPUB builder，
    /// 供 notifyViewportSize 更新 renderSize 使用。
    private var epubBuilder: EPUBAttributedStringBuilder?
    private var onlineBuilder: OnlineProviderAttributedStringBuilder?

    /// 捲動模式專用引擎（與 page engine 並列）。當 builder 可取得時自動建立。
    @Published private(set) var scrollEngine: CoreTextScrollEngine?

    @Published var isCoreTextReady: Bool = false

    /// Tracks the current global page index (kept in sync by ReaderView / CoreTextPageEngineView).
    var currentEpubPage: Int = 0

    /// Stable content position captured at navigation time (when the spine IS loaded).
    /// More reliable than converting currentEpubPage at save time, because spinePageOffsets
    /// may shift as more chapters load and replace estimated page counts.
    private var savedSpineIndex: Int = 0
    private var savedCharOffset: Int = 0

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
        let docsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let progressDir = docsURL.appendingPathComponent(
            "epub_charoffsets/\(bookIdentifier)"
        )
        let store = CharOffsetStore(directoryURL: progressDir)

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        // ── Phase 7 A/B 分支 ─────────────────────────────────────────────
        self.onlineBuilder = nil
        let newEngine: CoreTextPageEngine
        if GlobalSettings.shared.useRenderableNodePipeline {
            let builder = EPUBAttributedStringBuilder(session: session, renderSize: effectiveSize)
            self.epubBuilder = builder
            newEngine = CoreTextPageEngine(
                attributedBuilder: builder,
                renderSettings: settings,
                offsetStore: store
            )
            self.scrollEngine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        } else {
            // 雖然 paged 引擎走 resourceProvider 路徑，但捲動模式仍需要 AttributedStringBuilding。
            // 額外建一個 EPUB builder 給 scrollEngine 用（兩條路徑共享同一個 PublicationSession）。
            let builder = EPUBAttributedStringBuilder(session: session, renderSize: effectiveSize)
            self.epubBuilder = builder
            newEngine = CoreTextPageEngine(
                resourceProvider: ReadiumBookResourceAdapter(session: session),
                renderSettings: settings,
                offsetStore: store
            )
            self.scrollEngine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        }

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
        let builder = TXTAttributedStringBuilder(chapters: chapters)
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
        let docsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let progressDir = docsURL.appendingPathComponent(
            "epub_charoffsets/\(bookIdentifier)"
        )
        let store = CharOffsetStore(directoryURL: progressDir)
        let newEngine = CoreTextPageEngine(
            attributedBuilder: attributedBuilder,
            renderSettings: settings,
            offsetStore: store
        )
        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        self.epubBuilder = nil
        self.onlineBuilder = nil
        self.scrollEngine = CoreTextScrollEngine(builder: attributedBuilder, renderSettings: settings)
        isCoreTextReady = false

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        if effectiveSize.width > 0 {
            let startUptime = ProcessInfo.processInfo.systemUptime
            logProgress("loadTXT start bookId=\(bookIdentifier) renderSize=\(effectiveSize)")
            Task {
                await newEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
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
        customScheme: String = "reader-online"
    ) {
        let docsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let progressDir = docsURL.appendingPathComponent(
            "epub_charoffsets/\(bookIdentifier)"
        )
        let store = CharOffsetStore(directoryURL: progressDir)
        let resourceAdapter = UniversalBookResourceAdapter(
            contentProvider: contentProvider,
            chapterSourceHrefs: chapterSourceHrefs,
            customScheme: customScheme
        )
        let newEngine = CoreTextPageEngine(
            resourceProvider: resourceAdapter,
            renderSettings: settings,
            offsetStore: store
        )
        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        // 線上書：另建一個 OnlineProviderAttributedStringBuilder 給 scrollEngine 使用。
        let effectiveSizeForBuilder = renderSize.width > 0 ? renderSize : lastViewportSize
        let onlineBuilder = OnlineProviderAttributedStringBuilder(
            provider: contentProvider,
            renderSize: effectiveSizeForBuilder
        )
        self.onlineBuilder = onlineBuilder
        self.scrollEngine = CoreTextScrollEngine(builder: onlineBuilder, renderSettings: settings)
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
        // Phase 7: EPUB builder が deferred start 前に作成された時のために renderSize を更新
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

    // MARK: - Progress persistence

    /// Called at page-turn time when the spine is guaranteed to be loaded.
    /// Caches the stable (spineIndex, charOffset) for use in syncProgress.
    func updateCurrentPosition(globalPage: Int, engine eng: any PageRenderingProvider) {
        currentEpubPage = globalPage
        let (spine, offset) = eng.charOffset(forPage: globalPage)
        savedSpineIndex = spine
        savedCharOffset = offset
        logProgress("updateCurrentPosition globalPage=\(globalPage) spine=\(spine) charOffset=\(offset)")
    }

    /// Saves a CharOffsetRecord for the given bookId.
    func syncProgress(bookId: String) {
        guard let eng = engine else { return }
        // Use position cached at navigation time — more reliable than converting
        // from currentEpubPage now, because spinePageOffsets may have shifted.
        let record = CharOffsetRecord(
            bookId: bookId,
            spineIndex: savedSpineIndex,
            charOffset: savedCharOffset,
            timestamp: Date()
        )
        eng.offsetStore.save(record)
        logProgress("syncProgress bookId=\(bookId) globalPage=\(currentEpubPage) spine=\(savedSpineIndex) charOffset=\(savedCharOffset)")
    }

    /// Flushes pending saves synchronously.
    func flushProgress(bookId: String) {
        engine?.offsetStore.flushSync()
        logProgress("flushProgress bookId=\(bookId)")
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
}
