import SwiftUI

/// What 作品詳情 pushes. One item, so the page has one destination (iOS 17 guardrail 12).
private enum WorkDetailPush: Hashable {
    /// A copy's reader; at a 目錄 entry's anchor when one was picked.
    case reader(UUID, ReaderTOCTarget? = nil)
    /// A 青空文庫 work not on the shelf yet: the reader imports it under its own 正在開啟書籍.
    case aozoraReader(AozoraWork)
    /// 編輯遠端資料, for the version shown.
    case editor
    /// A public library's author page, from the author's name or 作者其他作品's 查看全部.
    case author(PublicLibraryAuthorDestination)
    /// Another work, from 作者其他作品 or 同系列.
    case work(WorkDetailRoute)
    /// The series page, from the hero's link or 同系列's 查看全部.
    case series(WorkSeriesShelf)
    /// A 青空文庫 分類's works (依分類's group, by id), from the hero's link.
    case aozoraClassification(String)
}

/// When 作品詳情 reads its series: for the versions read, again when they change.
private struct SeriesLoad: Hashable {
    let versions: [SourceItemKey]
}

/// What 作品詳情's 目錄 is read for: a version in a format, once its library item is known.
private struct TOCLoad: Hashable {
    let version: SourceItemKey
    let formatID: String?
    let hasItem: Bool
}

/// When 作品詳情 reads its versions: once no action runs, again when asked, and again once
/// 青空文庫's catalog is read, which a 青空文庫 copy's work comes from.
private struct VersionsLoad: Hashable {
    let idle: Bool
    let revision: Int
    let hasAozoraCatalog: Bool
}

/// When 作品詳情 reads the shown copy's sidecar: for each copy, and again after a write to it.
private struct SidecarLoad: Hashable {
    let copy: UUID?
    let revision: Int
}

/// A Gutenberg book's catalog entry, read when its version is shown.
private enum GutenbergLoad {
    case loading
    case failed(String)

    var isLoading: Bool { if case .loading = self { true } else { false } }
}

/// 作品詳情 opened from a reader (5f-4b, decision 32): the book being read, and the way back to
/// that same reader. Never a second reader over it.
struct WorkDetailReaderContext {
    /// The book the reader has open; a book-source page switches this book's source.
    let bookId: UUID
    /// Back to the reader, at a chapter when one was picked on the page.
    let continueReading: (ReaderTOCTarget?) -> Void
    /// The book left the shelf from the page; the reader closes with it.
    let removedFromShelf: () -> Void
}

/// 作品詳情 (unified library 5f, design §14.1): the one page of a work, as Emby has one page
/// per item (Phase 5 plan, decisions 27 and 28). Every Explore card, the bookshelf's ••• and
/// the remote libraries' lists open it. 來源 switches between the versions this device knows
/// of the work in place; the buttons, the facts and the description follow the version shown.
///
/// Each version acts through what its source already uses: a library item (OPDS, Calibre,
/// WebDAV, and a Gutenberg book once its catalog entry is read) through
/// `RemoteLibraryActionModel`, a 青空文庫 work through `AozoraLibraryDownloading`. A
/// book-source version is that source's own page, drawn here in place (5f-3): its chapter
/// list, 換源, shelf and reader are `OnlineBookView`'s (or `AudiobookDetailView`'s), with the
/// work's other versions first in its 換源 sheet. A book-source book on the shelf is that
/// page too (5f-4): the shelf has no second 書籍詳情.
struct WorkDetailView: View {
    let route: WorkDetailRoute
    /// Takes the page off its stack when the shelf copy it was opened for leaves the shelf
    /// from its source's page; without it the page stays and reads its versions again.
    let onRemoveFromShelf: (() -> Void)?
    /// Set when a reader opened the page: only the version it reads is shown (decision 32:
    /// the work's other copies are not versions of it, and reading one would stack a reader).
    let readerContext: WorkDetailReaderContext?
    /// Set when 搜索 opened the page (5f-4c, unified search 4c-3): each book-source version's
    /// result, by node key, frozen at the tap. Such a version's page keeps its result's origins
    /// for 換源, as the result's own page did.
    let searchResults: [SourceItemKey: SearchBook]
    /// The work's other members 搜索 found (4c-3), listed with the versions this device knows.
    let searchVersions: [WorkDetailRoute]
    @EnvironmentObject private var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @StateObject private var actions = RemoteLibraryActionModel()
    @StateObject private var authorWorks = AuthorWorksModel()
    @StateObject private var toc = WorkTableOfContentsModel()
    /// 「尋找可用來源」 (7b-2): the books its search found of the work join `versions`. It runs on
    /// its own once the work's page shows (2026-10-17).
    @StateObject private var finder = WorkSourceFinder()
    @State private var showChapterList = false
    /// The chapter picked from 查看全部, opened once its sheet is gone.
    @State private var pendingChapter: OnlineChapterRef?
    /// The series a version on this device belongs to (同系列); nil while read, or when none.
    @State private var series: WorkSeriesShelf?
    /// The versions this device knows of the work (`ShelfProvider.versions`).
    @State private var listed: [WorkDetailRoute]
    @State private var versionsLoaded = false
    /// The version picked from 來源; nil shows the primary one.
    @State private var chosen: SourceItemKey?
    @State private var pushed: WorkDetailPush?
    /// The copy just read without adding, while 「加入書架？」 asks about it.
    @State private var shelvePrompt: ReadingBook?
    @State private var introExpanded = false
    /// The sidecar values of the shelf copy shown (`shownCopy`), read again when it is written.
    @State private var copySidecar: [MetadataValue] = []
    /// Bumped when the shown copy's sidecar is written: the filler can answer while the page is
    /// open (an import's copy opened at once, or sources imported since).
    @State private var sidecarRevision = 0
    /// Library items by version that are not in the version itself: a Gutenberg book's from
    /// its catalog entry, and one edited through 編輯遠端資料 as saved.
    @State private var items: [SourceItemKey: RemoteLibraryItem] = [:]
    @State private var gutenbergLoads: [SourceItemKey: GutenbergLoad] = [:]
    /// A Gutenberg book's authors from its catalog entry, by version.
    @State private var gutenbergAuthors: [SourceItemKey: [GutenbergAuthor]] = [:]
    /// The format picked per version; absent, the preferred one.
    @State private var formatIDs: [SourceItemKey: String] = [:]
    @State private var writeCapabilities: RemoteLibraryWriteCapabilities?

