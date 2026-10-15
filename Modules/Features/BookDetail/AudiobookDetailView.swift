import SwiftUI
import os.log

/// On-device routing diagnostics (Console.app, category `audioroute`): one line per
/// detail-page tap showing every signal the audio/text routing decision used.
private let audioRouteLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.yuedu.app", category: "audioroute")

// MARK: - Audiobook Detail (unified audiobook landing page)

/// Everything an audiobook detail page pushes, through its one `navigationDestination`.
private enum AudiobookDetailPush: Hashable {
    /// A genre link's category, or 同題材's 查看全部.
    case category(ExploreCategoryReference)
    /// A 同題材 book.
    case book(OnlineBook)
}

/// Dedicated detail page for audiobooks. Audiobooks must NOT fall into the text-book
/// `OnlineBookView`; this is the single UI every audiobook lands on regardless of
/// whether the signal comes from `bookSourceType == 1` or a per-book aggregate-source
/// payload such as `tab=听书`.
struct AudiobookDetailView: View {
    /// Aggregated search book when opened from search; `nil` from a single-source context (Discover).
    private let searchBook: SearchBook?
    private let onRemoveFromShelf: (() -> Void)?
    /// Hands a confirmed switch to a non-audio source to `OnlineBookDetailDestination`,
    /// which replaces this page with the text detail page.
    private let onSourceKindChange: ((BookOrigin) -> Void)?
    /// On 作品詳情, the work's versions: 換源 lists the others first, and picking one switches
    /// the page to it (unified library 5f-3). `nil` elsewhere.
    private let workVersions: BookDetailInfoChoice?

