import SwiftUI
import UIKit

extension ReaderView {

    /// Only the bottom panel is drawn here — the top chrome is a real `.toolbar`
    /// (`modernToolbarContent`), which on iOS 26 already renders as floating glass
    /// controls.
    ///
    /// The glass follows the *system* appearance, not the reader theme, so a
    /// night-theme page under a light system would get light chrome. Pin the
    /// scheme to the theme.
    var readerChrome: some View {
        modernBottomBar
            .environment(\.colorScheme, readerColorScheme)
    }

    /// The appearance the reading menu's glass is drawn in: the reader theme's, never the
    /// system's. The bottom bar, the navigation bar and the book card's popover each have to
    /// be told separately — the bar is UIKit's and the popover is a presentation of its own,
    /// so neither inherits it from the bottom bar's environment. Pinning only the bottom bar
    /// put a light book card over a dark bottom bar (feedback #78).
    var readerColorScheme: ColorScheme {
        readerTheme == .night ? .dark : .light
    }

    // MARK: - Top chrome

    /// The chrome colours 自定義 can override; see `ReaderChromePalette`.
    var modernPalette: ReaderChromePalette {
        ReaderChromePalette(theme: readerTheme, settings: settings)
    }

    /// Three glass islands: 返回 (circle) · 書名 (capsule) · 封面 (circle), each in
    /// its own placement.
    ///
    /// Each one needs its own placement. Putting all three in `.topBarLeading` and
    /// splitting them with `ToolbarSpacer` does not spread them: the leading group is
    /// width-constrained, so the three ended up crushed together against the left edge
    /// with the title truncated to one character. Nor are they one `ToolbarItemGroup`
    /// with `Spacer()`s, even though that is how the bookshelf's multi-select bottom bar
    /// builds the same shape. That works in `.bottomBar`, which hands the group the full
    /// width; the navigation bar's `.principal` region sizes to its content, so the
    /// spacers collapsed and took 書名 and 封面 with them — the device showed a bare
    /// chevron floating mid-bar and nothing else. Verified twice on hardware. Do not
    /// merge these back into one group.
    ///
    /// Separate placements are also what centres 書名: `.principal` is the only one
    /// that does, and a flexible `ToolbarSpacer` in the leading group only pushes to
    /// that group's own trailing edge. The catch is that a principal item is the
    /// bar's title view and never takes the glass by itself, so the title capsule
    /// draws its own (`ReaderTitleCapsuleButtonStyle`). `.plain` is the opposite lever
    /// — an opt-out — which the cover uses so the artwork itself is the circle.
    @ToolbarContentBuilder
    var modernToolbarContent: some ToolbarContent {
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

    /// 換源 only means something for an online book read from a source — the same
    /// condition the book card's 換源 action uses.
    private var canChangeModernSource: Bool {
        book?.isOnline == true && book?.bookSourceId != nil
    }

    /// 書名 over where it is read from, in one glass capsule never narrower than
    /// `readerModernTitleMinWidth`. A tap opens the book card the cover does; a long
    /// press opens 換源, which the card also offers for anyone who does not know the
    /// gesture.
    private var modernTitleButton: some View {
        Button {
            showModernBookCard = true
        } label: {
            VStack(spacing: 0) {
                Text(modernBookTitle)
                    .font(DSFont.subheadline)
                    .foregroundStyle(modernPalette.topIcon)
                Text(modernSourceText)
                    .font(DSFont.caption2)
                    .foregroundStyle(modernPalette.topIcon.opacity(0.62))
            }
            .lineLimit(1)
            .frame(minWidth: DSLayout.readerModernTitleMinWidth)
        }
        .buttonStyle(ReaderTitleCapsuleButtonStyle(
            onLongPress: canChangeModernSource ? { showChangeSourceSheet = true } : nil
        ))
        .accessibilityLabel(
            [modernBookTitle, modernBookAuthor, modernSourceText]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
        .accessibilityHint(localized("書本選單"))
        .accessibilityIdentifier("reader_title_capsule")
        .accessibilityActions {
            if canChangeModernSource {
                Button(localized("換源")) { showChangeSourceSheet = true }
            }
        }
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
        .accessibilityLabel(localized("書本選單"))
        // On the cover, not on 書名: a popover anchored to the bar's principal item ran
        // off the trailing edge of the screen on iOS 27. Its width is what keeps the
        // two side margins equal; see `DSLayout.readerModernBookCardWidth`.
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
                    // Drawn by the presentation, outside the card's environment: the
                    // scheme set on the card below never reaches it, and the glass stayed
                    // light over a night page (feedback #78, checked on iOS 26.5).
                    .environment(\.colorScheme, readerColorScheme)
                }
                // `.popover` has no `onDismiss`, so the card's own disappearance is the
                // dismissal signal the deferred route waits on. Deliberately a real
                // lifecycle callback, not a timer.
                .onDisappear(perform: presentDeferredModernBookCardRoute)
                // A presentation starts again from the system appearance, so the card's
                // own system colours would be light over a night page; see
                // `readerColorScheme`. Its glass is set in `presentationBackground` above.
                .environment(\.colorScheme, readerColorScheme)
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
            progressText: readerProgressText,
            chapterSliderProgressValue: { chapterSliderProgressValue() },
            applyChapterSliderProgress: { applyChapterSliderProgress($0) },
            chapterTitleForProgress: { chapterTitle(forProgress: $0).converted(to: settings.textConversion) },
            isCurrentPageBookmarked: isCurrentPageBookmarked,
            onPrevChapter: { jumpToChapter(currentChapterIndex - 1) },
            onNextChapter: { jumpToChapter(currentChapterIndex + 1) },
            onOpenTOC: { showTOC = true },
            onOpenSettings: { showQuickThemePanel = true },
            onListen: { handleListeningAction() },
            onToggleDarkMode: { toggleReaderDarkMode() },
            onOpenBookmarks: { showBookmarkList = true },
            onToggleBookmark: { toggleCurrentPageBookmark() },
            moreActions: settings.visibleReaderSecondaryActions(readerMoreActions)
        )
    }

