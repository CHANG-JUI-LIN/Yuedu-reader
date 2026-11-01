import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Feedback #112 (網路書源 html, 無動畫翻頁): back to 書架, tap the cover, turn the page — the
/// next page shows for a frame and the reader snaps back to the page the book opened on; now
/// and then it jumps back several pages instead. The opening position reaches the paged host
/// as its external target, and the target parks a pending navigation for the case it lands on
/// a 載入中 page. When it landed on a real page, nothing took that back, so the next chapter
/// to lay out — a neighbour preloading after the opening transition — replayed the opening
/// position over every turn made since.
@Suite("The opening position is placed once", .serialized)
@MainActor
struct ReaderOpeningTargetReplayTests {

    @Test("a chapter laid out after the reader turned leaves them on the page they turned to",
          arguments: [PageTurnStyle.none, .slide])
    func chapterLandingAfterTurnKeepsTurnedPage(style: PageTurnStyle) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: OpeningTargetBuilder(chapterCount: 4),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        // Reopening: the saved chapter's text is cached, so it is laid out before the reader
        // shows and the opening position lands on a real page, not a 載入中 one.
        _ = await engine.preloadChapter(at: 2)
        let chapter = try #require(engine.layouts[2])
        try #require(chapter.pageRanges.count > 3)
        let opening = CoreTextReadingPosition(spineIndex: 2, charOffset: Int(chapter.pageRanges[1].location))
        let turnedTo = CoreTextReadingPosition(spineIndex: 2, charOffset: Int(chapter.pageRanges[2].location))
        engine.updateReadingPosition(opening)
        let openingPage = try #require(engine.pageIndex(for: opening))

        let state = OpeningHostState(target: opening, page: openingPage)
        let host = UIHostingController(rootView: OpeningPagedHost(state: state, engine: engine, style: style))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func shownPosition() -> CoreTextReadingPosition? {
            (host.firstDescendant(UIPageViewController.self)?.viewControllers?.first
                as? CoreTextReadingPositionProviding)?.coreTextReadingPosition
        }
        // 滑動 swaps the page at once and pushes it in over 0.25 s; a chapter landing inside
        // that window waits for the stack, so the turn has to be over for the landing to be
        // the one this test means.
        func turnIsOver() -> Bool {
            host.firstDescendant(UIPageViewController.self)?.view.layer.animationKeys()?.isEmpty ?? true
        }
        // The opening position is on screen and the navigator has its one-shot back.
        try await waitUntil { state.externalTarget == nil && shownPosition() == opening }

        // A tap on the next-page zone, issued the way `ReaderView.issuePageTurn` does.
        state.turn(.forward, showing: openingPage + 1, animated: style != .none)
        try await waitUntil { shownPosition() == turnedTo && turnIsOver() }

        // The neighbour that preloads once the opening transition is over lands now.
        _ = await engine.preloadChapter(at: 3)
        await drainMainQueue()

        #expect(shownPosition() == turnedTo,
                "the reader was taken back to \(String(describing: shownPosition())) after turning to \(turnedTo)")
    }

    private func drainMainQueue() async {
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
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

/// What `ReaderView` hands the paged host: the navigator's external target, cleared through
/// the host's callback, and the page-turn command a tap zone issues.
@MainActor
private final class OpeningHostState: ObservableObject {
    @Published var externalTarget: CoreTextReadingPosition?
    @Published var page: Int
    @Published private(set) var command: ReaderPageTurnCommand?
    private var version: UInt = 0

    init(target: CoreTextReadingPosition, page: Int) {
        externalTarget = target
        self.page = page
    }

    func turn(_ step: ReaderPageTurnCommand.Step, showing page: Int, animated: Bool) {
        self.page = page
        version &+= 1
        command = ReaderPageTurnCommand(step: step, animated: animated, version: version)
    }
}

private struct OpeningPagedHost: View {
    @ObservedObject var state: OpeningHostState
    let engine: any PageRenderingProvider
    let style: PageTurnStyle

    var body: some View {
        CoreTextPageEngineView(
            engine: engine, pageTurnStyle: style, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: state.externalTarget,
            pageTurnCommand: state.command, clearExternalTargetPosition: { state.externalTarget = nil },
            currentPage: $state.page,
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
    }
}

/// Online chapters: several pages each, laid out one at a time as they arrive.
private actor OpeningTargetBuilder: AttributedStringBuilding {
    nonisolated let chapterCount: Int
    init(chapterCount: Int) { self.chapterCount = chapterCount }
    nonisolated var prefersLazyByteScan: Bool { true }
    nonisolated func chapterTitle(at index: Int) -> String { "第\(index + 1)章" }
    func chapterDataSize(at index: Int) -> Int { 0 }
    nonisolated func buildChapter(at index: Int, settings: ReaderRenderSettings,
                                  themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        let text = String(repeating: "第\(index + 1)章的正文，風穿過山林，江水映著月光。\n", count: 120)
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
