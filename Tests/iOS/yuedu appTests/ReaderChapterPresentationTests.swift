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

    @Test("cancelled shows the loading surface, never a failure")
    func cancelledShowsLoadingSurface() {
        // A preempted fetch answered nothing about the chapter. Painting 章節載入失敗 for it
        // is the spurious failure users cleared by refreshing.
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: false, loadState: .cancelled) == ReaderChapterOverlayState.loading)
    }

    @Test("ready but missing content shows recoverable failure")
    func readyButMissingContentShowsRecoverableFailure() {
        #expect(ReaderChapterPresentation.overlayState(isContentAvailable: false, loadState: .ready) == ReaderChapterOverlayState.failed(message: "資料不一致，請點擊重試"))
    }

    @Test("entering a cached chapter replaces a stale CoreText placeholder")
    func enteringCachedChapterReplacesPlaceholder() {
        #expect(
            ReaderChapterPresentation.entryRefreshAction(
                chapterIndex: 7,
                usesCoreText: true,
                loadState: .ready,
                isContentAvailable: true,
                isLayoutAvailable: false
            ) == .notifyChapterDataChanged(7)
        )
    }

    @Test("entering an already laid out chapter does not rebuild it")
    func enteringLaidOutChapterDoesNotRebuild() {
        #expect(
            ReaderChapterPresentation.entryRefreshAction(
                chapterIndex: 7,
                usesCoreText: true,
                loadState: .ready,
                isContentAvailable: true,
                isLayoutAvailable: true
            ) == .none
        )
    }

    @Test("a newly discovered cached chapter waits for its ready publication")
    func newlyDiscoveredCacheDoesNotDoubleRefresh() {
        #expect(
            ReaderChapterPresentation.entryRefreshAction(
                chapterIndex: 7,
                usesCoreText: true,
                loadState: .idle,
                isContentAvailable: true,
                isLayoutAvailable: false
            ) == .none
        )
    }
}
