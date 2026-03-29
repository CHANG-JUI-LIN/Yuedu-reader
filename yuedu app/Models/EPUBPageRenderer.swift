import Combine
import UIKit
import WebKit

/// Thin adapter that keeps the existing public interface ReaderView depends on while
/// also exposing a CoreTextPageEngine for the CoreText rendering path.
///
/// The web rendering path (LiveWebReader) is preserved unchanged so that the
/// existing useWebRenderer flow in ReaderView continues to compile and work.
@MainActor
final class EPUBPageRenderer: ObservableObject {

    // MARK: - Web renderer (existing path)

    private let webEngine = LiveWebReader()
    private var subscriptions: Set<AnyCancellable> = []

    // MARK: - CoreText engine (new path)

    private(set) var engine: CoreTextPageEngine?

    /// Returns the CoreTextPageEngine as a PageRenderingProvider when available.
    var pageRenderingProvider: PageRenderingProvider? { engine }

    // MARK: - Init

    init() {
        webEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
    }

    // MARK: - Published / computed properties (delegates to web engine)

    var onRelocated: ((String, Double) -> Void)? {
        get { webEngine.onRelocated }
        set { webEngine.onRelocated = newValue }
    }

    var onTapZone: ((String) -> Void)? {
        get { webEngine.onTapZone }
        set { webEngine.onTapZone = newValue }
    }

    var isReady: Bool { webEngine.isReady }
    var isScrollModeEnabled: Bool { webEngine.scrollModeEnabled }
    var totalPages: Int { webEngine.totalPages }
    var renderSessionID: Int { webEngine.renderSessionID }
    var layoutGeneration: Int { webEngine.layoutGeneration }
    var webViewGeneration: Int { webEngine.webViewGeneration }
    var liveWebView: WKWebView? { webEngine.webView }
    var currentEpubPage: Int {
        get { webEngine.currentEpubPage }
        set {
            guard newValue != webEngine.currentEpubPage else { return }
            webEngine.goToPage(newValue)
        }
    }
    var errorMessage: String? { webEngine.errorMessage }
    var tocItems: [[String: Any]] { webEngine.tocItems }
    var tocCount: Int { webEngine.tocCount }
    var bookTitle: String { webEngine.bookTitle }
    var percentage: Double { webEngine.percentage }
    var currentChapterIdx: Int { webEngine.currentChapterIdx }
    var snapshotProgress: Double { webEngine.snapshotProgress }
    var isCommitting: Bool { webEngine.isCommitting }

    // MARK: - Load methods

    func load(package: RenderPackage, settings: ReaderRenderSettings) {
        webEngine.load(package: package, settings: settings)
    }

    /// Web renderer path — delegates to LiveWebReader.
    func load(
        publicationSession session: PublicationSession,
        bookIdentifier: String,
        settings: ReaderRenderSettings
    ) {
        webEngine.load(
            publicationSession: session,
            bookIdentifier: bookIdentifier,
            settings: settings
        )
    }

