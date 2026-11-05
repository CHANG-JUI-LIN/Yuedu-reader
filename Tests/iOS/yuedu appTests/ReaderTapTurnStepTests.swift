import YueduCoreText
import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 仿真 (curl) lost its animation on a tap turn, now and then on any book and every time on
/// some pages of 剑来. A tap used to carry a destination computed from the page-number
/// binding when it landed; whenever that binding disagreed with the page on screen — it lags
/// a swipe, a chapter landing renumbers every page after it — the destination was not the
/// visible page's neighbour, and a non-neighbour was set without animation, often onto a
/// page the reader never asked for. A tap is now one step from the page on screen.
@Suite("A tap turns one page from where the reader is", .serialized)
@MainActor
struct ReaderTapTurnStepTests {

    @Test("a tap after the page number fell behind curls to the page after the one on screen")
    func staleBindingStillCurlsToTheNeighbour() async throws {
        let reader = try await TapTurnReader.open(atPage: 5)
        defer { reader.close() }
        // The binding falls behind the page on screen, as it does while a swipe settles or
        // after an earlier chapter's layout renumbers the pages.
        reader.state.page = 1
        await reader.drainMainQueue()

        // What `ReaderView.goToNextPage` issues from that binding.
        reader.state.turn(.forward, showing: 2, animated: true)
        let animated = try await reader.waitForTurn(to: 6)

        #expect(reader.shownPage() == 6, "the tap landed on \(String(describing: reader.shownPage()))")
        #expect(animated, "the tap turned without the curl animation")
    }

    @Test("taps while a curl is still playing add a page each")
    func tapsDuringCurlAccumulate() async throws {
        let reader = try await TapTurnReader.open(atPage: 5)
        defer { reader.close() }

        reader.state.turn(.forward, showing: 6, animated: true)
        try await reader.waitUntil { reader.isAnimating() }
        reader.state.turn(.forward, showing: 7, animated: true)
        _ = try await reader.waitForTurn(to: 7)

        #expect(reader.shownPage() == 7, "two taps landed on \(String(describing: reader.shownPage()))")
    }

    /// Fast tapping runs ahead of loading: the next chapter's layout has not landed, and
    /// the page turned to is its 載入中 page. The curl's back was named from the page
    /// before the target, which a loading page does not have, so the turn ran without
    /// the curl. Forward, the sheet lifted is the page on screen.
    ///
    /// A loading page has nothing laid out to step through, so a further tap is refused
    /// until the chapter lands — as a swipe from it is. Taps used to walk on through the
    /// chapter's estimated pages by index, and through the next chapter when that one
    /// was estimated at a single page (回饋中心 #140).
    @Test("a tap into a chapter still loading curls onto its start and waits there")
    func tapsIntoLoadingChapterCurl() async throws {
        let gate = ChapterLoadGate()
        let reader = try await TapTurnReader.open(builder: TapTurnBuilder(loading: (1, gate)), preloading: [0]) {
            $0.layouts[0].map { $0.pageRanges.count - 1 }
        }
        defer { gate.open(); reader.close() }
        let lastPage = try #require(reader.shownPage())

        let animated = try await reader.tapOntoLoadingPage(.forward, landingOn: lastPage + 1)
        #expect(animated, "the tap into the loading chapter turned without the curl animation")
        #expect(reader.shownPosition() == .chapterStart(1))

        reader.state.turn(.forward, showing: lastPage + 2, animated: true)
        await reader.drainMainQueue()
        try await reader.waitUntil { !reader.isAnimating() && !reader.isTurning() }
        #expect(reader.shownPosition() == .chapterStart(1),
                "a tap from the loading page moved to \(String(describing: reader.shownPosition()))")

