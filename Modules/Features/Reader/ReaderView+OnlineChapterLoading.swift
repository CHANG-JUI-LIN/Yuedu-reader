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
                if let package = cachedChapterPackage(for: chapterIndex),
                   containsParagraphReview(in: package.content) {
                    hasParagraphReviews = true
                }
                prefetchAdjacentChapters(around: chapterIndex)
            }
            if case .failed = newState,
               manuallyRefreshingChapterIndex == chapterIndex {
                manuallyRefreshingChapterIndex = nil
            }
            applyChapterRefreshAction(for: chapterIndex, newState: newState)
        }
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
        if effectiveScrollMode, let scrollEngine = epubRenderer.scrollEngine {
            if newState == .ready, contentAvailable {
                if chapterIndex == currentChapterIndex {
                    scrollEngine.invalidateChapterDocument(at: chapterIndex)
                    scheduleScrollReslice()
                } else {
                    Task { await scrollEngine.retryChapterIfNeeded(chapterIndex) }
                }
                return
            }
        }
        let action = ReaderChapterPresentation.refreshAction(
            changedChapterIndex: chapterIndex,
            currentChapterIndex: currentChapterIndex,
            usesCoreText: usesCoreTextEPUB,
            newState: newState,
            isContentAvailable: contentAvailable
        )
        #if DEBUG
        AppLogger.render("[StateDebug] applyRefreshAction ch=\(chapterIndex) newState=\(newState) contentAvailable=\(contentAvailable) currentCh=\(currentChapterIndex) → action=\(action)")
        #endif

        switch action {
        case .none:
            break
        case .notifyChapterDataChanged(let visibleChapterIndex):
            guard let engine = epubRenderer.engine else {
                #if DEBUG
                AppLogger.render("[StateDebug] notifyChapterDataChanged SKIPPED: engine is nil")
                #endif
                return
            }
            #if DEBUG
            AppLogger.render("[StateDebug] notifyChapterDataChanged ch=\(visibleChapterIndex) launching Task")
            #endif
            Task {
                await engine.notifyChapterDataChanged(at: visibleChapterIndex)
                if self.savedCoreTextRestoreTarget != nil {
                    self.applyInitialProgressIfNeeded()
                }
                if self.manuallyRefreshingChapterIndex == visibleChapterIndex {
                    self.manuallyRefreshingChapterIndex = nil
                }
            }
        case .rebuildPages:
            #if DEBUG
            AppLogger.render("[StateDebug] rebuildPages()")
            #endif
            rebuildPages()
            if manuallyRefreshingChapterIndex == chapterIndex {
                manuallyRefreshingChapterIndex = nil
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
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(DSColor.textSecondary)
            Text(localized("章節載入失敗"))
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
            Text(localized(message))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(4)
                .multilineTextAlignment(.center)
            Button {
                retryCurrentChapterLoad()
            } label: {
                Text(localized("重試"))
                    .font(DSFont.body.weight(.semibold))
                    .padding(.horizontal, DSSpacing.lg)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    /// Surgical retry for the failed chapter only: removes that chapter's
    /// invalid artifact, clears its state, and refetches it. Other readable
    /// chapters are never purged.
    func retryCurrentChapterLoad() {
        // An explicit tap re-arms the automatic recovery below: the user asking again
        // means the previous attempt's verdict is no longer the last word.
        chapterConsistencyRecoveryAttempts[currentChapterIndex] = nil
        AppLogger.render("⟐ chapter retry tapped ch=\(currentChapterIndex)")
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
        if let engine = epubRenderer.engine {
            Task { await engine.notifyChapterDataChanged(at: idx) }
        }
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
