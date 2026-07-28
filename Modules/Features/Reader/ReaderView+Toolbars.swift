import SwiftUI
import UIKit

extension ReaderView {

    @ViewBuilder
    var readerChrome: some View {
        switch settings.appearanceReaderInterface {
        case .classic:
            topBar
            bottomBar
        case .modern:
            // Only the bottom panel is drawn here — 現代's top chrome is a real
            // `.toolbar` (`modernToolbarContent`), which on iOS 26 already renders as
            // the floating glass controls this interface is modelled on.
            //
            // The glass follows the *system* appearance, not the reader theme, so a
            // night-theme page under a light system would get light chrome. Pin the
            // scheme to the theme — the same thing appleBooksControls does.
            modernBottomBar
                .environment(\.colorScheme, readerTheme == .night ? .dark : .light)
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
                        .floatingSurface(in: Circle(), fill: readerTheme.barColor)
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

    // MARK: - 現代 Chrome

    var showsModernToolbars: Bool {
        showBars && settings.appearanceReaderInterface == .modern
    }

    /// 現代's top chrome: three separate glass controls — 返回 / 書名+作者 / 封面.
    ///
    /// Each one needs its own placement. Putting all three in `.topBarLeading` and
    /// splitting them with `ToolbarSpacer` does not spread them: the leading group is
    /// width-constrained, so the three ended up crushed together against the left edge
    /// with the title truncated to one character. Leading / principal / trailing are
    /// what the bar spreads.
    ///
    /// All three are `Button`s on purpose. iOS 26 puts glass behind toolbar *controls*
    /// only — the title was a plain `Text` before and rendered bare over the page.
    /// Tapping the title opens the same book card the cover does.
    @ToolbarContentBuilder
    var modernToolbarContent: some ToolbarContent {
        if settings.appearanceReaderInterface == .modern {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    closeReader()
                } label: {
                    Label(localized("退出閱讀"), systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("reader_back_button")
                .accessibilityLabel(localized("退出閱讀"))
            }

            ToolbarItem(placement: .principal) {
                Button {
                    showModernBookCard = true
                } label: {
                    VStack(spacing: 1) {
                        Text(modernBookTitle)
                            .font(DSFont.subheadline)
                            .lineLimit(1)
                        if !modernBookAuthor.isEmpty {
                            Text(modernBookAuthor)
                                .font(DSFont.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityLabel(
                    modernBookAuthor.isEmpty
                        ? modernBookTitle
                        : "\(modernBookTitle), \(modernBookAuthor)"
                )
                .accessibilityHint(localized("書籍詳情"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showModernBookCard = true
                } label: {
                    modernCoverThumbnail
                }
                .accessibilityLabel(localized("書籍詳情"))
                // Arrow on the thumbnail's bottom edge, so the card hangs under the
                // cover it belongs to rather than covering it.
                .popover(isPresented: $showModernBookCard, arrowEdge: .bottom) {
                    modernBookCard
                        // Keep it a popover on iPhone too — the card belongs to the
                        // cover it hangs off, which a sheet would break.
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var modernCoverThumbnail: some View {
        Group {
            if let modernCoverImage {
                Image(uiImage: modernCoverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                TitleCardPlaceholder(title: modernBookTitle)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
    }

    var modernBottomBar: some View {
        ReaderModernBottomControlBar(
            readerTheme: Binding(
                get: { readerTheme },
                set: { readerTheme = $0 }
            ),
            overlayContentMaxWidth: overlayContentMaxWidth,
            canGoPrevChapter: canGoPrevChapter,
            canGoNextChapter: canGoNextChapter,
            chapterTitle: currentChapterTitle.converted(to: settings.textConversion),
            chapterPageInfo: chapterPageInfo,
            chapterSliderProgressValue: { chapterSliderProgressValue() },
            applyChapterSliderProgress: { applyChapterSliderProgress($0) },
            chapterTitleForProgress: { chapterTitle(forProgress: $0) },
            onPrevChapter: { jumpToChapter(currentChapterIndex - 1) },
            onNextChapter: { jumpToChapter(currentChapterIndex + 1) },
            onOpenTOC: { readerMenuTab = .toc; showTOC = true },
            onOpenBookmarks: { readerMenuTab = .bookmark; showTOC = true },
            onOpenSettings: { showQuickThemePanel = true }
        )
    }

    var modernBookCard: some View {
        ReaderModernBookCard(
            coverImage: modernCoverImage,
            bookTitle: modernBookTitle,
            author: modernBookAuthor,
            formatText: modernFormatText,
            progressText: modernChapterProgressText,
            // Reversed for the same reason the Apple Books menu reverses it: the list is
            // built most-specific-first (聽書 … 刷新) and reads better the other way round.
            actions: readerSecondaryActions.reversed().map { action in
                // Close the popover before running the action — every one of them opens
                // its own sheet or panel, and iOS won't present a second modal from a
                // popover that is still up.
                ReaderSecondaryAction(id: action.id, icon: action.icon, label: action.label) {
                    showModernBookCard = false
                    action.action()
                }
            },
            onOpenDetail: onlineBookDetail == nil ? nil : {
                showModernBookCard = false
                showOnlineBookDetail = true
            }
        )
    }

    var modernBookTitle: String {
        book?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var modernBookAuthor: String {
        book?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The 格式 chip. Online books resolve to `.html` internally, which is true but
    /// meaningless to a reader, so they get 「線上」 instead of "HTML".
    var modernFormatText: String {
        guard let book else { return "" }
        return book.isOnline ? localized("線上") : book.resolvedPipelineKind.displayFormat
    }

    /// "current chapter / total chapters" — the 進度 chip in the book card. Chapters,
    /// not pages: pages shift as chapters load, chapter position doesn't.
    var modernChapterProgressText: String {
        guard !chapters.isEmpty else { return "" }
        return "\(min(currentChapterIndex + 1, chapters.count)) / \(chapters.count)"
    }

    /// Reads the book's cover off disk for the 現代 chrome. Same file the TTS
    /// now-playing artwork uses; kept in `modernCoverImage` so neither the top bar nor
    /// the book card decodes it during layout.
    func loadModernCoverImage() {
        guard settings.appearanceReaderInterface == .modern,
              let coverPath = book?.coverImagePath else {
            modernCoverImage = nil
            return
        }
        modernCoverImage = loadTOCStyleCoverImage(filename: coverPath)
    }

    var appleBooksControls: some View {
        AppleBooksReaderControls(
            activePanel: $appleBooksActivePanel,
            progressValue: { chapterSliderProgressValue() },
            applyProgress: { applyChapterSliderProgress($0) },
            progressDescription: { chapterTitle(forProgress: $0) },
            secondaryActions: readerSecondaryActions,
            onOpenTOC: { readerMenuTab = .toc; showTOC = true },
            onOpenSearch: { showReaderSearch = true },
            onOpenSettings: { showQuickThemePanel = true }
        )
        .environment(\.colorScheme, readerTheme == .night ? .dark : .light)
    }

    var readerSecondaryActions: [ReaderSecondaryAction] {
        var actions = [
            ReaderSecondaryAction(
                id: .playback,
                icon: "headphones",
                label: localized("聽書"),
                action: { openPlaybackPanel() }
            )
        ]

        if book?.isOnline == true {
            actions.append(
                ReaderSecondaryAction(
                    id: .download,
                    icon: downloadButtonIcon,
                    label: localized("下載"),
                    action: { handleDownloadAction() }
                )
            )
        }

        if book?.isOnline == true, book?.bookSourceId != nil {
            actions.append(
                ReaderSecondaryAction(
                    id: .changeSource,
                    icon: "arrow.left.and.right",
                    label: localized("換源"),
                    action: { showChangeSourceSheet = true }
                )
            )
        }

        if !(book?.onlineChapters?.isEmpty ?? true) {
            actions.append(
                ReaderSecondaryAction(
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
