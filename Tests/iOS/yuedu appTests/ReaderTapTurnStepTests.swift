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
}

/// The paged host as `ReaderView` mounts it, with a real session coordinator so turns queue
/// the way they do in the app.
@MainActor
private final class TapTurnReader {
    let state: TapTurnHostState
    let engine: CoreTextPageEngine
    private let host: UIHostingController<TapTurnHost>
    private let window: UIWindow
    private let directory: URL

    private init(state: TapTurnHostState, engine: CoreTextPageEngine, host: UIHostingController<TapTurnHost>,
                 window: UIWindow, directory: URL) {
        self.state = state
        self.engine = engine
        self.host = host
        self.window = window
        self.directory = directory
    }

    static func open(atPage page: Int) async throws -> TapTurnReader {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CoreTextPageEngine(
            attributedBuilder: TapTurnBuilder(),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        let bookId = UUID().uuidString
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: bookId)
        _ = await engine.preloadChapter(at: 0)
        _ = await engine.preloadChapter(at: 1)
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
        let reader = TapTurnReader(state: state, engine: engine, host: host, window: window, directory: directory)
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

    /// The curl animates layers inside the page view controller's view, not the view itself.
    func isAnimating() -> Bool {
        func animating(_ layer: CALayer) -> Bool {
            !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: animating)
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
            onPageChanged: { _, _ in }, onTapZone: { _ in }
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

/// Two chapters of plain prose, a dozen pages each.
private actor TapTurnBuilder: AttributedStringBuilding {
    nonisolated let chapterCount = 2
    nonisolated var prefersLazyByteScan: Bool { true }
    nonisolated func chapterTitle(at index: Int) -> String { "第\(index + 1)章" }
    func chapterDataSize(at index: Int) -> Int { 0 }
    nonisolated func buildChapter(at index: Int, settings: ReaderRenderSettings,
                                  themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        let text = String(repeating: "第\(index + 1)章的正文，風穿過山林，江水映著月光。\n", count: 240)
        return AttributedChapterBuildResult(attributedString: NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: themeTextColor,
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
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
