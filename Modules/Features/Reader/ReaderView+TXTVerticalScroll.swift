import YueduCoreText
import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - Continuous reading (all text sources)
    /// Mounted only once the book has its engines: before that, `buildBody` shows the
    /// no-engine surface both modes share.
    @ViewBuilder
    var scrollBody: some View {
        if let scrollEngine = epubRenderer.scrollEngine, epubRenderer.scrollSegmentIsPending {
            // The host is built on its segment's axis, never built on the book's and turned: the
            // segment of the chapter it opens on is decided first. The loading surface stands over this.
            Color.clear
                .task(id: ObjectIdentifier(scrollEngine)) {
                    _ = await epubRenderer.enterScrollSegment(containing: computeScrollInitialPosition().chapter)
                }
        } else if let scrollEngine = epubRenderer.scrollEngine {
            let initialPos = computeScrollInitialPosition()
            CoreTextScrollHostView(
                engine: scrollEngine,
                axis: scrollAxis,
                sideInsets: effectivePageMargins,
                // Vertical writing scrolls sideways, so its columns simply end short of the
                // bars, at the insets paged mode lays out to. They were sized from the safe
                // area alone and started under the header, and ran on under the footer
                // (2026-10-15).
                verticalInset: scrollAxis.isHorizontalRTL
                    ? readerBarContentInsets.top
                    : readerConfig.pageMarginV,
                bottomMargin: scrollAxis.isHorizontalRTL ? readerBarContentInsets.bottom : 0,
                barInsets: scrollAxis.isHorizontalRTL ? .zero : readerScrollBarInsets,
                autoScrollHandle: autoScrollHandle,
                backgroundColor: readerScrollBackgroundColor,
                initialChapter: initialPos.chapter,
                initialCharOffset: initialPos.charOffset,
                navigationRequest: scrollNavigationRequest,
                playbackHighlight: activePlaybackHighlight,
                textAnnotations: coreTextTextAnnotations,
                visibleRefreshCommit: epubRenderer.pendingVisibleRefreshCommit,
                onVisibleRefreshFinished: { transactionID, outcome in
                    epubRenderer.finishVisibleRefresh(
                        transactionID: transactionID,
                        outcome: outcome
                    )
                },
                onTap: { toggleReaderChrome() },
                onUserScrollBegan: { hideReaderChromeForPageTurn() },
                onProgressCommit: { position in
                    guard ReaderProgressSyncPolicy.canPublishIndexPosition(
                        isTXT: book?.resolvedPipelineKind == .txt, indexReady: txtIndexReady
                    ) else { return }
                    if pendingScrollJumpTarget != nil { pendingScrollJumpTarget = nil }
                    let change: ReaderChapterPresentationState.Change?
                    if usesSessionLocalScrollProgress {
                        change = chapterPresentation.commitScrollChapter(position.spineIndex,
                            controlsVisible: showBars || showTOC || showTTSPanel || showAIAssistantPanel)
                    } else {
                        change = nil
                        scrollVisibleChapter = position.spineIndex
                        currentChapterIndex = position.spineIndex
                    }
                    moveReaderSession(to: position, source: .scrollCommit)
                    if change?.any == true { handleReaderPositionChangedForTTS() }
                    if change?.visible == true, let session = activePublicationSession {
                        Task { await backgroundAudioCoordinator.update(session: session, chapterIndex: position.spineIndex) }
                    }
                    // Persist progress on every settled gesture as before. Only
                    // broad UI invalidation is omitted; bars observe the session.
                    let pct = epubRenderer.engine?.totalProgress(forSpine: position.spineIndex, charOffset: position.charOffset) ?? 0
                    store.updatePosition(bookId: bookId, position: pct,
                                         notifyLibraryViews: !usesSessionLocalScrollProgress)
                },
                onInternalLinkTap: { href in
                    if let target = ReaderHTMLUtilities.reviewTarget(fromHref: href) {
                        // Sources that build their review URL in jsLib (同人小说网) resolve through
                        // their own runtime first; `reviewTarget` only ever holds a real URL.
                        guard target.requiresSourceJS else {
                            reviewTarget = target
                            return
                        }
                        Task { @MainActor in
                            reviewTarget = try? await LegadoReviewActionRunner.shared.resolve(target)
                        }
                        return
                    }
                    // Footnotes never reach here: `CoreTextCollectionScrollViewController`
                    // intercepts them at the tap and presents the anchored popover,
                    // where the marker's rect is known.
                    Task {
                        guard let targetPage = await epubRenderer.resolveInternalLink(href, fromSpineIndex: currentChapterIndex),
                              let pagedEngine = epubRenderer.engine else { return }
                        let (spine, charOffset) = pagedEngine.charOffset(forPage: targetPage)
                        await MainActor.run {
                            let position = CoreTextReadingPosition(spineIndex: spine, charOffset: charOffset)
                            moveReaderSession(
                                to: position,
                                source: .internalLink,
                                pageIndex: targetPage,
                                totalPages: pagedEngine.totalPages
                            )
                            currentChapterIndex = spine
                            scrollVisibleChapter = spine
                            pendingScrollJumpTarget = position
                            requestScrollNavigation(to: position)
                        }
                    }
                },
                onChapterContentRequired: { chapterIndex in
                    ensureChapterReady(chapterIndex: chapterIndex)
                },
                // Scrolling past a segment's edge goes to the chapter beyond it, as 下一章 would.
                onSegmentBoundary: { spine in jumpToChapter(spine) }
            )
            .id(ObjectIdentifier(scrollEngine))
            .background(readerSurfaceBackground)
            .ignoresSafeArea()
        }
    }

    /// Every caller has moved the reader's session to `position` first.
    func requestScrollNavigation(to position: CoreTextReadingPosition) {
        Task { @MainActor in
            // A chapter of another writing mode is in another segment. Entering it changes the scroll
            // settings' mode, and the refresh that change submits lays the segment out at the session's
            // position: one reslice, at `position`.
            guard await epubRenderer.enterScrollSegment(containing: position.spineIndex) == .unchanged else { return }
            scrollNavigationVersion &+= 1
            scrollNavigationRequest = ReaderScrollNavigationRequest(
                version: scrollNavigationVersion,
                position: position
            )
        }
    }

    var usesSessionLocalScrollProgress: Bool {
        ReaderProgressSyncPolicy.usesSessionLocalScrollProgress(
            isScrollMode: effectiveScrollMode, hasScrollEngine: epubRenderer.scrollEngine != nil
        )
    }

    /// The session owns the canonical character position in every rendering mode.
    /// A pending target is used only before that session has been constructed.
    func computeScrollInitialPosition() -> (chapter: Int, charOffset: Int) {
        if let position = readerSessionCoordinator?.state.location.coreTextPosition {
            return (position.spineIndex, position.charOffset)
        }
        if let target = pendingScrollJumpTarget {
            return (target.spineIndex, target.charOffset)
        }
        return (max(0, currentChapterIndex), 0)
    }

    /// Which way the book reads. A publisher EPUB's is its own, resolved before its first layout
    /// (`EPUBPageRenderer.bookDirection`); a book that follows 排版方向 reads the way the setting lays it
    /// out, read live so the toggle turns it.
    var bookDirection: BookDirection {
        if let direction = epubRenderer.bookDirection { return direction }
        return BookDirection(uniform: book?.allowsVerticalWritingMode == true ? settings.readerWritingMode : .horizontal)
    }

    var effectiveScrollMode: Bool {
        settings.scrollMode
    }

    /// The mode scroll mode lays chapters out in: the segment's on screen, else the book's.
    var scrollWritingMode: ReaderWritingMode {
        epubRenderer.scrollSegmentMode ?? bookDirection.principalMode
    }

    var scrollAxis: CoreTextScrollAxis {
        scrollWritingMode.isVertical ? .horizontalRTL : .vertical
    }

    func goToPrevPage() {
        guard currentPage > 0 else { return }
        autoReader.resetReveal()
        issuePageTurn(.backward, showing: previousReaderPage(before: currentPage))
    }

    /// 自動閱讀's page advance: instant, and it reports the end of the book so the
    /// mode can end itself.
    @discardableResult
    func advanceAutoReadPage() -> Bool {
        let maxPage: Int
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            maxPage = engine.totalPages - 1
        } else {
            maxPage = allPages.count - 1
        }
        guard currentPage < maxPage else { return false }
        issuePageTurn(.forward, showing: nextReaderPage(after: currentPage, maxPage: maxPage), animated: false)
        return true
    }

    func goToNextPage() {
        let maxPage: Int
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            maxPage = engine.totalPages - 1
        } else {
            maxPage = allPages.count - 1
        }
        guard currentPage < maxPage else { return }
        autoReader.resetReveal()
        issuePageTurn(.forward, showing: nextReaderPage(after: currentPage, maxPage: maxPage))
    }

    /// Phase-2 intent channel: page turns are explicit one-shot commands consumed
    /// by the paged executor (see ReaderPageTurnCommand). The command is a step; the
    /// executor decides the page from what is on screen when it runs.
    /// - Parameter page: written to `currentPage` at once, so the page number follows
    ///   the tap. It is display state only — the executor never reads it, and the
    ///   page that settles is published back over it.
    /// - Parameter animated: overrides the reader's own page-turn animation.
    ///   自動閱讀 passes `false`: its curtain *is* the animation, and running the
    ///   reader's 仿真／覆蓋／滑動 underneath it would be two transitions at once —
    ///   legado bypasses its `PageDelegate` for the same reason.
    func issuePageTurn(_ step: ReaderPageTurnCommand.Step, showing page: Int, animated: Bool? = nil) {
        currentPage = page
        pageTurnVersion &+= 1
        pageTurnCommand = ReaderPageTurnCommand(
            step: step,
            animated: animated ?? (effectivePageTurnStyle != .none),
            version: pageTurnVersion
        )
    }

}