    /// Bumped when a book-source version's page takes its book off the shelf, so the versions
    /// are read again without the copy.
    @State private var versionsRevision = 0

    init(route: WorkDetailRoute, onRemoveFromShelf: (() -> Void)? = nil, readerContext: WorkDetailReaderContext? = nil,
         searchResults: [SourceItemKey: SearchBook] = [:], searchVersions: [WorkDetailRoute] = []) {
        self.route = route
        self.onRemoveFromShelf = onRemoveFromShelf
        self.readerContext = readerContext
        self.searchResults = searchResults
        self.searchVersions = searchVersions
        _listed = State(initialValue: WorkVersions.merge(tapped: route, copies: [], members: searchVersions))
        if readerContext != nil { _chosen = State(initialValue: route.nodeKey) }
    }

    /// The versions 來源 lists: those known, then those 「尋找可用來源」 found.
    private var versions: [WorkDetailRoute] { WorkSourceFinder.joined(listed, found: finder.found) }
    private var selected: WorkDetailRoute? { WorkVersions.selected(in: versions, chosen: chosen) }
    private var author: String { route.summary.authors.joined(separator: "、") }

    var body: some View {
        page
            .task(id: VersionsLoad(idle: actions.action == nil, revision: versionsRevision,
                                   hasAozoraCatalog: aozora.catalog != nil)) {
                // Again after each action: a book added to the shelf is a version of its own.
                guard actions.action == nil else { return }
                guard readerContext == nil else {
                    versionsLoaded = true
                    return
                }
                listed = await ShelfProvider(store: store).versions(of: route, aozora: aozora.catalog, also: searchVersions)
                versionsLoaded = true
                // A 青空文庫 copy stands for itself until the catalog is read; reading it changes
                // this task's id, and the versions are read again with the work.
                if aozora.catalog == nil,
                   versions.contains(where: { $0.record.copyID != nil && $0.record.key.instance.type == .aozora }) {
                    await aozora.load()
                }
                // A book-source page keeps its place once shown: the copy its 加入書架 makes would
                // otherwise come first and take the page from under its reader.
                if chosen == nil, let shown = selected, onlineBook(of: shown) != nil { chosen = shown.nodeKey }
            }
            .task(id: selected?.nodeKey) { await prepare(selected) }
            .task(id: findsOnOpen) {
                guard findsOnOpen else { return }
                findSources(onOpen: true)
            }
            .task(id: tocLoad) {
                await toc.load(copy: tocLoad.flatMap { _ in selected.flatMap(tocCopy(of:)) }, store: store,
                               remoteLibrary: dependencies.remoteLibrary, positions: dependencies.readingPositionStore)
            }
            .task(id: SidecarLoad(copy: shownCopy?.id, revision: sidecarRevision)) {
                copySidecar = shownCopy.map(store.copyIntroValues(of:)) ?? []
            }
            .onReceive(store.importedMetadata.writes) { id in
                if id == shownCopy?.id { sidecarRevision += 1 }
            }
            .task(id: authorWorksRequest) { await authorWorks.load(authorWorksRequest, store: store) }
            .task(id: seriesLoad) {
                guard let seriesLoad else {
                    series = nil
                    return
                }
                series = await ShelfProvider(store: store).series(of: versions.filter { seriesLoad.versions.contains($0.nodeKey) })
            }
            .onDisappear { actions.cancelForDisappearance() }
            .onChange(of: scenePhase) { _, phase in finder.setPresentationActive(phase == .active) }
            .onChange(of: finder.state) { _, state in
                // The search ran on its own; say how it ended, as the row now does.
                switch state {
                case .done, .failed, .noSources:
                    UIAccessibility.post(notification: .announcement, argument: findSourcesItem.value)
                case .idle, .searching:
                    break
                }
            }
    }

    /// A book-source version, found or on the shelf, is its source's own page; every other
    /// version is this one's. Each has one item destination of its own (guardrail 12).
    @ViewBuilder
    private var page: some View {
        if let readerContext, let version = selected, let book = onlineBook(of: version) {
            // The reader's own book as text, as its reader reads it: no page-kind switch, and
            // 換源 rebinds this copy (`sourceSwitchBookId`), mapping the chapter.
            OnlineBookView(book: book, sourceSwitchBookId: readerContext.bookId,
                           onRemoveFromShelf: readerContext.removedFromShelf,
                           onContinueReading: { chapterIndex in
                               readerContext.continueReading(chapterIndex.map { ReaderTOCTarget(spineIndex: $0, fragment: nil) })
                           })
                .environmentObject(store)
                // The reader's own navigator, unlike the other branch: its detail returns to it.
                .id(version.nodeKey)
        } else if let version = selected, let book = onlineBook(of: version) {
            OnlineBookDetailDestination(
                onlineEntry(of: version, book: book),
                onRemoveFromShelf: { leftShelf(version) },
                workVersions: versionChoice(version)
            )
            .environmentObject(store)
            // Never the shelf's card coordinator: closing a reader onto a pushed page through
            // it left iOS 17's navigation bar off screen (5f-1).
            .environment(\.readerNavigator, nil)
            .id(version.nodeKey)
        } else {
            workPage
        }
    }

