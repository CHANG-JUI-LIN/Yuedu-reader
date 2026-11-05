import AVFoundation
import CoreImage
import LNPopupUI
import SwiftUI
import UIKit

// MARK: - Audiobook Reader (dedicated full-screen player page)
//
// The reader for `.audio` books. While the app's tabs are on top it opens out of the app
// root's now-playing bar and folds back into it (`NowPlayingPopupHost`, `opensOutOfRootBar`),
// as Apple Books' does; under a sheet or a cover, the page presents it over itself through
// `BookReaderView`. Playback itself lives in the long-lived `AudiobookPlayer.shared`
// singleton, so closing this page keeps audio going with lock-screen controls; re-opening
// re-attaches to the live session.
//
// The page is Apple Books' audiobook player, one to one (maintainer, 2026-11-05, from a
// recording): a grabber instead of a top bar, the cover large while playing and smaller while
// paused, a scrolling title with the author under it, a thumbless timeline with the chapter's
// title between the times, 「1倍」・15 s back・play・15 s on・sleep, the system volume, then
// AirPlay and 目錄. Apple Books' price pill is 加入書架 here, for a book played without being
// shelved, and its ••• maps onto what Yuedu has: 分享 and 加入分組 (收藏清單), 加入書架,
// 標記為已讀完, 作品詳情 (在商店中檢視), and 移除書架. The features the recording lacks — 上一章 /
// 下一章, 播放模式, 跳過片頭片尾 and the source's own buttons — are in the same menu.

struct AudiobookReaderView: View {
    let bookId: UUID
    /// The page was opened from the book's own 作品詳情 (`AudiobookDetailView`) without the book
    /// being on the shelf: the cover and 作品詳情 go back to that page.
    var detailIsPresenter = false
    /// The player grows out of the app root's bar and folds back into it (`NowPlayingPopupHost`),
    /// which also draws it down and says when it opens and closes. Otherwise a reader, or a page
    /// presented over the tabs, presents it full screen, and it goes as a cover does.
    var opensOutOfRootBar = false

