import XCTest
@testable import yuedu_app

final class ReaderChapterPresentationTests: XCTestCase {

    func test_contentAvailabilitySuppressesOverlays() {
        let p1 = ReaderChapterPresentation(chapterIndex: 0, isCurrent: true, hasContent: true, isCoreText: true, loadState: .loading)
        XCTAssertEqual(p1.overlayState, .hidden)

        let p2 = ReaderChapterPresentation(chapterIndex: 0, isCurrent: true, hasContent: true, isCoreText: true, loadState: .failed(reason: "err"))
        XCTAssertEqual(p2.overlayState, .hidden)
    }

    func test_missingContentShowsLoadingForIdleAndLoading() {
        let p1 = ReaderChapterPresentation(chapterIndex: 1, isCurrent: false, hasContent: false, isCoreText: false, loadState: .idle)
        XCTAssertEqual(p1.overlayState, .loading)

        let p2 = ReaderChapterPresentation(chapterIndex: 1, isCurrent: false, hasContent: false, isCoreText: false, loadState: .loading)
        XCTAssertEqual(p2.overlayState, .loading)
    }

    func test_missingContentShowsFailureForFailedReason() {
        let p = ReaderChapterPresentation(chapterIndex: 2, isCurrent: false, hasContent: false, isCoreText: false, loadState: .failed(reason: "network"))
        XCTAssertEqual(p.overlayState, .failed(message: "network"))
    }

    func test_readyOnCurrentTriggersCorrectRefreshAction() {
        let coreText = ReaderChapterPresentation(chapterIndex: 3, isCurrent: true, hasContent: true, isCoreText: true, loadState: .ready)
        XCTAssertEqual(coreText.refreshAction, .notifyChapterDataChanged(index: 3))

        let nonCore = ReaderChapterPresentation(chapterIndex: 4, isCurrent: true, hasContent: true, isCoreText: false, loadState: .ready)
        XCTAssertEqual(nonCore.refreshAction, .rebuildPages)

        let notCurrent = ReaderChapterPresentation(chapterIndex: 5, isCurrent: false, hasContent: true, isCoreText: true, loadState: .ready)
        XCTAssertEqual(notCurrent.refreshAction, .none)
    }
}