    /// CoreText path — creates a CoreTextPageEngine and kicks off async loading.
    /// Call this when you want to use the CoreText renderer instead of the web renderer.
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
        let newEngine = CoreTextPageEngine(session: session, offsetStore: store)
        self.engine = newEngine
        Task {
            await newEngine.start(renderSize: renderSize, bookId: bookIdentifier)
        }
    }

    func reloadWithUpdatedPackage(_ package: RenderPackage, settings: ReaderRenderSettings) {
        webEngine.reloadWithUpdatedPackage(package, settings: settings)
    }

    // MARK: - Navigation

    func goToPage(_ page: Int, completion: (() -> Void)? = nil) {
        webEngine.goToPage(page, completion: completion)
    }

    func jumpToChapter(_ chapterIdx: Int, preferredLocalPage: Int? = nil) {
        webEngine.jumpToChapter(chapterIdx, preferredLocalPage: preferredLocalPage)
    }

    func chapterIndex(forGlobalPage page: Int) -> Int {
        webEngine.chapterIndex(forGlobalPage: page)
    }

    func localPage(forGlobalPage page: Int) -> Int {
        webEngine.localPage(forGlobalPage: page)
    }

    func pageCount(forChapter index: Int) -> Int {
        webEngine.pageCount(forChapter: index)
    }

    func firstGlobalPage(forChapter index: Int, preferredLocalPage: Int? = nil) -> Int? {
        webEngine.firstGlobalPage(forChapter: index, preferredLocalPage: preferredLocalPage)
    }

    // MARK: - Progress persistence

    func syncProgressToPage(_ page: Int, flush: Bool = false) {
        webEngine.syncProgressToPage(page, flush: flush)
    }

    func flushProgress() {
        webEngine.flushProgress()
    }

    /// CoreText progress persistence: saves a CharOffsetRecord for the given bookId.
    func syncProgress(bookId: String) {
        guard let eng = engine else { return }
        let (spineIndex, charOffset) = eng.charOffset(forPage: eng.currentPage)
        let record = CharOffsetRecord(
            bookId: bookId,
            spineIndex: spineIndex,
            charOffset: charOffset,
            timestamp: Date()
        )
        eng.offsetStore.save(record)
    }

    /// CoreText progress persistence: flushes pending saves synchronously.
    func flushProgress(bookId: String) {
        engine?.offsetStore.flushSync()
    }

    // MARK: - Viewport / layout settings

    func setViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) {
        webEngine.setViewport(size: size, safeAreaInsets: safeAreaInsets)
    }

    func setFontSize(_ size: CGFloat) {
        webEngine.setFontSize(size)
        // Invalidate CoreText layout when font size changes.
        if let eng = engine {
            Task { await eng.invalidateLayout(newSize: eng.renderSize) }
        }
    }

    func setTheme(_ theme: String) {
        webEngine.setTheme(theme)
        // Apply theme to CoreText engine without re-paginating body text.
        if let eng = engine {
            eng.applyThemeChange(textColor: .label, backgroundColor: .systemBackground)
        }
    }

    func setPageMargins(horizontal: CGFloat, vertical: CGFloat) {
        webEngine.setPageMargins(horizontal: horizontal, vertical: vertical)
    }

    func setTransition(_ mode: String) {
        webEngine.setTransition(mode)
    }

    // MARK: - Gesture / animation passthrough

    func dragOffset(_ dx: CGFloat) {
        webEngine.dragOffset(dx)
    }

    func interruptAnimation() -> CGFloat? {
        webEngine.interruptAnimation()
    }

    func beginGestureInteraction(interruptedOffset: CGFloat? = nil) {
        webEngine.beginGestureInteraction(interruptedOffset: interruptedOffset)
    }

    func updateGestureInteraction() {
        webEngine.updateGestureInteraction()
    }

    func endGestureInteraction(targetPage: Int) {
        webEngine.endGestureInteraction(targetPage: targetPage)
    }

    func resetDragBase() {
        webEngine.resetDragBase()
    }

    // MARK: - Snapshot / display

    func snapshot(forPage page: Int) -> UIImage? {
        webEngine.snapshot(forPage: page)
    }

    func pageSnapshotState(forPage page: Int) -> PageRenderState {
        webEngine.pageSnapshotState(forPage: page)
    }

    func prepareDisplaySnapshot(forPage page: Int, priority: Int = 0) {
        webEngine.prepareDisplaySnapshot(forPage: page, priority: priority)
    }

    func preloadSnapshots(around page: Int, radius: Int = 2) {
        webEngine.preloadSnapshots(around: page, radius: radius)
    }

    func willDisplayPage(_ page: Int, style: PageTurnStyle) {
        webEngine.willDisplayPage(page, style: style)
    }

    func settleInteractionPage(_ page: Int, style: PageTurnStyle) {
        webEngine.settleInteractionPage(page, style: style)
    }

    func cancelInteractionPage(_ page: Int, style: PageTurnStyle) {
        webEngine.cancelInteractionPage(page, style: style)
    }

    func turnPageProgrammatically(forward: Bool) {
        let target = currentEpubPage + (forward ? 1 : -1)
        guard target >= 0, target < totalPages else { return }
        webEngine.turnPageProgrammatically(forward: forward, style: .slide)
    }

    func turnPageProgrammatically(forward: Bool, style: PageTurnStyle) {
        webEngine.turnPageProgrammatically(forward: forward, style: style)
    }

    func themeBackgroundColor() -> UIColor {
        webEngine.themeBackgroundUIColor()
    }

    func requestSnapshot(for page: Int, completion: @escaping (UIImage?) -> Void) {
        if let image = webEngine.snapshot(forPage: page) {
            completion(image)
            return
        }

        webEngine.prepareDisplaySnapshot(
            forPage: page,
            priority: page == webEngine.currentEpubPage ? -1 : 0
        )

        var attempts = 0
        func poll() {
            if let image = self.webEngine.snapshot(forPage: page) {
                completion(image)
                return
            }
            if attempts >= 20 {
                completion(nil)
                return
            }
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                poll()
            }
        }
        poll()
    }

    func cancelSnapshotRequest(for page: Int) {
        webEngine.cancelSnapshot(forPage: page)
    }

    func settleDrag(toGlobalPage page: Int, style: PageTurnStyle) {
        webEngine.settleDrag(toGlobalPage: page, style: style)
    }
}