        gate.open()
        let chapterStart = try await reader.waitForLayout(of: 1)
        try await reader.waitUntil { reader.shownPage() == chapterStart }
        reader.state.turn(.forward, showing: chapterStart + 1, animated: true)
        #expect(try await reader.waitForTurn(to: chapterStart + 1), "the turn after the chapter landed did not curl")
    }

    /// Backward, the sheet lifted is the target: the loading chapter's last page knows it
    /// is the chapter's end, and nothing before it can be named until the chapter lands.
    @Test("a tap back into a chapter still loading curls onto its end and waits there")
    func tapsBackIntoLoadingChapterCurl() async throws {
        let gate = ChapterLoadGate()
        // Chapter 0 is the one the engine lays out to start, so the gated chapter is 1.
        let reader = try await TapTurnReader.open(builder: TapTurnBuilder(loading: (1, gate)), preloading: [0, 2]) {
            $0.pageIndex(for: .chapterStart(2))
        }
        defer { gate.open(); reader.close() }
        let firstPage = try #require(reader.shownPage())

        let animated = try await reader.tapOntoLoadingPage(.backward, landingOn: firstPage - 1)
        #expect(animated, "the tap back into the loading chapter turned without the curl animation")
        #expect(reader.shownPosition() == .chapterEnd(1))

        reader.state.turn(.backward, showing: firstPage - 2, animated: true)
        await reader.drainMainQueue()
        try await reader.waitUntil { !reader.isAnimating() && !reader.isTurning() }
        #expect(reader.shownPosition() == .chapterEnd(1),
                "a tap from the loading page moved to \(String(describing: reader.shownPosition()))")
    }

    /// 回饋中心 #140, #119, #70: "才看到31章一下次就给我跳到112章去了". An online book's
    /// chapters have no size until they are fetched, so each one not laid out yet is
    /// estimated at a single page. A tap stepped the global index by one from the turn
    /// still playing, so a burst of taps at a chapter's end walked one index per chapter
    /// through the chapters still loading and settled chapters later
    /// (ReaderPositionSentry: (19, 2385) → (22, 0), the page drawn as
    /// `renderSnapshot MISS noLayout page=158 spine=22`).
    @Test("taps past a chapter's last page stop on the next chapter while it loads")
    func tapsPastChapterEndStopOnTheNextChapter() async throws {
        let gate = ChapterLoadGate()
        let reader = try await TapTurnReader.open(
            builder: TapTurnBuilder(chapterCount: 5, loading: ([1, 2], gate), unsized: [1, 2]),
            preloading: [0]
        ) {
            $0.layouts[0].map { $0.pageRanges.count - 1 }
        }
        defer { gate.open(); reader.close() }
        let lastPage = try #require(reader.shownPage())

        reader.state.turn(.forward, showing: lastPage + 1, animated: true)
        try await reader.waitUntil { reader.isAnimating() }
        reader.state.turn(.forward, showing: lastPage + 2, animated: true)
        await reader.drainMainQueue()
        reader.state.turn(.forward, showing: lastPage + 3, animated: true)
        await reader.drainMainQueue()
        try await reader.waitUntil { !reader.isAnimating() && !reader.isTurning() }
        await reader.drainMainQueue()

        #expect(reader.shownPosition() == .chapterStart(1),
                "three taps past 第1章's end landed on \(String(describing: reader.shownPosition()))")

        gate.open()
        let chapterStart = try await reader.waitForLayout(of: 1)
        try await reader.waitUntil { reader.shownPage() == chapterStart }
        #expect(reader.shownPosition() == .chapterStart(1))
    }

    /// The second jump in #140: after a 目錄 jump the reader was on 第31章 when 第112章
    /// laid out. Every page after the chapter that landed was renumbered, the page
    /// number went to the host alone, and the host read it back as 第112章 and moved
    /// the reader there. A chapter landing away from the page on screen renumbers the
    /// pages but does not move the reader, so what goes out is the page on screen.
    @Test("a chapter landing away from the page on screen reports that page by its position")
    func distantChapterLandingKeepsThePosition() async throws {
        let reader = try await TapTurnReader.open(
            builder: TapTurnBuilder(chapterCount: 5, loading: nil, unsized: [1]),
            preloading: [4]
        ) {
            $0.pageIndex(for: .chapterStart(4)).map { $0 + 2 }
        }
        defer { reader.close() }
        let shown = try #require(reader.shownPosition())
        let pageBefore = try #require(reader.engine.pageIndex(for: shown))
        reader.state.reported.removeAll()

        // 第2章 is estimated at one page until it lays out; it is a dozen.
        _ = await reader.engine.preloadChapter(at: 1)
        let pageAfter = try #require(reader.engine.pageIndex(for: shown))
        try #require(pageAfter != pageBefore, "the landing chapter did not renumber the page on screen")
        try await reader.waitUntil { reader.state.page == pageAfter }
        await reader.drainMainQueue()

        #expect(!reader.state.reported.isEmpty, "the renumbered page was never reported")
        for report in reader.state.reported {
            #expect(report.position == shown,
                    "page \(report.page) went out as \(String(describing: report.position)), not the page on screen \(shown)")
        }
        #expect(reader.shownPosition() == shown)
    }
}

