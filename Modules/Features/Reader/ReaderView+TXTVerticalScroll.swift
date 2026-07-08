import SwiftUI
import UIKit

extension ReaderView {

    // MARK: - TXT Vertical Scroll Mode
    @ViewBuilder
    var scrollBody: some View {
        if let scrollEngine = epubRenderer.scrollEngine {
            let initialPos = computeScrollInitialPosition()
            CoreTextScrollHostView(
                engine: scrollEngine,
                axis: scrollAxis,
                horizontalInset: effectivePageMarginH,
                verticalInset: scrollAxis.isHorizontalRTL
                    ? ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
                    : readerConfig.pageMarginV,
                bottomMargin: scrollAxis.isHorizontalRTL
                    ? ReaderLayoutMetrics.bottomInset(
                        safeBottom: 0,
                        footerBottomPadding: readerConfig.footerBottomPadding,
                        footerTextGap: readerConfig.footerTextGap
                      )
                    : 0,
                backgroundColor: readerTheme.uiBackgroundColor,
                initialChapter: initialPos.chapter,
                initialCharOffset: initialPos.charOffset,
                resliceToken: scrollResliceToken,
                playbackHighlightText: activePlaybackHighlightText,
                textAnnotations: coreTextTextAnnotations,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                },
                onProgressCommit: { position in
                    pendingScrollJumpTarget = nil
                    scrollVisibleChapter = position.spineIndex
                    currentChapterIndex = position.spineIndex
                    moveReaderSession(to: position, source: .scrollCommit)
                    let pct = epubRenderer.engine?.totalProgress(forSpine: position.spineIndex, charOffset: position.charOffset) ?? 0
                    store.updatePosition(bookId: bookId, position: pct)
                },
                onInternalLinkTap: { href in
                    if let target = ReaderHTMLUtilities.reviewTarget(fromHref: href) {
                        reviewTarget = target
                        return
                    }
                    // duokan popup footnote: show the note in place rather than jumping to the tail.
                    if let note = FootnoteStore.text(spineIndex: currentChapterIndex, href: href) {
                        footnoteItem = ReaderFootnoteItem(text: note)
                        return
                    }
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
                            scrollResliceToken &+= 1
                        }
                    }
                },
                onChapterContentRequired: { chapterIndex in
                    ensureChapterReady(chapterIndex: chapterIndex)
                }
            )
            .background(readerTheme.backgroundColor)
            .ignoresSafeArea()
            .modifier(ScrollConfigObserver(readerConfig: readerConfig, readerTheme: readerTheme) { scheduleScrollReslice() })
        } else {
            legacyScrollBody
        }
    }

    func scheduleScrollReslice() {
        guard let engine = epubRenderer.scrollEngine else { return }
        engine.updateRenderSettings(buildRenderSettings())
        scrollResliceToken &+= 1
    }

    /// Scroll mode starting position priority:
    /// 1) Paged engine ready → use current page's (spine, charOffset) (same-session switch)
    /// 2) Persisted snapshot (mode == .scroll) → restore from last exit position (cold start)
    /// 3) Fallback to currentChapterIndex / 0
    func computeScrollInitialPosition() -> (chapter: Int, charOffset: Int) {
        if let position = readerSessionCoordinator?.state.location.coreTextPosition {
            return (position.spineIndex, position.charOffset)
        }
        if let target = pendingScrollJumpTarget {
            return (target.spineIndex, target.charOffset)
        }
        return (max(0, currentChapterIndex), 0)
    }

    func buildRenderSettings() -> ReaderRenderSettings {
        let topInset = ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop)
        let bottomInset = ReaderLayoutMetrics.bottomInset(
            safeBottom: 0,
            footerBottomPadding: readerConfig.footerBottomPadding,
            footerTextGap: readerConfig.footerTextGap
        )
        return ReaderRenderSettings(
            theme: readerTheme.rawValue,
            textColor: readerTheme.uiTextColor,
            backgroundColor: readerTheme.uiBackgroundColor,
            fontSize: readerConfig.fontSize,
            lineHeightMultiple: readerConfig.lineHeightMultiple,
            lineSpacing: readerConfig.lineSpacing,
            paragraphSpacing: readerConfig.paragraphSpacing,
            letterSpacing: readerConfig.letterSpacing,
            marginH: effectivePageMarginH,
            marginV: readerConfig.pageMarginV,
            footerHeight: ReaderLayoutMetrics.footerHeight,
            contentInsets: UIEdgeInsets(
                top: topInset,
                left: effectivePageMarginH,
                bottom: bottomInset,
                right: effectivePageMarginH
            ),
            writingMode: effectiveWritingMode,
            fontPostScriptName: UserReaderFontResolver.selectedPostScriptName,
            isBold: readerConfig.readerFontBold,
            titleVisible: readerConfig.readerTitleVisible,
            titleSize: readerConfig.readerTitleSize,
            titleTopSpacing: readerConfig.readerTitleTopSpacing,
            titleBottomSpacing: readerConfig.readerTitleBottomSpacing
        )
    }

    var effectiveWritingMode: ReaderWritingMode {
        guard isVerticalEPUB || book?.allowsVerticalWritingMode == true else {
            return .horizontal
        }
        return isVerticalEPUB ? .verticalRTL : settings.readerWritingMode
    }

    var effectiveScrollMode: Bool {
        settings.scrollMode
    }

    var scrollAxis: CoreTextScrollAxis {
        effectiveWritingMode.isVertical ? .horizontalRTL : .vertical
    }

    var legacyScrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { ci, chapter in
                        Text(chapter.title.converted(to: settings.textConversion))
                            .font(.system(size: readerConfig.readerTitleSize, weight: .bold, design: .serif))
                            .foregroundColor(readerTheme.textColor)
                            .padding(.top, 80)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)
                            .id("chapter_\(ci)")
                            .onAppear { scrollVisibleChapter = ci }

                        if chapter.content.isEmpty && book?.isOnline == true {
                            VStack(spacing: 16) {
                                ProgressView()
                                Text(localized("載入章節中…"))
                                    .font(.system(size: fontSize - 2, design: .serif))
                                    .foregroundColor(readerTheme.textColor.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .onAppear { ensureChapterReady(chapterIndex: ci) }
                        } else {
                            let cleaned = chapter.content
                            let paragraphs = cleaned.converted(to: settings.textConversion)
                                .components(separatedBy: "\n").filter { !$0.isEmpty }
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                                Text(para)
                                    .font(.system(size: fontSize, design: .serif))
                                    .foregroundColor(readerTheme.textColor)
                                    .kerning(readerConfig.letterSpacing)
                                    .lineSpacing(readerConfig.lineSpacing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, readerConfig.paragraphSpacing)
                            }
                            Color.clear.frame(height: max(0, 48 - readerConfig.paragraphSpacing)).clipped()
                        }

                        Divider()
                            .padding(.horizontal, 24)
                            .opacity(0.25)
                    }
                    Color.clear.frame(height: 80)
                }
            }
            .onAppear {
                if scrollVisibleChapter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("chapter_\(scrollVisibleChapter)", anchor: .top)
                    }
                }
            }
        }
        .background(readerTheme.backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
        }
    }

    func goToPrevPage() {
        guard currentPage > 0 else { return }
        issuePageTurn(to: previousReaderPage(before: currentPage))
    }

    func goToNextPage() {
        let maxPage: Int
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            maxPage = engine.totalPages - 1
        } else {
            maxPage = allPages.count - 1
        }
        guard currentPage < maxPage else { return }
        issuePageTurn(to: nextReaderPage(after: currentPage, maxPage: maxPage))
    }

    /// Phase-2 intent channel: page turns are explicit one-shot commands consumed
    /// by the paged executor (see ReaderPageTurnCommand). `currentPage` is still
    /// written immediately — as display state and as the accumulation baseline for
    /// rapid-tap bursts — but the executor no longer treats binding drift as an
    /// instruction, so this write can never trigger a correction transition.
    func issuePageTurn(to targetPage: Int) {
        currentPage = targetPage
        pageTurnVersion &+= 1
        pageTurnCommand = ReaderPageTurnCommand(
            target: targetPage,
            animated: effectivePageTurnStyle != .none,
            version: pageTurnVersion
        )
    }

}
