import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Logic
    func findChapterFirstPage(_ chapterIdx: Int) -> Int? {
        return allPages.firstIndex(where: { $0.chapterIndex == chapterIdx })
    }

    func jumpToBookmark(_ bookmark: Bookmark) {
        let position = bookmark.position
        guard chapters.indices.contains(position.spineIndex) else { return }
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            currentChapterIndex = position.spineIndex
            scrollVisibleChapter = position.spineIndex
            pendingScrollJumpTarget = position
            moveReaderSession(to: position, source: .jump)
            scrollResliceToken &+= 1
            return
        }
        jumpToChapter(position.spineIndex, charOffset: position.charOffset)
    }

    /// 標註所在章節內的頁碼（1-based）；CoreText 引擎不可用時回傳 nil。
    func inChapterPageNumber(for bookmark: Bookmark) -> Int? {
        guard usesCoreTextEPUB, let engine = epubRenderer.engine else { return nil }
        let position = bookmark.position
        if let layout = engine.layouts[position.spineIndex] {
            return layout.pageIndex(for: position.charOffset) + 1
        }
        // 章節尚未排版：用引擎相同的保守估算（~400 字/頁）。
        return max(0, position.charOffset / 400) + 1
    }

    /// 從清單刪除一筆書籤或標註；標註需同步重繪 overlay。
    func deleteBookmarkEntry(_ bookmark: Bookmark) {
        store.removeBookmark(bookId: bookId, bookmarkId: bookmark.id)
        if bookmark.kind == .underline || bookmark.kind == .highlight {
            syncCoreTextTextAnnotations()
        }
    }

    /// Navigate to a TOC entry, honoring its in-spine anchor so sub-sections of one spine file
    /// land on their own page instead of the file's start.
    func jumpToTOCEntry(_ chapter: BookChapter) {
        let position = tocPosition(for: chapter, engine: epubRenderer.engine)
        jumpToChapter(position.spineIndex, charOffset: position.charOffset)
    }

    func jumpToChapter(_ idx: Int, charOffset: Int = 0) {
        guard chapters.indices.contains(idx) else { return }
        if effectiveScrollMode, epubRenderer.scrollEngine != nil {
            let position = CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset)
            currentChapterIndex = idx
            scrollVisibleChapter = idx
            pendingScrollJumpTarget = position
            moveReaderSession(to: position, source: .jump)
            scrollResliceToken &+= 1
            ensureChapterReady(chapterIndex: idx, priority: .jump)
            return
        }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let position = CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset)
            AppLogger.render("[FlipTrace] ReaderView.jumpToChapter request spine=\(idx) charOffset=\(charOffset) layoutReady=\(engine.layouts[idx] != nil)")
            ensureReaderNavigator(initialPosition: position)
            setCoreTextExternalTarget(position)
            _ = engine.pageViewController(for: position)
            currentChapterIndex = idx
            if let exactPage = engine.pageIndex(for: position) {
                currentPage = exactPage
                moveReaderSession(to: position, source: .jump, pageIndex: exactPage, totalPages: engine.totalPages)
                AppLogger.render("[FlipTrace] ReaderView.jumpToChapter exact spine=\(idx) page=\(exactPage)")
            } else if let estimatedPage = engine.estimatedGlobalPage(for: position) {
                currentPage = estimatedPage
                moveReaderSession(
                    to: position,
                    source: .jump,
                    pageIndex: estimatedPage,
                    totalPages: engine.totalPages,
                    isEstimated: true
                )
                AppLogger.render("[FlipTrace] ReaderView.jumpToChapter placeholder spine=\(idx) page=\(estimatedPage)")
            } else {
                moveReaderSession(to: position, source: .jump)
            }
            epubRenderer.currentEpubPage = currentPage
            let alreadyReady = readerViewModel.chapterState(for: idx) == .ready
            ensureChapterReady(chapterIndex: idx, priority: .jump)
            if alreadyReady, isChapterContentAvailable(at: idx) {
                Task { await engine.notifyChapterDataChanged(at: idx) }
            }
            if idx > 0 { Task { await engine.preloadChapter(at: idx - 1) } }
            if idx < chapters.count - 1 { Task { await engine.preloadChapter(at: idx + 1) } }
        } else {
            currentChapterIndex = idx
            if let p = findChapterFirstPage(idx) { currentPage = p }
            moveReaderSession(to: CoreTextReadingPosition(spineIndex: idx, charOffset: charOffset), source: .jump)
            ensureChapterReady(chapterIndex: idx, priority: .jump)
        }
    }

    func beginReadingStatsSession() {
        guard readingStatsTracker == nil, let currentBook = book else { return }
        readingStatsTracker = ReadingStatsSessionTracker(
            bookId: currentBook.id.uuidString,
            bookTitle: currentBook.title,
            startCharacterOffset: currentReadingStatsCharacterOffset()
        )
    }

    func updateReadingStatsPosition() {
        guard var tracker = readingStatsTracker else { return }
        tracker.updateVisibleCharacterOffset(currentReadingStatsCharacterOffset())
        readingStatsTracker = tracker
    }

    func recordReadingStatsPosition(
        _ position: CoreTextReadingPosition,
        source: ReaderLocation.Source
    ) {
        guard var tracker = readingStatsTracker else { return }
        let offset = readingStatsContentOffset(for: position)

        switch source {
        case .settledPage, .scrollCommit:
            tracker.updateVisibleCharacterOffset(offset)
        case .internalLink, .jump, .modeSwitch, .restored, .placeholder:
            tracker.relocate(to: offset)
        }
        readingStatsTracker = tracker
    }

    func finishReadingStatsSession() {
        guard var tracker = readingStatsTracker else { return }
        tracker.updateVisibleCharacterOffset(currentReadingStatsCharacterOffset())
        if let session = tracker.finish() {
            ReadingStatsStore.shared.recordSession(session)
        }
        readingStatsTracker = nil
    }

    func currentReadingStatsCharacterOffset() -> Int? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            if effectiveScrollMode, let location = readerSessionCoordinator?.state.location {
                return readerContentMetrics(
                    for: location.coreTextPosition,
                    engine: engine
                )?.currentUnitOffset
            }

            guard engine.totalPages > 0 else { return nil }
            let page = max(0, min(currentPage, engine.totalPages - 1))
            let position = engine.charOffset(forPage: page)
            return readerContentMetrics(
                for: CoreTextReadingPosition(
                    spineIndex: position.spineIndex,
                    charOffset: position.charOffset
                ),
                engine: engine
            )?.currentUnitOffset
        }

        guard !allPages.isEmpty else { return nil }
        let page = max(0, min(currentPage, allPages.count - 1))
        return readerOverlayLegacyContentIndex.currentUnitOffset(forPageAt: page)
    }

    func readingStatsContentOffset(for position: CoreTextReadingPosition) -> Int? {
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            return readerContentMetrics(for: position, engine: engine)?.currentUnitOffset
        }
        guard !allPages.isEmpty else { return nil }
        let page = max(0, min(currentPage, allPages.count - 1))
        return readerOverlayLegacyContentIndex.currentUnitOffset(forPageAt: page)
    }

    func readerContentMetrics(
        for position: CoreTextReadingPosition,
        engine: any PagedReaderEngine
    ) -> ReaderContentMetrics? {
        let currentChapterCharacterCount = effectiveScrollMode
            ? epubRenderer.scrollEngine?.characterCount(forChapter: position.spineIndex)
            : nil
        return engine.contentMetrics(
            forSpine: position.spineIndex,
            charOffset: position.charOffset,
            currentChapterCharacterCount: currentChapterCharacterCount
        )
    }

    func rebuildReaderOverlayLegacyContentIndex() {
        readerOverlayLegacyContentIndex = ReaderLegacyContentIndex(
            pages: allPages.map {
                ReaderLegacyContentIndex.Page(
                    chapterIndex: $0.chapterIndex,
                    contentLength: $0.content.count
                )
            }
        )
    }

    func autoSaveProgress(force: Bool = false) {
        guard !isRestoringPosition else { return }

        if effectiveScrollMode {
            AppLogger.render("autoSave scroll visibleChapter=\(scrollVisibleChapter)")
            store.updatePosition(
                bookId: bookId,
                position: Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1)),
                forceSave: force
            )
            return
        }

        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let total = engine.totalPages
            guard total > 0 else { return }
            let candidatePage: Int = {
                if currentPage == 0, engine.currentPage > 0 {
                    return engine.currentPage
                }
                return currentPage
            }()
            guard let resolved = coreTextPositionIfLayoutReady(engine: engine, page: candidatePage) else {
                AppLogger.render("autoSave coreText skipped page=\(candidatePage) reason=layoutNotReady")
                return
            }
            let spineIndex = resolved.spineIndex
            let charOffset = resolved.charOffset
            currentChapterIndex = spineIndex
            let pct = engine.totalProgress(forSpine: spineIndex, charOffset: charOffset)
            let normalized = min(1.0, max(0.0, pct))
            AppLogger.render(
                "autoSave coreText page=\(candidatePage) spine=\(spineIndex) charOffset=\(charOffset) pct=\(String(format: "%.6f", normalized))"
            )
            store.updatePosition(bookId: bookId, position: normalized, forceSave: force)
        } else if !effectiveScrollMode && !allPages.isEmpty {
            let page = allPages[min(currentPage, allPages.count - 1)]
            currentChapterIndex = page.chapterIndex
            maybeEarlyPrefetchIfNearChapterEnd()
            let progress = Double(currentPage) / Double(max(allPages.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
            AppLogger.render(
                "autoSave paged currentPage=\(currentPage) chapter=\(page.chapterIndex) pageInChapter=\(page.pageInChapter) pct=\(String(format: "%.6f", normalized))"
            )
            store.updatePosition(bookId: bookId, position: normalized, forceSave: force)
        } else {
            let progress = Double(scrollVisibleChapter) / Double(max(chapters.count - 1, 1))
            let normalized = min(1.0, max(0.0, progress))
            AppLogger.render(
                "autoSave scroll visibleChapter=\(scrollVisibleChapter) pct=\(String(format: "%.6f", normalized))"
            )
            store.updatePosition(bookId: bookId, position: normalized, forceSave: force)
        }
    }

    func saveProgress() {
        let wasRestoring = isRestoringPosition
        AppLogger.render("saveProgress begin wasRestoring=\(wasRestoring)")
        isRestoringPosition = false
        autoSaveProgress(force: true)
        isRestoringPosition = wasRestoring
        if let navigator = readerSessionCoordinator?.navigator {
            Task {
                await navigator.flush()
            }
        }
    }

    func refreshCurrentChapter() {
        guard let b = book, let refs = b.onlineChapters, !refs.isEmpty else { return }
        let idx = currentChapterIndex
        #if DEBUG
        AppLogger.render("[StateDebug] refreshCurrentChapter ch=\(idx) ← clearing ENTIRE book cache and restarting fetch")
        #endif
        // Clear all cached chapters for the entire book since the "next chapter misdetected as next page"
        // bug contaminates subsequent chapters into the current chapter's cache. Clearing just the current
        // chapter is insufficient; the whole book must be purged.
        dependencies.bookSourceFetcher.clearAllChapterCache(bookId: b.id)
        store.clearAllCachedChapterFilenames(bookId: b.id)
        for ref in refs {
            readerViewModel.resetChapterState(for: ref.index)
        }
        // Immediately invalidate the current chapter's layout and show loading UI
        // so the user doesn't continue seeing the old (concatenated) content while the refetch completes.
        if let engine = epubRenderer.engine {
            Task { await engine.notifyChapterDataChanged(at: idx) }
        }
        ensureChapterReady(chapterIndex: idx, priority: .jump)
    }

    var downloadButtonIcon: String {
        guard let b = book else { return "icloud.and.arrow.down" }
        switch b.offlineDownloadState {
        case .none, .failed:
            return "icloud.and.arrow.down"
        case .paused:
            return "arrow.clockwise.circle"
        case .downloading:
            return "pause.circle"
        case .available:
            return "checkmark.icloud"
        }
    }

    func handleDownloadAction() {
        guard book?.isOnline == true else { return }
        // All download interaction (range selection, progress, pause/resume, remove)
        // now lives inside the download sheet — open it for every state.
        showDownloadOptions = true
    }

    func startOfflineDownload(startChapterIndex: Int, chapterCount: Int) {
        guard let b = book, b.isOnline else { return }
        readerViewModel.handleDownloadAction(
            book: b,
            store: store,
            startChapterIndex: startChapterIndex,
            chapterCount: chapterCount
        )
    }

    func resumeOfflineDownload() {
        guard let b = book else { return }
        guard let task = b.offlineDownloadTask?.clamped(to: b.onlineChapters?.count ?? 0) else {
            return
        }
        let completed = task.clampedCompletedChapterCount
        let remaining = task.totalChapterCount - completed
        guard remaining > 0 else { return }
        readerViewModel.handleDownloadAction(
            book: b,
            store: store,
            startChapterIndex: task.startChapterIndex + completed,
            chapterCount: remaining
        )
    }

    func pauseOfflineDownload() {
        guard let b = book else { return }
        readerViewModel.handleDownloadAction(
            book: b,
            store: store,
            startChapterIndex: 0,
            chapterCount: nil
        )
    }

    /// Source change search has been moved to ReaderViewModel.loadOtherOrigins. This method only triggers it and passes required data.
    func loadOtherOrigins(forceRefresh: Bool = false) {
        guard let b = book, let currentSourceId = b.bookSourceId else { return }
        readerViewModel.loadOtherOrigins(
            book: b,
            currentSourceId: currentSourceId,
            enabledSources: BookSourceStore.shared.enabledSources,
            store: store,
            forceRefresh: forceRefresh
        )
    }

    /// Display name of the source the book is currently being read from.
    var currentSourceName: String {
        guard let id = book?.bookSourceId,
              let source = BookSourceStore.shared.sources.first(where: { $0.id == id }),
              !source.bookSourceName.isEmpty else { return localized("未知書源") }
        return source.bookSourceName
    }

}
