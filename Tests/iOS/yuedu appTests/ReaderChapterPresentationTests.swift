import Testing
@testable import yuedu_app

@Suite("ReaderChapterPresentation", .serialized)
struct ReaderChapterPresentationTests {

    @Test("manual refresh relayouts validated cache without fetching")
    func manualRefreshRelayoutsValidatedCache() {
        #expect(
            ReaderChapterPresentation.manualRefreshAction(isContentAvailable: true)
                == .relayoutCachedContent
        )
    }

    @Test("manual refresh fetches only when current content is missing")
    func manualRefreshFetchesMissingContent() {
        #expect(
            ReaderChapterPresentation.manualRefreshAction(isContentAvailable: false)
                == .fetchMissingContent
        )
    }

    @Test("content availability suppresses overlays")
    func contentAvailabilitySuppressesOverlays() {
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: true, loadState: .loading) == ReaderChapterOverlayState.hidden)
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: true, loadState: .failed(reason: "err")) == ReaderChapterOverlayState.hidden)
    }

    @Test("missing content shows loading for idle and loading")
    func missingContentShowsLoadingForIdleAndLoading() {
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: false, loadState: .idle) == ReaderChapterOverlayState.loading)
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: false, loadState: .loading) == ReaderChapterOverlayState.loading)
    }

    @Test("missing content shows failure for failed reason")
    func missingContentShowsFailureForFailedReason() {
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: false, loadState: .failed(reason: "network")) == ReaderChapterOverlayState.failed(message: "network"))
    }

    @Test("ready on current triggers correct refresh action")
    func readyOnCurrentTriggersCorrectRefreshAction() {
        #expect(ReaderChapterPresentation.refreshAction(changedChapterIndex: 3, currentChapterIndex: 3, usesCoreText: true, newState: .ready, isContentAvailable: true) == ReaderChapterRefreshAction.notifyChapterDataChanged(3))
        #expect(ReaderChapterPresentation.refreshAction(changedChapterIndex: 4, currentChapterIndex: 4, usesCoreText: false, newState: .ready, isContentAvailable: true) == ReaderChapterRefreshAction.rebuildPages)
    }

    @Test("ready without validated content does not auto-refetch")
    func readyWithoutValidatedContentDoesNotAutoRefetch() {
        #expect(ReaderChapterPresentation.refreshAction(changedChapterIndex: 5, currentChapterIndex: 5, usesCoreText: true, newState: .ready, isContentAvailable: false) == ReaderChapterRefreshAction.none)
    }

    @Test("different indices return none")
    func differentIndicesReturnNone() {
        #expect(ReaderChapterPresentation.refreshAction(changedChapterIndex: 2, currentChapterIndex: 3, usesCoreText: true, newState: .ready, isContentAvailable: true) == ReaderChapterRefreshAction.none)
    }

    @Test("ready but missing content shows recoverable failure")
    func readyButMissingContentShowsRecoverableFailure() {
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: false, loadState: .ready) == ReaderChapterOverlayState.failed(message: "資料不一致，請點擊重試"))
    }
}