/// The paged host as `ReaderView` mounts it, with a real session coordinator so turns queue
/// the way they do in the app.
@MainActor
private final class TapTurnReader {
    let state: TapTurnHostState
    let engine: CoreTextPageEngine
    private let coordinator: ReaderSessionCoordinator
    private let host: UIHostingController<TapTurnHost>
    private let window: UIWindow
    private let directory: URL

    private init(state: TapTurnHostState, engine: CoreTextPageEngine, coordinator: ReaderSessionCoordinator,
                 host: UIHostingController<TapTurnHost>, window: UIWindow, directory: URL) {
        self.state = state
        self.engine = engine
        self.coordinator = coordinator
        self.host = host
        self.window = window
        self.directory = directory
    }

    static func open(atPage page: Int) async throws -> TapTurnReader {
        try await open { _ in page }
    }

    static func open(builder: TapTurnBuilder = TapTurnBuilder(), preloading chapters: [Int] = [0, 1],
                     at openingPage: (CoreTextPageEngine) -> Int?) async throws -> TapTurnReader {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        let bookId = UUID().uuidString
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: bookId)
        for chapter in chapters {
            _ = await engine.preloadChapter(at: chapter)
        }
        let page = try #require(openingPage(engine))
        let opening = try #require(engine.readingPosition(forPage: page))
        try #require(engine.pageIndex(for: opening) == page)
        engine.updateReadingPosition(opening)

        let coordinator = ReaderSessionCoordinator(navigator: ReaderNavigator(
            initialState: ReaderPresentationState(
                location: .chapterStart(0), direction: .ltr, spreadMode: .singlePage,
                viewportSize: CGSize(width: 320, height: 480),
                appearance: ReaderAppearance(theme: .sepia, fontSize: 17, lineHeightMultiple: 1.5,
                    lineSpacing: 0, paragraphSpacing: 8, letterSpacing: 0, marginH: 0, marginV: 0,
                    footerHeight: 0, writingMode: .horizontal),
                pagingStyle: .curl),
            positionStore: TapTurnPositionStore(), bookId: bookId))
        let state = TapTurnHostState(target: opening, page: page)
        let host = UIHostingController(rootView: TapTurnHost(state: state, engine: engine, coordinator: coordinator))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let reader = TapTurnReader(state: state, engine: engine, coordinator: coordinator, host: host,
                                   window: window, directory: directory)
        try await reader.waitUntil { state.externalTarget == nil && reader.shownPage() == page && !reader.isAnimating() }
        return reader
    }

    func close() {
        window.isHidden = true
        try? FileManager.default.removeItem(at: directory)
    }

    private var pageViewController: UIPageViewController? {
        host.firstDescendant(UIPageViewController.self)
    }

    func shownPage() -> Int? {
        (pageViewController?.viewControllers?.first as? CoreTextReadingPositionProviding)?
            .coreTextReadingPosition.flatMap { engine.pageIndex(for: $0) }
    }

    /// The position of the page on screen, laid out or 載入中.
    func shownPosition() -> CoreTextReadingPosition? {
        (pageViewController?.viewControllers?.first as? CoreTextReadingPositionProviding)?.coreTextReadingPosition
    }

    /// Whether a turn is still playing or queued.
    func isTurning() -> Bool {
        coordinator.isPageTransitioning
    }

    /// Waits for the chapter to lay out; returns its first page.
    func waitForLayout(of chapter: Int) async throws -> Int {
        try await waitUntil { engine.layouts[chapter] != nil }
        return try #require(engine.pageIndex(for: .chapterStart(chapter)))
    }

    /// The page a 載入中 page on screen stands for; a page with no layout has no position to ask.
    func loadingPageIndex() -> Int? {
        (pageViewController?.viewControllers?.first as? PlaceholderPageViewController)?.globalPageIndex
    }

    /// Taps once, as `ReaderView` issues it, and waits for the turn to settle on the
    /// 載入中 page `page`; returns whether it animated on the way.
    func tapOntoLoadingPage(_ step: ReaderPageTurnCommand.Step, landingOn page: Int) async throws -> Bool {
        state.turn(step, showing: page, animated: true)
        var animated = false
        try await waitUntil {
            animated = animated || isAnimating()
            return loadingPageIndex() == page && !isAnimating()
        }
        return animated
    }

    /// The curl animates layers inside the page view controller's view, not the view itself.
    /// A 載入中 page's spinner spins for as long as it shows; it is not a turn.
    func isAnimating() -> Bool {
        func animating(_ layer: CALayer) -> Bool {
            guard !(layer.delegate is UIActivityIndicatorView) else { return false }
            return !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: animating)
        }
        return pageViewController.map { animating($0.view.layer) } ?? false
    }

    /// Waits for the turn to settle on `page`; returns whether it animated on the way.
    func waitForTurn(to page: Int) async throws -> Bool {
        var animated = false
        try await waitUntil {
            animated = animated || isAnimating()
            return shownPage() == page && !isAnimating()
        }
        return animated
    }

    func drainMainQueue() async {
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for the paged host")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class TapTurnHostState: ObservableObject {
    @Published var externalTarget: CoreTextReadingPosition?
    @Published var page: Int
    @Published private(set) var command: ReaderPageTurnCommand?
    /// Every page change the host was told about, as `ReaderView` receives them.
    var reported: [(page: Int, position: CoreTextReadingPosition?)] = []
    private var version: UInt = 0

    init(target: CoreTextReadingPosition, page: Int) {
        externalTarget = target
        self.page = page
    }

    /// Issued the way `ReaderView.issuePageTurn` does.
    func turn(_ step: ReaderPageTurnCommand.Step, showing page: Int, animated: Bool) {
        self.page = page
        version &+= 1
        command = ReaderPageTurnCommand(step: step, animated: animated, version: version)
    }
}

