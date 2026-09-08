import Testing
@testable import yuedu_app

@Suite("ReaderChapterPresentation", .serialized)
struct ReaderChapterPresentationTests {

    @Test("offscreen volume and prefetched chapters do not advance the network window")
    func readyEventsPrefetchOnlyAroundVisibleChapter() {
        // Reproduces launch at chapter one (spine 3), while the volume header
        // (spine 0) publishes ready first. Its neighbors must not take the source lock.
        let centers = [0, 3, 4, 2].compactMap {
            ReaderChapterPresentation.adjacentPrefetchCenter(
                readyChapterIndex: $0, currentChapterIndex: 3
            )
        }
        #expect(centers == [3])
    }

    @Test("a previous chapter finishing after a jump does not prefetch behind the reader")
    func readyEventsUseLatestVisibleChapter() {
        #expect(ReaderChapterPresentation.adjacentPrefetchCenter(
            readyChapterIndex: 12, currentChapterIndex: 19
        ) == nil)
        #expect(ReaderChapterPresentation.adjacentPrefetchCenter(
            readyChapterIndex: 19, currentChapterIndex: 19
        ) == 19)
    }

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
