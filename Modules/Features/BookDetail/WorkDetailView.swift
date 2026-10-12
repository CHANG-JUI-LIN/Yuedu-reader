import SwiftUI

/// What 作品詳情 pushes. One item, so the page has one destination (iOS 17 guardrail 12).
private enum WorkDetailPush: Hashable {
    case reader(UUID)
    /// 編輯遠端資料, for the version shown.
    case editor
    /// A public library's author page, from the author's name or 作者其他作品's 查看全部.
    case author(PublicLibraryAuthorDestination)
    /// Another work, from 作者其他作品.
    case work(WorkDetailRoute)
}

/// When 作品詳情 reads its versions: once no action runs, and again when asked.
private struct VersionsLoad: Hashable {
    let idle: Bool
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
    let continueReading: (Int?) -> Void
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
    @EnvironmentObject private var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @StateObject private var actions = RemoteLibraryActionModel()
    @StateObject private var authorWorks = AuthorWorksModel()
    @State private var versions: [WorkDetailRoute]
    @State private var versionsLoaded = false
    /// The version picked from 來源; nil shows the primary one.
    @State private var chosen: SourceItemKey?
    @State private var pushed: WorkDetailPush?
    @State private var introExpanded = false
    /// The sidecar values of the shelf copy shown (`shownCopy`), read once per copy.
    @State private var copySidecar: [MetadataValue] = []
    /// Library items by version that are not in the version itself: a Gutenberg book's from
    /// its catalog entry, and one edited through 編輯遠端資料 as saved.
    @State private var items: [SourceItemKey: RemoteLibraryItem] = [:]
    @State private var gutenbergLoads: [SourceItemKey: GutenbergLoad] = [:]
    /// A Gutenberg book's authors from its catalog entry, by version.
    @State private var gutenbergAuthors: [SourceItemKey: [GutenbergAuthor]] = [:]
    /// The format picked per version; absent, the preferred one.
    @State private var formatIDs: [SourceItemKey: String] = [:]
    /// Whether the shown copy's offline file exists, checked when the copy or its file changes
    /// rather than on every body evaluation.
    @State private var offlineFileExists = false
    @State private var writeCapabilities: RemoteLibraryWriteCapabilities?

    /// Bumped when a book-source version's page takes its book off the shelf, so the versions
    /// are read again without the copy.
    @State private var versionsRevision = 0

    init(route: WorkDetailRoute, onRemoveFromShelf: (() -> Void)? = nil, readerContext: WorkDetailReaderContext? = nil) {
        self.route = route
        self.onRemoveFromShelf = onRemoveFromShelf
        self.readerContext = readerContext
        _versions = State(initialValue: [route])
        if readerContext != nil { _chosen = State(initialValue: route.nodeKey) }
    }

    private var selected: WorkDetailRoute? { WorkVersions.selected(in: versions, chosen: chosen) }
    private var author: String { route.summary.authors.joined(separator: "、") }