    var modernBookCard: some View {
        ReaderModernBookCard(
            coverImage: modernCoverImage,
            bookTitle: modernBookTitle,
            author: modernBookAuthor,
            formatText: modernFormatText,
            progressText: modernChapterProgressText,
            // Reversed: the list is built most-specific-first (下載 … 刷新) and reads
            // better the other way round.
            // `visibleReaderSecondaryActions` then drops whatever 自定義 switched off.
            actions: settings.visibleReaderSecondaryActions(readerSecondaryActions.reversed()).map { action in
                // Every one of these opens its own sheet, and iOS won't present a modal from
                // a popover that is still up — nor from one that is still dismissing, which
                // is why running the action in the same turn as `showModernBookCard = false`
                // left 聽書 (then in the card) dead: the card slid back into the thumbnail and
                // no panel came up.
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
            onOpenDetail: book == nil ? nil : {
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
            openWorkDetail()
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

    /// The title capsule's second line: the source an online book is read from, or
    /// 本機 for a book that lives on this device.
    var modernSourceText: String {
        guard let book else { return "" }
        return book.isOnline ? currentSourceName : localized("本機")
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

    /// Reads the book's cover off disk for the top bar's cover button. Same file the TTS
    /// now-playing artwork uses; kept in `modernCoverImage` so neither the top bar nor
    /// the book card decodes it during layout.
    func loadModernCoverImage() {
        guard let coverPath = book?.coverImagePath else {
            modernCoverImage = nil
            return
        }
        modernCoverImage = loadTOCStyleCoverImage(filename: coverPath)
    }

    /// The book card's actions. 聽書 is not one of them — it is in the bottom bar — and
    /// the AI ones are in 更多 (`readerMoreActions`).
    var readerSecondaryActions: [ReaderSecondaryAction] {
        var actions: [ReaderSecondaryAction] = []

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

        if let source = readerSource,
           !source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions.append(
                ReaderSecondaryAction(
                    id: .sourceLogin,
                    icon: "person.crop.circle",
                    label: localized("來源配置登入"),
                    action: { sourceLoginTarget = source }
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

        if SourceCallBackService.showsCustomButton(readerSource) {
            actions.append(
                ReaderSecondaryAction(
                    id: .sourceCustomButton,
                    icon: "hand.tap",
                    label: localized("自訂按鈕"),
                    action: { runSourceCustomButton() }
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

    /// AI 助手 and AI 翻譯, which 更多 in the bottom bar lists under 書籤.
    var readerMoreActions: [ReaderSecondaryAction] {
        // Shown whatever the AI settings are: hiding it when unconfigured would leave a
        // reader with no way to discover the feature exists. The panel itself explains what
        // to fill in. Without Pro both are marked and open the paywall.
        let aiLocked = !readerPremiumVisibility.allowsAI
        var actions = [
            ReaderSecondaryAction(
                id: .aiAssistant,
                icon: "sparkles",
                label: localized("AI 助手"),
                isLocked: aiLocked,
                action: { openAIAssistant() }
            )
        ]

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

        return actions
    }

    var currentOnlineChapter: OnlineChapterRef? {
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
            BookSourceStore.shared.source(id: id)
        }
        // Resolving the source's headers can run its JS (`@js:` header rules), on its host.
        let chapterURL = chapter.url
        Task {
            var urlRequest: URLRequest?
            if let source {
                urlRequest = await BookSourceSession.session(for: source).host.run {
                    $0.sourceBrowserRequest(urlString: chapterURL)
                }
            }
            urlRequest = urlRequest ?? URL(string: chapterURL).map { URLRequest(url: $0) }
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

    /// The close button. A book not on the shelf is offered to it by the page the reader closes
    /// onto (`readerShelvePrompt`), which a swipe back reaches too.
    func closeReader() {
        dismissReaderPresentation()
    }

    /// All pushed-reader exits must pass through the coordinator so the custom close
    /// animator, UIKit stack, and retained reader state agree.
    func dismissReaderPresentation() {
        // Only the chapter on screen was worth translating; what finished is kept.
        AIChapterTranslationService.shared.cancel(book: bookId)
        if let navigator = readerNavigator {
            // endRead goes out from the coordinator's close (`readerClosingHandler`), which a
            // swipe back reaches too.
            navigator.close()
        } else {
            notifySourceEndRead()
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
        let estimatedPromptHeight: CGFloat = 36
        return footerBandBottomPadding(forHeight: estimatedPromptHeight)
    }

    /// The bottom padding that centres a floating control `height` tall on the page's footer
    /// band, so with the chrome down it covers the band rather than the page's last lines.
    func footerBandBottomPadding(forHeight height: CGFloat) -> CGFloat {
        let footerBandBottomFromBottom = max(
            0,
            readerConfig.footerBottomPadding
        )
        let footerBandCenterFromBottom = footerBandBottomFromBottom
            + ReaderLayoutMetrics.footerHeight / 2
        return max(8, footerBandCenterFromBottom - height / 2)
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

/// The title capsule: a tap is the button's action, a long press is `onLongPress`.
/// Primitive, so the two cannot both fire — a long-press gesture added to a plain
/// button would still open the book card on the release that ends it. Same reason as
/// 外觀's theme tiles.
///
/// It draws its own Liquid Glass because a `.principal` toolbar item is the bar's
/// title view and never gets the treatment on its own. Before iOS 26 there is no
/// glass at all, so the title keeps the plain look it has always had there.
private struct ReaderTitleCapsuleButtonStyle: PrimitiveButtonStyle {
    /// Nil when there is nothing to do on a long press.
    let onLongPress: (() -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        ReaderTitleCapsuleButtonBody(configuration: configuration, onLongPress: onLongPress)
    }
}

private struct ReaderTitleCapsuleButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let onLongPress: (() -> Void)?

    var body: some View {
        let capsule = configuration.label
            .padding(.horizontal, DSSpacing.lg)
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Capsule())
            .titleCapsuleGlass()
        if let onLongPress {
            if #available(iOS 18.0, *) {
                // One gesture with the long press first, so exactly one of the two can win.
                // `.onTapGesture` plus `.onLongPressGesture` stacked as two modifiers gave the
                // inner tap precedence: a hold never reached the long press, and lifting the
                // finger still counted as a tap, so holding the capsule opened the book card.
                capsule.gesture(
                    LongPressGesture()
                        .exclusively(before: TapGesture())
                        .onEnded { gesture in
                            switch gesture {
                            case .first: onLongPress()
                            case .second: configuration.trigger()
                            }
                        }
                )
            } else {
                // iOS 17: the exclusive gesture above never ends in its tap here — on 17.5 a
                // tap on the capsule reached the app and opened nothing. iOS 17 keeps the two
                // stacked gestures 外觀's theme tiles use. Delete this branch once the
                // deployment target is iOS 18.
                capsule
                    .onTapGesture { configuration.trigger() }
                    .onLongPressGesture(minimumDuration: 0.5, perform: onLongPress)
            }
        } else {
            capsule.onTapGesture { configuration.trigger() }
        }
    }
}

private extension View {
    @ViewBuilder
    func titleCapsuleGlass() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
        }
        #else
        self
        #endif
    }
}
