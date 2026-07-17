import SwiftUI
import UIKit

extension ReaderView {

    @ViewBuilder
    var readerChrome: some View {
        switch settings.appearanceReaderInterface {
        case .classic:
            topBar
            bottomBar
        case .appleBooks:
            EmptyView()
        }
    }

    var showsAppleBooksToolbars: Bool {
        showBars && settings.appearanceReaderInterface == .appleBooks
    }

    var showsAppleBooksBottomToolbar: Bool {
        showsAppleBooksToolbars && appleBooksActivePanel == nil
    }

    @ToolbarContentBuilder
    var appleBooksToolbarContent: some ToolbarContent {
        if settings.appearanceReaderInterface == .appleBooks {
            ToolbarItem(placement: .principal) {
                Text(appleBooksPagesLeftText)
                    .font(DSFont.subheadline)
                    .foregroundStyle(readerTheme.textColor.opacity(0.62))
                    .lineLimit(1)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appleBooksActivePanel = nil
                    closeReader()
                } label: {
                    Label(localized("退出閱讀"), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("reader_close_button")
                .accessibilityLabel(localized("退出閱讀"))
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()

                Button {
                    toggleAppleBooksPanel(.menu)
                } label: {
                    Label(localized("選單"), systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                        .frame(
                            width: DSLayout.readerAppleBooksControlSize,
                            height: DSLayout.readerAppleBooksControlSize
                        )
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("選單"))
                .accessibilityHint(localized("點兩下展開閱讀工具"))
            }
        }
    }

    // MARK: - Top Bar
    var topBar: some View {
        ReaderTopBar(
            theme: readerTheme,
            chapterTitle: currentChapterTitle.converted(to: settings.textConversion),
            // The "顯示標題 / 標題大小 / 上距 / 下距" settings drive the in-content
            // chapter title (top of the page), NOT this nav bar. The top bar
            // shows no chapter title — only fixed chrome padding.
            titleVisible: false,
            titleSize: 16,
            titleTopSpacing: 10,
            titleBottomSpacing: 10,
            isBookmarked: isCurrentPageBookmarked,
            overlayMaxWidth: overlayContentMaxWidth,
            onBack: { closeReader() },
            onToggleBookmark: {
                guard let position = currentTopBarBookmarkPosition else { return }
                withAnimation(.easeInOut(duration: uiFeedbackDuration)) {
                    store.toggleBookmark(
                        bookId: bookId,
                        chapterIndex: position.spineIndex,
                        chapterTitle: bookmarkChapterTitle(for: position.spineIndex),
                        position: position,
                        excerpt: currentPageExcerpt
                    )
                }
            },
            onOpenBookDetail: onlineBookDetail == nil ? nil : {
                showOnlineBookDetail = true
            }
        )
    }

    // MARK: - Bottom Bar
    var bottomBar: some View {
        ReaderBottomControlBar(
            readerTheme: Binding(
                get: { readerTheme },
                set: { readerTheme = $0 }
            ),
            overlayContentMaxWidth: overlayContentMaxWidth,
            showRefreshButton: !(book?.onlineChapters?.isEmpty ?? true),
            showChangeSourceButton: book?.isOnline == true && book?.bookSourceId != nil,
            showDownloadButton: book?.isOnline == true,
            downloadButtonIcon: downloadButtonIcon,
            canGoPrevChapter: canGoPrevChapter,
            canGoNextChapter: canGoNextChapter,
            chapterPageInfo: chapterPageInfo,
            totalProgressPercent: totalProgressPercent,
            chapterSliderProgressValue: { chapterSliderProgressValue() },
            applyChapterSliderProgress: { applyChapterSliderProgress($0) },
            chapterTitleForProgress: { chapterTitle(forProgress: $0) },
            onPrevChapter: { jumpToChapter(currentChapterIndex - 1) },
            onNextChapter: { jumpToChapter(currentChapterIndex + 1) },
            onRefresh: { refreshCurrentChapter() },
            onOpenChangeSource: { showChangeSourceSheet = true },
            onDownloadAction: { handleDownloadAction() },
            onOpenTTS: { openPlaybackPanel() },
            onOpenTOC: { readerMenuTab = .toc; showTOC = true },
            onOpenBookmarks: { readerMenuTab = .bookmark; showTOC = true },
            onOpenSettings: { showQuickThemePanel = true }
        )
    }

    var appleBooksControls: some View {
        AppleBooksReaderControls(
            activePanel: $appleBooksActivePanel,
            progressValue: { chapterSliderProgressValue() },
            applyProgress: { applyChapterSliderProgress($0) },
            progressDescription: { chapterTitle(forProgress: $0) },
            secondaryActions: appleBooksSecondaryActions,
            onOpenTOC: { readerMenuTab = .toc; showTOC = true },
            onOpenSearch: { showReaderSearch = true },
            onOpenSettings: { showQuickThemePanel = true }
        )
        .environment(\.colorScheme, readerTheme == .night ? .dark : .light)
    }

    var appleBooksSecondaryActions: [AppleBooksReaderAction] {
        var actions = [
            AppleBooksReaderAction(
                id: .playback,
                icon: "headphones",
                label: localized("聽書"),
                action: { openPlaybackPanel() }
            )
        ]

        if book?.isOnline == true {
            actions.append(
                AppleBooksReaderAction(
                    id: .download,
                    icon: downloadButtonIcon,
                    label: localized("下載"),
                    action: { handleDownloadAction() }
                )
            )
        }

        if book?.isOnline == true, book?.bookSourceId != nil {
            actions.append(
                AppleBooksReaderAction(
                    id: .changeSource,
                    icon: "arrow.left.and.right",
                    label: localized("換源"),
                    action: { showChangeSourceSheet = true }
                )
            )
        }

        if !(book?.onlineChapters?.isEmpty ?? true) {
            actions.append(
                AppleBooksReaderAction(
                    id: .refresh,
                    icon: "arrow.clockwise",
                    label: localized("刷新"),
                    action: { refreshCurrentChapter() }
                )
            )
        }

        return actions
    }

    func toggleAppleBooksPanel(_ target: AppleBooksReaderControlPanel) {
        withAnimation(DSAnimation.standard) {
            appleBooksActivePanel = AppleBooksReaderControlPanel.panel(
                afterTapping: target,
                current: appleBooksActivePanel
            )
        }
    }

    func closeReader() {
        if let snap = snapshotBook, snap.isOnline, book == nil {
            showAddToShelfAlert = true
        } else {
            dismissReaderPresentation()
        }
    }

    /// Complete an already-confirmed exit without re-opening the add-to-shelf
    /// prompt. All pushed-reader exits must pass through the coordinator so
    /// the custom close animator, UIKit stack, and retained reader state agree.
    func dismissReaderPresentation() {
        if let navigator = readerNavigator {
            navigator.close()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    var quickPageTurnOption: ReaderQuickPageTurnOption {
        if settings.scrollMode {
            return .scroll
        }
        switch settings.pageTurnStyle {
        case .slide: return .slide
        case .curl: return .curl
        case .cover, .none: return .fastFade
        }
    }

    func applyQuickPageTurnOption(_ option: ReaderQuickPageTurnOption) {
        switch option {
        case .slide:
            settings.scrollMode = false
            settings.pageTurnStyle = .slide
        case .curl:
            settings.scrollMode = false
            settings.pageTurnStyle = .curl
        case .fastFade:
            settings.scrollMode = false
            settings.pageTurnStyle = .none
        case .scroll:
            settings.scrollMode = true
        }
    }

    var appleBooksPagesLeftText: String {
        let left: Int
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let (spineIndex, charOffset) = engine.charOffset(forPage: currentPage)
            if let layout = engine.layouts[spineIndex], !layout.pageRanges.isEmpty {
                let localPage = layout.pageIndex(for: charOffset)
                // displayPageCount: estimated total while the chapter is still
                // partially paginated, exact once complete.
                left = max(0, layout.displayPageCount - localPage - 1)
            } else {
                left = 0
            }
        } else if !allPages.isEmpty {
            let page = allPages[min(currentPage, allPages.count - 1)]
            let total = allPages.filter { $0.chapterIndex == page.chapterIndex }.count
            left = max(0, total - page.pageInChapter - 1)
        } else {
            left = 0
        }
        return String(format: localized("%d pages left in chapter"), left)
    }

    var readerSearchItems: [ReaderBookSearchItem] {
        if let engine = epubRenderer.engine, engine.totalPages > 0 {
            return (0..<engine.totalPages).map { pageIndex in
                let position = engine.charOffset(forPage: pageIndex)
                let title = chapters.indices.contains(position.spineIndex)
                    ? chapters[position.spineIndex].title
                    : String(format: localized("第 %d 章"), position.spineIndex + 1)
                return ReaderBookSearchItem(
                    pageIndex: pageIndex,
                    chapterTitle: title.converted(to: settings.textConversion),
                    text: engine.plainText(forPage: pageIndex).converted(to: settings.textConversion)
                )
            }
        }
        return allPages.enumerated().map { index, page in
            ReaderBookSearchItem(
                pageIndex: index,
                chapterTitle: page.chapterTitle.converted(to: settings.textConversion),
                text: page.content.converted(to: settings.textConversion)
            )
        }
    }

    func ttsJumpPromptView(alignment: Alignment) -> some View {
        HStack(spacing: 8) {
            Button {
                jumpBackToTTSChapter()
            } label: {
                Label(localized("原進度"), systemImage: "arrow.uturn.backward")
                    .font(DSFont.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 18)
                .overlay(Color.white.opacity(0.18))

            Button {
                startTTSFromPromptChapter()
            } label: {
                Label(localized("從本章開始聽"), systemImage: "headphones")
                    .font(DSFont.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.48), in: Capsule())
        .frame(maxWidth: 520, alignment: alignment)
        .accessibilityLabel(ttsJumpPromptMessage)
    }

    var ttsJumpPromptCollapsedBottomPadding: CGFloat {
        let footerBandBottomFromBottom = max(
            0,
            readerConfig.footerBottomPadding
        )
        let footerBandCenterFromBottom = footerBandBottomFromBottom
            + ReaderLayoutMetrics.footerHeight / 2
        let estimatedPromptHeight: CGFloat = 36
        return max(8, footerBandCenterFromBottom - estimatedPromptHeight / 2)
    }

    var ttsJumpPromptMessage: String {
        guard let ttsChapterIndex, chapters.indices.contains(ttsChapterIndex) else {
            return localized("你已移到其他章節，可以選擇回到正在朗讀的位置，或從目前章節重新開始。")
        }
        return String(
            format: localized("聽書仍在「%@」，可以選擇回去，或改從目前章節開始。"),
            chapters[ttsChapterIndex].title
        )
    }

}
