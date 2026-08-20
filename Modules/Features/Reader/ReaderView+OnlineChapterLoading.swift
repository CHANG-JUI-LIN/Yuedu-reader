import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Online Chapter Lazy Loading
    func ensureChapterReady(
        chapterIndex: Int,
        priority: ChapterFetchPriority = .immediate
    ) {
        guard let currentBook = book else { return }
        #if DEBUG
        AppLogger.render("[StateDebug] ensureChapterReady ch=\(chapterIndex) priority=\(priority) currentCh=\(currentChapterIndex)")
        #endif
        Task { @MainActor in
            await readerViewModel.ensureChapterReady(
                book: currentBook,
                chapterIndex: chapterIndex,
                priority: priority,
                store: store
            )
        }
    }

    func handleChapterStateChanges(_ states: [Int: ChapterLoadState]) {
        let previousStates = observedChapterStates
        observedChapterStates = states


        for (chapterIndex, newState) in states where previousStates[chapterIndex] != newState {
            #if DEBUG
            AppLogger.render("[StateDebug] chapterStates[\(chapterIndex)] \(String(describing: previousStates[chapterIndex])) → \(newState) currentChapter=\(currentChapterIndex) usesCoreText=\(usesCoreTextEPUB) isCoreTextReady=\(epubRenderer.isCoreTextReady)")
            #endif
            // Narration stalled at a chapter boundary waits on exactly this signal.
            handleTTSChapterWaitStateChange(newState, at: chapterIndex)
            if newState == .ready {
                // A chapter that loads proves the chapter URLs are usable, so the run of
                // failures that would have implicated the table of contents is over.
                chaptersFailedSinceTOCCheck.removeAll()
                prefetchAdjacentChapters(around: chapterIndex)
            }
            if newState == .cancelled {
                reissueCancelledChapterFetch(chapterIndex)
            }
            if case .failed = newState {
                noteChapterFailureForStaleTOC(chapterIndex)
                if manuallyRefreshingChapterIndex == chapterIndex {
                    manuallyRefreshingChapterIndex = nil
                }
            }
            applyChapterRefreshAction(for: chapterIndex, newState: newState)
        }
    }

    /// Chapters fail one at a time; a stale table of contents fails all of them. Counting
    /// distinct failures is the only way to tell those apart — no single failure can.
    func noteChapterFailureForStaleTOC(_ chapterIndex: Int) {
        guard book?.isOnline == true else { return }
        chaptersFailedSinceTOCCheck.insert(chapterIndex)
        guard StaleTOCSuspicion.decide(
            distinctFailedChapters: chaptersFailedSinceTOCCheck.count,
            alreadyRevalidated: didRevalidateTOCForFailures
        ) == .revalidateTableOfContents else { return }
        revalidateTOCOnceForFailures()
    }

    /// Refetches the table of contents, then retries the chapters that failed against the old
    /// one. Once per reader session.
    ///
    /// The TOC cache is keyed by `(sourceId, url)` — it belongs to the source, not the book —
    /// so it outlives the book: deleting a book and re-adding it from 發現頁 hands back the
    /// same possibly-expired chapter URLs, which is why 移除下載 could leave a whole book
    /// failing and only 換源 (a different `sourceId`, therefore a different key) fixed it.
    /// `refreshOnlineBookMetadata` already bypasses that cache unconditionally.
    ///
    /// Strictly one shot: if a freshly fetched TOC still fails, the failure is real and the
    /// failure overlay is the honest answer. Retrying past that is the avalanche this
    /// codebase keeps having to delete.
    func revalidateTOCOnceForFailures() {
        guard !didRevalidateTOCForFailures else { return }
        guard let currentBook = book, currentBook.isOnline else { return }
        didRevalidateTOCForFailures = true

        let failedChapters = chaptersFailedSinceTOCCheck
        let bookId = currentBook.id
        AppLogger.network("⟐ several chapters failed, revalidating TOC", context: [
            "bookId": bookId.uuidString,
            "failedChapters": failedChapters.count,
        ])
        Task { @MainActor in
            do {
                // `forceInfoRefresh` too: the TOC URL itself comes from the book record, so a
                // site that moved its chapter URLs may well have moved that as well.
                _ = try await store.refreshOnlineBookMetadata(
                    bookId: bookId,
                    forceInfoRefresh: true,
                    bookSourceFetcher: dependencies.bookSourceFetcher,
                    offlineChapterStore: dependencies.offlineChapterStore
                )
            } catch {
                AppLogger.network("⟐ TOC revalidation failed", error: error, context: [
                    "bookId": bookId.uuidString,
                ])
                return
            }
            // The budget was spent on URLs that are now replaced; leaving it would quarantine
            // the book for failures the new table of contents may well not repeat.
            await dependencies.chapterFetcher.resetFailureBudget(for: bookId)
            chaptersFailedSinceTOCCheck.removeAll()
            for index in failedChapters {
                readerViewModel.resetChapterState(for: index)
            }
            ensureChapterReady(chapterIndex: currentChapterIndex, priority: .jump)
        }
    }

    /// A cancelled fetch answered nothing, so the chapter is still wanted. Ask again rather
    /// than leaving the reader on a loading surface nothing will ever resolve — that was the
    /// second way 載入中 became permanent, and unlike the placeholder one it left no trace.
    ///
    /// This cannot loop: `ensureChapterReady` returns early while a request is in flight, and
    /// the only remaining canceller is a same-chapter priority upgrade, which installs its
    /// replacement in the same step. Limited to chapters somebody is actually waiting on —
    /// a cancelled prefetch for a chapter nobody has reached is work that should stay dropped.
    func reissueCancelledChapterFetch(_ chapterIndex: Int) {
        guard chapterIndex == currentChapterIndex || chapterIndex == ttsPendingChapterIndex
        else { return }
        AppLogger.render("⟐ chapter fetch cancelled, re-requesting ch=\(chapterIndex)")
        ensureChapterReady(chapterIndex: chapterIndex, priority: .jump)
    }

    func applyChapterRefreshAction(for chapterIndex: Int, newState: ChapterLoadState) {
        let contentAvailable = isChapterContentAvailable(at: chapterIndex)
        if newState == .ready {
            if contentAvailable {
                chapterConsistencyRecoveryAttempts[chapterIndex] = nil
            } else {
                if manuallyRefreshingChapterIndex == chapterIndex {
                    manuallyRefreshingChapterIndex = nil
                }
                if chapterIndex == currentChapterIndex {
                    recoverInconsistentChapterOnce(chapterIndex)
                }
            }
        }
        #if DEBUG
        AppLogger.render("[StateDebug] applyRefreshAction ch=\(chapterIndex) newState=\(newState) contentAvailable=\(contentAvailable) currentCh=\(currentChapterIndex)")
        #endif

        guard newState == .ready, contentAvailable else { return }
        guard epubRenderer.engine != nil || epubRenderer.scrollEngine != nil else {
            if chapterIndex == currentChapterIndex {
                rebuildPages()
                if manuallyRefreshingChapterIndex == chapterIndex {
                    manuallyRefreshingChapterIndex = nil
                }
            }
            return
        }
        if effectiveScrollMode, let scrollEngine = epubRenderer.scrollEngine {
            // A chapter arriving is a data event: each chapter is independent and none
            // supersedes another. Feed the engine directly so it can never be cancelled
            // by the next chapter's refresh — that is what left the visible chapter
            // stranded on its 載入中 placeholder when several chapters landed at once
            // (opening a book loads N, N-1 and N+1 together). Fall back to a refresh only
            // when the engine had nothing pending and this is the chapter on screen.
            let renderer = epubRenderer
            let fallbackRequest = chapterIndex == currentChapterIndex
                ? chapterContentRefreshRequest(chapterIndex: chapterIndex)
                : nil
            Task { @MainActor in
                let didRetry = await scrollEngine.retryChapterIfNeeded(chapterIndex)
                if !didRetry, let fallbackRequest {
                    _ = await renderer.refresh(fallbackRequest)
                }
                if manuallyRefreshingChapterIndex == chapterIndex {
                    manuallyRefreshingChapterIndex = nil
                }
            }
            return
        }
        submitChapterContentRefresh(chapterIndex: chapterIndex)
    }

    func chapterContentRefreshRequest(chapterIndex: Int) -> ReaderRenderRefreshRequest {
        ReaderRenderRefreshRequest(
            intent: .chapterContent(chapterIndex),
            mode: activeReaderDisplayMode,
            settings: activeReaderRenderSettings,
            position: currentReaderRefreshPosition,
            viewportSize: currentReaderRenderSize
        )
    }

    /// Hands a chapter's newly available content to the renderer, then — only for the
    /// chapter on screen — asks for the visible page to be re-placed against it.
    ///
    /// Supply and visible refresh are deliberately separate. A refresh transaction is
    /// latest-wins: `beginRefreshTransaction` cancels the previous preparation task and
    /// calls `engine.cancelPendingWork()`. Driving the supply from inside one therefore let
    /// a chapter's arrival cancel its neighbour's mid-load — and `notifyChapterDataChanged`
    /// clears the old layout *before* rebuilding it, so the victim was left with no layout,
    /// no `onChapterReady`, and nothing that would ever ask again. The visible chapter then
    /// sat on its 載入中 placeholder until the book was reopened or the chapter re-entered
    /// from another one. Opening an online book triggers this every time: N, N-1 and N+1
    /// land together and each used to submit its own refresh.
    ///
    /// The scroll engine was already fixed this way; this is the paged half of the rule.
    func submitChapterContentRefresh(chapterIndex: Int) {
        guard epubRenderer.engine != nil || epubRenderer.scrollEngine != nil else { return }
        let renderer = epubRenderer
        let pagedEngine = epubRenderer.engine
        // Snapshot before any await: the request carries position, settings and viewport
        // as they are at the moment the chapter arrived.
        let request = chapterContentRefreshRequest(chapterIndex: chapterIndex)
        let isVisibleChapter = chapterIndex == currentChapterIndex
        Task { @MainActor in
            // Per-chapter, idempotent, outside every transaction: no other chapter can
            // cancel it.
            if let pagedEngine {
                await pagedEngine.notifyChapterDataChanged(at: chapterIndex)
            }
            guard isVisibleChapter else {
                if manuallyRefreshingChapterIndex == chapterIndex {
                    manuallyRefreshingChapterIndex = nil
                }
                return
            }
            let result = await renderer.refresh(request)
            guard manuallyRefreshingChapterIndex == chapterIndex else { return }
            switch result {
            case .completed, .failed:
                manuallyRefreshingChapterIndex = nil
            case .superseded:
                break
            }
        }
    }

    /// 移除下載 deleted every cached chapter of this book while the reader is open. The load
    /// states still claim `.ready`, and against an empty cache that pair renders as
    /// 資料不一致 — with nothing to clear it, because no state transitioned and no chapter
    /// was entered. Drop the states the files backed, then refetch what is on screen.
    func handleOnlineChapterCacheCleared() {
        AppLogger.cache("⟐ offline cache cleared, resetting chapter states", context: [
            "chapter": currentChapterIndex,
        ])
        readerViewModel.resetAllChapterStates()
        chapterConsistencyRecoveryAttempts.removeAll()
        // Resetting alone would leave the overlay spinning forever: nothing else refetches
        // a chapter whose state merely went back to `.idle`.
        ensureChapterReady(chapterIndex: currentChapterIndex, priority: .jump)
    }

    // MARK: - Failure Surface

    /// Shown when the current chapter's fetch failed (`.failed` state, or
    /// ready-but-empty cache). Loading deliberately has NO overlay; only
    /// failures surface, with the reason and a MANUAL retry — no auto-retry,
    /// because rate-limited sources (起點代理限流) would avalanche.
    @ViewBuilder
    func chapterLoadFailureOverlay(message: String) -> some View {
        let repairSource = androidIdentityRepairCandidate(failureMessage: message)
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(DSColor.textSecondary)
                .accessibilityHidden(true)
            Text(localized("章節載入失敗"))
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text(localized(message))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(4)
                .multilineTextAlignment(.center)
            if let repairSource {
                // The source asked for a device id and got none, and the toggle that
                // fixes it lives in 書源編輯 → 基本 — unreachable from here. Offer it
                // where the failure is. See `AndroidIdentityRecovery`.
                Text(localized("此書源要求裝置識別碼，目前沒有提供給它"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    enableAndroidIdentityAndRetry(source: repairSource)
                } label: {
                    Text(localized("提供裝置識別碼並重試"))
                        .font(DSFont.body.weight(.semibold))
                        .padding(.horizontal, DSSpacing.lg)
                }
                .buttonStyle(.borderedProminent)
                // 重試 steps back to secondary here: retrying without the device id
                // repeats the request the source just refused.
                retryChapterButton.buttonStyle(.bordered)
            } else {
                retryChapterButton.buttonStyle(.borderedProminent)
            }
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    /// Unstyled so the caller can set its prominence — the failure card demotes it
    /// when there is a repair worth tapping first.
    private var retryChapterButton: some View {
        Button {
            retryCurrentChapterLoad()
        } label: {
            Text(localized("重試"))
                .font(DSFont.body.weight(.semibold))
                .padding(.horizontal, DSSpacing.lg)
        }
    }

    /// The book's source when 提供裝置識別碼 is the plausible repair for this
    /// failure — the only case where the failure card offers more than 重試.
    func androidIdentityRepairCandidate(failureMessage: String) -> BookSource? {
        guard let book, book.isOnline,
              let source = AndroidIdentityRecovery.source(withId: book.bookSourceId),
              AndroidIdentityRecovery.canRepair(source, failureMessage: failureMessage)
        else { return nil }
        return source
    }

    /// Turn the opt-in on for this source, then run the same surgical retry the
    /// 重試 button does — the refused request's cached artifact has to go, or the
    /// retry would replay the error the source already stored.
    func enableAndroidIdentityAndRetry(source: BookSource) {
        AndroidIdentityRecovery.enable(source)
        retryCurrentChapterLoad()
    }

    /// Surgical retry for the failed chapter only: removes that chapter's
    /// invalid artifact, clears its state, and refetches it. Other readable
    /// chapters are never purged.
    func retryCurrentChapterLoad() {
        // An explicit tap re-arms the automatic recovery below: the user asking again
        // means the previous attempt's verdict is no longer the last word.
        chapterConsistencyRecoveryAttempts[currentChapterIndex] = nil
        AppLogger.render("⟐ chapter retry tapped ch=\(currentChapterIndex)")
        // The quarantine budget is cumulative across chapters and only ever cleared by a
        // success, so a book that once failed five times carries that verdict forever. An
        // explicit tap says the verdict is stale. Only the manual button does this — the
        // automatic recovery below must not, or the threshold would never mean anything.
        if let bookId = book?.id {
            Task { @MainActor in
                await dependencies.chapterFetcher.resetFailureBudget(for: bookId)
                store.clearAutomaticQuarantine(bookId: bookId)
            }
        }
        refetchChapter(at: currentChapterIndex)
    }

    /// `.ready` with nothing readable on disk means the load state and the cache disagree —
    /// exactly what the manual 重試 button already resolves, which is why users found that
    /// "刷新一下就好了". Do that refetch for them, but only once per chapter: a chapter that
    /// reports the mismatch again after a full refetch is genuinely broken, and the failure
    /// overlay is the honest answer. Looping instead would restore the endless spinner this
    /// overlay replaced.
    func recoverInconsistentChapterOnce(_ chapterIndex: Int) {
        guard chapterConsistencyRecoveryAttempts[chapterIndex, default: 0] == 0 else { return }
        chapterConsistencyRecoveryAttempts[chapterIndex] = 1
        AppLogger.cache("⟐ chapterState/cache mismatch, auto refetch", context: [
            "index": chapterIndex,
        ])
        refetchChapter(at: chapterIndex)
    }

    private func refetchChapter(at idx: Int) {
        guard let currentBook = book else { return }
        dependencies.bookSourceFetcher.clearChapterCache(
            bookId: currentBook.id,
            chapterIndex: idx
        )
        store.clearCachedChapter(bookId: currentBook.id, chapterIndex: idx)
        readerViewModel.resetChapterState(for: idx)
        // .jump = user-initiated highest priority; preempts any stale in-flight.
        ensureChapterReady(chapterIndex: idx, priority: .jump)
    }

    func prefetchAdjacentChapters(around chapterIndex: Int) {
        guard let b = book, b.isOnline else { return }
        readerViewModel.prefetchAround(book: b, center: chapterIndex, store: store)
    }

    /// When the user scrolls past the last 25% of the current chapter, trigger next chapter prefetch early.
    /// This provides more buffer time compared to waiting until the last page.
    func maybeEarlyPrefetchIfNearChapterEnd() {
        guard let b = book, b.isOnline,
              let refs = b.onlineChapters else { return }
        let chIdx = currentChapterIndex
        let nextIdx = chIdx + 1
        guard refs.indices.contains(nextIdx) else { return }

        // Skip if the next chapter is already cached.
        guard !dependencies.bookSourceFetcher.isChapterCached(
            bookId: b.id, chapterIndex: nextIdx,
            expectedSourceURL: nil, expectedTOCTitle: nil) else { return }

        // Check if we're past 75% of the current chapter's pages.
        let pagesInChapter = allPages.filter { $0.chapterIndex == chIdx }
        guard !pagesInChapter.isEmpty else { return }
        let currentPageInChapter = allPages.indices.contains(currentPage)
            ? allPages[currentPage].pageInChapter : 0
        guard currentPageInChapter >= (pagesInChapter.count * 3) / 4 else { return }

        readerViewModel.prefetchAround(book: b, center: chIdx, store: store)
    }

}
