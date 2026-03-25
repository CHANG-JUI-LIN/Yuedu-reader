import Combine
import SwiftUI
import UIKit
import WebKit

@MainActor
final class EPUBPageRenderer: ObservableObject {
    private let engine = LiveWebReader()
    @Published var readingGate: ReadingGateState = .loading
    private lazy var snapshotWebView = EPUBSnapshotWebView(schemeHandler: engine.schemeHandler)
    private var subscriptions: Set<AnyCancellable> = []
    private var snapshotCallbacks: [Int: [(UIImage?) -> Void]] = [:]
    private var snapshotWatchers: [Int: AnyCancellable] = [:]
    private var snapshotTimeouts: [Int: DispatchWorkItem] = [:]

    init() {
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
    }

    var onRelocated: ((String, Double) -> Void)? {
        get { engine.onRelocated }
        set { engine.onRelocated = newValue }
    }

    var onTapZone: ((String) -> Void)? {
        get { engine.onTapZone }
        set { engine.onTapZone = newValue }
    }

    var isReady: Bool { engine.isReady }
    var isScrollModeEnabled: Bool { engine.scrollModeEnabled }
    var totalPages: Int { engine.totalPages }
    var renderSessionID: Int { engine.renderSessionID }
    var layoutGeneration: Int { engine.layoutGeneration }
    var webViewGeneration: Int { engine.webViewGeneration }
    var liveWebView: WKWebView? { engine.webView }
    var currentEpubPage: Int {
        get { engine.currentEpubPage }
        set {
            guard newValue != engine.currentEpubPage else { return }
            engine.goToPage(newValue)
        }
    }
    var errorMessage: String? { engine.errorMessage }
    var tocItems: [[String: Any]] { engine.tocItems }
    var tocCount: Int { engine.tocCount }
    var bookTitle: String { engine.bookTitle }
    var percentage: Double { engine.percentage }
    var currentChapterIdx: Int { engine.currentChapterIdx }
    var snapshotProgress: Double { engine.snapshotProgress }
    var isCommitting: Bool { engine.isCommitting }
    var globalPageMap: [(chapter: Int, page: Int)] { engine.globalPageMap }
    var pipelineKind: BookPipelineKind { engine.pipelineKind }

    func load(package: RenderPackage, settings: ReaderRenderSettings) {
        engine.load(package: package, settings: settings)
    }

    func load(
        publicationSession session: PublicationSession,
        bookIdentifier: String,
        settings: ReaderRenderSettings
    ) {
        engine.load(
            publicationSession: session,
            bookIdentifier: bookIdentifier,
            settings: settings
        )
    }

    func loadEPUB(source: EPUBReaderSource, settings: ReaderRenderSettings) {
        switch source {
        case .publication(let session):
            engine.setTransition("horizontal")
            engine.load(
                publicationSession: session,
                bookIdentifier: session.sourceURL.standardizedFileURL.path,
                settings: settings
            )
        }
        readingGate = .loading
        Task { [weak self] in
            guard let self else { return }
            // 等 engine 開始載入（100ms 讓 publicationSession 建立）
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.triggerReadingGate(forChapter: 0)
        }
    }

    func loadEPUBScroll(source: EPUBReaderSource, settings: ReaderRenderSettings) {
        switch source {
        case .publication(let session):
            engine.setTransition("vertical")
            engine.load(
                publicationSession: session,
                bookIdentifier: session.sourceURL.standardizedFileURL.path,
                settings: settings
            )
        }
        readingGate = .loading
        Task { [weak self] in
            guard let self else { return }
            // 等 engine 開始載入（100ms 讓 publicationSession 建立）
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.triggerReadingGate(forChapter: 0)
        }
    }

    func reloadWithUpdatedPackage(_ package: RenderPackage, settings: ReaderRenderSettings) {
        engine.reloadWithUpdatedPackage(package, settings: settings)
    }

    func goToPage(_ page: Int, completion: (() -> Void)? = nil) {
        engine.goToPage(page, completion: completion)
    }

    func goToGlobalPage(_ page: Int, completion: (() -> Void)? = nil) {
        engine.goToPage(page, completion: completion)
    }

    func jumpToChapter(_ chapterIdx: Int, preferredLocalPage: Int? = nil) {
        engine.jumpToChapter(chapterIdx, preferredLocalPage: preferredLocalPage)
        // Gate 判斷：目標章節第 0 頁截圖不存在才觸發
        let firstPage = engine.firstGlobalPage(forChapter: chapterIdx) ?? -1
        if firstPage < 0 || engine.snapshot(forPage: firstPage) == nil {
            triggerReadingGate(forChapter: chapterIdx)
        }
    }

    func chapterIndex(forGlobalPage page: Int) -> Int {
        engine.chapterIndex(forGlobalPage: page)
    }

    func localPage(forGlobalPage page: Int) -> Int {
        engine.localPage(forGlobalPage: page)
    }

    func pageCount(forChapter index: Int) -> Int {
        engine.pageCount(forChapter: index)
    }

    func firstGlobalPage(forChapter index: Int, preferredLocalPage: Int? = nil) -> Int? {
        engine.firstGlobalPage(forChapter: index, preferredLocalPage: preferredLocalPage)
    }

    func syncProgressToPage(_ page: Int, flush: Bool = false) {
        engine.syncProgressToPage(page, flush: flush)
    }

    func open(locator: ReaderLocator) {
        engine.open(locator: locator)
    }

    func flushProgress() {
        engine.flushProgress()
    }

    func setViewport(size: CGSize, safeAreaInsets: UIEdgeInsets) {
        engine.setViewport(size: size, safeAreaInsets: safeAreaInsets)
    }