    @State private var currentBook: OnlineBook
    @State private var pushed: AudiobookDetailPush?
    @StateObject private var genres = SourceGenreLinks()
    @EnvironmentObject var bookStore: BookStore
    // DismissAction is repeatedly replaced by iOS 17 while a page is pushed above this
    // detail (a genre's category, a 同題材 book). Its stable binding avoids a navigation
    // layout loop, as on `OnlineBookView`.
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.appDependencies) private var dependencies
    private var gs: GlobalSettings { GlobalSettings.shared }
    private var source: BookSource? { BookSourceStore.shared.source(id: currentBook.sourceId) }

    @State private var chapters: [OnlineChapterRef] = []
    @State private var loading = false
    @State private var loadError: String? = nil
    @State private var detailInfo: OnlineBook? = nil
    @State private var loadedRuntimeVariables: [String: String]? = nil
    @State private var introExpanded = false
    @State private var addingToShelf = false
    @State private var addedBookId: UUID? = nil
    @State private var sourceCallBackTap: SourceCallBackTapRequest?
    @State private var activePlayerBookId: UUID? = nil
    @State private var alreadyInShelf = false
    /// The shelved copy's sidecar values, read once per copy for its description.
    @State private var copySidecar: [MetadataValue] = []
    @State private var openingPlayer = false
    @State private var showPlayer = false
    @State private var showSourcePicker = false
    @State private var showChapterList = false
    @State private var pendingChapterSelection: Int?
    @State private var confirmsRemoval = false
    @State private var showsSourceVariableEditor = false
    @State private var showsBookVariableEditor = false
    @State private var showsMoreChooser = false
    @State private var introActionRequest: BookIntroActionRequest?
    /// Chosen in the source sheet; applied once the sheet has dismissed.
    @State private var pendingOrigin: BookOrigin?
    /// A source of another content kind, waiting for the user's confirmation.
    @State private var kindMismatchOrigin: BookOrigin?
    /// A version of the work chosen in the source sheet; applied once the sheet has dismissed.
    @State private var pendingVersion: String?

    // MARK: Init

    /// Single-source entry (Discover).
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
        _currentBook = State(
            initialValue: OnlineBookDetailPresentationPolicy.sanitized(book)
        )
    }

    /// Search entry — opens `initialOrigin` when given, otherwise the first audio
    /// origin, then falls back to the first origin.
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
        if let origin = initialOrigin
            ?? searchBook.preferredOrigin(for: .audio)
            ?? searchBook.origins.first {
            let selectedIntro = searchBook.detailIntro(for: origin)
            _currentBook = State(initialValue: OnlineBook(
                id: SearchResultDetailIdentity.onlineBookID(
                    searchBookID: searchBook.id,
                    originID: origin.id
                ),
                name: searchBook.name, author: searchBook.author,
                intro: selectedIntro.isEmpty
                    ? searchBook.detailIntro
                    : selectedIntro,
                coverUrl: origin.coverUrl,
                bookUrl: origin.bookUrl, tocUrl: origin.tocUrl,
                wordCount: origin.wordCount, lastChapter: origin.lastChapter,
                kind: origin.kind, sourceId: origin.sourceId,
                sourceName: origin.sourceName, runtimeVariables: origin.runtimeVariables))
        } else {
            _currentBook = State(initialValue: OnlineBook(
                id: SearchResultDetailIdentity.onlineBookID(
                    searchBookID: searchBook.id,
                    originID: nil
                ),
                name: searchBook.name, author: searchBook.author,
                intro: "", coverUrl: "", bookUrl: "", tocUrl: "",
                wordCount: "", lastChapter: "", kind: "",
                sourceId: searchBook.id, sourceName: ""))
        }
    }

    private var sourceName: String {
        let name = currentBook.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let s = source?.bookSourceName, !s.isEmpty { return s }
        return localized("未知來源配置")
    }

    private var canSwitchSource: Bool {
        (searchBook?.origins.count ?? 0) > 1
    }

    // MARK: Display fallbacks (detail overrides search result, never with placeholders)

    private var displayName: String {
        if let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let b = currentBook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? localized("未知書名") : b
    }

    private var displayAuthor: String {
        if let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let b = currentBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? localized("未知作者") : b
    }

    private var displayCoverUrl: String {
        if let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return currentBook.coverUrl
    }

    /// The book on the shelf this page shows, while it is on the shelf.
    private var shelvedCopy: ReadingBook? {
        guard alreadyInShelf, let id = addedBookId else { return nil }
        return bookStore.shelfRecord(id: id)
    }

    /// What the page shows of the book: a shelved copy's own title, author and description
    /// (5f-4d, decisions 32–33: the reader's edits come first), else the source's.
    /// `displayName`, `displayAuthor` and `displayIntro` stay the source's, for its scripts
    /// and for what a shelf add writes.
    private var shownMetadata: (name: String, author: String, intro: CopyMetadata.Intro?) {
        guard let copy = shelvedCopy.map({ bookStore.copyMetadata(of: $0, sidecar: copySidecar, liveIntro: displayIntro) }) else {
            let intro = displayIntro.isEmpty ? nil : CopyMetadata.Intro(text: displayIntro, isEdited: false, isSourcesOwn: true)
            return (displayName, displayAuthor, intro)
        }
        return (copy.title ?? displayName, copy.author ?? displayAuthor, copy.intro)
    }

    private var displayIntro: String {
        if let detail = detailInfo?.intro, !detail.isEmpty {
            return detail
        }
        return currentBook.intro
    }

    private var displayLatestChapter: String {
        if let d = detailInfo?.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return d
        }
        return currentBook.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tags: [String] {
        OnlineBookMetadataFormatter.tags(
            detailKind: detailInfo?.kind,
            fallbackKind: currentBook.kind
        )
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

    // MARK: Body

    var body: some View {
        let shown = shownMetadata
        return BookDetailScaffold(title: shown.name, compactAction: playAction) {
            BookDetailHero(
                artworkShape: .square,
                cover: coverArtwork(shown),
                title: shown.name,
                author: shown.author,
                meta: tags.joined(separator: " · "),
                primary: playAction,
                secondary: shelfAction,
                authorActions: sourceCallBacks == nil ? sourceLinks.authorActions(shown.author) : [],
                sourceGestures: sourceCallBacks?.gestures,
                links: sourceCallBacks == nil ? sourceLinks.links(for: tags) : []
            )
        } content: {
            if let intro = shown.intro {
                BookDetailIntroSection(
                    text: intro.text,
                    isExpanded: $introExpanded,
                    baseURL: intro.isSourcesOwn ? currentBook.bookUrl : nil,
                    onAction: intro.isSourcesOwn ? requestIntroAction : nil,
                    readsSourceFormats: intro.isSourcesOwn
                )
            }
            BookDetailChapterSection(
                title: localized("章節"),
                chapters: chapters,
                isLoading: loading,
                errorMessage: loadError,
                latestChapter: displayLatestChapter,
                onRetry: { load() },
                onShowAll: { showChapterList = true }
            ) { offset, chapter in
                BookDetailChapterRow(
                    title: BookDetailChapterTitle.display(chapter, offset: offset),
                    caption: String(format: localized("第 %d 章"), offset + 1),
                    isLocked: chapter.isVip || chapter.isPay,
                    trailing: .play,
                    action: { play(chapterIndex: offset) }
                )
            }
            BookDetailRelatedSection(
                related: genres.related,
                choices: genres.choices,
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
            // 作品資訊 last: the first half serves reading and finding more (2026-10-12).
            BookDetailInfoSection(items: infoItems)
        }
        .environment(\.locale, Locale(identifier: gs.localeIdentifier))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BookDetailMoreMenu(
                    hasSource: source != nil,
                    onSetSourceVariable: { showsSourceVariableEditor = true },
                    onSetBookVariable: { showsBookVariableEditor = true },
                    onOpenChooser: { showsMoreChooser = true },
                    sourceActions: sourceCallBacks?.menuActions
                )
            }
        }
        .bookDetailMoreChooser(
            isPresented: $showsMoreChooser,
            onSetSourceVariable: { showsSourceVariableEditor = true },
            onSetBookVariable: { showsBookVariableEditor = true },
            sourceActions: sourceCallBacks?.menuActions
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
        .sheet(isPresented: $showSourcePicker, onDismiss: resolvePendingOrigin) {
            if canSwitchSource, let searchBook {
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
        .sourceKindMismatchAlert(origin: $kindMismatchOrigin, onConfirm: applyOrigin)
        .removeFromShelfConfirmation(isPresented: $confirmsRemoval, onConfirm: removeFromShelf)
        .sheet(isPresented: $showChapterList, onDismiss: {
            guard let chapterIndex = pendingChapterSelection else { return }
            pendingChapterSelection = nil
            play(chapterIndex: chapterIndex)
        }) {
            NavigationStack {
                BookDetailChapterListSheet(
                    chapters: chapters,
                    trailing: .play,
                    onSelect: { offset in
                        pendingChapterSelection = offset
                        showChapterList = false
                    }
                )
            }
        }
        .navigationDestination(item: $pushed) { push in
            switch push {
            case .category(let reference):
                BookDetailCategoryPage(reference: reference)
                    .environmentObject(bookStore)
            case .book(let book):
                BookDetailRelatedBookDestination(book: book)
                    .environmentObject(bookStore)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let bid = activePlayerBookId {
                if bookStore.books.contains(where: { $0.id == bid }) {
                    BookReaderView(bookId: bid).environmentObject(bookStore)
                } else {
                    AudiobookReaderView(bookId: bid).environmentObject(bookStore)
                }
            }
        }
        .onAppear {
            checkAlreadyInShelf()
            if chapters.isEmpty, loadError == nil { load() }
        }
        .task(id: shelvedCopy?.id) { copySidecar = shelvedCopy.map(bookStore.copyIntroValues(of:)) ?? [] }
        .task(id: genreLoadKey) {
            guard let key = genreLoadKey else { return }
            await genres.load(key: key, source: source, tags: tags, book: currentBook)
        }
    }

    // MARK: Genres and author

    /// What the genre links and 同題材 are read for: the source, the genres and the book. Nil
    /// until the chapters have loaded or failed: the source's categories are read after them,
    /// never in the way of the page's own loading, and with the genres the detail gives.
    private var genreLoadKey: String? {
        guard !(loading || (chapters.isEmpty && loadError == nil)) else { return nil }
        return ([source?.bookSourceUrl ?? "", currentBook.bookUrl] + tags).joined(separator: "\u{1F}")
    }

    /// The genre and author taps, for a source that does not take them itself.
    private var sourceLinks: BookDetailSourceLinks {
        BookDetailSourceLinks(source: source, genres: genres, openCategory: { pushed = .category($0) })
    }

    // MARK: Hero

    /// A shelved copy's own artwork, custom cover included, as the shelf draws it; else the
    /// source's cover.
    @ViewBuilder
    private func coverArtwork(_ shown: (name: String, author: String, intro: CopyMetadata.Intro?)) -> some View {
        if let copy = shelvedCopy {
            HomeCoverArtwork(cover: .shelf(copy), title: shown.name,
                             author: shown.author == localized("未知作者") ? "" : shown.author,
                             size: CGSize(width: DSLayout.bookDetailSquareArtworkSide, height: DSLayout.bookDetailSquareArtworkSide))
        } else {
            sourceCoverArtwork
        }
    }

    private var sourceCoverArtwork: some View {
        BookCoverImage(
            coverURL: displayCoverUrl,
            title: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            sourceBaseURL: source?.bookSourceUrl,
            sourceHeaders: source?.parsedHeaders ?? [:]
        )
    }

    private var playAction: BookDetailAction {
        BookDetailAction(
            title: resumeChapterIndex > 0 ? localized("繼續播放") : localized("開始播放"),
            systemImage: "play.fill",
            isBusy: openingPlayer,
            isEnabled: !chapters.isEmpty && !addingToShelf,
            detail: resumeChapterIndex > 0 ? BookDetailResume.detail(chapterIndex: resumeChapterIndex, progress: nil) : nil,
            action: { play(chapterIndex: resumeChapterIndex) }
        )
    }

    private var shelfAction: BookDetailAction {
        BookDetailAction(
            title: alreadyInShelf
                ? localized("移除書架")
                : (addingToShelf ? localized("加入中…") : localized("加入書架")),
            systemImage: alreadyInShelf ? "checkmark" : "plus",
            isBusy: addingToShelf,
            isEnabled: !chapters.isEmpty,
            action: {
                if alreadyInShelf { confirmsRemoval = true } else { addToShelfOnly() }
            }
        )
    }

    private var infoItems: [BookDetailInfoItem] {
        var items: [BookDetailInfoItem] = []
        if !chapters.isEmpty {
            items.append(BookDetailInfoItem(
                id: "chapters", label: localized("章節"), value: chapters.count.formatted()
            ))
        }
        items.append(.source(name: sourceName) { showSourcePicker = true })
        return items
    }

    /// The runtime variables the next play, shelf add or fetch will carry.
    private var effectiveRuntimeVariables: [String: String]? {
        if alreadyInShelf, let id = addedBookId,
           let shelved = bookStore.books.first(where: { $0.id == id }) {
            return shelved.runtimeVariables
        }
        return resolvedRuntimeVariables
    }

    /// A 簡介 button or image: its script runs against this page's book.
    /// `book` as this page's source scripts see it (簡介 buttons, `callBackJs`).
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

    /// The taps and menu items a source that listens for events takes (legado `SourceCallBack`).
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
            action: action,
            source: source,
            book: sourceScriptBook,
            runtimeVariables: effectiveRuntimeVariables ?? [:]
        )
    }

    /// Legado's 設置書籍變量: write `custom` into every runtime-variable map this page
    /// carries forward, and into the shelf record when the book is on the shelf.
    private func saveBookVariable(_ value: String) {
        currentBook.runtimeVariables = BookCustomVariable.merged(value, into: currentBook.runtimeVariables)
        if let loaded = loadedRuntimeVariables {
            loadedRuntimeVariables = BookCustomVariable.merged(value, into: loaded)
        }
        if detailInfo != nil {
            detailInfo?.runtimeVariables = BookCustomVariable.merged(value, into: detailInfo?.runtimeVariables)
        }
        if alreadyInShelf, let id = addedBookId,
           let shelved = bookStore.books.first(where: { $0.id == id }) {
            bookStore.updateBookRuntimeVariables(
                bookId: id,
                variables: BookCustomVariable.merged(value, into: shelved.runtimeVariables)
            )
        }
    }

    /// The search-result origin this page shows, for the source sheet's checkmark.
    private var currentOrigin: BookOrigin? {
        searchBook?.origins.first {
            $0.sourceId == currentBook.sourceId && $0.bookUrl == currentBook.bookUrl
        }
    }

    /// Resume from the saved audio position when this book is already on the shelf.
    private var resumeChapterIndex: Int {
        guard let id = addedBookId ?? existingShelfBookId(),
              let book = bookStore.books.first(where: { $0.id == id })
        else { return 0 }
        return min(max(0, book.audioChapterIndex), max(0, chapters.count - 1))
    }

    // MARK: Load (detail + TOC via the shared fetcher API)

    /// Runs after the source sheet has dismissed, so the confirmation alert is not
    /// presented over a sheet that is still leaving.
    private func resolvePendingOrigin() {
        if let version = pendingVersion {
            pendingVersion = nil
            workVersions?.selection.wrappedValue = version
            return
        }
        guard let origin = pendingOrigin else { return }
        pendingOrigin = nil
        if DetailSourceKind.kind(of: origin, in: searchBook)
            != DetailSourceKind.kind(of: currentBook, in: searchBook) {
            kindMismatchOrigin = origin
        } else {
            applyOrigin(origin)
        }
    }

    /// The work's versions besides the one this page shows.
    private var otherWorkVersions: [BookDetailInfoChoice.Option] {
        guard let workVersions else { return [] }
        return workVersions.options.filter { $0.id != workVersions.selection.wrappedValue }
    }

    private func applyOrigin(_ origin: BookOrigin) {
        if DetailSourceKind.kind(of: origin, in: searchBook) != .audio,
           let onSourceKindChange {
            onSourceKindChange(origin)
            return
        }
        switchToOrigin(origin)
    }

    private func switchToOrigin(_ origin: BookOrigin) {
        let newBook: OnlineBook
        if let searchBook {
            newBook = OnlineBook(detailOrigin: origin, in: searchBook)
        } else {
            newBook = OnlineBook(detailOrigin: origin, name: currentBook.name, author: currentBook.author)
        }
        guard newBook.sourceId != currentBook.sourceId
            || newBook.bookUrl != currentBook.bookUrl else { return }

        currentBook = newBook
        detailInfo = nil
        chapters = []
        loadError = nil
        loadedRuntimeVariables = nil
        addedBookId = nil
        activePlayerBookId = nil
        alreadyInShelf = false
        introExpanded = false
        checkAlreadyInShelf()
        load()
    }

    private func isCurrentRequest(_ request: OnlineBook) -> Bool {
        request.sourceId == currentBook.sourceId
            && ChangeSourceCache.urlKey(request.bookUrl)
                == ChangeSourceCache.urlKey(currentBook.bookUrl)
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
                        url: request.bookUrl, source: source, runtimeVariables: runtimeVars,
                        knownBook: request)
                    runtimeVars = Self.mergedRuntimeVariables(runtimeVars, pkg.runtimeVariables)
                    await MainActor.run {
                        guard isCurrentRequest(request) else { return }
                        detailInfo = OnlineBookDetailPresentationPolicy.sanitized(
                            pkg.onlineBook
                        )
                    }
                    if !pkg.tocUrl.isEmpty { tocURL = pkg.tocUrl }
                }
                let tocPkg = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                    tocUrl: tocURL, source: source, runtimeVariables: runtimeVars)
                runtimeVars = Self.mergedRuntimeVariables(runtimeVars, tocPkg.runtimeVariables)
                await MainActor.run {
                    guard isCurrentRequest(request) else { return }
                    chapters = tocPkg.chapters
                    loadedRuntimeVariables = runtimeVars
                    loading = false
                }
            } catch {
                await MainActor.run {
                    guard isCurrentRequest(request) else { return }
                    loadError = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private static func mergedRuntimeVariables(
        _ base: [String: String]?,
        _ next: [String: String]?
    ) -> [String: String]? {
        var merged = base ?? [:]
        if let next {
            merged.merge(next) { _, new in new }
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: Play

    private func existingShelfBookId() -> UUID? {
        bookStore.onlineBook(
            sourceId: currentBook.sourceId, bookInfoURL: currentBook.bookUrl)?.id
    }

    private func checkAlreadyInShelf() {
        addedBookId = existingShelfBookId()
        alreadyInShelf = addedBookId != nil
    }

    private func removeFromShelf() {
        guard alreadyInShelf, let bookId = addedBookId else { return }
        if let onRemoveFromShelf {
            onRemoveFromShelf()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
        if let shelved = bookStore.readingBook(id: bookId) {
            SourceCallBackService.notify(.delBookShelf, book: shelved)
        }
        bookStore.delete(bookId: bookId)
        addedBookId = nil
        activePlayerBookId = nil
        alreadyInShelf = false
    }

    private func addToShelfOnly() {
        guard !alreadyInShelf, !addingToShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let newBook = bookStore.addOnlineBook(
            name: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            sourceId: source.id,
            bookInfoURL: currentBook.bookUrl,
            tocURL: resolvedTOCURL,
            coverUrl: displayCoverUrl,
            runtimeVariables: resolvedRuntimeVariables,
            contentKind: .audio,
            chapters: chapters)
        addedBookId = newBook.id
        activePlayerBookId = newBook.id
        alreadyInShelf = true
        addingToShelf = false
        SourceCallBackService.notify(.addBookShelf, book: newBook)
    }

    private func preparePlayerCoverFallback(bookId: UUID, source: BookSource) {
        AudiobookPlayer.shared.prepareCoverFallback(
            bookId: bookId,
            coverUrl: displayCoverUrl,
            sourceBaseURL: source.bookSourceUrl,
            sourceHeaders: source.parsedHeaders
        )
    }

    private func transientAudiobook(
        source: BookSource,
        runtimeVariables: [String: String]?,
        chapterIndex: Int
    ) -> ReadingBook {
        var book = ReadingBook(
            title: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            source: currentBook.bookUrl,
            contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .audio
        book.bookSourceId = source.id
        book.bookInfoURL = currentBook.bookUrl
        book.tocURL = resolvedTOCURL
        book.runtimeVariables = runtimeVariables
        book.onlineChapters = chapters.map { chapter in
            var sanitized = chapter
            sanitized.title = ReaderHTMLUtilities.displayText(fromHTMLFragment: chapter.title)
            return sanitized
        }
        book.audioChapterIndex = chapterIndex
        return book
    }

    /// Open playback. Only the explicit "加入書架" action creates a permanent shelf item.
    private func play(chapterIndex: Int) {
        guard !chapters.isEmpty, let source, !openingPlayer else { return }
        openingPlayer = true

        let runtimeVars = resolvedRuntimeVariables
        if let existing = existingShelfBookId() {
            addedBookId = existing
            alreadyInShelf = true
            bookStore.updateOnlineBookContentKind(bookId: existing, kind: .audio)
            bookStore.updateOnlineChapters(
                bookId: existing,
                chapters: chapters,
                runtimeVariables: runtimeVars
            )
            bookStore.updateAudioPosition(
                bookId: existing, chapter: chapterIndex, time: 0,
                totalChapters: chapters.count, forceSave: true)
            preparePlayerCoverFallback(bookId: existing, source: source)
            activePlayerBookId = existing
        } else {
            let transient = transientAudiobook(
                source: source,
                runtimeVariables: runtimeVars,
                chapterIndex: chapterIndex
            )
            preparePlayerCoverFallback(bookId: transient.id, source: source)
            AudiobookPlayer.shared.startTransient(book: transient, store: bookStore)
            activePlayerBookId = transient.id
            // Listened to without being shelved, by a player that never enters the library:
            // only its name stays, for 搜索's 最近閱讀.
            OffShelfReadRecords.record(title: transient.title, author: transient.author, coverUrl: displayCoverUrl)
        }
        openingPlayer = false
        showPlayer = true
    }
}

// MARK: - Source-type routing helper

extension BookSourceStore {
    /// True when the source backing this id is a dedicated audiobook source.
    func isAudiobookSource(id: UUID?) -> Bool {
        guard let id else { return false }
        return sources.first { $0.id == id }?.bookSourceType == 1
    }

    func isAudiobook(_ book: OnlineBook) -> Bool {
        let source = sources.first { $0.id == book.sourceId }
        let kind = book.inferredContentKind(source: source)
        let modes = OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
        audioRouteLog.notice(
            "⟐ route \(book.name, privacy: .public) → \(String(describing: kind), privacy: .public) srcType=\(source?.bookSourceType ?? -1) modes=\(modes.joined(separator: ","), privacy: .public) vars=\(book.runtimeVariables?.keys.joined(separator: ",") ?? "-", privacy: .public) url=\(String(book.bookUrl.prefix(160)), privacy: .public)"
        )
        return kind == .audio
    }

    func isAudiobook(_ searchBook: SearchBook) -> Bool {
        let kind = searchBook.inferredContentKind(sourceStore: self)
        let origin = searchBook.origins.first
        let source = sources.first { $0.id == origin?.sourceId }
        audioRouteLog.notice(
            "⟐ route(search snapshot) \(searchBook.name, privacy: .public) → \(String(describing: kind), privacy: .public) origins=\(searchBook.origins.count) srcType=\(source?.bookSourceType ?? -1) url=\(String(origin?.bookUrl.prefix(160) ?? ""), privacy: .public)"
        )
        return kind == .audio
    }

    // Quiet variants for list/cover badges — the logging `isAudiobook` methods above are
    // routing diagnostics and must not fire per-cell while a list scrolls.
    func isAudiobookForBadge(_ book: OnlineBook) -> Bool {
        book.inferredContentKind(source: sources.first { $0.id == book.sourceId }) == .audio
    }

    func isAudiobookForBadge(_ searchBook: SearchBook) -> Bool {
        searchBook.inferredContentKind(sourceStore: self) == .audio
    }
}

#Preview {
    NavigationStack {
        AudiobookDetailView(book: OnlineBook(
            name: "斗羅大陸",
            author: "唐家三少",
            intro: "唐門外門弟子唐三，因偷學內門絕學為唐門所不容，跳崖明志卻來到了另一個世界——斗羅大陸。",
            coverUrl: "",
            bookUrl: "https://example.com/audiobook/1",
            tocUrl: "https://example.com/audiobook/1/toc",
            wordCount: "",
            lastChapter: "",
            kind: "玄幻",
            sourceId: UUID(),
            sourceName: "示範有聲來源配置"))
        .environmentObject(BookStore())
    }
}