    @EnvironmentObject var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDependencies) private var dependencies
    /// Compact in iPhone landscape: the player is laid out side by side there, since cover,
    /// title and controls stacked are taller than the window.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var player = AudiobookPlayer.shared

    @State private var palette = AudiobookPlayerPalette(cover: nil)
    /// How far the page has been drawn down by its grabber or cover.
    @State private var dragOffset: CGFloat = 0
    /// The `+0:15` bubble: the skips' total since it appeared; nil once it has gone.
    @State private var skippedSeconds: TimeInterval?
    @State private var skipBubbleGeneration = 0
    @State private var showsSpeed = false
    @State private var showsCustomSleep = false
    @State private var showChapterList = false
    @State private var showSkipCredits = false
    @State private var showsAddToGroup = false
    @State private var confirmsRemoval = false
    @State private var workDetail: AudiobookWorkDetail?
    @State private var pendingShare: PendingShareExport<URL>?
    @State private var shareURL: URL?
    @State private var addingToShelf = false
    /// The shelf book a transient session became through 加入書架 on this page.
    @State private var shelvedBookId: UUID?
    @State private var sourcePage: ReaderHTMLUtilities.ReviewTarget?
    // Before iOS 18 a menu cannot launch a sheet or popover; its rows open from these choosers'
    // real `onDismiss` instead (`MenuModalPresentationPolicy`).
    @State private var showsMoreChooser = false
    @State private var moreSequence = DismissalSequencedPresentation<AudiobookMoreRoute>()
    @State private var showsSleepChooser = false
    @State private var sleepSequence = DismissalSequencedPresentation<AudiobookSleepChoice>()

    /// The book on screen: the one opened, or the shelf book it became.
    private var currentBookId: UUID { shelvedBookId ?? bookId }
    /// The shelf's record of it — without its table of contents, cheap enough for each frame.
    private var shelfRecord: ReadingBook? { store.shelfRecord(id: currentBookId) }
    private var isTransient: Bool { shelfRecord == nil }
    private var usesSequencedMenus: Bool { MenuModalPresentationPolicy.requiresDismissalSequencedChooser }

    var body: some View {
        GeometryReader { proxy in
            let layout = AudiobookPlayerLayout(proxy: proxy, isCompactHeight: verticalSizeClass == .compact)
            ZStack {
                palette.gradient.ignoresSafeArea()
                if layout.isCompactHeight {
                    landscape(layout)
                } else {
                    portrait(layout)
                }
            }
        }
        .offset(y: dragOffset)
        // Dark styling for THIS page only. `.preferredColorScheme(.dark)` applies to the
        // whole window, which flipped the bookshelf dark for an instant during the
        // fullScreenCover transition (the "theme flashes black" bug). The environment
        // override scopes the dark appearance to this subtree; the page paints its own
        // ground, so nothing else is needed.
        .environment(\.colorScheme, .dark)
        // No close button, as in Apple Books: VoiceOver's two-finger scrub closes the page.
        .accessibilityAction(.escape) { close() }
        .onAppear {
            palette = AudiobookPlayerPalette(cover: player.coverImage)
            // Out of the root's bar the book was started by whoever opened it
            // (`NowPlayingHub.openAudiobookPlayer`), and the host reports opening and closing.
            guard !opensOutOfRootBar else { return }
            if let book = store.readingBook(id: bookId) {
                player.start(book: book, store: store)
                SourceCallBackService.notify(.startRead, book: book, chapter: currentCallBackChapter)
            } else if !player.isActive(bookId: bookId) {
                close()
            }
        }
        // legado `AudioPlayActivity` sends endRead when its player screen goes away.
        .onDisappear {
            guard !opensOutOfRootBar, let book = store.readingBook(id: currentBookId) else { return }
            SourceCallBackService.notify(.endRead, book: book, chapter: currentCallBackChapter)
        }
        .onChange(of: player.coverImage.map(ObjectIdentifier.init)) { _, _ in
            palette = AudiobookPlayerPalette(cover: player.coverImage)
        }
        .task(id: player.bookId) { shareURL = resolveShareURL() }
        .sheet(item: $sourcePage) { target in
            LegadoReviewBrowserView(target: target) { _ in sourcePage = nil }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChapterList) {
            AudiobookChapterListView(player: player)
        }
        .sheet(isPresented: $showSkipCredits) {
            AudiobookSkipCreditsView(player: player)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showsAddToGroup) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableNarrowWidth) {
                BookshelfAddToGroupSheet(groups: store.groupBookCounts) { group in
                    store.setGroup(group, for: currentBookId)
                }
            }
        }
        .sheet(item: $workDetail) { detail in
            workDetailPage(detail.route)
        }
        .sheet(item: $pendingShare) { export in
            ShareExportSheet(export: export)
        }
        .sheet(isPresented: $showsMoreChooser, onDismiss: runPendingMoreRoute) {
            DismissalSequencedActionChooser(title: localized("更多"), actions: moreChooserActions) {
                moreSequence.select($0)
            }
        }
        .sheet(isPresented: $showsSleepChooser, onDismiss: runPendingSleepChoice) {
            DismissalSequencedActionChooser(title: localized("睡眠定時"), actions: sleepChooserActions) {
                sleepSequence.select($0)
            }
        }
        .removeFromShelfConfirmation(isPresented: $confirmsRemoval, onConfirm: removeFromShelf)
    }

    // MARK: Layout

    private func portrait(_ layout: AudiobookPlayerLayout) -> some View {
        VStack(spacing: 0) {
            grabber
            GeometryReader { region in
                let side = layout.coverSide(in: region.size)
                cover(side: side)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity)
                    .padding(.top, layout.coverTopGap)
            }
            .contentShape(Rectangle())
            .gesture(dismissDrag, including: dismissDragMask)
            controls(layout)
        }
        .frame(maxWidth: layout.columnWidth)
        .frame(maxWidth: .infinity)
    }

    /// iPhone landscape: the cover on the leading side, the rest beside it.
    private func landscape(_ layout: AudiobookPlayerLayout) -> some View {
        VStack(spacing: 0) {
            grabber
            HStack(spacing: DSLayout.audiobookPlayerHorizontalMargin) {
                GeometryReader { region in
                    let side = min(region.size.width, region.size.height)
                    cover(side: side)
                        .frame(width: side, height: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Rectangle())
                .gesture(dismissDrag, including: dismissDragMask)
                .padding(.leading, DSLayout.audiobookPlayerHorizontalMargin)
                controls(layout)
                    .frame(maxWidth: DSLayout.audiobookPlayerMaximumColumnWidth)
            }
        }
    }

    /// Title, timeline, transport, volume and the bottom row: Apple Books' gaps, centre to
    /// centre, shrunk for a shorter window.
    private func controls(_ layout: AudiobookPlayerLayout) -> some View {
        VStack(spacing: 0) {
            titleRow
                .frame(height: DSLayout.audiobookPlayerTitleRowHeight)
            if let message = player.error {
                errorBlock(message)
            }
            layout.gap(DSLayout.audiobookPlayerTimelineTopGap, above: 0, below: DSLayout.audiobookPlayerSliderHeight / 2)
            progressSection
            layout.gap(
                DSLayout.audiobookPlayerTransportTopGap,
                above: AudiobookProgressSection.labelsHalfHeight,
                below: DSLayout.minimumTapTarget / 2
            )
            transportRow
                .frame(height: DSLayout.minimumTapTarget)
            layout.gap(
                DSLayout.audiobookPlayerVolumeTopGap,
                above: DSLayout.minimumTapTarget / 2,
                below: DSLayout.audiobookPlayerSliderHeight / 2
            )
            volumeRow
                .frame(height: DSLayout.audiobookPlayerSliderHeight)
            layout.gap(
                DSLayout.audiobookPlayerBottomRowTopGap,
                above: DSLayout.audiobookPlayerSliderHeight / 2,
                below: DSLayout.minimumTapTarget / 2
            )
            bottomRow
                .frame(height: DSLayout.minimumTapTarget)
            layout.gap(DSLayout.audiobookPlayerBottomInset, above: DSLayout.minimumTapTarget / 2, below: 0)
        }
    }

    // MARK: Grabber and dismissal

    private var grabber: some View {
        Button { close() } label: {
            Capsule()
                .fill(DSColor.audiobookPlayerGrabber)
                .frame(
                    width: DSLayout.audiobookPlayerGrabberSize.width,
                    height: DSLayout.audiobookPlayerGrabberSize.height
                )
                .padding(.top, DSLayout.audiobookPlayerGrabberTopInset)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(dismissDrag, including: dismissDragMask)
        .accessibilityLabel(localized("收合播放頁"))
    }

    /// Folds the player back into the root's bar, or takes the cover away.
    private func close() {
        if opensOutOfRootBar {
            NowPlayingHub.shared.isPlayerOpen = false
        } else {
            dismiss()
        }
    }

    /// Out of the root's bar, the bar's own drag folds the page back into it, the page shrinking
    /// into the bar under the finger; this one would fight it.
    private var dismissDragMask: GestureMask { opensOutOfRootBar ? .subviews : .all }

    /// The page follows a finger drawn down it, and goes once drawn far enough or flung.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: DSSpacing.sm)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let distance = DSLayout.audiobookPlayerDismissDistance
                if value.translation.height > distance || value.predictedEndTranslation.height > distance * 2 {
                    close()
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring) { dragOffset = 0 }
                }
            }
    }

    // MARK: Cover

    /// Large while playing, smaller while paused, as Apple Books' cover breathes with playback.
    /// A chapter loading keeps it as it was asked to be: playing.
    private var coverIsLarge: Bool { player.isPlaying || player.isLoading }

    private func cover(side: CGFloat) -> some View {
        Group {
            if let image = player.coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(DSColor.audiobookPlayerChip)
                    Image(systemName: "headphones")
                        .font(DSFont.fixed(size: side / 4))
                        .foregroundStyle(DSColor.audiobookPlayerControl)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.audiobookPlayerCoverCornerRadius, style: .continuous))
        .shadow(
            color: DSColor.audiobookPlayerCoverShadow,
            radius: coverIsLarge ? DSLayout.audiobookPlayerCoverShadowRadius : DSLayout.audiobookPlayerCoverShadowRadius / 2,
            y: coverIsLarge ? DSLayout.audiobookPlayerCoverShadowRadius / 2 : DSLayout.audiobookPlayerCoverShadowRadius / 4
        )
        // The cover the root bar's artwork grows into as the player opens, and shrinks back to.
        .popupTransitionTarget()
        .overlay {
            if player.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(DSColor.audiobookPlayerPrimary)
            }
        }
        .scaleEffect(coverIsLarge ? 1 : DSLayout.audiobookPlayerPausedCoverScale)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.72),
            value: coverIsLarge
        )
        .onTapGesture(perform: showWorkDetail)
        // The title beside it opens the same page; VoiceOver meets it there.
        .accessibilityHidden(true)
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(spacing: DSLayout.audiobookPlayerChipSpacing) {
            Button(action: showWorkDetail) {
                VStack(alignment: .leading, spacing: 0) {
                    AudiobookMarqueeText(
                        text: player.bookTitle,
                        font: DSFont.fixed(size: DSLayout.audiobookPlayerTitleFontSize, weight: .semibold),
                        color: DSColor.audiobookPlayerPrimary
                    )
                    if !player.bookAuthor.isEmpty {
                        AudiobookMarqueeText(
                            text: player.bookAuthor,
                            font: DSFont.fixed(size: DSLayout.audiobookPlayerTitleFontSize),
                            color: DSColor.audiobookPlayerSecondary
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canShowWorkDetail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                player.bookAuthor.isEmpty
                    ? player.bookTitle
                    : String(format: localized("%1$@，%2$@"), player.bookTitle, player.bookAuthor)
            )
            .accessibilityAddTraits(canShowWorkDetail ? .isButton : [])
            .accessibilityHint(canShowWorkDetail ? localized("作品詳情") : "")

            if isTransient, player.isActive(bookId: currentBookId) {
                addToShelfPill
            }
            moreButton
        }
        .padding(.leading, DSLayout.audiobookPlayerHorizontalMargin)
        .padding(.trailing, DSLayout.audiobookPlayerHorizontalMargin - 1)
    }

    /// Apple Books' price pill: here the one thing a book played without being shelved lacks.
    private var addToShelfPill: some View {
        Button(action: addToShelf) {
            Text(localized(addingToShelf ? "加入中…" : "加入書架"))
                .font(DSFont.fixed(size: DSLayout.audiobookPlayerPillFontSize, weight: .semibold))
                .foregroundStyle(DSColor.audiobookPlayerPrimary)
                .lineLimit(1)
                .padding(.horizontal, DSLayout.audiobookPlayerPillHorizontalPadding)
                .frame(height: DSLayout.audiobookPlayerPillHeight)
                .background(Capsule().fill(DSColor.audiobookPlayerChip))
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addingToShelf)
        .fixedSize()
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(spacing: DSSpacing.sm) {
            Text(message)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.audiobookPlayerPrimary)
                .multilineTextAlignment(.center)
            Button(localized("重試")) {
                player.retryCurrentChapter()
            }
            .foregroundStyle(DSColor.audiobookPlayerPrimary)
            .font(DSFont.subheadline.weight(.semibold))
        }
        .padding(.horizontal, DSLayout.audiobookPlayerHorizontalMargin)
        .padding(.top, DSSpacing.sm)
    }

    // MARK: ••• menu

    private var moreButton: some View {
        Group {
            if usesSequencedMenus {
                Button { showsMoreChooser = true } label: { moreLabel }
            } else {
                // Apple Books keeps 分享 on top and 移除… at the bottom even when the menu
                // opens upwards, where the system would otherwise flip it.
                Menu { moreMenuContent } label: { moreLabel }
                    .menuOrder(.fixed)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("更多"))
    }

    private var moreLabel: some View {
        Image(systemName: "ellipsis")
            .font(DSFont.fixed(size: DSLayout.audiobookPlayerPillFontSize, weight: .bold))
            .foregroundStyle(DSColor.audiobookPlayerPrimary)
            .frame(width: DSLayout.audiobookPlayerMoreButtonSide, height: DSLayout.audiobookPlayerMoreButtonSide)
            .background(Circle().fill(DSColor.audiobookPlayerChip))
            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }

    /// Apple Books' ••• in its order, on what Yuedu has; then what the recording lacks.
    @ViewBuilder
    private var moreMenuContent: some View {
        ControlGroup {
            if let shareURL {
                ShareLink(item: shareURL, preview: SharePreview(player.bookTitle)) {
                    Label(localized("分享"), systemImage: "square.and.arrow.up")
                }
            }
            Button { perform(.addToGroup) } label: {
                Label(localized("加入分組"), systemImage: "plus.circle")
            }
            .disabled(isTransient)
        }
        Section {
            ForEach(primaryMoreRoutes, id: \.self) { route in
                Button { perform(route) } label: { Label(route.title, systemImage: route.systemImage) }
            }
        }
        Section {
            Button { perform(.previousChapter) } label: {
                Label(localized("上一章"), systemImage: "backward.end")
            }
            .disabled(!player.hasPreviousChapter)
            Button { perform(.nextChapter) } label: {
                Label(localized("下一章"), systemImage: "forward.end")
            }
            .disabled(!player.hasNextChapter)
            Picker(selection: Binding(get: { player.playMode }, set: { perform(.playMode($0)) })) {
                ForEach(AudiobookPlayMode.allCases, id: \.self) { mode in
                    Label(mode.localizedTitle, systemImage: mode.systemImage).tag(mode)
                }
            } label: {
                Label(localized("播放模式"), systemImage: player.playMode.systemImage)
            }
            .pickerStyle(.menu)
            Button { perform(.skipCredits) } label: {
                Label(localized("跳過片頭片尾"), systemImage: skipsCredits ? "forward.fill" : "forward")
            }
            .accessibilityValue(skipCreditsValue)
            ForEach(sourceMoreRoutes, id: \.self) { route in
                Button { perform(route) } label: { Label(route.title, systemImage: route.systemImage) }
            }
        }
        if !isTransient {
            Section {
                Button(role: .destructive) { perform(.removeFromShelf) } label: {
                    Label(AudiobookMoreRoute.removeFromShelf.title, systemImage: AudiobookMoreRoute.removeFromShelf.systemImage)
                }
            }
        }
    }

    /// 加入書架 (加入藏書), 標記為已讀完, 作品詳情 (在商店中檢視): what applies to this book.
    private var primaryMoreRoutes: [AudiobookMoreRoute] {
        var routes: [AudiobookMoreRoute] = []
        if isTransient { routes.append(.addToShelf) }
        if let record = shelfRecord, record.currentPosition < 0.99 { routes.append(.markFinished) }
        if canShowWorkDetail { routes.append(.workDetail) }
        return routes
    }

    private var sourceMoreRoutes: [AudiobookMoreRoute] {
        guard let source = callBackSource else { return [] }
        var routes: [AudiobookMoreRoute] = []
        if SourceCallBackService.showsCustomButton(source) { routes.append(.customButton) }
        if player.currentAudioURL != nil { routes.append(.copyPlayURL) }
        return routes
    }

    /// The same rows for iOS 17's chooser, which has no submenus: one row per play mode.
    private var moreChooserActions: [DismissalSequencedAction<AudiobookMoreRoute>] {
        var routes: [AudiobookMoreRoute] = []
        if shareURL != nil { routes.append(.share) }
        if !isTransient { routes.append(.addToGroup) }
        routes += primaryMoreRoutes
        if player.hasPreviousChapter { routes.append(.previousChapter) }
        if player.hasNextChapter { routes.append(.nextChapter) }
        routes += AudiobookPlayMode.allCases.map(AudiobookMoreRoute.playMode)
        routes.append(.skipCredits)
        routes += sourceMoreRoutes
        if !isTransient { routes.append(.removeFromShelf) }
        return routes.map { route in
            if case .playMode(let mode) = route {
                return DismissalSequencedAction(
                    route: route,
                    title: String(format: localized("播放模式：%@"), mode.localizedTitle),
                    systemImage: mode == player.playMode ? "checkmark" : mode.systemImage
                )
            }
            return DismissalSequencedAction(
                route: route, title: route.title, systemImage: route.systemImage,
                isDestructive: route == .removeFromShelf
            )
        }
    }

    private func runPendingMoreRoute() {
        guard let route = moreSequence.consumeAfterDismissal() else { return }
        perform(route)
    }

    private func perform(_ route: AudiobookMoreRoute) {
        switch route {
        case .share:
            // iOS 17's chooser only; a native menu shares from its own `ShareLink`.
            if let shareURL {
                pendingShare = PendingShareExport(title: localized("分享"), name: player.bookTitle, item: shareURL)
            }
        case .addToGroup:
            showsAddToGroup = true
        case .addToShelf:
            addToShelf()
        case .markFinished:
            NowPlayingBookActions.markFinished(bookId: currentBookId, store: store)
        case .workDetail:
            showWorkDetail()
        case .previousChapter:
            player.previousChapter()
        case .nextChapter:
            player.nextChapter()
        case .playMode(let mode):
            player.setPlayMode(mode)
            // The menu has closed; VoiceOver hears the mode it chose.
            AccessibilityNotification.Announcement(mode.localizedTitle).post()
        case .skipCredits:
            showSkipCredits = true
        case .customButton:
            if let source = callBackSource {
                runSourceTap(.clickCustomButton, source: source, result: nil, fallback: nil)
            }
        case .copyPlayURL:
            if let source = callBackSource, let url = player.currentAudioURL?.absoluteString {
                runSourceTap(.clickCopyPlayUrl, source: source, result: url) {
                    UIPasteboard.general.string = url
                    BookSourceFormLoginView.presentToastAlert(message: localized("已複製"))
                }
            }
        case .removeFromShelf:
            confirmsRemoval = true
        }
    }

    private var skipsCredits: Bool {
        player.openingCreditsSeconds > 0 || player.closingCreditsSeconds > 0
    }

    private var skipCreditsValue: String {
        guard skipsCredits else { return localized("狀態：關閉") }
        return String(
            format: localized("片頭 %d 秒，片尾 %d 秒"),
            player.openingCreditsSeconds,
            player.closingCreditsSeconds
        )
    }

    // MARK: Shelf actions

    private func addToShelf() {
        guard !addingToShelf else { return }
        addingToShelf = true
        Task { @MainActor in
            defer { addingToShelf = false }
            if let id = await NowPlayingBookActions.addPlayingAudiobookToShelf(store: store, dependencies: dependencies) {
                shelvedBookId = id
            }
        }
    }

    /// 移除書架: the page goes with the book, as the reader's does.
    private func removeFromShelf() {
        NowPlayingBookActions.removeFromShelf(bookId: currentBookId, store: store) { close() }
    }

    private func resolveShareURL() -> URL? {
        player.playingBook.flatMap { NowPlayingBookActions.shareURL(for: $0, store: store) }
    }

    // MARK: 作品詳情

    /// A shelf book has its 作品詳情 over the player, as Apple Books' store page is; a book
    /// played from its own page without being shelved goes back to that page.
    private var canShowWorkDetail: Bool { !isTransient || detailIsPresenter }

    private func showWorkDetail() {
        guard canShowWorkDetail else { return }
        guard let record = shelfRecord else {
            close()
            return
        }
        guard let route = NowPlayingBookActions.workDetailRoute(for: record, store: store) else { return }
        workDetail = AudiobookWorkDetail(route: route)
    }

    private func workDetailPage(_ route: WorkDetailRoute) -> some View {
        NavigationStack {
            WorkDetailView(route: route, readerContext: WorkDetailReaderContext(
                bookId: currentBookId,
                continueReading: { target in
                    workDetail = nil
                    if let target { player.selectChapter(target.spineIndex) }
                },
                removedFromShelf: {
                    workDetail = nil
                    player.stop()
                    close()
                }
            ))
            .environmentObject(store)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { workDetail = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
        }
        // The detail page is the app's, in the app's own appearance.
        .environment(\.colorScheme, systemColorScheme)
    }

    @Environment(\.colorScheme) private var systemColorScheme

    // MARK: Progress

    private var progressSection: some View {
        AudiobookProgressSection(
            currentTime: player.currentTime,
            duration: player.duration,
            chapterIndex: player.chapterIndex,
            onSeek: { player.seek(to: $0, inChapter: $1) },
            onSkipBackward: { skip(by: -15) },
            onSkipForward: { skip(by: 15) },
            chapterTitle: player.currentChapterTitle,
            sleepFireDate: player.sleepFireDate
        )
        .disabled(player.isLoading || player.duration <= 0)
        .overlay(alignment: .topLeading) { skipBubble }
    }

    /// `+0:15` over the playhead after a skip, adding up while the skips keep coming.
    @ViewBuilder
    private var skipBubble: some View {
        if let skippedSeconds {
            GeometryReader { proxy in
                let fraction = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : 0
                let track = proxy.size.width - 2 * DSLayout.audiobookPlayerHorizontalMargin
                let x = DSLayout.audiobookPlayerHorizontalMargin + track * fraction
                Text(AudiobookPlayerTime.skipped(skippedSeconds))
                    .font(DSFont.fixed(size: DSLayout.audiobookPlayerTimeFontSize + 1, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DSColor.audiobookPlayerPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, DSSpacing.xxs)
                    .background(Capsule().fill(DSColor.audiobookPlayerSkipBubble))
                    .fixedSize()
                    .position(
                        x: min(max(x, DSLayout.audiobookPlayerHorizontalMargin + DSSpacing.lg),
                               proxy.size.width - DSLayout.audiobookPlayerHorizontalMargin - DSSpacing.lg),
                        y: DSLayout.audiobookPlayerSliderHeight / 2 - DSLayout.audiobookPlayerSkipBubbleRise
                    )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
            .task(id: skipBubbleGeneration) {
                // How long the bubble is shown — a display time, not a wait for state to settle:
                // each skip restarts it, and a cancelled sleep leaves the bubble to the newer skip.
                do {
                    try await Task.sleep(for: .seconds(DSLayout.audiobookPlayerSkipBubbleDuration))
                    withAnimation { self.skippedSeconds = nil }
                } catch {}
            }
        }
    }

    private func skip(by seconds: TimeInterval) {
        if seconds < 0 { player.skipBackward(-seconds) } else { player.skipForward(seconds) }
        withAnimation(.easeOut(duration: 0.15)) {
            skippedSeconds = (skippedSeconds ?? 0) + seconds
        }
        skipBubbleGeneration += 1
    }

    // MARK: Transport

    private var transportRow: some View {
        AudiobookFractionalRow(centers: DSLayout.audiobookPlayerTransportCenters) {
            speedButton
            Button { skip(by: -15) } label: {
                transportIcon("gobackward.15", size: DSLayout.audiobookPlayerSkipIconSize)
            }
            .accessibilityLabel(localized("倒退 15 秒"))
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(DSFont.fixed(size: DSLayout.audiobookPlayerPlayIconSize))
                    .foregroundStyle(DSColor.audiobookPlayerPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: DSLayout.audiobookPlayerPlayButtonSide, height: DSLayout.audiobookPlayerPlayButtonSide)
                    .contentShape(Rectangle())
            }
            .disabled(player.isLoading)
            .accessibilityLabel(localized(player.isPlaying ? "暫停" : "播放"))
            Button { skip(by: 15) } label: {
                transportIcon("goforward.15", size: DSLayout.audiobookPlayerSkipIconSize)
            }
            .accessibilityLabel(localized("快轉 15 秒"))
            sleepButton
        }
        .buttonStyle(.plain)
    }

    private func transportIcon(_ systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(DSFont.fixed(size: size))
            .foregroundStyle(DSColor.audiobookPlayerControl)
            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }

    /// 「1倍」, lit up — white, heavier and glowing — once the speed is anything else, as Apple
    /// Books marks a speed that changes playback.
    private var speedButton: some View {
        let isChanged = AudiobookPlaybackRate.snapped(player.playbackRate) != 1
        return Button { showsSpeed = true } label: {
            Text(AudiobookPlaybackRate.label(player.playbackRate))
                .font(DSFont.fixed(
                    size: DSLayout.audiobookPlayerSpeedFontSize,
                    weight: isChanged ? .semibold : .medium
                ).monospacedDigit())
                .foregroundStyle(isChanged ? DSColor.audiobookPlayerPrimary : DSColor.audiobookPlayerControl)
                .shadow(color: isChanged ? DSColor.audiobookPlayerActiveGlow : .clear, radius: DSSpacing.sm)
                .contentTransition(.numericText(value: Double(player.playbackRate)))
                .animation(reduceMotion ? nil : .snappy, value: player.playbackRate)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("倍速"))
        .accessibilityValue(AudiobookPlaybackRate.label(player.playbackRate))
        .popover(isPresented: $showsSpeed, arrowEdge: .bottom) {
            AudiobookSpeedPicker(rate: player.playbackRate) { player.setRate($0) }
                .audiobookPlayerPopover(palette: palette)
        }
    }

    // MARK: Sleep timer

    private var sleepButton: some View {
        Group {
            if usesSequencedMenus {
                Button { showsSleepChooser = true } label: { sleepLabel }
            } else {
                Menu {
                    ForEach(AudiobookSleepChoice.menu, id: \.self) { choice in
                        // A toggle per row: checked where the timer is, and each tap acts —
                        // 自訂 again opens the wheel again.
                        Toggle(choice.title, isOn: Binding(
                            get: { AudiobookSleepChoice(player.sleepOption) == choice },
                            set: { _ in choose(choice) }
                        ))
                    }
                } label: {
                    sleepLabel
                }
                // 自訂 on top, 關閉 at the bottom, as Apple Books lists them above the moon.
                .menuOrder(.fixed)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("睡眠定時"))
        .accessibilityValue(sleepAccessibilityValue)
        .popover(isPresented: $showsCustomSleep, arrowEdge: .bottom) {
            AudiobookCustomSleepTimer { minutes in
                showsCustomSleep = false
                player.setSleepOption(.minutes(minutes))
            }
            .audiobookPlayerPopover(palette: palette)
        }
    }

    private var sleepIsActive: Bool { player.sleepOption != .off }

    private var sleepLabel: some View {
        Image(systemName: sleepIsActive ? "moon.zzz.fill" : "moon.zzz")
            .font(DSFont.fixed(size: DSLayout.audiobookPlayerSleepIconSize))
            .foregroundStyle(sleepIsActive ? DSColor.audiobookPlayerPrimary : DSColor.audiobookPlayerControl)
            .shadow(color: sleepIsActive ? DSColor.audiobookPlayerActiveGlow : .clear, radius: DSSpacing.sm)
            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }

    private var sleepAccessibilityValue: String {
        if let fireDate = player.sleepFireDate {
            return AudiobookPlayerTime.spokenCountdown(to: fireDate, from: Date())
        }
        return AudiobookSleepChoice(player.sleepOption).title
    }

    private func choose(_ choice: AudiobookSleepChoice) {
        if let option = choice.option {
            player.setSleepOption(option)
        } else {
            showsCustomSleep = true
        }
    }

    private var sleepChooserActions: [DismissalSequencedAction<AudiobookSleepChoice>] {
        let current = AudiobookSleepChoice(player.sleepOption)
        return AudiobookSleepChoice.menu.map { choice in
            DismissalSequencedAction(
                route: choice, title: choice.title,
                systemImage: choice == current ? "checkmark" : "moon.zzz"
            )
        }
    }

    private func runPendingSleepChoice() {
        guard let choice = sleepSequence.consumeAfterDismissal() else { return }
        choose(choice)
    }

    // MARK: Volume and bottom row

    private var volumeRow: some View {
        HStack(spacing: DSLayout.audiobookPlayerVolumeSpacing) {
            Image(systemName: "speaker.fill")
                .font(DSFont.fixed(size: DSLayout.audiobookPlayerSpeakerIconSize))
                .frame(width: DSLayout.audiobookPlayerQuietSpeakerWidth)
                .accessibilityHidden(true)
            AudiobookVolumeSlider()
                .frame(height: DSLayout.audiobookPlayerSliderHeight)
            Image(systemName: "speaker.wave.3.fill")
                .font(DSFont.fixed(size: DSLayout.audiobookPlayerSpeakerIconSize))
                .frame(width: DSLayout.audiobookPlayerLoudSpeakerWidth)
                .accessibilityHidden(true)
        }
        .foregroundStyle(DSColor.audiobookPlayerControl)
        .padding(.leading, DSLayout.audiobookPlayerVolumeLeadingInset)
        .padding(.trailing, DSLayout.audiobookPlayerVolumeTrailingInset)
    }

    private var bottomRow: some View {
        AudiobookFractionalRow(centers: DSLayout.audiobookPlayerBottomRowCenters) {
            AudiobookRoutePicker()
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            Button { showChapterList = true } label: {
                Image(systemName: "list.bullet")
                    .font(DSFont.fixed(size: DSLayout.audiobookPlayerBottomIconSize))
                    .foregroundStyle(DSColor.audiobookPlayerControl)
                    .opacity(player.chapters.isEmpty ? DSLayout.audiobookPlayerDisabledOpacity : 1)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.chapters.isEmpty)
            .accessibilityLabel(localized("目錄"))
        }
    }

    // MARK: Source events (legado `AudioPlayActivity` custom button / 複製播放 URL)

    /// The book's source when it listens for events or asks for its own button.
    private var callBackSource: BookSource? {
        guard let id = shelfRecord?.bookSourceId,
              let source = BookSourceStore.shared.source(id: id),
              SourceCallBackService.isListening(source) || SourceCallBackService.showsCustomButton(source)
        else { return nil }
        return source
    }

    private var currentCallBackChapter: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot? {
        player.chapters.indices.contains(player.chapterIndex)
            ? SourceCallBackService.chapterSnapshot(player.chapters[player.chapterIndex]) : nil
    }

    private func runSourceTap(
        _ event: SourceCallBackEvent, source: BookSource, result: String?,
        fallback: (@MainActor () -> Void)?
    ) {
        guard let book = store.readingBook(id: currentBookId) else { return }
        let chapter = currentCallBackChapter
        Task { @MainActor in
            let outcome = await SourceCallBackService.tap(
                event, source: source,
                book: SourceCallBackService.snapshot(of: book, chapter: chapter),
                runtimeVariables: book.runtimeVariables ?? [:], chapter: chapter, result: result
            )
            if let page = outcome.page {
                // The script ran for seconds; the menu that started it is long gone.
                sourcePage = page
            }
            if SourceCallBackService.shouldFallBack(outcome) {
                fallback?()
            }
        }
    }

    // MARK: Helpers

    static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() { return "\(Int(rate)).0x" }
        return "\(rate)x"
    }

    /// The timeline's VoiceOver value: where it is, of how long. Made of the times printed
    /// under it.
    static func positionText(_ time: TimeInterval, of duration: TimeInterval) -> String {
        guard duration > 0 else { return formatTime(time) }
        return String(format: localized("%1$@，共 %2$@"), formatTime(time), formatTime(duration))
    }

    nonisolated static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// 作品詳情 over the player, by an identity of its own: a route is a value, and the same book's
/// route opened twice is two presentations.
struct AudiobookWorkDetail: Identifiable {
    let id = UUID()
    let route: WorkDetailRoute
}

/// What the ••• menu does; also the rows of iOS 17's chooser.
enum AudiobookMoreRoute: Hashable {
    case share
    case addToGroup
    case addToShelf
    case markFinished
    case workDetail
    case previousChapter
    case nextChapter
    case playMode(AudiobookPlayMode)
    case skipCredits
    case customButton
    case copyPlayURL
    case removeFromShelf

    var title: String {
        switch self {
        case .share: localized("分享")
        case .addToGroup: localized("加入分組")
        case .addToShelf: localized("加入書架")
        case .markFinished: localized("標記為已讀完")
        case .workDetail: localized("作品詳情")
        case .previousChapter: localized("上一章")
        case .nextChapter: localized("下一章")
        case .playMode(let mode): mode.localizedTitle
        case .skipCredits: localized("跳過片頭片尾")
        case .customButton: localized("自訂按鈕")
        case .copyPlayURL: localized("複製播放網址")
        case .removeFromShelf: localized("移除書架…")
        }
    }

    var systemImage: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .addToGroup: "plus.circle"
        case .addToShelf: "text.badge.plus"
        case .markFinished: "checkmark.circle"
        case .workDetail: "info.circle"
        case .previousChapter: "backward.end"
        case .nextChapter: "forward.end"
        case .playMode(let mode): mode.systemImage
        case .skipCredits: "forward"
        case .customButton: "hand.tap"
        case .copyPlayURL: "link"
        case .removeFromShelf: "trash"
        }
    }
}

/// The page's measures for the window it is in: Apple Books' vertical gaps scaled to the
/// window's height, and its column on a wide window.
struct AudiobookPlayerLayout {
    let isCompactHeight: Bool
    let columnWidth: CGFloat
    let verticalScale: CGFloat

    init(proxy: GeometryProxy, isCompactHeight: Bool) {
        self.isCompactHeight = isCompactHeight
        let fullHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        verticalScale = min(1, max(
            DSLayout.audiobookPlayerMinimumVerticalScale,
            fullHeight / DSLayout.audiobookPlayerReferenceHeight
        ))
        columnWidth = min(proxy.size.width, DSLayout.audiobookPlayerMaximumColumnWidth)
    }

    var coverTopGap: CGFloat { DSLayout.audiobookPlayerCoverTopGap * verticalScale }

    /// The cover's side in the room between the grabber and the title: the column less its
    /// insets, or less where the room is shorter.
    func coverSide(in region: CGSize) -> CGFloat {
        let byWidth = region.width - 2 * DSLayout.audiobookPlayerCoverHorizontalInset
        let byHeight = region.height - coverTopGap - DSLayout.audiobookPlayerCoverMinimumBottomGap * verticalScale
        return max(0, min(byWidth, byHeight))
    }

    /// The space between two rows whose centres are `centerGap` apart (scaled), given the
    /// halves of the rows above and below it.
    func gap(_ centerGap: CGFloat, above: CGFloat, below: CGFloat) -> some View {
        Color.clear.frame(height: max(0, centerGap * verticalScale - above - below))
    }
}

// MARK: - Chapter list

struct AudiobookChapterListView: View {
    @ObservedObject var player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.chapters, id: \.index) { chapter in
                    Button {
                        player.selectChapter(chapter.index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title.isEmpty
                                 ? String(format: localized("第 %d 章"), chapter.index + 1)
                                 : chapter.title)
                                .foregroundStyle(DSColor.textPrimary)
                                .font(DSFont.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if chapter.index == player.chapterIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(DSColor.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityAddTraits(chapter.index == player.chapterIndex ? .isSelected : [])
                    .interfaceSectionSurface()
                    .id(chapter.index)
                }
                .softScrollEdges()
                .onAppear { proxy.scrollTo(player.chapterIndex, anchor: .center) }
            }
            // Rows carry their own surface; the modifier below only clears the list
            // container, not each row's system fill. docs/design.md §4.1.
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("目錄"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
        }
    }
}

// MARK: - Skip credits

/// legado-E / legado-with-MD3 跳過片頭片尾: the seconds skipped at the start and cut at the
/// end of every chapter of this book, 0–180 each, in whole seconds as legado has them.
struct AudiobookSkipCreditsView: View {
    @ObservedObject var player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var openingSeconds: Double
    @State private var closingSeconds: Double

    private let range = Double(AudiobookPlayer.creditsSecondsRange.lowerBound)
        ... Double(AudiobookPlayer.creditsSecondsRange.upperBound)

    init(player: AudiobookPlayer) {
        self.player = player
        _openingSeconds = State(initialValue: Double(player.openingCreditsSeconds))
        _closingSeconds = State(initialValue: Double(player.closingCreditsSeconds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsSliderRow(
                        title: localized("片頭"),
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        valueText: Self.secondsText(openingSeconds),
                        value: $openingSeconds,
                        range: range,
                        step: 1
                    )
                    SettingsSliderRow(
                        title: localized("片尾"),
                        systemImage: "text.line.last.and.arrowtriangle.forward",
                        valueText: Self.secondsText(closingSeconds),
                        value: $closingSeconds,
                        range: range,
                        step: 1
                    )
                } footer: {
                    Text(localized("只套用在這本書；片頭只在章節從頭播放時跳過。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .navigationTitle(localized("跳過片頭片尾"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player.setSkipCredits(
                            openingSeconds: Int(openingSeconds.rounded()),
                            closingSeconds: Int(closingSeconds.rounded())
                        )
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
    }

    private static func secondsText(_ seconds: Double) -> String {
        String(format: localized("%d 秒"), Int(seconds.rounded()))
    }
}

// MARK: - Play mode presentation

extension AudiobookPlayMode {
    /// legado-with-MD3's names for the modes (`audio_play_mode_*`).
    var localizedTitle: String {
        switch self {
        case .listEndStop: return localized("順序播放")
        case .singleLoop: return localized("單曲循環")
        case .random: return localized("隨機播放")
        case .listLoop: return localized("列表循環")
        }
    }

    var systemImage: String {
        switch self {
        case .listEndStop: return "arrow.right.to.line"
        case .singleLoop: return "repeat.1"
        case .random: return "shuffle"
        case .listLoop: return "repeat"
        }
    }
}

#if DEBUG
#Preview {
    AudiobookReaderView(bookId: UUID())
        .environmentObject(BookStore())
}

#Preview("橫向", traits: .landscapeLeft) {
    AudiobookReaderView(bookId: UUID())
        .environmentObject(BookStore())
}

#Preview("跳過片頭片尾") {
    AudiobookSkipCreditsView(player: .shared)
}
#endif

// MARK: - 播放進度

/// The chapter's timeline, and the place to drag it somewhere else: Apple Books' thumbless bar,
/// the time played and the time left at its ends, the chapter's title between them — and, while
/// a sleep timer runs, its count-down in place of the time left.
struct AudiobookProgressSection: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    /// The chapter `currentTime` is on.
    let chapterIndex: Int
    /// A time on the timeline of the chapter the scrub began on.
    let onSeek: (TimeInterval, Int?) -> Void
    /// VoiceOver's swipe down / up: the 15 seconds the buttons beside play skip.
    let onSkipBackward: () -> Void
    let onSkipForward: () -> Void
    var chapterTitle: String = ""
    var sleepFireDate: Date?

    /// The times' line, half of it: the page's gaps are measured to its centre.
    static let labelsHalfHeight = DSLayout.audiobookPlayerTimeFontSize / 2 + 1

    /// The time under the finger while it drags.
    @State private var scrubTime: TimeInterval?
    /// The chapter the scrub began on; its times are only meaningful on that chapter.
    @State private var scrubbedChapter: Int?

    private var shownTime: TimeInterval { scrubTime ?? currentTime }

    var body: some View {
        VStack(spacing: 0) {
            ScrubSlider(
                value: shownTime,
                bounds: 0...max(duration, 1),
                tint: DSColor.audiobookPlayerTrackFill,
                trackTint: DSColor.audiobookPlayerTrack,
                isThumbless: true,
                onScrub: { time in
                    if scrubTime == nil { scrubbedChapter = chapterIndex }
                    scrubTime = time
                },
                onCommit: { time in
                    // Once per scrub, never per tick: a seek to the chapter's end every ~40 ms
                    // while the finger rested there finished whichever chapter was current by
                    // then (simulator, CoreMedia log) — chapters were skipped.
                    onSeek(time, scrubbedChapter)
                    scrubTime = nil
                },
                onIncrement: onSkipForward,
                onDecrement: onSkipBackward
            )
            .frame(height: DSLayout.audiobookPlayerSliderHeight)
            .accessibilityLabel(localized("播放進度"))
            .accessibilityValue(AudiobookReaderView.positionText(shownTime, of: duration))

            ZStack {
                Text(chapterTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, DSLayout.audiobookPlayerChapterTitleInset)
                HStack {
                    Text(AudiobookReaderView.formatTime(shownTime))
                    Spacer()
                    trailingTime
                }
            }
            .font(DSFont.fixed(size: DSLayout.audiobookPlayerTimeFontSize, weight: .medium).monospacedDigit())
            .foregroundStyle(DSColor.audiobookPlayerTertiary)
            .frame(height: Self.labelsHalfHeight * 2)
            .padding(.top, DSLayout.audiobookPlayerTimeLabelGap - DSLayout.audiobookPlayerSliderHeight / 2 - Self.labelsHalfHeight)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, DSLayout.audiobookPlayerHorizontalMargin)
    }

    @ViewBuilder
    private var trailingTime: some View {
        if let sleepFireDate {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Label {
                    Text(AudiobookPlayerTime.countdown(to: sleepFireDate, from: timeline.date))
                } icon: {
                    Image(systemName: "zzz")
                }
                .labelStyle(AudiobookCountdownLabelStyle())
                .foregroundStyle(DSColor.audiobookPlayerPrimary)
            }
        } else {
            Text(AudiobookPlayerTime.remaining(shownTime, of: duration))
        }
    }
}

/// The count-down's 「zzz 45:00」: the symbol tight before the time.
private struct AudiobookCountdownLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DSSpacing.xxs) {
            configuration.icon
            configuration.title
        }
    }
}

#Preview("播放進度") {
    AudiobookProgressSection(
        currentTime: 100,
        duration: 600,
        chapterIndex: 0,
        onSeek: { _, _ in },
        onSkipBackward: {},
        onSkipForward: {},
        chapterTitle: "第 1 章",
        sleepFireDate: Date().addingTimeInterval(45 * 60)
    )
    .padding(.vertical, DSSpacing.lg)
    .background(AudiobookPlayerPalette(cover: nil).gradient)
    .environment(\.colorScheme, .dark)
}
