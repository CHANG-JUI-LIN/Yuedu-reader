import CryptoKit
import SwiftUI

/// Everything a video detail page pushes, through its one `navigationDestination`.
private enum VideoDetailPush: Hashable {
    case category(ExploreCategoryReference)
    case book(OnlineBook)
}

/// What the player cover shows: a shelf book through the reader entry, or a book played from
/// this page without being shelved.
private enum VideoPlayerRequest: Identifiable {
    case shelf(UUID)
    case transient(ReadingBook)

    var id: UUID {
        switch self {
        case .shelf(let id): id
        case .transient(let book): book.id
        }
    }
}

/// A video's detail page, laid out as a media centre lays out a series (maintainer, 2026-11-01:
/// 「視頻的詳情頁就是按照emby播放器，別共用一個詳情頁」「就是什麼海報牆之類的」, then 「去看
/// infuse、rex、senplayer、vidhub…的詳情頁」): the poster across the top, fading into the page
/// (`VideoDetailHero`), the title and a row of buttons led by play, then 選集 — the 線路
/// picked as a season is, its episodes as tiles — and a poster wall of the source's other works
/// in the same genre. Videos only: books keep Editorial Minimalism.
///
/// Its data goes through the services every detail page uses: the shared fetcher for detail
/// and episodes, `ShelfWorkService` for the shelf, `SourceGenreLinks` for the genre wall.
struct VideoDetailView: View {
    private let searchBook: SearchBook?
    private let onRemoveFromShelf: (() -> Void)?
    /// Hands a confirmed switch to a source of another kind to `OnlineBookDetailDestination`.
    private let onSourceKindChange: ((BookOrigin) -> Void)?
    private let workVersions: BookDetailInfoChoice?

