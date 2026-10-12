import SwiftUI

// MARK: - Online Book Detail + TOC

struct OnlineBookView: View {
    /// The aggregated search book, when opened from search — enables source switching (換源).
    /// `nil` when opened from a single-source context (e.g. Discover).
    private let searchBook: SearchBook?
    /// When opened from the reader, this is the shelf record whose source the detail page is
    /// editing. `OnlineBook` is only a presentation value, so changing its local state alone
    /// cannot update the reader's `ReadingBook`.
    private let sourceSwitchBookId: UUID?
    private let onRemoveFromShelf: (() -> Void)?
    /// Reader-owned details return to their retained reader instead of opening another.
    private let onContinueReading: ((Int?) -> Void)?
    /// Hands a confirmed switch to an audio source to `OnlineBookDetailDestination`,
    /// which replaces this page with the audiobook detail page. `nil` for the
    /// reader-owned detail, which commits every switch to its open reader's book.
    private let onSourceKindChange: ((BookOrigin) -> Void)?
    /// On 作品詳情, the work's versions: 換源 lists the others first, and picking one switches
    /// the page to it (unified library 5f-3). `nil` elsewhere.
    private let workVersions: BookDetailInfoChoice?

    @State private var currentBook: OnlineBook
    @EnvironmentObject var bookStore: BookStore
    // DismissAction is repeatedly replaced by iOS 17 while a reader is pushed
    // above this detail. Its stable binding avoids a navigation layout loop.
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.appDependencies) private var dependencies
    @State private var readerRoute: DetailReaderRoute?
    @State private var pendingChapterSelection: Int?

    private var gs: GlobalSettings { GlobalSettings.shared }
    private var source: BookSource? { BookSourceStore.shared.source(id: currentBook.sourceId) }

    @State private var chapters: [OnlineChapterRef] = []
    @State private var loadingTOC = false
    @State private var tocError: String? = nil
    @State private var addingToShelf = false
    @State private var openingReader = false
    @State private var addedBookId: UUID? = nil
    @State private var sourceCallBackTap: SourceCallBackTapRequest?
    @State private var showReader = false
    @State private var alreadyInShelf = false
    /// The shelved copy's sidecar values, read once per copy for its description.
    @State private var copySidecar: [MetadataValue] = []
    @State private var temporaryReaderBookId: UUID? = nil
    @State private var detailInfo: OnlineBook? = nil
    @State private var tocRuntimeVariables: [String: String]? = nil
    @State private var pendingShelfSourceSwitch = false
    @State private var introExpanded = false
    @State private var showSourcePicker = false
    /// Chosen in the source sheet; applied once the sheet has dismissed.
    @State private var pendingOrigin: BookOrigin?
    /// A source of another content kind, waiting for the user's confirmation.
    @State private var kindMismatchOrigin: BookOrigin?
    /// A version of the work chosen in the source sheet; applied once the sheet has dismissed.
    @State private var pendingVersion: String?
    @State private var showChapterList = false
    @State private var confirmsRemoval = false
    @State private var showsSourceVariableEditor = false
    @State private var showsBookVariableEditor = false
    @State private var showsMoreChooser = false
    @State private var introActionRequest: BookIntroActionRequest?

    // MARK: Init

    /// Single-source entry (Discover). No source switching.
    init(
        book: OnlineBook,
        sourceSwitchBookId: UUID? = nil,
        onRemoveFromShelf: (() -> Void)? = nil,
        onContinueReading: ((Int?) -> Void)? = nil,
        onSourceKindChange: ((BookOrigin) -> Void)? = nil,
        workVersions: BookDetailInfoChoice? = nil
    ) {
        self.searchBook = nil
        self.sourceSwitchBookId = sourceSwitchBookId
        self.onRemoveFromShelf = onRemoveFromShelf
        self.onContinueReading = onContinueReading
        self.onSourceKindChange = onSourceKindChange
        self.workVersions = workVersions
        _currentBook = State(
            initialValue: OnlineBookDetailPresentationPolicy.sanitized(book)
        )
    }

    /// Search entry — opens `initialOrigin` when given, otherwise the first origin;
    /// keeps the rest for 換源.
    init(
        searchBook: SearchBook,
        initialOrigin: BookOrigin? = nil,
        sourceSwitchBookId: UUID? = nil,
        onRemoveFromShelf: (() -> Void)? = nil,
        onContinueReading: ((Int?) -> Void)? = nil,
        onSourceKindChange: ((BookOrigin) -> Void)? = nil
    ) {
        self.searchBook = searchBook
        self.sourceSwitchBookId = sourceSwitchBookId
        self.onRemoveFromShelf = onRemoveFromShelf
        self.onContinueReading = onContinueReading
        self.onSourceKindChange = onSourceKindChange
        self.workVersions = nil
        if let origin = initialOrigin ?? searchBook.origins.first {
            _currentBook = State(initialValue: OnlineBook(detailOrigin: origin, in: searchBook))
        } else {
            _currentBook = State(initialValue: OnlineBook(
                id: SearchResultDetailIdentity.onlineBookID(
                    searchBookID: searchBook.id,
                    originID: nil
                ),
                name: searchBook.name, author: searchBook.author,
                intro: searchBook.detailIntro, coverUrl: searchBook.coverUrl,
                bookUrl: "", tocUrl: "", wordCount: "",
                lastChapter: searchBook.lastChapter, kind: searchBook.kind,
                sourceId: searchBook.id, sourceName: ""
            ))
        }
    }

    private var canSwitchSource: Bool {
        (searchBook?.origins.count ?? 0) > 1
    }

    // MARK: Resolved display values (detail page overrides search result)

    private var displayName: String {
        let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b.isEmpty ? localized("未知書名") : b
    }

    private var displayAuthor: String {
        let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        if !b.isEmpty { return b }
        let candidates = [
            detailInfo?.intro ?? "",
            currentBook.intro,
            detailInfo?.kind ?? "",
            currentBook.kind
        ].joined(separator: "\n")
        if let extracted = Self.extractAuthorFromText(candidates), !extracted.isEmpty {
            return extracted
        }
        return localized("未知作者")
    }

    private static func extractAuthorFromText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let pattern = "作者[：:]\\s*([^\\s|、，,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayCoverUrl: String {
        let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = currentBook.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b
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

    private var displayWordCount: String {
        OnlineBookMetadataFormatter.wordCount(
            detailValue: detailInfo?.wordCount,
            fallbackValue: currentBook.wordCount
        )
    }

    private var displayLatestChapter: String {
        let d = detailInfo?.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return currentBook.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceName: String {
        let name = currentBook.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let s = source?.bookSourceName, !s.isEmpty { return s }
        return localized("未知來源配置")
    }

    /// Category string split into individual genre tags, junk filtered out.
    private var tags: [String] {
        OnlineBookMetadataFormatter.tags(
            detailKind: detailInfo?.kind,
            fallbackKind: currentBook.kind
        )
    }

    private var resolvedTOCURL: String? {
        let detailed = detailInfo?.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detailed, !detailed.isEmpty { return detailed }
        let fallback = currentBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    // MARK: Body

    var body: some View {
        let shown = shownMetadata
        return BookDetailScaffold(
            title: shown.name,
            compactAction: readAction,
            onRefresh: { await loadTOC(forceRefresh: true) }
        ) {
            BookDetailHero(
                artworkShape: .book,
                cover: coverArtwork(shown),
                title: shown.name,
                author: shown.author,
                meta: tags.joined(separator: " · "),
                primary: readAction,
                secondary: shelfAction,
                sourceGestures: sourceCallBacks?.gestures
            )
        } content: {
            BookDetailInfoStrip(items: infoItems)
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
                title: localized("目錄"),
                chapters: chapters,
                isLoading: loadingTOC,
                errorMessage: tocError,
                latestChapter: displayLatestChapter,
                onRetry: { Task { await loadTOC() } },
                onShowAll: { showChapterList = true }
            ) { offset, chapter in
                BookDetailChapterRow(
                    title: BookDetailChapterTitle.display(chapter, offset: offset),
                    isLocked: chapter.isVip || chapter.isPay,
                    trailing: .disclosure,
                    action: { openReader(chapterIndex: chapter.index) }
                )
            }
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
        .bookIntroActions($introActionRequest) { await loadTOC(forceRefresh: true) }
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
        .navigationDestination(item: $readerRoute) { route in
            BookReaderView(bookId: route.id)
                .environmentObject(bookStore)
                // SwiftUI owns this destination and its return path. Never attach
                // the shelf's UIKit card driver to an Explore/Search route.
                .environment(\.readerNavigator, nil)
                .environment(\.readerUsesParentNavigationStack, true)
                .navigationBarBackButtonHidden(true)
                .reservingNavigationBackSwipe()
                .onDisappear {
                    // Opening details above this reader also makes it disappear;
                    // only a removed reader route releases the trial book.
                    if readerRoute == nil { readerDidClose() }
                }
        }
        .fullScreenCover(isPresented: $showReader, onDismiss: readerDidClose) {
            // Audiobooks keep their dedicated modal player.
            if let bid = addedBookId {
                BookReaderView(bookId: bid)
                    .environmentObject(bookStore)
                    .environment(\.readerNavigator, nil)
            }
        }
        .sheet(isPresented: $showChapterList, onDismiss: {
            guard let chapterIndex = pendingChapterSelection else { return }
            pendingChapterSelection = nil
            openReader(chapterIndex: chapterIndex)
        }) {
            NavigationStack {
                BookDetailChapterListSheet(
                    chapters: chapters,
                    trailing: .disclosure,
                    onSelect: { offset in
                        pendingChapterSelection = chapters[offset].index
                        showChapterList = false
                    }
                )
            }
        }
        .onAppear {
            checkAlreadyInShelf()
            if chapters.isEmpty { Task { await loadTOC() } }
        }
        .task(id: shelvedCopy?.id) { copySidecar = shelvedCopy.map(bookStore.copyIntroValues(of:)) ?? [] }
    }

    // MARK: Hero

    /// A shelved copy's own artwork, custom cover included, as the shelf draws it; else the
    /// source's cover.
    @ViewBuilder
    private func coverArtwork(_ shown: (name: String, author: String, intro: CopyMetadata.Intro?)) -> some View {
        if let copy = shelvedCopy {
            HomeCoverArtwork(cover: .shelf(copy), title: shown.name,
                             author: shown.author == localized("未知作者") ? "" : shown.author,
                             size: CGSize(width: DSLayout.bookCoverHeroWidth, height: DSLayout.bookCoverHeroHeight))
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

    private var readAction: BookDetailAction {
        BookDetailAction(
            title: openingReader
                ? localized("打開中…")
                : (alreadyInShelf ? localized("繼續閱讀") : localized("立即閱讀")),
            systemImage: "book.fill",
            isBusy: openingReader,
            isEnabled: !chapters.isEmpty && !addingToShelf,
            action: { openReader() }
        )
    }

    private var shelfAction: BookDetailAction {
        BookDetailAction(
            title: alreadyInShelf
                ? localized("移除書架")
                : (addingToShelf ? localized("加入中…") : localized("加入書架")),
            systemImage: alreadyInShelf ? "minus" : "plus",
            isBusy: addingToShelf,
            isEnabled: !chapters.isEmpty,
            action: {
                if alreadyInShelf { confirmsRemoval = true } else { addToShelfOnly() }
            }
        )
    }

    private var infoItems: [BookDetailInfoItem] {
        var items: [BookDetailInfoItem] = []
        if !displayWordCount.isEmpty {
            items.append(BookDetailInfoItem(
                id: "wordCount", label: localized("字數"), value: displayWordCount
            ))
        }
        if !chapters.isEmpty {
            items.append(BookDetailInfoItem(
                id: "chapters", label: localized("章節"), value: chapters.count.formatted()
            ))
        }
        items.append(.source(name: sourceName) { showSourcePicker = true })
        return items
    }

    /// The runtime variables the next fetch, shelf add or reader open will carry.
    private var effectiveRuntimeVariables: [String: String]? {
        if alreadyInShelf, let id = addedBookId,
           let shelved = bookStore.books.first(where: { $0.id == id }) {
            return shelved.runtimeVariables
        }
        return tocRuntimeVariables ?? detailInfo?.runtimeVariables ?? currentBook.runtimeVariables
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
        if let toc = tocRuntimeVariables {
            tocRuntimeVariables = BookCustomVariable.merged(value, into: toc)
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

    // MARK: Logic

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
        if DetailSourceKind.kind(of: origin, in: searchBook) == .audio,
           let onSourceKindChange {
            onSourceKindChange(origin)
            return
        }
        switchToOrigin(origin)
    }

    /// Switch to a different source (origin) and reload the detail + TOC from scratch.
    private func switchToOrigin(_ origin: BookOrigin) {
        let newBook: OnlineBook
        if let searchBook {
            newBook = OnlineBook(detailOrigin: origin, in: searchBook)
        } else {
            newBook = OnlineBook(detailOrigin: origin, name: currentBook.name, author: currentBook.author)
        }
        guard newBook.sourceId != currentBook.sourceId
            || newBook.bookUrl != currentBook.bookUrl else { return }

        pendingShelfSourceSwitch = sourceSwitchBookId != nil
        currentBook = newBook
        detailInfo = nil
        tocRuntimeVariables = nil
        chapters = []
        tocError = nil
        addedBookId = nil
        alreadyInShelf = false
        introExpanded = false
        checkAlreadyInShelf()
        Task { await loadTOC() }
    }

    private func isCurrentRequest(_ request: OnlineBook) -> Bool {
        request.sourceId == currentBook.sourceId
            && ChangeSourceCache.urlKey(request.bookUrl)
                == ChangeSourceCache.urlKey(currentBook.bookUrl)
    }

    private func checkAlreadyInShelf() {
        // Reader details edit the book that opened the page. Do not replace its identity with
        // an already-shelved sibling just because the newly selected source is also present.
        // The source switch must commit back to the reader's original `bookId`.
        if let sourceSwitchBookId,
           bookStore.books.contains(where: { $0.id == sourceSwitchBookId }) {
            addedBookId = sourceSwitchBookId
            alreadyInShelf = true
            return
        }
        let existing = bookStore.onlineBook(
            sourceId: currentBook.sourceId, bookInfoURL: currentBook.bookUrl)
        addedBookId = existing?.id
        alreadyInShelf = existing != nil
    }

    private func loadTOC(forceRefresh: Bool = false) async {
        guard let source else {
            tocError = localized("來源配置已被刪除")
            return
        }

        loadingTOC = true
        tocError = nil
        let requestBook = currentBook
        let shouldPersistShelfSourceSwitch = pendingShelfSourceSwitch

        do {
            var currentRuntimeVariables = requestBook.runtimeVariables

            // ① Cache-first: a previously fetched TOC for this book renders
            //    instantly; the detail info and a fresh TOC still load below.
            let provisionalTocURL = requestBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? requestBook.bookUrl
                : requestBook.tocUrl
            var showedCachedTOC = false
            if !forceRefresh, !provisionalTocURL.isEmpty,
               let cached = await dependencies.bookSourceFetcher.cachedTOCPackage(
                   tocUrl: provisionalTocURL, source: source
               ) {
                showedCachedTOC = true
                await MainActor.run {
                    guard isCurrentRequest(requestBook) else { return }
                    chapters = cached.chapters
                    tocRuntimeVariables = cached.runtimeVariables
                    loadingTOC = false
                }
            }

            let applyFirstPage: ([OnlineChapterRef]) -> Void = { firstChapters in
                // First page ready — show immediately, don't wait for multi-page fetch
                Task { @MainActor in
                    guard self.isCurrentRequest(requestBook) else { return }
                    if self.chapters.isEmpty {
                        self.chapters = firstChapters
                        self.loadingTOC = false
                    }
                    if !shouldPersistShelfSourceSwitch, let bookId = self.addedBookId {
                        self.bookStore.updateOnlineChapters(bookId: bookId, chapters: firstChapters)
                    }
                }
            }

            let applyFinal: (TOCPackage) async -> Void = { tocPackage in
                if shouldPersistShelfSourceSwitch, let sourceSwitchBookId = self.sourceSwitchBookId {
                    // A second source tap can finish before this request. Never let an older
                    // TOC commit under the newer selection's shelf record.
                    let commitContext = await MainActor.run { () -> (UUID, BookOrigin)? in
                        guard self.isCurrentRequest(requestBook) else { return nil }
                        return (sourceSwitchBookId, self.sourceOrigin(for: tocPackage))
                    }
                    guard let (sourceSwitchBookId, origin) = commitContext else { return }
                    do {
                        try await self.bookStore.updateOnlineBookSource(
                            bookId: sourceSwitchBookId,
                            origin: origin,
                            preparedTOC: tocPackage,
                            offlineChapterStore: self.dependencies.offlineChapterStore
                        )
                    } catch {
                        await MainActor.run {
                            guard self.isCurrentRequest(requestBook) else { return }
                            self.tocError = error.localizedDescription
                            self.loadingTOC = false
                        }
                        return
                    }
                    await MainActor.run {
                        guard self.isCurrentRequest(requestBook) else { return }
                        self.pendingShelfSourceSwitch = false
                    }
                }
                await MainActor.run {
                    guard isCurrentRequest(requestBook) else { return }
                    chapters = tocPackage.chapters
                    tocRuntimeVariables = tocPackage.runtimeVariables
                    loadingTOC = false
                    if !shouldPersistShelfSourceSwitch, let bookId = addedBookId {
                        bookStore.updateOnlineChapters(
                            bookId: bookId,
                            chapters: tocPackage.chapters,
                            runtimeVariables: tocPackage.runtimeVariables
                        )
                    }
                }
            }

            // ② Concurrent fast path: the book already carries a TOC URL
            //    distinct from the detail page, so detail info and TOC can
            //    load in parallel instead of TOC waiting on detail.
            let trimmedTocURL = requestBook.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !showedCachedTOC,
               !trimmedTocURL.isEmpty,
               trimmedTocURL != requestBook.bookUrl,
               !requestBook.bookUrl.isEmpty {
                let parallelRuntimeVariables = currentRuntimeVariables
                async let tocTask = dependencies.bookSourceFetcher.fetchTOCPackage(
                    tocUrl: trimmedTocURL,
                    source: source,
                    runtimeVariables: parallelRuntimeVariables,
                    onFirstPageReady: applyFirstPage,
                    forceRefresh: forceRefresh
                )
                let infoPackage = try await SourcePerfTrace.spanAsync(
                    "detail.total", source.bookSourceName
                ) {
                    try await dependencies.bookSourceFetcher.fetchBookInfoPackage(
                        url: requestBook.bookUrl,
                        source: source,
                        runtimeVariables: parallelRuntimeVariables,
                        knownBook: requestBook
                    )
                }
                currentRuntimeVariables = infoPackage.runtimeVariables
                await MainActor.run {
                    guard isCurrentRequest(requestBook) else { return }
                    detailInfo = OnlineBookDetailPresentationPolicy.sanitized(
                        infoPackage.onlineBook
                    )
                }
                var tocPackage = try await tocTask
                // Detail resolved a different TOC URL (rare) — it wins.
                if !infoPackage.tocUrl.isEmpty, infoPackage.tocUrl != trimmedTocURL {
                    tocPackage = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                        tocUrl: infoPackage.tocUrl,
                        source: source,
                        runtimeVariables: currentRuntimeVariables,
                        onFirstPageReady: nil,
                        forceRefresh: forceRefresh
                    )
                }
                await applyFinal(tocPackage)
                return
            }

            // ③ Serial fallback: fetch the detail page for full info and the
            //    real TOC URL, then the TOC (instant when ① already showed
            //    this URL's cache).
            var finalTocURL = requestBook.bookUrl
            if !requestBook.bookUrl.isEmpty {
                let infoPackage = try await SourcePerfTrace.spanAsync(
                    "detail.total", source.bookSourceName
                ) {
                    try await dependencies.bookSourceFetcher.fetchBookInfoPackage(
                        url: requestBook.bookUrl,
                        source: source,
                        runtimeVariables: currentRuntimeVariables,
                        knownBook: requestBook
                    )
                }
                currentRuntimeVariables = infoPackage.runtimeVariables
                await MainActor.run {
                    guard isCurrentRequest(requestBook) else { return }
                    detailInfo = OnlineBookDetailPresentationPolicy.sanitized(
                        infoPackage.onlineBook
                    )
                }
                if !infoPackage.tocUrl.isEmpty {
                    finalTocURL = infoPackage.tocUrl
                }
            }
            let tocPackage = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                tocUrl: finalTocURL,
                source: source,
                runtimeVariables: currentRuntimeVariables,
                onFirstPageReady: applyFirstPage,
                forceRefresh: forceRefresh
            )
            await applyFinal(tocPackage)
        } catch {
            await MainActor.run {
                guard isCurrentRequest(requestBook) else { return }
                // A cached TOC is already on screen — keep it rather than
                // replacing it with an error banner.
                if chapters.isEmpty {
                    tocError = error.localizedDescription
                }
                loadingTOC = false
            }
        }
    }

    /// Converts the detail page's selected source back into the shelf model. The TOC package is
    /// passed through so the source switch does not fetch the same TOC a second time.
    private func sourceOrigin(for tocPackage: TOCPackage) -> BookOrigin {
        BookOrigin(
            sourceId: currentBook.sourceId,
            sourceName: currentBook.sourceName,
            bookUrl: currentBook.bookUrl,
            tocUrl: resolvedTOCURL ?? tocPackage.tocURL,
            coverUrl: displayCoverUrl,
            intro: displayIntro,
            lastChapter: displayLatestChapter,
            wordCount: displayWordCount,
            kind: detailInfo?.kind ?? currentBook.kind,
            runtimeVariables: tocPackage.runtimeVariables
                ?? detailInfo?.runtimeVariables
                ?? currentBook.runtimeVariables
        )
    }

    /// Remove from shelf.
    private func removeFromShelf() {
        guard alreadyInShelf, let bookId = addedBookId else { return }
        // Return control to the presenting navigation route before removing its backing item.
        // Otherwise `navigationDestination(item:)` keeps this detail destination alive after
        // the shelf row disappears, leaving only the themed background (white or black).
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
        alreadyInShelf = false
    }

    /// Add to shelf without opening the reader.
    private func addToShelfOnly() {
        guard !alreadyInShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let newBook = bookStore.addOnlineBook(
            name: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
            sourceId: source.id,
            bookInfoURL: currentBook.bookUrl,
            tocURL: resolvedTOCURL,
            coverUrl: displayCoverUrl,
            runtimeVariables: tocRuntimeVariables
                ?? detailInfo?.runtimeVariables
                ?? currentBook.runtimeVariables,
            chapters: chapters
        )
        addedBookId = newBook.id
        addingToShelf = false
        alreadyInShelf = true
        SourceCallBackService.notify(.addBookShelf, book: newBook)
    }

    /// Kept once it is on the shelf: its download put it there
    /// (`BookStore.ensureOnlineBookForDownload`).
    private func shouldKeepTemporaryReaderBook(_ bookId: UUID) -> Bool {
        bookStore.books.contains { $0.id == bookId }
    }

    private func readerDidClose() {
        guard let tempId = temporaryReaderBookId else { return }
        if shouldKeepTemporaryReaderBook(tempId) {
            temporaryReaderBookId = nil
            addedBookId = tempId
            alreadyInShelf = true
        } else {
            bookStore.delete(bookId: tempId)
            temporaryReaderBookId = nil
            if addedBookId == tempId { addedBookId = nil }
            checkAlreadyInShelf()
        }
    }

    /// Ensure the book is on the shelf before opening, so the reader has a valid bookId.
    private func openReader(chapterIndex: Int? = nil) {
        guard !chapters.isEmpty, let source, !openingReader else { return }
        if let onContinueReading {
            onContinueReading(chapterIndex)
            return
        }
        guard readerRoute == nil, !showReader else { return }
        openingReader = true

        var targetBookId: UUID

        if alreadyInShelf, let existingId = addedBookId,
            bookStore.books.contains(where: { $0.id == existingId })
        {
            bookStore.updateOnlineChapters(
                bookId: existingId,
                chapters: chapters,
                runtimeVariables: tocRuntimeVariables
            )
            temporaryReaderBookId = nil
            targetBookId = existingId
        } else {
            // A book read without being added is a record off the shelf: it neither shows
            // on the shelf nor syncs. It used to be a shelf book until the reader closed,
            // and synced while it was open; a device on 2.0.6, which never takes a
            // deletion, kept it as a second copy of the book (reported 2026-10-04). One a
            // reader left behind — the app ended before it closed — is read again rather
            // than joined by another.
            let runtimeVariables = tocRuntimeVariables
                ?? detailInfo?.runtimeVariables
                ?? currentBook.runtimeVariables
            let tempBook: ReadingBook
            if let leftover = bookStore.onlineBook(
                sourceId: source.id, bookInfoURL: currentBook.bookUrl, onShelf: false
            ) {
                bookStore.updateOnlineChapters(
                    bookId: leftover.id,
                    chapters: chapters,
                    runtimeVariables: runtimeVariables
                )
                tempBook = leftover
            } else {
                tempBook = bookStore.addOnlineBook(
                    name: displayName,
                    author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
                    sourceId: source.id,
                    bookInfoURL: currentBook.bookUrl,
                    tocURL: resolvedTOCURL,
                    coverUrl: displayCoverUrl,
                    runtimeVariables: runtimeVariables,
                    chapters: chapters,
                    isInBookshelf: false
                )
            }
            addedBookId = tempBook.id
            temporaryReaderBookId = tempBook.id
            targetBookId = tempBook.id
        }

        Task { @MainActor in
            // Finish persisting a selected chapter before the new reader restores it.
            if let chapterIndex {
                let position = CoreTextReadingPosition(spineIndex: chapterIndex, charOffset: 0)
                await dependencies.readingPositionStore.save(position, for: targetBookId.uuidString)
            }
            guard let readingBook = bookStore.readingBook(id: targetBookId) else {
                openingReader = false
                return
            }
            if readingBook.resolvedPipelineKind == .audio {
                openingReader = false
                showReader = true
                return
            }
            readerRoute = DetailReaderRoute(id: targetBookId)
            openingReader = false
        }
    }
}

// MARK: - Preview

#Preview {
    let sample = OnlineBook(
        name: "修仙聊天群",
        author: "世味煮作茶",
        intro: "某一天，剛被開除的上班族余小安偶然進入了一個奇怪的修仙聊天群，接受了一個種藥草的委託，從此，他變成了一個種地的……不過他的顧客名字都很奇怪，比如：白帝仙王、青龍仙君、太上仙尊。",
        coverUrl: "",
        bookUrl: "https://example.com/book/1",
        tocUrl: "https://example.com/book/1/toc",
        wordCount: "34.8萬字",
        lastChapter: "第703章 大結局",
        kind: "都市腦洞 | 都市 | 系統 | 神豪 | 諸天萬界",
        sourceId: UUID(),
        sourceName: "晴天小說"
    )
    return NavigationStack {
        OnlineBookView(book: sample)
            .environmentObject(BookStore())
    }
}

#Preview("作品詳情的書源版本") {
    let sample = OnlineBook(
        name: "修仙聊天群", author: "世味煮作茶", intro: "", coverUrl: "",
        bookUrl: "https://example.com/book/1", tocUrl: "https://example.com/book/1/toc",
        wordCount: "34.8萬字", lastChapter: "第703章 大結局", kind: "都市", sourceId: UUID(), sourceName: "晴天小說"
    )
    // 換源 lists 書架 above the sources.
    let versions = BookDetailInfoChoice(options: [.init(id: "source", title: "晴天小說"), .init(id: "copy", title: "書架 · 已讀 42%")],
                                        selection: .constant("source"))
    return NavigationStack {
        OnlineBookView(book: sample, workVersions: versions)
            .environmentObject(BookStore())
    }
}
