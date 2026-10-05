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



            ToolbarItem(placement: .topBarLeading) {
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
                }
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
            onOpenSearch: { showReaderSearch = true },
            onToggleBookmark: {
                toggleCurrentPageBookmark()
            },
            menuActions: readerSecondaryActions.filter { !ReaderChromeActionItem($0.id).isClassicCircle },
            onOpenBookDetail: onlineBookDetail == nil ? nil : {
                openOnlineBookDetail()
            }
        )
    }

    // MARK: - Bottom Bar
    var bottomBar: some View {
        ReaderBottomControlBar(
            readerTheme: readerTheme,
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
            chapterTitleForProgress: { chapterTitle(forProgress: $0).converted(to: settings.textConversion) },
            onPrevChapter: { jumpToChapter(currentChapterIndex - 1) },
            onNextChapter: { jumpToChapter(currentChapterIndex + 1) },
            onRefresh: { refreshCurrentChapter() },
            onOpenChangeSource: { showChangeSourceSheet = true },
            onDownloadAction: { handleDownloadAction() },
            onOpenTTS: { handleListeningAction() },
            onOpenTOC: { showTOC = true },
            onOpenBookmarks: { showBookmarkList = true },
            onToggleDarkMode: { toggleReaderDarkMode() },
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
    /// 現代's own chrome colours. 現代 exposes no `topFill`: its navigation bar is
    /// the system's glass with the background deliberately hidden, so only the
    /// symbol colour is ours to set.
    var modernPalette: ReaderChromePalette {
        ReaderChromePalette(interface: .modern, theme: readerTheme, settings: settings)
    }

    /// Three glass islands: 返回 (circle) · 書名 (capsule) · 封面 (circle), each in
    /// its own placement.
    ///
    /// They are NOT one `ToolbarItemGroup` with `Spacer()`s, even though that is how
    /// the bookshelf's multi-select bottom bar builds the same shape. That works in
    /// `.bottomBar`, which hands the group the full width; the navigation bar's
    /// `.principal` region sizes to its content, so the spacers collapsed and took
    /// 書名 and 封面 with them — the device showed a bare chevron floating mid-bar
    /// and nothing else. Verified twice on hardware. Do not merge these back into
    /// one group.
    ///
    /// Separate placements are also what centres 書名: `.principal` is the only one
    /// that does, and a flexible `ToolbarSpacer` in the leading group only pushes to
    /// that group's own trailing edge. The catch is that a principal item is the
    /// bar's title view and never takes the glass by itself, so it asks explicitly
    /// with `.buttonStyle(.glass)`. `.plain` is the opposite lever — an opt-out —
    /// which the cover uses so the artwork itself is the circle.
    @ToolbarContentBuilder
    var modernToolbarContent: some ToolbarContent {
        if settings.appearanceReaderInterface == .modern {
            ToolbarItem(placement: .topBarLeading) {
                modernBackButton
            }
            ToolbarItem(placement: .principal) {
                modernTitleButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                modernCoverButton
            }
        }
    }

    private var modernBackButton: some View {
        Button {
            closeReader()
        } label: {
            Label(localized("退出閱讀"), systemImage: "chevron.left")
                .labelStyle(.iconOnly)
                .foregroundStyle(modernPalette.topIcon)
        }
        .accessibilityIdentifier("reader_back_button")
        .accessibilityLabel(localized("退出閱讀"))
    }

    /// One line, one glass capsule. The author moved into the card: a second line
    /// makes the capsule tall and breaks the row of equal-height islands.
    private var modernTitleButton: some View {
        Button {
            showModernBookCard = true
        } label: {
            Text(modernBookTitle)
                .font(DSFont.subheadline)
                .foregroundStyle(modernPalette.topIcon)
                .lineLimit(1)
        }
        .modernToolbarGlass()
        .accessibilityLabel(
            modernBookAuthor.isEmpty
                ? modernBookTitle
                : "\(modernBookTitle), \(modernBookAuthor)"
        )
        .accessibilityHint(localized("書籍詳情"))
    }

    private var modernCoverButton: some View {
        Button {
            showModernBookCard = true
        } label: {
            modernCoverThumbnail
        }
        // `.plain` so the cover *is* the control: a bordered/glass toolbar button
        // would draw its own circle and inset the artwork inside it, which is the
        // small-square-in-a-circle look this replaces.
        .buttonStyle(.plain)
        .accessibilityLabel(localized("書籍詳情"))
        // Arrow on the thumbnail's bottom edge, so the card hangs under the cover it
        // belongs to rather than covering it.
        .popover(isPresented: $showModernBookCard, arrowEdge: .bottom) {
            modernBookCard
                // Keep it a popover on iPhone too — the card belongs to the cover it
                // hangs off, which a sheet would break.
                .presentationCompactAdaptation(.popover)
                // The popover's own surface — corners and arrow included, which is
                // why the card itself paints nothing. On iOS 26 this is the same
                // glass the 現代 bottom bar wears, with 自定義's panelFill fading in
                // as 透明度 drops; a flat `panelFill` is what it was before, and what
                // it still is with 毛玻璃 off. A plain rectangle because the popover
                // does the clipping.
                .presentationBackground {
                    Color.clear.floatingSurfaceBackground(
                        in: Rectangle(),
                        fill: modernPalette.panelFill
                    )
                }
                // `.popover` has no `onDismiss`, so the card's own disappearance is the
                // dismissal signal the deferred route waits on. Deliberately a real
                // lifecycle callback, not a timer.
                .onDisappear(perform: presentDeferredModernBookCardRoute)
        }
    }

    /// The cover fills the whole control as a circle. It used to be a 30pt rounded
    /// square sitting inside the toolbar button's own circular chrome, which read as
    /// a small picture in a ring rather than as the book.
    private var modernCoverThumbnail: some View {
        Group {
            if let modernCoverImage {
                Image(uiImage: modernCoverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedBookCover(title: modernBookTitle, author: modernBookAuthor)
            }
        }
        .frame(
            width: DSLayout.readerModernCoverButtonSize,
            height: DSLayout.readerModernCoverButtonSize
        )
        .clipShape(Circle())
        // A hairline keeps a pale cover from dissolving into a pale page.
        .overlay(Circle().stroke(modernPalette.topIcon.opacity(0.25), lineWidth: 0.5))
        .contentShape(Circle())
    }

    var modernBottomBar: some View {
        ReaderModernBottomControlBar(
            readerTheme: readerTheme,
            overlayContentMaxWidth: overlayContentMaxWidth,
            canGoPrevChapter: canGoPrevChapter,
            canGoNextChapter: canGoNextChapter,
            chapterTitle: currentChapterTitle.converted(to: settings.textConversion),
            chapterPageInfo: chapterPageInfo,
            chapterSliderProgressValue: { chapterSliderProgressValue() },
            applyChapterSliderProgress: { applyChapterSliderProgress($0) },
            chapterTitleForProgress: { chapterTitle(forProgress: $0).converted(to: settings.textConversion) },
            onPrevChapter: { jumpToChapter(currentChapterIndex - 1) },
            onNextChapter: { jumpToChapter(currentChapterIndex + 1) },
            onOpenTOC: { showTOC = true },
            onOpenBookmarks: { showBookmarkList = true },
            onToggleDarkMode: { toggleReaderDarkMode() },
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
            // `visibleReaderSecondaryActions` then drops whatever 自定義 switched off —
            // Apple Books keeps the full list, since none of its chrome is customizable.
            actions: settings.visibleReaderSecondaryActions(readerSecondaryActions.reversed()).map { action in
                // Every one of these opens its own sheet, and iOS won't present a modal from
                // a popover that is still up — nor from one that is still dismissing, which
                // is why running the action in the same turn as `showModernBookCard = false`
                // left 聽書 dead: the card slid back into the thumbnail and no panel came up.
                // Retain the route and let the popover's real dismissal run it.
                ReaderSecondaryAction(id: action.id, icon: action.icon, label: action.label, isLocked: action.isLocked) {
                    modernBookCardPresentation.select(.secondary(action.id))
                    showModernBookCard = false
                }
            },
            palette: modernPalette,
            availableWidth: readerViewportSize.width,
            // Same deferral as the actions above: `ReaderBookSearchView` is a sheet, and a
            // sheet asked for while the popover is still dismissing never appears.
            onOpenSearch: {
                modernBookCardPresentation.select(.search)
                showModernBookCard = false
            },
            onOpenDetail: onlineBookDetail == nil ? nil : {
                modernBookCardPresentation.select(.bookDetail)
                showModernBookCard = false
            }
        )
    }

    /// Opens whatever the 現代 book card was asked for, once the popover is actually gone.
    func presentDeferredModernBookCardRoute() {
        guard let route = modernBookCardPresentation.consumeAfterDismissal() else { return }
        switch route {
        case .bookDetail:
            openOnlineBookDetail()
        case .secondary(let id):
            readerSecondaryActions.first { $0.id == id }?.action()
        case .search:
            showReaderSearch = true
        }
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
        return book.displayFormatLabel
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
            progressDescription: { chapterTitle(forProgress: $0).converted(to: settings.textConversion) },
            // AI 助手 is a menu row there; the action row drops what needs Pro the reader
            // does not have (翻譯) — without Pro, the rows keep AI's one marked entry.
            secondaryActions: readerSecondaryActions.filter { $0.id != .aiAssistant && !$0.isLocked },
            aiAssistant: readerSecondaryActions.first { $0.id == .aiAssistant },
            onOpenTOC: { showTOC = true },
            onOpenBookmarks: { showBookmarkList = true },
            onOpenSearch: { showReaderSearch = true },
            onOpenSettings: { showQuickThemePanel = true },
            isDarkMode: settings.readerDarkMode,
            onToggleDarkMode: { toggleReaderDarkMode() }
        )
        .environment(\.colorScheme, readerTheme == .night ? .dark : .light)
    }

    var readerSecondaryActions: [ReaderSecondaryAction] {
        var actions = [
            ReaderSecondaryAction(
                id: .playback,
                icon: "headphones",
                label: localized("聽書"),
                action: { handleListeningAction() }
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

        if currentOnlineChapter != nil {
            actions.append(
                ReaderSecondaryAction(
                    id: .openWebPage,
                    icon: "globe",
                    label: localized("開啟網頁"),
                    action: { openCurrentChapterWebPage() }
                )
            )
        }

        // Shown whatever the AI settings are: hiding it when unconfigured would leave a
        // reader with no way to discover the feature exists. The panel itself explains what
        // to fill in. Without Pro both are marked and open the paywall.
        let aiLocked = !readerPremiumVisibility.allowsAI
        actions.append(
            ReaderSecondaryAction(
                id: .aiAssistant,
                icon: "sparkles",
                label: localized("AI 助手"),
                isLocked: aiLocked,
                action: { openAIAssistant() }
            )
        )

        // 整章翻譯 lays translations into reflowed text; a fixed-layout page has none.
        if !isFixedLayoutEPUB {
            actions.append(
                ReaderSecondaryAction(
                    id: .translation,
                    icon: "translate",
                    label: localized("AI 翻譯"),
                    isLocked: aiLocked,
                    action: { openTranslationSheet() }
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

    private var currentOnlineChapter: OnlineChapterRef? {
        guard let book, book.isOnline, let chapters = book.onlineChapters,
              chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    /// 開啟網頁: the current chapter's page, opened with the source's headers and cookies the
    /// way Legado's reading menu opens its chapter URL. This is where a reader gets past a
    /// Cloudflare check or a login — nothing opens one by itself — and the cookies the page
    /// leaves serve the source's next requests.
    func openCurrentChapterWebPage() {
        guard let book, let chapter = currentOnlineChapter else { return }
        let source = book.bookSourceId.flatMap { id in
            BookSourceStore.shared.sources.first { $0.id == id }
        }
        // Resolving the source's headers can run its JS (`@js:` header rules).
        Task {
            let urlRequest = await SourceScriptThread.run {
                source.flatMap {
                    BookSourceSession.session(for: $0).bridgeForAsyncOperations
                        .sourceBrowserRequest(urlString: chapter.url)
                } ?? URL(string: chapter.url).map { URLRequest(url: $0) }
            }
            let request = SourceBrowserRequest(
                url: chapter.url, title: chapter.title, urlRequest: urlRequest, awaitsResult: false)
            SourceBrowserPresenter.present(request) { _ in }
        }
    }

    /// AI 助手, or the paywall without Pro.
    func openAIAssistant() {
        guard readerPremiumVisibility.allowsAI else {
            paywallFeature = .aiReading
            return
        }
        showAIAssistantPanel = true
    }

    /// 整章翻譯's sheet, or the paywall without Pro.
    func openTranslationSheet() {
        guard readerPremiumVisibility.allowsAI else {
            paywallFeature = .aiReading
            return
        }
        showTranslationSheet = true
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
        // Only the chapter on screen was worth translating; what finished is kept.
        AIChapterTranslationService.shared.cancel(book: bookId)
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
        case .cover: return .cover
        case .curl: return .curl
        case .none: return .fastFade
        }
    }

    func applyQuickPageTurnOption(_ option: ReaderQuickPageTurnOption) {
        switch option {
        case .slide:
            settings.scrollMode = false
            settings.pageTurnStyle = .slide
        case .cover:
            settings.scrollMode = false
            settings.pageTurnStyle = .cover
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
            if let pagination = displayedChapterPagination(in: engine) {
                // displayPageCount: estimated total while the chapter is still
                // partially paginated, exact once complete.
                left = max(0, pagination.displayPageCount - pagination.localPageIndex - 1)
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
                    text: engine.plainText(forPage: pageIndex)
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
            chapters[ttsChapterIndex].title.converted(to: settings.textConversion)
        )
    }

}

/// Liquid Glass on a `.principal` toolbar item, which the bar treats as its title
/// view and never grants the treatment to on its own. Before iOS 26 there is no
/// glass at all, so the control keeps exactly the look it has always had.
private extension View {
    @ViewBuilder
    func modernToolbarGlass() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