private struct TapTurnHost: View {
    @ObservedObject var state: TapTurnHostState
    let engine: any PageRenderingProvider
    let coordinator: ReaderSessionCoordinator

    var body: some View {
        CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: coordinator, externalTargetVersion: 0, externalTargetPosition: state.externalTarget,
            pageTurnCommand: state.command, clearExternalTargetPosition: { state.externalTarget = nil },
            currentPage: $state.page,
            onPageChanged: { page, position in state.reported.append((page, position)) }, onTapZone: { _ in }
        )
    }
}

private final class TapTurnPositionStore: ReadingPositionStore, @unchecked Sendable {
    private var storage: [String: CoreTextReadingPosition] = [:]
    func save(_ position: CoreTextReadingPosition, for bookId: String) async { storage[bookId] = position }
    func load(for bookId: String) async -> CoreTextReadingPosition? { storage[bookId] }
    func loadSync(for bookId: String) -> CoreTextReadingPosition? { storage[bookId] }
    func flush(for bookId: String) async {}
}

/// Chapters of plain prose, a dozen pages each.
private actor TapTurnBuilder: AttributedStringBuilding {
    nonisolated let chapterCount: Int
    /// Chapters that stay 載入中 until the gate opens.
    nonisolated let loading: (chapters: Set<Int>, gate: ChapterLoadGate)?
    /// Chapters whose size is unknown until they are fetched, as an online book's are:
    /// each is estimated at one page until it lays out.
    nonisolated let unsized: Set<Int>

    init(chapterCount: Int = 3, loading: (chapter: Int, gate: ChapterLoadGate)? = nil) {
        self.init(chapterCount: chapterCount, loading: loading.map { ([$0.chapter], $0.gate) }, unsized: [])
    }

    init(chapterCount: Int, loading: (chapters: Set<Int>, gate: ChapterLoadGate)?, unsized: Set<Int>) {
        self.chapterCount = chapterCount
        self.loading = loading
        self.unsized = unsized
    }

    /// Sizes are known up front, as an EPUB's are, so a chapter not laid out yet is
    /// estimated at many pages rather than one — unless it is `unsized`.
    nonisolated var prefersLazyByteScan: Bool { false }
    nonisolated func chapterTitle(at index: Int) -> String { "第\(index + 1)章" }
    func chapterDataSize(at index: Int) -> Int { unsized.contains(index) ? 0 : Self.text(of: index).utf8.count }
    private nonisolated static func text(of index: Int) -> String {
        String(repeating: "第\(index + 1)章的正文，風穿過山林，江水映著月光。\n", count: 240)
    }
    nonisolated func buildChapter(at index: Int, settings: ReaderRenderSettings,
                                  themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        if let loading, loading.chapters.contains(index) {
            await loading.gate.wait()
        }
        return AttributedChapterBuildResult(attributedString: NSAttributedString(string: Self.text(of: index), attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: themeTextColor,
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
    }
}

/// Holds a chapter's build until the test lets it finish.
private final class ChapterLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isOpen else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiting.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiting
        waiting.removeAll()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

private extension UIViewController {
    func firstDescendant<T: UIViewController>(_ type: T.Type) -> T? {
        for child in children {
            if let match = (child as? T) ?? child.firstDescendant(type) { return match }
        }
        return nil
    }
}