    private var workPage: some View {
        BookDetailScaffold(title: route.summary.title, compactAction: primaryAction) {
            BookDetailHero(artworkShape: route.record.contentKind == .audio ? .square : .book,
                           cover: cover, title: route.summary.title, author: author,
                           meta: "", primary: primaryAction, secondary: secondaryAction,
                           authorActions: authorLinks, links: heroLinks)
        } content: {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                status
                if versionsLoaded, WorkVersions.primary(in: versions) == nil {
                    ContentUnavailableView {
                        UnavailableLabel(localized("目前沒有可閱讀的來源"), systemImage: "book.closed")
                    }
                }
                gutenbergStatus
                if let selected, let item = libraryItem(of: selected) {
                    libraryActions(selected, item: item)
                }
                // Hero → 簡介 → 作品關聯 → 作品資訊 (maintainer, 2026-10-12): the first half serves
                // reading and finding more, the end looking things up. No section without data.
                if let intro {
                    // Never a book source's own description: a book-source version draws its
                    // own page. Legado's formats are not read here (decision 33).
                    BookDetailIntroSection(text: intro, isExpanded: $introExpanded, readsSourceFormats: false)
                }
                if let reason = route.recommendationReason {
                    BookDetailRecommendationSection(reason: reason)
                }
                tableOfContents
                if let series {
                    BookDetailSeriesSection(series: series, onShowAll: { pushed = .series(series) },
                                            onSelect: { pushed = .work($0) })
                }
                BookDetailAuthorWorksSection(
                    state: authorWorks.state,
                    onShowAll: authorWorksRequest?.authorPage.map { page in { pushed = .author(page) } },
                    onSelect: { pushed = .work($0) },
                    onRetry: { Task { await authorWorks.retry(authorWorksRequest, store: store) } }
                )
                BookDetailInfoSection(items: infoItems)
            }
        }
        .onChange(of: pushed) { previous, current in
            // Back from a reader, by its close button or a swipe: offer what was read to the shelf.
            guard current == nil, let previous, let id = readCopyID(previous) else { return }
            shelvePrompt = ReaderShelvePrompt.copy(id, in: store)
        }
        .readerShelvePrompt($shelvePrompt, onAdd: { _ = store.addReadingBookToShelf(id: $0.id) })
        .sheet(isPresented: $showChapterList, onDismiss: {
            guard let chapter = pendingChapter else { return }
            pendingChapter = nil
            openChapter(chapter)
        }) {
            if case .loaded(_, let chapters) = toc.state {
                NavigationStack {
                    BookDetailChapterListSheet(chapters: chapters, trailing: .disclosure, onSelect: { offset in
                        pendingChapter = chapters[offset]
                        showChapterList = false
                    })
                }
            }
        }
        .navigationDestination(item: $pushed) { push in
            switch push {
            case .reader(let id, let target):
                // Pushed by this page on whichever stack it is on, as every detail page pushes
                // its reader. Never the shelf's UIKit card driver: closing onto a pushed page,
                // it left iOS 17's navigation bar off screen.
                BookReaderView(bookId: id, openingTOCTarget: target).environmentObject(store)
                    .environment(\.readerNavigator, nil)
                    .environment(\.readerUsesParentNavigationStack, true)
                    .navigationBarBackButtonHidden(true)
                    .reservingNavigationBackSwipe()
            case .aozoraReader(let work):
                AozoraReaderEntry(work: work).environmentObject(store)
                    .environment(\.readerNavigator, nil)
                    .environment(\.readerUsesParentNavigationStack, true)
                    .navigationBarBackButtonHidden(true)
                    .reservingNavigationBackSwipe()
            case .editor:
                if let selected, let item = libraryItem(of: selected), let writeCapabilities {
                    RemoteLibraryBookEditor(item: item, capabilities: writeCapabilities) { updated in
                        items[selected.nodeKey] = updated
                        formatIDs[selected.nodeKey] = nil
                        pushed = nil
                    }
                    .environmentObject(store)
                }
            case .author(let destination):
                WorkDetailAuthorPage(destination: destination).environmentObject(store)
            case .work(let route):
                WorkDetailView(route: route).environmentObject(store)
            case .series(let series):
                WorkDetailSeriesPage(series: series).environmentObject(store)
            case .aozoraClassification(let id):
                if let index = aozora.catalog, let group = index.classificationGroups.first(where: { $0.id == id }) {
                    WorkDetailAozoraWorksPage(title: localized(group.titleKey),
                                              works: group.ids.compactMap { index.worksByID[$0] }, index: index)
                        .environmentObject(store)
                }
            }
        }
    }

    // MARK: 目錄

    /// The chapters of the copy the version is read from, read as the page opens (maintainer,
    /// 2026-10-13), as a book source's page lists its own: the first few, then 查看全部.
    @ViewBuilder
    private var tableOfContents: some View {
        let chapters: [OnlineChapterRef] = if case .loaded(_, let chapters) = toc.state { chapters } else { [] }
        let failure: String? = if case .failed(let message) = toc.state { message } else { nil }
        if toc.state != .none {
            BookDetailChapterSection(
                title: localized("目錄"), chapters: chapters, isLoading: toc.state == .loading, errorMessage: failure,
                latestChapter: "", onRetry: { reloadTOC() }, onShowAll: { showChapterList = true }
            ) { offset, chapter in
                BookDetailChapterRow(title: BookDetailChapterTitle.display(chapter, offset: offset), isLocked: false,
                                     trailing: .disclosure, action: { openChapter(chapter) })
                    .accessibilityIdentifier("detail.toc.\(offset)")
            }
        }
    }

    /// What 目錄 is read for: the version shown, once the work's versions are known, in its
    /// format, once a Gutenberg book's item is read. None on the page a reader opened.
    private var tocLoad: TOCLoad? {
        guard readerContext == nil, versionsLoaded, let version = selected else { return nil }
        return TOCLoad(version: version.nodeKey, formatID: selectedFormat(of: version)?.id,
                       hasItem: libraryItem(of: version) != nil)
    }

    /// The copy the version is read from, as 開始閱讀 reads it; nil for a version with none
    /// (a book source's, drawn by its own page) or a format that does not read.
    private func tocCopy(of version: WorkDetailRoute) -> (() async throws -> ReadingBook)? {
        switch version.opening {
        case .copy(let id):
            guard let book = copy(id) else { return nil }
            return { book }
        case .aozora(let work):
            return { [dependencies, store] in try await dependencies.aozoraLibrary.readingCopy(work: work, store: store) }
        case .moduleBook(let book):
            return { [dependencies, store] in try await dependencies.moduleBooks.readingCopy(book, store: store) }
        case .gutenberg, .opdsEntry, .webDAVFile:
            guard let item = libraryItem(of: version), let format = selectedFormat(of: version), format.isSupported else {
                return nil
            }
            return { [dependencies, store] in try dependencies.remoteLibrary.readingCopy(item: item, format: format, store: store) }
        case .onlineBook, .bibliographic:
            return nil
        }
    }

    private func reloadTOC() {
        Task {
            await toc.load(copy: selected.flatMap(tocCopy(of:)), store: store,
                           remoteLibrary: dependencies.remoteLibrary, positions: dependencies.readingPositionStore)
        }
    }

    /// Opens the copy at `chapter`: its spine item's position is saved first so the reader
    /// restores to it, and the reader then goes on to the entry's anchor as its own 目錄 does.
    private func openChapter(_ chapter: OnlineChapterRef) {
        guard case .loaded(let bookID, _) = toc.state else { return }
        let target = WorkTableOfContents.target(of: chapter)
        // From a reader, its own book jumps there in that reader.
        if let readerContext, bookID == readerContext.bookId {
            readerContext.continueReading(target)
            return
        }
        Task {
            await dependencies.readingPositionStore.save(CoreTextReadingPosition(spineIndex: chapter.index, charOffset: 0),
                                                         for: bookID.uuidString)
            pushed = .reader(bookID, target.fragment == nil ? nil : target)
        }
    }

    // MARK: Author

    /// The author's page in the public library the version is from; elsewhere the author is
    /// plain text. None on the page a reader opened, where another book could open a second
    /// reader (decision 32).
    private var authorLinks: [BookDetailAuthorAction] {
        guard readerContext == nil, let selected else { return [] }
        switch selected.opening {
        case .aozora(let work):
            guard let index = aozora.catalog else { return [] }
            return work.authorCredits.compactMap { credit in
                guard let person = index.personsByID[credit.person] else { return nil }
                return BookDetailAuthorAction(id: person.id + credit.role, name: person.name,
                                              action: { pushed = .author(.aozora(person, index)) })
            }
        case .gutenberg:
            return (gutenbergAuthors[selected.nodeKey] ?? []).mainAuthors.map { author in
                BookDetailAuthorAction(id: author.id, name: author.displayName, action: { pushed = .author(.gutenberg(author)) })
            }
        case .copy, .opdsEntry, .webDAVFile, .onlineBook, .moduleBook, .bibliographic:
            return []
        }
    }

    /// Those the hero leaves out, each a row of 作品資訊 by what they did, opening their page.
    private func contributorItems(_ version: WorkDetailRoute) -> [BookDetailInfoItem] {
        switch version.opening {
        case .aozora(let work):
            guard let index = aozora.catalog else { return [] }
            return work.otherCredits.enumerated().compactMap { offset, credit in
                guard let person = index.personsByID[credit.person] else { return nil }
                return BookDetailInfoItem(id: "credit\(offset)", label: localized(credit.role), value: person.name,
                                          action: { pushed = .author(.aozora(person, index)) })
            }
        case .gutenberg:
            return (gutenbergAuthors[version.nodeKey] ?? []).contributors.map { author in
                BookDetailInfoItem(id: "credit.\(author.id)", label: localized(author.roleKey), value: author.displayName,
                                   action: { pushed = .author(.gutenberg(author)) })
            }
        case .copy, .opdsEntry, .webDAVFile, .onlineBook, .moduleBook, .bibliographic:
            return []
        }
    }

    // MARK: Series

    /// Which versions 同系列 reads: the shelf's copies and the libraries' files, which carry a
    /// series in their metadata; none on the page a reader opened, where another book could
    /// open a second reader (decision 32), and none for a book source's page.
    private var seriesLoad: SeriesLoad? {
        guard readerContext == nil, versionsLoaded, let selected, onlineBook(of: selected) == nil else { return nil }
        let keys = versions.filter { version in
            switch version.opening {
            case .copy, .opdsEntry, .webDAVFile: true
            case .gutenberg, .aozora, .onlineBook, .moduleBook, .bibliographic: false
            }
        }.map(\.nodeKey)
        return keys.isEmpty ? nil : SeriesLoad(versions: keys)
    }

    /// The links under the author: a 青空文庫 work's 分類, which open 依分類's list, then the
    /// series page: 「三體 · 第 2 冊 ›」. Only what the version shown has.
    private var heroLinks: [BookDetailLink] {
        var links: [BookDetailLink] = []
        if let selected, case .aozora(let work) = selected.opening, let index = aozora.catalog {
            links += index.classificationGroups(of: work).map { group in
                BookDetailLink(id: "classification.\(group.id)", title: localized(group.titleKey),
                               action: { pushed = .aozoraClassification(group.id) })
            }
        }
        if let series {
            links.append(BookDetailLink(id: "series", title: series.line, action: { pushed = .series(series) },
                                        hint: localized("顯示這個系列的作品")))
        }
        return links
    }

    /// Where 作者其他作品 reads from for the version shown: its library's record of the author,
    /// or the shelf's for a copy or a library file. Once the versions are read, so none of
    /// them is offered as another work; not on the page a reader opened (decision 32).
    private var authorWorksRequest: AuthorWorksRequest? {
        guard readerContext == nil, versionsLoaded, let selected else { return nil }
        switch selected.opening {
        case .aozora(let work):
            return aozora.catalog.map { .aozora(work, $0) }
        case .gutenberg(let book):
            return gutenbergAuthors[selected.nodeKey]?.mainAuthors.first.map { .gutenberg($0, excluding: book) }
        case .copy, .opdsEntry, .webDAVFile:
            // The versions known: a book 「尋找可用來源」 found is no shelf work, and each one
            // found would read the author's works again.
            return .shelf(versions: listed)
        case .onlineBook, .moduleBook, .bibliographic:
            return nil
        }
    }

    /// The book a book-source version's page shows: the found one's frozen card, or an
    /// online shelf copy as the reader opens it.
    private func onlineBook(of version: WorkDetailRoute) -> OnlineBook? {
        switch version.opening {
        case .onlineBook(let frozen): frozen.book
        case .copy(let id): copy(id).flatMap(OnlineBook.init(shelfCopy:))
        case .opdsEntry, .webDAVFile, .gutenberg, .aozora, .moduleBook, .bibliographic: nil
        }
    }

    /// The page of a book-source version: 搜索's result as it was found, with its origins for 換源;
    /// every other one (a row's book, a shelf copy) as its own book.
    private func onlineEntry(of version: WorkDetailRoute, book: OnlineBook) -> OnlineBookDetailDestination.Entry {
        if let searchResult = searchResults[version.nodeKey] { return .search(searchResult) }
        return .book(book)
    }

    /// A book-source page took its book off the shelf. The copy the page was opened for takes
    /// the page with it when its stack can; a found version's page stays, as the version is
    /// still there, and the versions are read again without the copy.
    private func leftShelf(_ version: WorkDetailRoute) {
        if case .copy = version.opening, version.nodeKey == route.nodeKey, let onRemoveFromShelf {
            onRemoveFromShelf()
        } else {
            versionsRevision += 1
        }
    }

    // MARK: Hero

    private var cover: some View {
        let content: HomeCardContent.Cover = if case .copy(let id) = route.opening, let book = copy(id) {
            .shelf(book)
        } else {
            .reference(route.summary.cover, session: HomeCardContent.session(for: route.opening, connections: .shared))
        }
        return HomeCoverArtwork(cover: content, title: route.summary.title, author: author,
                                size: CGSize(width: DSLayout.bookDetailCoverWidth, height: DSLayout.bookDetailCoverHeight))
    }

    private var primaryAction: BookDetailAction {
        guard let version = selected, version.isReadable else {
            return BookDetailAction(title: localized("開始閱讀"), systemImage: "book", isEnabled: false, action: {})
        }
        switch version.opening {
        case .onlineBook, .bibliographic:
            // Drawn by the source's own page instead (see `page`); a bibliographic record is
            // never readable and is caught above.
            return BookDetailAction(title: localized("開始閱讀"), systemImage: "book", isEnabled: false, action: {})
        case .gutenberg where shelfCopy(of: version) != nil:
            return BookDetailAction(title: localized(hasBeenOpened(version) ? "繼續閱讀" : "開始閱讀"), systemImage: "book",
                                    isEnabled: actions.action == nil,
                                    detail: resumeDetail, action: { read(version) })
        case .opdsEntry, .webDAVFile, .gutenberg:
            return BookDetailAction(title: localized(libraryCopy?.lastOpenedDate == nil ? "開始閱讀" : "繼續閱讀"),
                                    systemImage: "book",
                                    isBusy: actions.action == .read || gutenbergLoads[version.nodeKey]?.isLoading == true,
                                    isEnabled: canActOnLibraryItem, detail: resumeDetail,
                                    action: { begin(.read) })
        case .copy, .aozora:
            return BookDetailAction(title: localized(hasBeenOpened(version) ? "繼續閱讀" : "開始閱讀"), systemImage: "book",
                                    isEnabled: actions.action == nil,
                                    detail: resumeDetail, action: { read(version) })
        case .moduleBook:
            return BookDetailAction(title: localized(hasBeenOpened(version) ? "繼續閱讀" : "開始閱讀"), systemImage: "book",
                                    isBusy: actions.action == .read, isEnabled: actions.action == nil,
                                    detail: resumeDetail, action: { read(version) })
        }
    }

    /// How far the copy 繼續閱讀 opens is read. Every version this page draws itself is a
    /// file (EPUB, TXT, PDF) whose spine items are not its chapters, so it is a share.
    private var resumeDetail: String? {
        BookDetailResume.detail(chapterIndex: nil, progress: readingCopy?.currentPosition)
    }

    /// 加入書架 for the version shown; 已加入書架 once its copy is on the shelf.
    private var secondaryAction: BookDetailAction? {
        guard let version = selected else { return nil }
        let added = BookDetailAction(title: localized("已加入書架"), systemImage: "checkmark", isEnabled: false, action: {})
        switch version.opening {
        case .copy(let id):
            return copy(id)?.isInBookshelf == true ? added : nil
        case .onlineBook, .bibliographic:
            return nil
        case .gutenberg where shelfCopy(of: version) != nil:
            return added
        case .opdsEntry, .webDAVFile, .gutenberg:
            if libraryCopy?.isInBookshelf == true { return added }
            return BookDetailAction(title: localized("加入書架"), systemImage: "plus",
                                    isBusy: actions.action == .addToShelf, isEnabled: canActOnLibraryItem,
                                    action: { begin(.addToShelf) })
        case .aozora(let work):
            if shelfCopy(of: version) != nil { return added }
            return BookDetailAction(title: localized("加入書架"), systemImage: "plus",
                                    isBusy: actions.action == .addToShelf, isEnabled: actions.action == nil,
                                    action: { addAozoraToShelf(work) })
        case .moduleBook(let book):
            if shelfCopy(of: version) != nil { return added }
            return BookDetailAction(title: localized("加入書架"), systemImage: "plus",
                                    isBusy: actions.action == .addToShelf, isEnabled: actions.action == nil,
                                    action: { addModuleBookToShelf(book) })
        }
    }

    // MARK: Content

    @ViewBuilder
    private var status: some View {
        if let action = actions.action {
            VStack(spacing: DSSpacing.sm) {
                ProgressView(action.progressTitle)
                Button(localized("取消"), role: .cancel) { actions.cancel() }
            }
            .frame(maxWidth: .infinity)
        }
        if let message = actions.message {
            Text(message)
                .font(DSFont.subheadline)
                .foregroundStyle(actions.failed ? DSColor.destructive : DSColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DSSpacing.lg)
        }
    }

    @ViewBuilder
    private var gutenbergStatus: some View {
        if let selected, case .gutenberg(let book) = selected.opening, case .failed(let message) = gutenbergLoads[selected.nodeKey] {
            VStack(spacing: DSSpacing.sm) {
                Text(message)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.destructive)
                Button(localized("重試")) { Task { await loadGutenberg(book, key: selected.nodeKey) } }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    private var infoItems: [BookDetailInfoItem] {
        guard let version = selected else { return [] }
        var result = [sourceItem(version)]
        // Not on the page a reader opened: it shows that reader's book only (decision 32).
        if readerContext == nil { result.append(findSourcesItem) }
        result += contributorItems(version)
        if let item = libraryItem(of: version), let format = selectedFormat(of: version) {
            result.append(BookDetailInfoItem(
                id: "format", label: localized("格式"), value: formatLabel(format),
                choice: item.formats.count > 1 ? BookDetailInfoChoice(
                    options: item.formats.map { .init(id: $0.id, title: formatLabel($0)) },
                    selection: Binding(get: { format.id }, set: { id in
                        formatIDs[version.nodeKey] = id
                        actions.clearMessage()
                    })) : nil))
            if let size = format.size, size > 0 {
                result.append(BookDetailInfoItem(id: "size", label: localized("檔案大小"),
                                                 value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
            }
        }
        if case .aozora(let work) = version.opening {
            // 青空文庫's bibliography, which stood under 簡介 until it moved here (2026-10-12).
            let bibliography: [(id: String, label: String, value: String)] = [
                ("subtitle", localized("副標題"), work.subtitle), ("yomi", localized("讀音"), work.yomi),
                ("basis", localized("底本"), work.source), ("publisher", localized("出版社"), work.sourcePublisher),
                ("published", localized("公開日"), work.published), ("kana", localized("文字遣い種別"), work.kanaStyle),
            ]
            result += bibliography.filter { !$0.value.isEmpty }.map {
                BookDetailInfoItem(id: $0.id, label: $0.label, value: $0.value)
            }
        }
        return result
    }

    /// 來源: the version shown, switched in place from its menu when the work has others.
    private func sourceItem(_ version: WorkDetailRoute) -> BookDetailInfoItem {
        guard let choice = versionChoice(version) else {
            return BookDetailInfoItem(id: "source", label: localized("來源"), value: sourceName(of: version))
        }
        return BookDetailInfoItem(
            id: "source", label: localized("來源"), value: sourceName(of: version), detail: localized("換源"),
            choice: choice, accessibilityInputLabels: [localized("換源")])
    }

    /// 「尋找可用來源」 (7b-2): searches the enabled sources for the work when the page opens and
    /// when tapped; what it finds joins 來源.
    private var findSourcesItem: BookDetailInfoItem {
        let value = finder.state.findSourcesValue(added: versions.count - listed.count, versionsLoaded: versionsLoaded,
                                                  hasReadable: WorkVersions.primary(in: versions) != nil)
        var detail: String?
        var action: (() -> Void)? = findSources
        switch finder.state {
        case .idle, .noSources:
            break
        case .searching:
            action = nil
        case .done(let more):
            if more {
                detail = localized("繼續搜索")
                action = { finder.resume() }
            }
        case .failed:
            detail = localized("重試")
        }
        return BookDetailInfoItem(id: "findSources", label: localized("尋找可用來源"), value: value, detail: detail,
                                  action: action, accessibilityHint: action == nil ? nil : localized("點兩下在已啟用的來源配置中搜尋這部作品"))
    }

    /// The work's own page searches once its versions are read: not a reader's page, which shows
    /// that reader's book only, and not a book source's page, whose 換源 searches for itself.
    private var findsOnOpen: Bool {
        guard readerContext == nil, versionsLoaded, let selected else { return false }
        return onlineBook(of: selected) == nil
    }

    private func findSources() { findSources(onOpen: false) }

    private func findSources(onOpen: Bool) {
        // The page stays on the version shown: with nothing listed readable, the first book found
        // would otherwise become the version shown, and the page its source's.
        if chosen == nil { chosen = selected?.nodeKey }
        finder.setPresentationActive(scenePhase == .active)
        if onOpen {
            finder.findOnOpen(route, sources: BookSourceStore.shared.sources)
        } else {
            finder.find(route, sources: BookSourceStore.shared.sources)
        }
    }

    /// The work's versions, `version` selected; nil when it is the only one. A book-source
    /// version's page lists the others in its 換源 sheet.
    private func versionChoice(_ version: WorkDetailRoute) -> BookDetailInfoChoice? {
        guard versions.count > 1 else { return nil }
        return BookDetailInfoChoice(
            options: versions.map { .init(id: $0.nodeKey.pickerID, title: optionTitle($0)) },
            selection: Binding(get: { version.nodeKey.pickerID }, set: { id in
                chosen = versions.first { $0.nodeKey.pickerID == id }?.nodeKey
                actions.clearMessage()
            }))
    }

    private func optionTitle(_ version: WorkDetailRoute) -> String {
        [sourceName(of: version), status(of: version)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What a library item offers besides reading and shelving: 編輯遠端資料, and the library's
    /// record of where the reader is. 下載供離線閱讀, the library's own web page and the note on
    /// what reading and shelving do were taken off on 2026-10-12 (maintainer: this page is where
    /// the book is read, not the library's control panel).
    /// Nothing at all when the item offers none of them, so no empty gap is left in the page.
    @ViewBuilder
    private func libraryActions(_ version: WorkDetailRoute, item: RemoteLibraryItem) -> some View {
        let unsupported = selectedFormat(of: version)?.isSupported != true
        let editable = writeCapabilities.map { $0.canEditMetadata || $0.canMove } ?? false
        let syncedCopy: ReadingBook? = if connections.connection(id: item.connectionID)?.syncProgress == true,
                                          selectedFormat(of: version)?.fileExtension == "epub",
                                          // Not the copy 目錄 made ahead of reading: nothing of it was read.
                                          let copy = libraryCopy, copy.isInBookshelf || copy.lastOpenedDate != nil { copy } else { nil }
        if unsupported || editable || syncedCopy != nil {
            VStack(alignment: .leading, spacing: 0) {
                if unsupported {
                    Label(localized("此格式暫不支援閱讀"), systemImage: "doc.badge.ellipsis")
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textSecondary)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                }
                if editable {
                    WorkDetailActionRow(title: localized("編輯遠端資料"), systemImage: "pencil") { pushed = .editor }
                        .disabled(actions.action != nil)
                }
                if let book = syncedCopy {
                    CalibreProgressStatusView(bookID: book.id, service: dependencies.calibreProgress)
                        .padding(.top, editable || unsupported ? DSSpacing.md : 0)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    /// The description of the version shown (decision 33): a shelf copy's, by `CopyMetadata`
    /// (the reader's own, its file's, then its library's, the item's newest), else the library
    /// item's own, else what the card had.
    private var intro: String? {
        let itemText = selected.flatMap(libraryItem(of:))?.summary
        if let copy = shownCopy {
            return store.copyMetadata(of: copy, sidecar: copySidecar, liveIntro: itemText).intro?.text
        }
        let text = itemText ?? route.summary.blurb
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The shelf copy of the version shown: the copy itself, or a library item's copy.
    private var shownCopy: ReadingBook? {
        guard let selected else { return nil }
        if case .copy(let id) = selected.opening { return copy(id) }
        return shelfCopy(of: selected)
    }

    // MARK: Versions

    private func sourceName(of version: WorkDetailRoute) -> String {
        switch version.opening {
        case .copy(let id): copySourceName(version.record.key, copy: copy(id))
        case .opdsEntry(_, let id), .webDAVFile(_, let id):
            connections.connection(id: id)?.name ?? id
        case .gutenberg: localized("Project Gutenberg")
        case .aozora: localized("青空文庫")
        case .moduleBook(let book): moduleTitle(book.reference.moduleID)
        case .onlineBook(let frozen): frozen.book.sourceName
        case .bibliographic: FilledMetadata.providerName(version.record.key.instance)
        }
    }

    /// Where a copy on the shelf came from: 「書架」 names only a book that is the copy alone
    /// (an imported file), never one taken from a library or a source (maintainer, 2026-10-12).
    private func copySourceName(_ key: SourceItemKey, copy: ReadingBook?) -> String {
        switch key.instance.type {
        case .aozora: localized("青空文庫")
        case .gutenberg: localized("Project Gutenberg")
        case .opds, .calibre, .webDAV: connections.connection(id: key.instance.id)?.name ?? localized("書架")
        case .bookSource:
            copy?.bookSourceId.flatMap { BookSourceStore.shared.source(id: $0)?.bookSourceName }
                .flatMap { $0.isEmpty ? nil : $0 } ?? localized("書架")
        case .module: moduleTitle(key.instance.id)
        case .library, .bibliographic: localized("書架")
        }
    }

    /// A module's title, or 模組 once it was removed.
    private func moduleTitle(_ id: String) -> String {
        RuleModuleLibrary.shared.module(id: id)?.module.title ?? localized("模組")
    }

    private func status(of version: WorkDetailRoute) -> String? {
        if case .copy(let id) = version.opening {
            return copy(id).map(BookshelfAccessibility.readingStatus(for:))
        }
        if case .bibliographic = version.opening { return localized("只有資料") }
        if !version.isReadable { return localized("此格式暫不支援閱讀") }
        return store.copyLookup().status(for: version.record.key)?.title
    }

    private func hasBeenOpened(_ version: WorkDetailRoute) -> Bool {
        if case .copy(let id) = version.opening { return copy(id)?.lastOpenedDate != nil }
        return store.copyLookup().copies(for: version.record.key).contains { $0.lastOpenedDate != nil }
    }

    /// A copy by id, from the shelf's memoized lookup rather than a scan of every record.
    private func copy(_ id: UUID) -> ReadingBook? {
        store.copyLookup().copies(for: .copy(id)).first
    }

    /// The copy 開始閱讀／繼續閱讀 opens for the version shown: its progress is the page's.
    /// A public library's book has one copy, found by the book alone, so a Gutenberg book's
    /// is read without its catalog entry (offline too); another library's is the copy of the
    /// format shown.
    private var readingCopy: ReadingBook? {
        guard let version = selected else { return nil }
        switch version.opening {
        case .copy(let id): return copy(id)
        case .aozora, .moduleBook: return readCopy(of: version.record.key)
        case .gutenberg: return shelfCopy(of: version) ?? libraryCopy
        case .opdsEntry, .webDAVFile: return libraryCopy
        case .onlineBook, .bibliographic: return nil
        }
    }

    /// The copy a reader pushed from this page reads.
    private func readCopyID(_ push: WorkDetailPush) -> UUID? {
        switch push {
        case .reader(let id, _): id
        case .aozoraReader(let work): readCopy(of: SourceRecord.derived(from: work).key)?.id
        case .editor, .author, .work, .series, .aozoraClassification: nil
        }
    }

    /// The copy a version is read from, on the shelf or not: one read without adding stays
    /// off the shelf and is read again (2026-10-13).
    private func readCopy(of key: SourceItemKey) -> ReadingBook? {
        let copies = store.copyLookup().copies(for: key)
        return copies.first(where: \.isInBookshelf) ?? copies.first
    }

    private func shelfCopy(of version: WorkDetailRoute) -> ReadingBook? {
        store.copyLookup().copies(for: version.record.key).first(where: \.isInBookshelf)
    }

    // MARK: Library items

    /// The library item a version reads from: an OPDS entry's or a WebDAV file's from the
    /// version, a Gutenberg book's once its catalog entry is read; an edit replaces either.
    private func libraryItem(of version: WorkDetailRoute) -> RemoteLibraryItem? {
        if let item = items[version.nodeKey] { return item }
        switch version.opening {
        case .opdsEntry(let entry, let connectionID):
            return RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item
        case .webDAVFile(let entry, let connectionID):
            return RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item
        case .copy, .gutenberg, .aozora, .onlineBook, .moduleBook, .bibliographic:
            return nil
        }
    }

    private func selectedFormat(of version: WorkDetailRoute) -> RemoteLibraryFormat? {
        guard let item = libraryItem(of: version) else { return nil }
        if let id = formatIDs[version.nodeKey], let format = item.formats.first(where: { $0.id == id }) { return format }
        // The format of the copy on the shelf, which this version stands for (`WorkVersions.merge`).
        if let copy = shelfCopy(of: version),
           let format = item.formats.first(where: { copy.remoteSource?.matches(item: item, format: $0) == true }) {
            return format
        }
        return RemoteLibraryBrowsePresentation.preferredFormat(in: item)
    }

    /// The copy of the shown library item in the format shown, as its library page had it.
    private var libraryCopy: ReadingBook? {
        guard let version = selected, let item = libraryItem(of: version), let format = selectedFormat(of: version) else {
            return nil
        }
        return dependencies.remoteLibrary.book(for: item, format: format, store: store)
    }

    private var canActOnLibraryItem: Bool {
        guard let version = selected else { return false }
        return selectedFormat(of: version)?.isSupported == true && actions.action == nil
    }

    private func formatLabel(_ format: RemoteLibraryFormat) -> String {
        let name = format.displayName.isEmpty ? String(format.mimeType.prefix(120)) : format.displayName
        return format.isSupported ? name : name + " · " + localized("不支援")
    }

    /// What showing a version needs first: a Gutenberg book's catalog entry, a 青空文庫 work's
    /// catalog for its credits, a library connection's write capabilities.
    private func prepare(_ version: WorkDetailRoute?) async {
        writeCapabilities = nil
        guard let version else { return }
        switch version.opening {
        case .gutenberg(let book):
            if items[version.nodeKey] == nil { await loadGutenberg(book, key: version.nodeKey) }
        case .aozora:
            if aozora.catalog == nil { await aozora.load() }
        case .opdsEntry(_, let connectionID), .webDAVFile(_, let connectionID):
            do {
                writeCapabilities = try await dependencies.remoteLibraryWriting.capabilities(connectionID: connectionID, directoryURL: nil)
            } catch {
                // Reading does not wait on it: 編輯遠端資料 is left out, as the library page did.
                AppLogger.network("Remote library write capabilities failed", error: SourceFailure.loggable(error),
                                  context: ["connection": connectionID])
            }
        case .copy, .onlineBook, .moduleBook, .bibliographic:
            break
        }
    }

    /// Reads a Gutenberg book's catalog entry through the store's own page model, the one
    /// fetch path, and keeps its item for the buttons.
    private func loadGutenberg(_ book: GutenbergBook, key: SourceItemKey) async {
        gutenbergLoads[key] = .loading
        let model = GutenbergBookPageModel(book: book)
        await model.load()
        if let detail = model.detail {
            items[key] = detail.item
            gutenbergAuthors[key] = detail.authors
            gutenbergLoads[key] = nil
        } else if let message = model.errorMessage {
            gutenbergLoads[key] = .failed(message)
        } else {
            // Cancelled with the page: nothing to show.
            gutenbergLoads[key] = nil
        }
    }

    // MARK: Actions

    private func read(_ version: WorkDetailRoute) {
        switch version.opening {
        case .copy(let id):
            openCopy(id)
        case .aozora(let work):
            if let book = readCopy(of: version.record.key) {
                openCopy(book.id)
                return
            }
            pushed = .aozoraReader(work)
        case .gutenberg:
            if let book = shelfCopy(of: version) {
                openCopy(book.id)
                return
            }
            begin(.read)
        case .opdsEntry, .webDAVFile:
            begin(.read)
        case .moduleBook(let book):
            if let copy = readCopy(of: version.record.key) {
                openCopy(copy.id)
                return
            }
            // Its table of contents is read first: the reader opens a copy that has one.
            actions.begin(.read) { [dependencies, store] in
                openCopy(try await dependencies.moduleBooks.readingCopy(book, store: store).id)
                return nil
            }
        case .onlineBook, .bibliographic:
            // Read from the source's own page (see `page`); a bibliographic record has nothing
            // to read.
            break
        }
    }

    private func addAozoraToShelf(_ work: AozoraWork) {
        actions.begin(.addToShelf) { [dependencies, store] in
            _ = try await dependencies.aozoraLibrary.addToShelf(work: work, store: store)
            return localized("已加入書架")
        }
    }

    private func addModuleBookToShelf(_ book: ModuleBook) {
        actions.begin(.addToShelf) { [dependencies, store] in
            _ = try await dependencies.moduleBooks.addToShelf(book, store: store)
            return localized("已加入書架")
        }
    }

    private func openCopy(_ id: UUID) {
        // From a reader, its own book is read in that reader.
        if let readerContext, id == readerContext.bookId {
            readerContext.continueReading(nil)
            return
        }
        pushed = .reader(id)
    }

    /// Reads or shelves the shown library item in the shown format.
    private func begin(_ action: RemoteLibraryActionModel.Action) {
        guard canActOnLibraryItem, let version = selected, let item = libraryItem(of: version),
              let format = selectedFormat(of: version) else { return }
        actions.begin(action, item: item, format: format, service: dependencies.remoteLibrary, store: store,
                      onRead: openCopy)
    }
}

private extension SourceItemKey {
    /// A `Picker` tag for 來源's menu.
    var pickerID: String { "\(instance.type.rawValue)|\(instance.id)|\(item)" }
}

/// One of a library item's further actions on its 作品詳情 (編輯遠端資料).
private struct WorkDetailActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DSFont.body)
                .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

extension WorkSourceFinder.State {
    /// 「尋找可用來源」's value. Before a search, a work with no readable version says so
    /// (AI 推薦 decision 4), once its versions are read: shelf copies arrive after the page opens.
    func findSourcesValue(added: Int, versionsLoaded: Bool, hasReadable: Bool) -> String {
        switch self {
        case .idle:
            versionsLoaded && !hasReadable ? localized("未找到可用來源") : ""
        case .searching:
            localized("搜尋來源配置中…")
        case .done:
            added > 0 ? String(format: localized("找到 %d 個來源"), added) : localized("未找到其他來源配置")
        case .failed:
            localized("搜索失敗")
        case .noSources:
            localized("沒有可用的來源配置，請先啟用來源配置")
        }
    }
}

#Preview("作品詳情") {
    let book = PublicLibraryCollection.chinese.books[0]
    NavigationStack {
        WorkDetailView(route: WorkDetailRoute(.gutenberg(book)))
    }
    .environmentObject(BookStore())
}

#Preview("作品詳情 · AI 推薦") {
    // An AI pick Open Library did not match: data only, its reason under 推薦理由.
    let record = SourceRecord(key: SourceItemKey(instance: AIRecommendationProvider.recordInstance, item: "十二國記"),
                              title: "十二國記", authors: ["小野不由美"], language: nil, contentKind: .text,
                              identifiers: [], copyID: nil, acquisitions: [.viewOnly])
    NavigationStack {
        WorkDetailView(route: WorkDetailRoute(
            record: record,
            summary: WorkSummary(title: "十二國記", authors: ["小野不由美"], cover: .generated(seed: "十二國記"),
                                 blurb: nil, language: nil, contentKind: .text),
            opening: .bibliographic,
            recommendationReason: "你最近讀了不少架空奇幻，這部以十二個國家為舞台的群像小說節奏紮實。"))
    }
    .environmentObject(BookStore())
}

#Preview("作品詳情 · WebDAV") {
    let entry = WebDAVBrowseClient.Entry(url: URL(string: "https://dav.example.com/books/三體.epub")!, name: "三體.epub",
                                         isDirectory: false, size: 1_048_576, etag: nil, lastModified: nil)
    NavigationStack {
        if let route = WorkDetailRoute(webDAV: entry, connectionID: "preview", root: URL(string: "https://dav.example.com/books/")!) {
            WorkDetailView(route: route)
        }
    }
    .environmentObject(BookStore())
}

#Preview("作品詳情 · 尋找可用來源") {
    // The row as 作品資訊 shows it before, during and after its search.
    ScrollView {
        BookDetailInfoSection(items: [
            BookDetailInfoItem(id: "idle", label: localized("尋找可用來源"), value: "", action: {}),
            BookDetailInfoItem(id: "unreadable", label: localized("尋找可用來源"), value: localized("未找到可用來源"),
                               action: {}),
            BookDetailInfoItem(id: "searching", label: localized("尋找可用來源"), value: localized("搜尋來源配置中…")),
            BookDetailInfoItem(id: "found", label: localized("尋找可用來源"),
                               value: String(format: localized("找到 %d 個來源"), 3), action: {}),
            BookDetailInfoItem(id: "paused", label: localized("尋找可用來源"), value: localized("未找到其他來源配置"),
                               detail: localized("繼續搜索"), action: {}),
            BookDetailInfoItem(id: "failed", label: localized("尋找可用來源"), value: localized("搜索失敗"),
                               detail: localized("重試"), action: {}),
        ])
    }
}
