import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 回饋中心 #118: back from the background the reader re-lays out its chapters, and an
/// earlier chapter can land after the visible page was put on screen, with a page count
/// different from its estimate. Every global page index after it shifts, and the page
/// on screen keeps the index it was built under. The curl data source stepped from that
/// index, so the next turn skipped pages or landed in the previous chapter. A page's
/// neighbours must come from its reading position, which survives repagination.
@Suite("Curl neighbours after repagination", .serialized)
@MainActor
struct CurlRepaginationNeighbourTests {
    @Test("curl steps one page in reading order after an earlier chapter repaginates", arguments: [false, true])
    func curlNeighboursFollowReadingPosition(isRTL: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Chapter 1 is a run of one-character lines: its real page count is far above
        // any estimate made from its size.
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: [
                String(repeating: "Opening page.\n", count: 20),
                String(repeating: "一\n", count: 600),
                String(repeating: "Reading page.\n", count: 120),
            ]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        await engine.preloadChapter(at: 2)

        // The visible pages are built before chapter 1 lands, as on returning to the app.
        let chapterStart = try #require(engine.pageIndex(for: .chapterStart(2)))
        let firstPage = engine.pageViewController(at: chapterStart)
        let visible = engine.pageViewController(at: chapterStart + 2)
        let visiblePosition = try #require((visible as? CoreTextReadingPositionProviding)?.coreTextReadingPosition)
        let firstPosition = try #require((firstPage as? CoreTextReadingPositionProviding)?.coreTextReadingPosition)
        #expect(visiblePosition.spineIndex == 2)

        await engine.preloadChapter(at: 1)
        let visiblePage = try #require(engine.pageIndex(for: visiblePosition))
        // Without a shift this test proves nothing.
        try #require(visiblePage != (visible as? any PageIndexProviding)?.globalPageIndex)

        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .curl, theme: .white, playbackHighlight: nil,
            isRTL: isRTL, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(visiblePage),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.isDoubleSided = true
        func forward(_ page: UIViewController) -> UIViewController? {
            isRTL ? coordinator.pageViewController(pvc, viewControllerBefore: page)
                  : coordinator.pageViewController(pvc, viewControllerAfter: page)
        }
        func backward(_ page: UIViewController) -> UIViewController? {
            isRTL ? coordinator.pageViewController(pvc, viewControllerAfter: page)
                  : coordinator.pageViewController(pvc, viewControllerBefore: page)
        }
        func pageIndex(of page: UIViewController?) -> Int? {
            (page as? CoreTextReadingPositionProviding)?.coreTextReadingPosition
                .flatMap { engine.pageIndex(for: $0) }
        }

        // Forward: the back of the visible page, then the page after it.
        let forwardBack = try #require(forward(visible) as? PageBackViewController)
        #expect(forwardBack.globalPageIndex == visiblePage)
        let next = forward(forwardBack)
        #expect(pageIndex(of: next) == visiblePage + 1)
        #expect((next as? CoreTextReadingPositionProviding)?.coreTextReadingPosition?.spineIndex == 2)

        // Backward: the back of the page before, then that page.
        let backwardBack = try #require(backward(visible) as? PageBackViewController)
        #expect(backwardBack.globalPageIndex == visiblePage - 1)
        let previous = backward(backwardBack)
        #expect(pageIndex(of: previous) == visiblePage - 1)
        #expect((previous as? CoreTextReadingPositionProviding)?.coreTextReadingPosition?.spineIndex == 2)

        // Only a chapter's first page turns back into the previous chapter, onto its last page.
        let chapterFirstPage = try #require(engine.pageIndex(for: firstPosition))
        let crossingBack = try #require(backward(firstPage) as? PageBackViewController)
        #expect(crossingBack.globalPageIndex == chapterFirstPage - 1)
        let previousChapterEnd = backward(crossingBack)
        #expect(pageIndex(of: previousChapterEnd) == chapterFirstPage - 1)
        #expect((previousChapterEnd as? CoreTextReadingPositionProviding)?.coreTextReadingPosition?.spineIndex == 1)
    }
}