    var body: some View {
        page
            .task(id: VersionsLoad(idle: actions.action == nil, revision: versionsRevision)) {
                // Again after each action: a book added to the shelf is a version of its own.
                guard actions.action == nil else { return }
                guard readerContext == nil else {
                    versionsLoaded = true
                    return
                }
                versions = await ShelfProvider(store: store).versions(of: route)
                versionsLoaded = true
                // A book-source page keeps its place once shown: the copy its 加入書架 makes would
                // otherwise come first and take the page from under its reader.
                if chosen == nil, let shown = selected, onlineBook(of: shown) != nil { chosen = shown.nodeKey }
            }
            .task(id: selected?.nodeKey) { await prepare(selected) }
            .task(id: shownCopy?.id) { copySidecar = shownCopy.map(store.copyIntroValues(of:)) ?? [] }
            .task(id: offlineProbe) {
                offlineFileExists = libraryCopy.map { dependencies.remoteLibrary.hasOfflineCopy($0) } ?? false
            }
            .task(id: authorWorksRequest) { await authorWorks.load(authorWorksRequest, store: store) }
            .onDisappear { actions.cancelForDisappearance() }
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
                           onContinueReading: readerContext.continueReading)
                .environmentObject(store)
                // The reader's own navigator, unlike the other branch: its detail returns to it.
                .id(version.nodeKey)
        } else if let version = selected, let book = onlineBook(of: version) {
            OnlineBookDetailDestination(
                .book(book),
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
                           authorActions: authorLinks,
                           progress: readingCopy?.currentPosition,
                           facts: selected.map { BookDetailFacts(text: sourceName(of: $0)) })
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
                if let intro {
                    // Never a book source's own description: a book-source version draws its
                    // own page. Legado's formats are not read here (decision 33).
                    BookDetailIntroSection(text: intro, isExpanded: $introExpanded, readsSourceFormats: false)
                }
                if let selected, case .aozora(let work) = selected.opening {
                    aozoraDetails(work)
                }
                BookDetailInfoSection(items: infoItems)
                BookDetailAuthorWorksSection(
                    state: authorWorks.state,
                    onShowAll: authorWorksRequest?.authorPage.map { page in { pushed = .author(page) } },
                    onSelect: { pushed = .work($0) },
                    onRetry: { Task { await authorWorks.retry(authorWorksRequest, store: store) } }
                )
            }
        }
        .navigationDestination(item: $pushed) { push in
            switch push {
            case .reader(let id):
                // Pushed by this page on whichever stack it is on, as every detail page pushes
                // its reader. Never the shelf's UIKit card driver: closing onto a pushed page,
                // it left iOS 17's navigation bar off screen.
                BookReaderView(bookId: id).environmentObject(store)
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
            }
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
            return work.credits.compactMap { credit in
                guard let person = index.personsByID[credit.person] else { return nil }
                return BookDetailAuthorAction(id: person.id + credit.role, name: person.name,
                                              action: { pushed = .author(.aozora(person, index)) })
            }
        case .gutenberg:
            return (gutenbergAuthors[selected.nodeKey] ?? []).map { author in
                BookDetailAuthorAction(id: author.id, name: author.name, action: { pushed = .author(.gutenberg(author)) })
            }
        case .copy, .opdsEntry, .webDAVFile, .onlineBook:
            return []
        }
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
            return gutenbergAuthors[selected.nodeKey]?.first.map { .gutenberg($0, excluding: book) }
        case .copy, .opdsEntry, .webDAVFile:
            return .shelf(versions: versions)
        case .onlineBook:
            return nil
        }
    }

    /// The book a book-source version's page shows: the found one's frozen card, or an
    /// online shelf copy as the reader opens it.
    private func onlineBook(of version: WorkDetailRoute) -> OnlineBook? {
        switch version.opening {
        case .onlineBook(let frozen): frozen.book
        case .copy(let id): copy(id).flatMap(OnlineBook.init(shelfCopy:))
        case .opdsEntry, .webDAVFile, .gutenberg, .aozora: nil
        }
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
        case .onlineBook:
            // Drawn by the source's own page instead (see `page`).
            return BookDetailAction(title: localized("開始閱讀"), systemImage: "book", isEnabled: false, action: {})
        case .opdsEntry, .webDAVFile, .gutenberg:
            return BookDetailAction(title: localized(libraryCopy?.lastOpenedDate == nil ? "開始閱讀" : "繼續閱讀"),
                                    systemImage: "book",
                                    isBusy: actions.action == .read || gutenbergLoads[version.nodeKey]?.isLoading == true,
                                    isEnabled: canActOnLibraryItem, action: { begin(.read) })
        case .copy, .aozora:
            return BookDetailAction(title: localized(hasBeenOpened(version) ? "繼續閱讀" : "開始閱讀"), systemImage: "book",
                                    isBusy: actions.action == .read, isEnabled: actions.action == nil,
                                    action: { read(version) })
        }
    }

    /// 加入書架 for the version shown; 已加入書架 once its copy is on the shelf.
    private var secondaryAction: BookDetailAction? {
        guard let version = selected else { return nil }
        let added = BookDetailAction(title: localized("已加入書架"), systemImage: "checkmark", isEnabled: false, action: {})
        switch version.opening {
        case .copy(let id):
            return copy(id)?.isInBookshelf == true ? added : nil
        case .onlineBook:
            return nil
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
            result.append(BookDetailInfoItem(id: "published", label: localized("公開日"), value: work.published))
            result.append(BookDetailInfoItem(id: "kana", label: localized("文字遣い種別"), value: work.kanaStyle))
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

    /// 下載供離線閱讀, 編輯遠端資料 and the library's own page: what a library item offers
    /// besides reading and shelving.
    private func libraryActions(_ version: WorkDetailRoute, item: RemoteLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedFormat(of: version)?.isSupported != true {
                Label(localized("此格式暫不支援閱讀"), systemImage: "doc.badge.ellipsis")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(minHeight: DSLayout.minimumTapTarget)
            }
            let isOffline = libraryCopy != nil && offlineFileExists
            WorkDetailActionRow(title: localized(isOffline ? "已下載" : "下載供離線閱讀"),
                                systemImage: isOffline ? "checkmark.circle" : "arrow.down.circle") { begin(.download) }
                .disabled(!canActOnLibraryItem || isOffline)
            if let capabilities = writeCapabilities, capabilities.canEditMetadata || capabilities.canMove {
                Divider()
                WorkDetailActionRow(title: localized("編輯遠端資料"), systemImage: "pencil") { pushed = .editor }
                    .disabled(actions.action != nil)
            }
            if let url = item.alternateURL {
                Divider()
                Link(destination: url) {
                    Label(localized("在書庫網站查看"), systemImage: "safari")
                        .font(DSFont.body)
                        .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
                }
            }
            Text(localized("閱讀不會自動加入書架；加入書架不會下載整本書。"))
                .dsSectionFooter()
                .padding(.top, DSSpacing.xs)
            if let connection = connections.connection(id: item.connectionID), connection.syncProgress,
               let book = libraryCopy, selectedFormat(of: version)?.fileExtension == "epub" {
                CalibreProgressStatusView(bookID: book.id, service: dependencies.calibreProgress)
                    .padding(.top, DSSpacing.md)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
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

    @ViewBuilder
    private func aozoraDetails(_ work: AozoraWork) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            if !work.yomi.isEmpty { Text(work.yomi).font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary) }
            if let index = aozora.catalog {
                ForEach(Array(work.credits.enumerated()), id: \.offset) { _, credit in
                    if let person = index.personsByID[credit.person] {
                        ThemedLabeledContent(localized(credit.role), value: person.name)
                    }
                }
            }
            if !work.subtitle.isEmpty { Text(work.subtitle).font(DSFont.body).foregroundStyle(DSColor.textPrimary) }
            if !work.source.isEmpty { ThemedLabeledContent(localized("底本"), value: work.source) }
            if !work.sourcePublisher.isEmpty { ThemedLabeledContent(localized("出版社"), value: work.sourcePublisher) }
            if let url = URL(string: work.card), url.scheme == "https", url.host == "www.aozora.gr.jp" {
                Link(localized("在青空文庫網站查看"), destination: url)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    // MARK: Versions

    private func sourceName(of version: WorkDetailRoute) -> String {
        switch version.opening {
        case .copy: localized("書架")
        case .opdsEntry(_, let id), .webDAVFile(_, let id):
            connections.connection(id: id)?.name ?? id
        case .gutenberg: localized("Project Gutenberg")
        case .aozora: localized("青空文庫")
        case .onlineBook(let frozen): frozen.book.sourceName
        }
    }

    private func status(of version: WorkDetailRoute) -> String? {
        if case .copy(let id) = version.opening {
            return copy(id).map(BookshelfAccessibility.readingStatus(for:))
        }
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
    private var readingCopy: ReadingBook? {
        guard let version = selected else { return nil }
        switch version.opening {
        case .copy(let id): return copy(id)
        case .aozora: return shelfCopy(of: version)
        case .opdsEntry, .webDAVFile, .gutenberg: return libraryCopy
        case .onlineBook: return nil
        }
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
        case .copy, .gutenberg, .aozora, .onlineBook:
            return nil
        }
    }

    private func selectedFormat(of version: WorkDetailRoute) -> RemoteLibraryFormat? {
        guard let item = libraryItem(of: version) else { return nil }
        if let id = formatIDs[version.nodeKey], let format = item.formats.first(where: { $0.id == id }) { return format }
        return RemoteLibraryBrowsePresentation.preferredFormat(in: item)
    }

    /// The copy of the shown library item in the format shown, as its library page had it.
    private var libraryCopy: ReadingBook? {
        guard let version = selected, let item = libraryItem(of: version), let format = selectedFormat(of: version) else {
            return nil
        }
        return dependencies.remoteLibrary.book(for: item, format: format, store: store)
    }

    private var offlineProbe: String {
        "\(libraryCopy?.id.uuidString ?? "")|\(libraryCopy?.remoteSource?.offlineFilename ?? "")"
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
        case .copy, .onlineBook:
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
            if let book = shelfCopy(of: version) {
                openCopy(book.id)
                return
            }
            actions.begin(.read) { [dependencies, store] in
                let book = try await dependencies.aozoraLibrary.addToShelf(work: work, store: store)
                try Task.checkCancellation()
                openCopy(book.id)
                return nil
            }
        case .opdsEntry, .webDAVFile, .gutenberg:
            begin(.read)
        case .onlineBook:
            // Read from the source's own page (see `page`).
            break
        }
    }

    private func addAozoraToShelf(_ work: AozoraWork) {
        actions.begin(.addToShelf) { [dependencies, store] in
            _ = try await dependencies.aozoraLibrary.addToShelf(work: work, store: store)
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

    /// Reads, shelves or downloads the shown library item in the shown format.
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

/// One of a library item's further actions under the information strip.
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

#Preview("作品詳情") {
    let book = PublicLibraryCollection.chinese.books[0]
    NavigationStack {
        WorkDetailView(route: WorkDetailRoute(.gutenberg(book)))
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