    func setFontSize(_ size: CGFloat) {
        engine.setFontSize(size)
    }

    func setTheme(_ theme: String) {
        engine.setTheme(theme)
    }

    func setPageMargins(horizontal: CGFloat, vertical: CGFloat) {
        engine.setPageMargins(horizontal: horizontal, vertical: vertical)
    }

    func setTransition(_ mode: String) {
        engine.setTransition(mode)
    }

    func dragOffset(_ dx: CGFloat) {
        engine.dragOffset(dx)
    }

    func interruptAnimation() -> CGFloat? {
        engine.interruptAnimation()
    }

    func beginGestureInteraction(interruptedOffset: CGFloat? = nil) {
        engine.beginGestureInteraction(interruptedOffset: interruptedOffset)
    }

    func updateGestureInteraction() {
        engine.updateGestureInteraction()
    }

    func endGestureInteraction(targetPage: Int) {
        engine.endGestureInteraction(targetPage: targetPage)
    }

    func resetDragBase() {
        engine.resetDragBase()
    }

    func snapshot(forPage page: Int) -> UIImage? {
        engine.snapshot(forPage: page)
    }

    func pageSnapshotState(forPage page: Int) -> PageRenderState {
        engine.pageSnapshotState(forPage: page)
    }

    func prepareDisplaySnapshot(forPage page: Int, priority: Int = 0) {
        engine.prepareDisplaySnapshot(forPage: page, priority: priority)
    }

    private func triggerReadingGate(forChapter chapterIdx: Int) {
        readingGate = .loading
        snapshotWebView.cancel()
        Task { [weak self] in
            guard let self else { return }
            guard let (html, baseURL) = await self.chapterHTMLForSnapshot(at: chapterIdx) else {
                self.readingGate = .open
                return
            }
            let globalOffset = self.engine.firstGlobalPage(forChapter: chapterIdx) ?? 0
            self.snapshotWebView.loadAndCapture(
                html: html,
                baseURL: baseURL,
                globalPageOffset: globalOffset,
                onPageReady: { [weak self] globalPage, image in
                    self?.storeSnapshot(image: image, forGlobalPage: globalPage)
                },
                onGateReady: { [weak self] in
                    withAnimation(.easeOut(duration: 0.2)) {
                        self?.readingGate = .open
                    }
                }
            )
        }
    }

    func storeSnapshot(image: UIImage, forGlobalPage page: Int) {
        engine.storeSnapshot(image: image, forGlobalPage: page)
    }

    func chapterHTMLForSnapshot(at index: Int) async -> (html: String, baseURL: URL)? {
        await engine.chapterHTMLForSnapshot(at: index)
    }

    var snapshotSchemeHandler: ReaderSchemeHandler {
        engine.schemeHandler
    }

    func preloadSnapshots(around page: Int, radius: Int = 2) {
        engine.preloadSnapshots(around: page, radius: radius)
    }

    func willDisplayPage(_ page: Int, style: PageTurnStyle) {
        engine.willDisplayPage(page, style: style)
    }

    func settleInteractionPage(_ page: Int, style: PageTurnStyle) {
        engine.settleInteractionPage(page, style: style)
    }

    func cancelInteractionPage(_ page: Int, style: PageTurnStyle) {
        engine.cancelInteractionPage(page, style: style)
    }

    func turnPageProgrammatically(forward: Bool) {
        let target = currentEpubPage + (forward ? 1 : -1)
        guard target >= 0, target < totalPages else { return }
        engine.turnPageProgrammatically(forward: forward, style: .slide)
    }

    func turnPageProgrammatically(forward: Bool, style: PageTurnStyle) {
        engine.turnPageProgrammatically(forward: forward, style: style)
    }

    func themeBackgroundColor() -> UIColor {
        engine.themeBackgroundUIColor()
    }

    func requestSnapshot(for page: Int, completion: @escaping (UIImage?) -> Void) {
        if let image = engine.snapshot(forPage: page) {
            completion(image)
            return
        }

        engine.prepareDisplaySnapshot(forPage: page, priority: page == engine.currentEpubPage ? -1 : 0)

        snapshotCallbacks[page, default: []].append(completion)

        if snapshotWatchers[page] == nil {
            snapshotWatchers[page] = engine.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.resolveSnapshotIfReady(for: page)
                }
        }

        if snapshotTimeouts[page] == nil {
            let timeoutWork = DispatchWorkItem { [weak self] in
                self?.finishSnapshotRequest(for: page, image: nil)
            }
            snapshotTimeouts[page] = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: timeoutWork)
        }

        resolveSnapshotIfReady(for: page)
    }

    func cancelSnapshotRequest(for page: Int) {
        engine.cancelSnapshot(forPage: page)
        finishSnapshotRequest(for: page, image: nil)
    }

    func settleDrag(toGlobalPage page: Int, style: PageTurnStyle) {
        engine.settleDrag(toGlobalPage: page, style: style)
    }

    private func resolveSnapshotIfReady(for page: Int) {
        if let image = engine.snapshot(forPage: page) {
            finishSnapshotRequest(for: page, image: image)
            return
        }

        let state = engine.pageSnapshotState(forPage: page)
        if state == .failed {
            finishSnapshotRequest(for: page, image: nil)
        }
    }

    private func finishSnapshotRequest(for page: Int, image: UIImage?) {
        let callbacks = snapshotCallbacks.removeValue(forKey: page) ?? []
        snapshotWatchers[page]?.cancel()
        snapshotWatchers.removeValue(forKey: page)

        if let timeout = snapshotTimeouts.removeValue(forKey: page) {
            timeout.cancel()
        }

        for callback in callbacks {
            callback(image)
        }
    }
}