    @State private var currentBook: OnlineBook
    @State private var pushed: VideoDetailPush?
    @StateObject private var genres = SourceGenreLinks()
    @EnvironmentObject var bookStore: BookStore
    // A stable binding while a page is pushed above this one, as on the other detail pages.
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.appDependencies) private var dependencies
    /// The artwork the poster card drew, for the hero's full-width poster; nil while it loads
    /// and when there is none. A cached poster is there from the first frame.
    @State private var poster: UIImage?
    /// The average colour of the poster's foot, which it fades into and the page is drawn in.
    @State private var posterFoot: CoverTint.RGB?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    private var source: BookSource? { BookSourceStore.shared.source(id: currentBook.sourceId) }

    @State private var chapters: [OnlineChapterRef] = []
    /// The 線路 and episodes `chapters` holds, read once per list.
    @State private var guide = VideoEpisodeGuide(chapters: [])
    @State private var loading = false
    @State private var loadError: String?
    @State private var detailInfo: OnlineBook?
    @State private var loadedRuntimeVariables: [String: String]?
    @State private var introExpanded = false
    @State private var addingToShelf = false
    @State private var addedBookId: UUID?
    @State private var alreadyInShelf = false
    @State private var player: VideoPlayerRequest?
    @State private var routeID = 0
    /// The episode at the leading edge of 選集's row: where it scrolls to, and which run of
    /// episodes the bar under it marks.
    @State private var leadingEpisode: Int?
    @State private var showsEpisodes = false
    @State private var pendingEpisode: Int?
    @State private var showSourcePicker = false
    @State private var pendingOrigin: BookOrigin?
    @State private var kindMismatchOrigin: BookOrigin?
    @State private var pendingVersion: String?
    @State private var confirmsRemoval = false
    @State private var showsSourceVariableEditor = false
    @State private var showsBookVariableEditor = false
    @State private var showsMoreChooser = false
    @State private var sourceCallBackTap: SourceCallBackTapRequest?
    @State private var introActionRequest: BookIntroActionRequest?

    // MARK: Init

    /// Single-source entry (Discover, the shelf).
    init(
        book: OnlineBook,
        onRemoveFromShelf: (() -> Void)? = nil,
        onSourceKindChange: ((BookOrigin) -> Void)? = nil,
        workVersions: BookDetailInfoChoice? = nil
    ) {
        self.searchBook = nil
        self.onRemoveFromShelf = onRemoveFromShelf
        self.onSourceKindChange = onSourceKindChange
        self.workVersions = workVersions
        let sanitized = OnlineBookDetailPresentationPolicy.sanitized(book)
        _currentBook = State(initialValue: sanitized)
        _poster = State(initialValue: BookCoverLoader.cachedImage(for: sanitized.coverUrl))
    }

    /// Search entry: `initialOrigin` when given, else the first video origin, else the first.
    init(
        searchBook: SearchBook,
        initialOrigin: BookOrigin? = nil,
        onRemoveFromShelf: (() -> Void)? = nil,
        onSourceKindChange: ((BookOrigin) -> Void)? = nil,
        workVersions: BookDetailInfoChoice? = nil
    ) {
        self.searchBook = searchBook
        self.onRemoveFromShelf = onRemoveFromShelf
        self.onSourceKindChange = onSourceKindChange
        self.workVersions = workVersions
        let origin = initialOrigin ?? searchBook.preferredOrigin(for: .video) ?? searchBook.origins.first
        let book = origin.map { OnlineBook(detailOrigin: $0, in: searchBook) }
            ?? OnlineBook(
                id: SearchResultDetailIdentity.onlineBookID(searchBookID: searchBook.id, originID: nil),
                name: searchBook.name, author: searchBook.author, intro: "", coverUrl: "",
                bookUrl: "", tocUrl: "", wordCount: "", lastChapter: "", kind: "",
                sourceId: searchBook.id, sourceName: "")
        _currentBook = State(initialValue: book)
        _poster = State(initialValue: BookCoverLoader.cachedImage(for: book.coverUrl))
    }

    // MARK: Display

    private var displayName: String {
        if let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let b = currentBook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? localized("未知書名") : b
    }

    private var displayAuthor: String {
        let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return d.isEmpty ? currentBook.author.trimmingCharacters(in: .whitespacesAndNewlines) : d
    }

    private var displayCoverUrl: String {
        if let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return currentBook.coverUrl
    }

    private var displayIntro: String {
        if let detail = detailInfo?.intro, !detail.isEmpty { return detail }
        return currentBook.intro
    }

    private var tags: [String] {
        OnlineBookMetadataFormatter.tags(detailKind: detailInfo?.kind, fallbackKind: currentBook.kind)
    }

    private var sourceName: String {
        let name = currentBook.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let s = source?.bookSourceName, !s.isEmpty { return s }
        return localized("未知來源配置")
    }

    private var resolvedTOCURL: String? {
        if let detailed = detailInfo?.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines), !detailed.isEmpty {
            return detailed
        }
        let fallback = currentBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private var resolvedRuntimeVariables: [String: String]? {
        loadedRuntimeVariables ?? detailInfo?.runtimeVariables ?? currentBook.runtimeVariables
    }


    private func episodeTitle(_ chapterIndex: Int) -> String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: chapters[chapterIndex].title)
    }

    /// The shelf copy's saved episode, while the book is on the shelf and has been played.
    private var resumeEpisode: Int? {
        guard let id = addedBookId ?? existingShelfBookId(),
              let book = bookStore.shelfRecord(id: id),
              book.audioChapterIndex > 0 || book.audioTimeSeconds > 0,
              guide.route(containing: book.audioChapterIndex) != nil else { return nil }
        return book.audioChapterIndex
    }

    // MARK: Body

    var body: some View {
        let guide = guide
        return BookDetailScaffold(title: displayName, compactAction: playAction(guide), heroUnderBars: true,
                                  pageTint: pageTint) {
            hero(guide)
        } content: {
            episodesSection(guide)
            BookDetailRelatedSection(
                related: genres.related,
                choices: genres.choices,
                layout: .wall,
                onChoose: { title in
                    guard let key = genreLoadKey else { return }
                    Task { await genres.choose(title, key: key, source: source, tags: tags, book: currentBook) }
                },
                onShowAll: { pushed = .category($0) },
                onSelect: { pushed = .book($0) },
                onRetry: {
                    guard let key = genreLoadKey else { return }
                    Task { await genres.retryRelated(key: key, source: source, tags: tags, book: currentBook) }
                }
            )
            BookDetailInfoSection(items: infoItems(guide))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BookDetailMoreMenu(
                    hasSource: source != nil,
                    onSetSourceVariable: { showsSourceVariableEditor = true },
                    onSetBookVariable: { showsBookVariableEditor = true },
                    onOpenChooser: { showsMoreChooser = true },
                    sourceActions: sourceMenuActions
                )
            }
        }
        .bookDetailMoreChooser(
            isPresented: $showsMoreChooser,
            onSetSourceVariable: { showsSourceVariableEditor = true },
            onSetBookVariable: { showsBookVariableEditor = true },
            sourceActions: sourceMenuActions
        )
        .sourceCallBackTaps($sourceCallBackTap)
        .bookIntroActions($introActionRequest) { load() }
        .bookVariableEditors(
            source: source,
            showsSourceVariable: $showsSourceVariableEditor,
            showsBookVariable: $showsBookVariableEditor,
            bookVariable: { BookCustomVariable.value(in: effectiveRuntimeVariables) },
            onSaveBookVariable: saveBookVariable
        )
        .sheet(isPresented: $showSourcePicker, onDismiss: resolvePendingOrigin) { sourceSheet }
        .sourceKindMismatchAlert(origin: $kindMismatchOrigin, onConfirm: applyOrigin)
        .removeFromShelfConfirmation(isPresented: $confirmsRemoval, onConfirm: removeFromShelf)
        // Played once the sheet has gone, so the player is not presented over a sheet leaving.
        .sheet(isPresented: $showsEpisodes, onDismiss: {
            guard let chapterIndex = pendingEpisode else { return }
            pendingEpisode = nil
            play(chapterIndex: chapterIndex)
        }) {
            VideoEpisodeSheet(guide: guide, current: resumeEpisode, title: episodeTitle) { chapterIndex in
                pendingEpisode = chapterIndex
                showsEpisodes = false
            }
        }
        .navigationDestination(item: $pushed) { push in
            switch push {
            case .category(let reference):
                BookDetailCategoryPage(reference: reference).environmentObject(bookStore)
            case .book(let book):
                BookDetailRelatedBookDestination(book: book).environmentObject(bookStore)
            }
        }
        .fullScreenCover(item: $player) { request in
            switch request {
            case .shelf(let id):
                // The reader entry moves the book to the front of 繼續閱讀, as the audiobook
                // page's does. Never the shelf's card driver: its close would go to the shelf,
                // not this cover.
                BookReaderView(bookId: id)
                    .environmentObject(bookStore)
                    .environment(\.readerNavigator, nil)
            case .transient(let book):
                VideoPlayerView(content: .transient(book), onClose: { player = nil })
                    .environmentObject(bookStore)
            }
        }
        .onAppear {
            checkAlreadyInShelf()
            if chapters.isEmpty, loadError == nil { load() }
        }
        .task(id: genreLoadKey) {
            guard let key = genreLoadKey else { return }
            await genres.load(key: key, source: source, tags: tags, book: currentBook)
        }
        .task(id: poster) {
            guard let poster else {
                posterFoot = nil
                return
            }
            posterFoot = await Task.detached(priority: .utility) {
                CoverTint.average(of: poster, bottomFraction: DSLayout.videoPosterFootFraction)
            }.value
        }
    }

    // MARK: Hero

    /// The colour of the poster's foot, darkened as far as white text on it needs; a neutral
    /// dark grey until the poster has loaded, and when there is none.
    private var pageTint: Color {
        guard let posterFoot else { return CoverTint.placeholder.color }
        return CoverTint.background(for: posterFoot, minimumContrast: contrast == .increased ? 7 : 4.5).color
    }

    private func hero(_ guide: VideoEpisodeGuide) -> some View {
        VideoDetailHero(poster: poster, title: displayName, facts: facts(guide)) {
            // The card fetches the artwork, through the path every cover takes; what it
            // draws becomes the full-width poster.
            cover.environment(\.coverImageObserver) { image in poster = image }
        } actions: {
            heroActions(guide)
        } intro: {
            if !displayIntro.isEmpty {
                BookDetailIntroSection(
                    text: displayIntro,
                    isExpanded: $introExpanded,
                    baseURL: currentBook.bookUrl,
                    onAction: requestIntroAction,
                    readsSourceFormats: true,
                    isUnavailable: false,
                    placement: .hero
                )
            }
        }
    }

    private var cover: some View {
        BookCoverImage(
            coverURL: displayCoverUrl,
            title: displayName,
            author: displayAuthor,
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
    }

    /// The maker, then the episode count and the source's genres: the line under the title.
    private func facts(_ guide: VideoEpisodeGuide) -> [String] {
        var facts: [String] = []
        let count = guide.routes.first?.episodes.count ?? 0
        if count > 0 { facts.append(String(format: localized("共 %d 集"), count)) }
        for tag in tags where !facts.contains(tag) { facts.append(tag) }
        let maker = displayAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        return (maker.isEmpty ? [] : [maker]) + facts.prefix(DSLayout.videoHeroFactLimit)
    }

    /// VidHub's action row: the play button, then the page's other actions together in one
    /// glass capsule as tall as it (maintainer, 2026-11-01: 「那三個按鈕包在一個膠囊裡面」,
    /// 「我要的是這樣的玻璃膠囊」); the capsule goes under it when the text is too large for
    /// one line.
    private func heroActions(_ guide: VideoEpisodeGuide) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.lg) {
                playButton(guide)
                actionCapsule(guide)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: DSSpacing.md) {
                playButton(guide)
                actionCapsule(guide)
            }
        }
    }

    private func actionCapsule(_ guide: VideoEpisodeGuide) -> some View {
        HStack(spacing: 0) { iconButtons(guide) }
            .font(DSFont.title3)
            .foregroundStyle(DSColor.textPrimary)
            .buttonStyle(.borderless)
            .frame(maxHeight: .infinity)
            .modifier(CardButtonGlass())
    }

    /// 繼續播放 at the saved episode, else 開始播放 at the first; either names the episode.
    private func playAction(_ guide: VideoEpisodeGuide) -> BookDetailAction {
        let resume = resumeEpisode
        let episode = resume ?? guide.firstEpisode
        return BookDetailAction(
            title: resume != nil ? localized("繼續播放") : localized("開始播放"),
            systemImage: "play.fill",
            isBusy: false,
            isEnabled: !guide.isEmpty && !addingToShelf,
            detail: episode.map { VideoEpisodeNaming.resumeDetail($0, in: guide, title: episodeTitle) },
            action: { if let episode { play(chapterIndex: episode) } }
        )
    }

    /// The white capsule plezy, Infuse and VidHub lead with, in light and dark alike
    /// (maintainer, 2026-11-01: 「給我調成白色吧，白天模式下」): its title, and the episode
    /// it plays on a second line under it.
    private func playButton(_ guide: VideoEpisodeGuide) -> some View {
        let action = playAction(guide)
        return Button(action: action.action) {
            HStack(spacing: DSLayout.videoPlayIconSpacing) {
                Image(systemName: action.systemImage)
                    .font(DSFont.subheadline)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(action.title)
                        .font(DSFont.footnote.weight(.semibold))
                    if let detail = action.detail {
                        Text(detail)
                            .font(DSFont.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            .padding(.vertical, DSSpacing.sm)
            .padding(.horizontal, DSSpacing.lg)
            .frame(maxWidth: DSLayout.videoPlayButtonMaxWidth)
        }
        .buttonStyle(BookDetailCardActionStyle(fill: DSColor.cardPrimaryActionFill,
                                               label: DSColor.cardPrimaryActionLabel,
                                               minHeight: DSLayout.videoPlayButtonHeight))
        .disabled(!action.isEnabled)
        .accessibilityLabel(action.title)
        .accessibilityValue(action.detail ?? "")
    }

    @ViewBuilder
    private func iconButtons(_ guide: VideoEpisodeGuide) -> some View {
        Button {
            if alreadyInShelf { confirmsRemoval = true } else { addToShelf() }
        } label: {
            Group {
                if addingToShelf {
                    ProgressView()
                } else {
                    Image(systemName: alreadyInShelf ? "checkmark" : "plus")
                }
            }
            .modifier(VideoHeroCapsuleIcon())
        }
        .disabled(chapters.isEmpty || addingToShelf)
        .accessibilityLabel(alreadyInShelf ? localized("移除書架") : localized("加入書架"))
        if !guide.isEmpty {
            Button { showsEpisodes = true } label: {
                Image(systemName: "list.bullet").modifier(VideoHeroCapsuleIcon())
            }
            .accessibilityLabel(localized("選集"))
        }
        Button { showSourcePicker = true } label: {
            Image(systemName: "arrow.triangle.2.circlepath").modifier(VideoHeroCapsuleIcon())
        }
        .accessibilityLabel(localized("換源"))
    }

    // MARK: 選集

    @ViewBuilder
    private func episodesSection(_ guide: VideoEpisodeGuide) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            episodesHeader(guide)
                .padding(.horizontal, DSLayout.videoDetailMargin)
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: DSLayout.videoEpisodeCardHeight)
            } else if let loadError {
                Button(action: load) {
                    Label(loadError, systemImage: "arrow.clockwise")
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.accent)
                        .frame(maxWidth: .infinity, minHeight: DSLayout.videoEpisodeCardHeight)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DSLayout.videoDetailMargin)
                .accessibilityHint(localized("載入失敗，點按重試"))
            } else if guide.isEmpty {
                Text(localized("這部影片沒有可播放的集數"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: DSLayout.videoEpisodeCardHeight)
            } else {
                episodeCards(guide)
            }
        }
    }

    /// VidHub's season header (「第 1 季 ⌄」): the 線路 menu itself when there are several,
    /// else 選集. The whole list opens from the capsule's 選集 button.
    @ViewBuilder
    private func episodesHeader(_ guide: VideoEpisodeGuide) -> some View {
        if guide.routes.count > 1 {
            routeMenu(guide)
        } else {
            Text(localized("選集"))
                .font(DSFont.headline.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func routeMenu(_ guide: VideoEpisodeGuide) -> some View {
        let current = guide.routes.first { $0.id == routeID } ?? guide.routes[0]
        return Menu {
            Picker(localized("線路"), selection: $routeID) {
                ForEach(guide.routes) { route in
                    Text(VideoEpisodeNaming.routeName(route)).tag(route.id)
                }
            }
        } label: {
            HStack(spacing: DSLayout.videoPlayIconSpacing) {
                Text(VideoEpisodeNaming.routeName(current))
                    .font(DSFont.headline.weight(.bold))
                Image(systemName: "chevron.down")
                    .font(DSFont.title3)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DSColor.textPrimary)
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("線路"))
        .accessibilityValue(VideoEpisodeNaming.routeName(current))
    }

    /// The 線路's episodes as VidHub's episode stills (`VideoEpisodeCard`), scrolled to the one
    /// 繼續播放 resumes, and under them its runs of episodes and the way to its last
    /// (`VideoEpisodeRangeBar`).
    private func episodeCards(_ guide: VideoEpisodeGuide) -> some View {
        let route = guide.routes.first { $0.id == routeID } ?? guide.routes[0]
        let resume = resumeEpisode
        let ranges = VideoEpisodeRange.ranges(of: route.episodes) { guide.episodeNumber(of: $0) ?? $0 + 1 }
        let lead = leadingEpisode ?? route.episodes.first
        return VStack(alignment: .leading, spacing: DSSpacing.lg) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: DSSpacing.md) {
                    ForEach(route.episodes, id: \.self) { chapterIndex in
                        episodeCard(chapterIndex, in: guide, isResume: chapterIndex == resume)
                    }
                }
                .scrollTargetLayout()
                // Room for the ring around the resumed episode, which the scroll view would clip.
                .padding(.vertical, DSLayout.videoEpisodeResumeRingOutset)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, DSSpacing.lg, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $leadingEpisode, anchor: .leading)
            VideoEpisodeRangeBar(
                ranges: ranges,
                selected: ranges.first { range in lead.map(range.episodes.contains) ?? false }?.id,
                onSelect: { range in withAnimation(DSAnimation.standard) { leadingEpisode = range.episodes.first } },
                onLast: { withAnimation(DSAnimation.standard) { leadingEpisode = route.episodes.last } }
            )
            .padding(.horizontal, DSSpacing.lg)
        }
        .onAppear { if let resume { leadingEpisode = resume } }
        .onChange(of: routeID) { _, _ in leadingEpisode = route.episodes.first }
    }

    private func episodeCard(_ chapterIndex: Int, in guide: VideoEpisodeGuide, isResume: Bool) -> some View {
        let number = guide.episodeNumber(of: chapterIndex) ?? chapterIndex + 1
        let numbered = String(format: localized("第 %d 集"), number)
        // The source's own name, unless it only says the same 第 N 集.
        let sourceName = episodeTitle(chapterIndex).trimmingCharacters(in: .whitespacesAndNewlines)
        let showsSourceName = !sourceName.isEmpty
            && sourceName.filter { !$0.isWhitespace } != numbered.filter { !$0.isWhitespace }
        let address = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].url : ""
        let stillKey = address.isEmpty ? nil : VideoEpisodeStills.key(sourceId: currentBook.sourceId, chapterURL: address)
        return VideoEpisodeCard(
            number: number,
            sourceName: showsSourceName ? sourceName : nil,
            name: VideoEpisodeNaming.episodeName(chapterIndex, in: guide, title: episodeTitle),
            isResume: isResume,
            stillKey: stillKey,
            loadStill: { await loadStill(chapterIndex, key: stillKey) },
            action: { play(chapterIndex: chapterIndex) }
        )
    }

    private func loadStill(_ chapterIndex: Int, key: String?) async -> VideoEpisodeStill? {
        guard let key, let book = playbackBook() else { return nil }
        let pixelSize = CGSize(width: DSLayout.videoEpisodeCardWidth * displayScale,
                               height: DSLayout.videoEpisodeCardHeight * displayScale)
        return await VideoEpisodeStills.shared.still(forKey: key, book: book, chapterIndex: chapterIndex,
                                                     store: bookStore, pixelSize: pixelSize)
    }

    // MARK: Info

    private func infoItems(_ guide: VideoEpisodeGuide) -> [BookDetailInfoItem] {
        var items: [BookDetailInfoItem] = []
        let count = guide.routes.reduce(0) { $0 + $1.episodes.count }
        if count > 0 {
            items.append(BookDetailInfoItem(id: "episodes", label: localized("集數"), value: count.formatted()))
        }
        if guide.routes.count > 1 {
            items.append(BookDetailInfoItem(id: "routes", label: localized("線路"),
                                            value: guide.routes.count.formatted()))
        }
        items.append(.source(name: sourceName) { showSourcePicker = true })
        return items
    }

    // MARK: Source

    @ViewBuilder
    private var sourceSheet: some View {
        if (searchBook?.origins.count ?? 0) > 1, let searchBook {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                SourcePickerSheet(
                    searchBook: searchBook,
                    currentOrigin: currentOrigin,
                    otherVersions: otherWorkVersions,
                    onSelectVersion: { id in pendingVersion = id },
                    onSelectOrigin: { origin in pendingOrigin = origin }
                )
            }
        } else {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                SourceSearchSheet(
                    query: currentBook.name,
                    currentSourceId: currentBook.sourceId,
                    currentBookURL: currentBook.bookUrl,
                    otherVersions: otherWorkVersions,
                    onSelectVersion: { id in pendingVersion = id },
                    onSelectOrigin: { origin in pendingOrigin = origin }
                )
            }
        }
    }

    private var currentOrigin: BookOrigin? {
        searchBook?.origins.first { $0.sourceId == currentBook.sourceId && $0.bookUrl == currentBook.bookUrl }
    }

    private var otherWorkVersions: [BookDetailInfoChoice.Option] {
        guard let workVersions else { return [] }
        return workVersions.options.filter { $0.id != workVersions.selection.wrappedValue }
    }

    private func resolvePendingOrigin() {
        if let version = pendingVersion {
            pendingVersion = nil
            workVersions?.selection.wrappedValue = version
            return
        }
        guard let origin = pendingOrigin else { return }
        pendingOrigin = nil
        if DetailSourceKind.kind(of: origin, in: searchBook) != DetailSourceKind.kind(of: currentBook, in: searchBook) {
            kindMismatchOrigin = origin
        } else {
            applyOrigin(origin)
        }
    }

    private func applyOrigin(_ origin: BookOrigin) {
        if DetailPageKind.of(origin, in: searchBook) != .video, let onSourceKindChange {
            onSourceKindChange(origin)
            return
        }
        let newBook = searchBook.map { OnlineBook(detailOrigin: origin, in: $0) }
            ?? OnlineBook(detailOrigin: origin, name: currentBook.name, author: currentBook.author)
        guard newBook.sourceId != currentBook.sourceId || newBook.bookUrl != currentBook.bookUrl else { return }
        currentBook = newBook
        detailInfo = nil
        poster = BookCoverLoader.cachedImage(for: newBook.coverUrl)
        chapters = []
        guide = VideoEpisodeGuide(chapters: [])
        loadError = nil
        loadedRuntimeVariables = nil
        addedBookId = nil
        alreadyInShelf = false
        introExpanded = false
        routeID = 0
        checkAlreadyInShelf()
        load()
    }

    // MARK: Source scripts

    private var effectiveRuntimeVariables: [String: String]? {
        if alreadyInShelf, let id = addedBookId, let shelved = bookStore.shelfRecord(id: id) {
            return shelved.runtimeVariables
        }
        return resolvedRuntimeVariables
    }

    private var sourceScriptBook: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot {
        .detailPage(
            name: displayName,
            author: displayAuthor,
            coverURL: displayCoverUrl,
            bookURL: currentBook.bookUrl,
            tocURL: resolvedTOCURL ?? currentBook.bookUrl,
            intro: displayIntro,
            runtimeVariables: effectiveRuntimeVariables ?? [:]
        )
    }

    private var sourceMenuActions: BookDetailSourceMenuActions? {
        BookDetailSourceMenuActions(source: source, book: sourceScriptBook, callBacks: sourceCallBacks)
    }

    private var sourceCallBacks: BookDetailSourceCallBacks? {
        BookDetailSourceCallBacks(
            source: source,
            book: sourceScriptBook,
            runtimeVariables: effectiveRuntimeVariables ?? [:],
            labels: tags,
            shelfBookId: addedBookId,
            bookStore: bookStore,
            send: { sourceCallBackTap = $0 }
        )
    }

    private func requestIntroAction(_ action: BookIntroAction) {
        guard let source else { return }
        introActionRequest = BookIntroActionRequest(
            action: action, source: source, book: sourceScriptBook,
            runtimeVariables: effectiveRuntimeVariables ?? [:]
        )
    }

    private func saveBookVariable(_ value: String) {
        currentBook.runtimeVariables = BookCustomVariable.merged(value, into: currentBook.runtimeVariables)
        if let loaded = loadedRuntimeVariables {
            loadedRuntimeVariables = BookCustomVariable.merged(value, into: loaded)
        }
        if detailInfo != nil {
            detailInfo?.runtimeVariables = BookCustomVariable.merged(value, into: detailInfo?.runtimeVariables)
        }
        if alreadyInShelf, let id = addedBookId, let shelved = bookStore.shelfRecord(id: id) {
            bookStore.updateBookRuntimeVariables(
                bookId: id, variables: BookCustomVariable.merged(value, into: shelved.runtimeVariables)
            )
        }
    }

    // MARK: Load

    /// What the genre wall is read for, once the episodes have loaded or failed.
    private var genreLoadKey: String? {
        guard !(loading || (chapters.isEmpty && loadError == nil)) else { return nil }
        return ([source?.bookSourceUrl ?? "", currentBook.bookUrl] + tags).joined(separator: "\u{1F}")
    }

    private func isCurrentRequest(_ request: OnlineBook) -> Bool {
        request.sourceId == currentBook.sourceId
            && ChangeSourceCache.urlKey(request.bookUrl) == ChangeSourceCache.urlKey(currentBook.bookUrl)
    }

    private func load() {
        guard let source else { loadError = localized("來源配置已被刪除"); return }
        loading = true
        loadError = nil
        loadedRuntimeVariables = nil
        let request = currentBook
        Task {
            do {
                var tocURL = request.bookUrl
                var runtimeVars = request.runtimeVariables
                if !request.bookUrl.isEmpty {
                    let pkg = try await dependencies.bookSourceFetcher.fetchBookInfoPackage(
                        url: request.bookUrl, source: source, runtimeVariables: runtimeVars, knownBook: request)
                    runtimeVars = Self.merged(runtimeVars, pkg.runtimeVariables)
                    guard isCurrentRequest(request) else { return }
                    detailInfo = OnlineBookDetailPresentationPolicy.sanitized(pkg.onlineBook)
                    if !pkg.tocUrl.isEmpty { tocURL = pkg.tocUrl }
                }
                let tocPkg = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                    tocUrl: tocURL, source: source, runtimeVariables: runtimeVars)
                runtimeVars = Self.merged(runtimeVars, tocPkg.runtimeVariables)
                guard isCurrentRequest(request) else { return }
                chapters = tocPkg.chapters
                guide = VideoEpisodeGuide(chapters: tocPkg.chapters)
                routeID = resumeEpisode.flatMap { guide.route(containing: $0)?.id } ?? 0
                loadedRuntimeVariables = runtimeVars
                loading = false
            } catch {
                guard isCurrentRequest(request) else { return }
                AppLogger.error("[Video] detail load failed", error: error, context: ["book": request.bookUrl])
                loadError = error.localizedDescription
                loading = false
            }
        }
    }

    private static func merged(_ base: [String: String]?, _ next: [String: String]?) -> [String: String]? {
        var merged = base ?? [:]
        if let next { merged.merge(next) { _, new in new } }
        return merged.isEmpty ? nil : merged
    }

    // MARK: Shelf and play

    private func existingShelfBookId() -> UUID? {
        bookStore.onlineBook(sourceId: currentBook.sourceId, bookInfoURL: currentBook.bookUrl)?.id
    }

    private func checkAlreadyInShelf() {
        addedBookId = existingShelfBookId()
        alreadyInShelf = addedBookId != nil
    }

    private func addToShelf() {
        guard !alreadyInShelf, !addingToShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let copy = ShelfWorkService.OnlineCopy(
            name: displayName,
            author: displayAuthor,
            sourceId: source.id,
            bookInfoURL: currentBook.bookUrl,
            tocURL: resolvedTOCURL,
            coverUrl: displayCoverUrl,
            runtimeVariables: resolvedRuntimeVariables,
            contentKind: .video,
            chapters: chapters)
        Task { @MainActor in
            defer { addingToShelf = false }
            do {
                let outcome = try await ShelfWorkService(store: bookStore, dependencies: dependencies).add(copy)
                addedBookId = outcome.book.id
                alreadyInShelf = true
                if case .alreadyOnShelf = outcome { return }
                SourceCallBackService.notify(.addBookShelf, book: outcome.book)
            } catch {
                AppLogger.error("[Video] shelf add failed", error: error, context: ["book": currentBook.bookUrl])
                loadError = error.localizedDescription
            }
        }
    }

    private func removeFromShelf() {
        guard alreadyInShelf, let bookId = addedBookId else { return }
        if let onRemoveFromShelf { onRemoveFromShelf() } else { presentationMode.wrappedValue.dismiss() }
        if let shelved = bookStore.readingBook(id: bookId) {
            SourceCallBackService.notify(.delBookShelf, book: shelved)
        }
        bookStore.delete(bookId: bookId)
        addedBookId = nil
        alreadyInShelf = false
    }

    /// The book an episode resolves its link through: the shelf copy with this page's
    /// episodes, which 播放 is about to save to it, else the page's unshelved copy.
    private func playbackBook() -> ReadingBook? {
        guard !chapters.isEmpty, let source else { return nil }
        guard let id = existingShelfBookId(), var shelved = bookStore.readingBook(id: id) else {
            return unshelvedBook(source: source)
        }
        shelved.onlineChapters = chapters
        shelved.runtimeVariables = resolvedRuntimeVariables
        return shelved
    }

    /// The work while it is not on the shelf, under one id for as long as it stays off it
    /// (`UUID.unshelvedVideoID`).
    private func unshelvedBook(source: BookSource) -> ReadingBook {
        var book = ReadingBook(id: .unshelvedVideoID(sourceId: source.id, bookURL: currentBook.bookUrl),
                               title: displayName, author: displayAuthor, source: currentBook.bookUrl,
                               contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .video
        book.bookSourceId = source.id
        book.bookInfoURL = currentBook.bookUrl
        book.tocURL = resolvedTOCURL
        book.runtimeVariables = resolvedRuntimeVariables
        book.coverUrl = displayCoverUrl
        book.onlineChapters = chapters
        return book
    }

    /// Plays an episode. Only 加入書架 shelves the book; a book not on the shelf plays with
    /// its position kept in memory, as an unshelved audiobook does.
    private func play(chapterIndex: Int) {
        guard !chapters.isEmpty, let source else { return }
        let runtimeVars = resolvedRuntimeVariables
        if let existing = existingShelfBookId() {
            addedBookId = existing
            alreadyInShelf = true
            bookStore.updateOnlineBookContentKind(bookId: existing, kind: .video)
            bookStore.updateOnlineChapters(bookId: existing, chapters: chapters, runtimeVariables: runtimeVars)
            // The same episode resumes where it was; another starts at its beginning.
            let saved = bookStore.shelfRecord(id: existing)
            let time = saved?.audioChapterIndex == chapterIndex ? saved?.audioTimeSeconds ?? 0 : 0
            bookStore.updateAudioPosition(bookId: existing, chapter: chapterIndex, time: time,
                                          totalChapters: chapters.count, forceSave: true)
            player = .shelf(existing)
        } else {
            var book = unshelvedBook(source: source)
            book.audioChapterIndex = chapterIndex
            player = .transient(book)
            // Watched without being shelved: only its name stays, for 搜索's 最近閱讀.
            OffShelfReadRecords.record(title: book.title, author: book.author, coverUrl: displayCoverUrl)
        }
    }
}

/// An action in the capsule beside the play button: its icon, with a whole tap target.
private struct VideoHeroCapsuleIcon: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: DSLayout.videoActionSlotWidth, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        VideoDetailView(book: OnlineBook(
            name: "示範短劇",
            author: "",
            intro: "一部用來預覽影片詳情頁的短劇。",
            coverUrl: "",
            bookUrl: "https://example.com/vod/1",
            tocUrl: "https://example.com/vod/1/toc",
            wordCount: "",
            lastChapter: "第 80 集",
            kind: "都市,短劇",
            sourceId: UUID(),
            sourceName: "示範影視來源"))
        .environmentObject(BookStore())
    }
}

extension UUID {
    /// An unshelved video's id, the same on every visit: the links its episodes resolve —
    /// for 選集's stills, then for 播放 — are cached under one directory per work instead of
    /// one per visit or per tap, which nothing but 快取管理 would ever reclaim. A link cached
    /// long ago and since expired is resolved again once, by the player and by the stills alike.
    static func unshelvedVideoID(sourceId: UUID, bookURL: String) -> UUID {
        let digest = SHA256.hash(data: Data("unshelved-video|\(sourceId.uuidString)|\(bookURL)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5: name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
