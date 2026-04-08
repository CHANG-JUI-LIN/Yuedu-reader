import Combine
import UIKit

/// CoreText-only EPUB renderer adapter.
/// WebView rendering path has been removed; all functionality routes to CoreTextPageEngine.
@MainActor
final class EPUBPageRenderer: ObservableObject {

    // MARK: - CoreText engine

    private(set) var engine: (any PageRenderingProvider)?

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
        let newEngine = CoreTextPageEngine(
            resourceProvider: ReadiumBookResourceAdapter(session: session),
            offsetStore: store
        )
        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        isCoreTextReady = false

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        if effectiveSize.width > 0 {
            Task {
                await newEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
                self.isCoreTextReady = true
            }
        } else {
            pendingStartBookId = bookIdentifier
        }
    }

    func loadTXT(
        text: String,
        title: String,
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
        let newEngine = TXTPageEngine(text: text, title: title, offsetStore: store, settings: settings)
        newEngine.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        self.engine = newEngine
        isCoreTextReady = false

        let effectiveSize = renderSize.width > 0 ? renderSize : lastViewportSize

        if effectiveSize.width > 0 {
            Task {
                await newEngine.start(renderSize: effectiveSize, bookId: bookIdentifier)
                self.isCoreTextReady = true
            }
        } else {
            pendingStartBookId = bookIdentifier
        }
    }

    /// Called by ReaderView whenever the viewport size changes.
    /// Stores the size and starts the CoreText engine if load() was called before layout.
    func notifyViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastViewportSize = size
        guard let bookId = pendingStartBookId, let eng = engine else { return }
        pendingStartBookId = nil
        Task {
            await eng.start(renderSize: size, bookId: bookId)
            self.isCoreTextReady = true
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
    }

    /// Flushes pending saves synchronously.
    func flushProgress(bookId: String) {
        engine?.offsetStore.flushSync()
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
}
