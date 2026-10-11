import SwiftUI

/// What 作品詳情 needs from the stack it is pushed on.
struct WorkDetailHost {
    /// The bookshelf's reader coordinator, for a book source's page; nil elsewhere.
    var readerNavigator: ReaderNavigationCoordinator? = nil
}

/// What 作品詳情 pushes: a version's own page, or the reader. One item, so the page has one
/// destination (iOS 17 guardrail 12).
private enum WorkDetailPush: Hashable {
    case source(WorkDetailRoute)
    case reader(UUID)
}

/// 作品詳情 (unified library 5f, design §14.1): the page every Explore card opens first, as
/// Emby's posters open the item's page (Phase 5 plan, decision 27), and the bookshelf's •••
/// opens for a copy. The main button reads the first version that can be read; 可用來源 lists
/// every version this device knows, each opening its own source's page.
///
/// Each version acts through what its source's own page already uses: a library item through
/// `RemoteLibraryActionModel`, a Gutenberg book through its catalog entry
/// (`GutenbergBookPageModel`) and the same model, a 青空文庫 work through
/// `AozoraLibraryDownloading`. A book-source result opens its own page: its reader is tied to
/// that page's chapter list.
struct WorkDetailView: View {
    let route: WorkDetailRoute
    let host: WorkDetailHost
    @EnvironmentObject private var store: BookStore
    @Environment(\.appDependencies) private var dependencies
    @StateObject private var actions = RemoteLibraryActionModel()
    @State private var versions: [WorkDetailRoute]
    @State private var versionsLoaded = false
    @State private var pushed: WorkDetailPush?
    @State private var introExpanded = false
    /// Gutenberg books whose catalog entry has been read, by book id.
    @State private var gutenbergItems: [String: RemoteLibraryItem] = [:]

    init(route: WorkDetailRoute, host: WorkDetailHost) {
        self.route = route
        self.host = host
        _versions = State(initialValue: [route])
    }

    private var primaryVersion: WorkDetailRoute? { WorkVersions.primary(in: versions) }
    private var shelfCopy: ReadingBook? {
        versions.lazy.compactMap { version -> ReadingBook? in
            guard case .copy(let id) = version.opening else { return nil }
            return copy(id).flatMap { $0.isInBookshelf ? $0 : nil }
        }.first
    }

    /// A copy by id, from the shelf's memoized lookup rather than a scan of every record.
    private func copy(_ id: UUID) -> ReadingBook? {
        store.copyLookup().copies(for: .copy(id)).first
    }
    private var author: String { route.summary.authors.joined(separator: "、") }

    var body: some View {
        BookDetailScaffold(title: route.summary.title, compactAction: primaryAction) {
            BookDetailHero(artworkShape: route.record.contentKind == .audio ? .square : .book,
                           cover: cover, title: route.summary.title, author: author,
                           meta: sourceName(of: route), primary: primaryAction, secondary: secondaryAction)
        } content: {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                status
                if versionsLoaded, primaryVersion == nil {
                    ContentUnavailableView {
                        UnavailableLabel(localized("目前沒有可閱讀的來源"), systemImage: "book.closed")
                    }
                }
                if let blurb = route.summary.blurb {
                    BookDetailIntroSection(text: blurb, isExpanded: $introExpanded)
                }
                versionList
            }
        }
        .navigationDestination(item: $pushed) { push in
            switch push {
            case .source(let version):
                WorkSourcePage(version: version, readerNavigator: host.readerNavigator)
                    .environmentObject(store)
            case .reader(let id):
                // Pushed by this page on whichever stack it is on, as every detail page pushes
                // its reader. Never the shelf's UIKit card driver: closing onto a pushed page,
                // it left iOS 17's navigation bar off screen.
                BookReaderView(bookId: id).environmentObject(store)
                    .environment(\.readerNavigator, nil)
                    .environment(\.readerUsesParentNavigationStack, true)
                    .navigationBarBackButtonHidden(true)
                    .reservingNavigationBackSwipe()
            }
        }
        .task(id: actions.action == nil) {
            // Again after each action: a book added to the shelf is a version of its own.
            guard actions.action == nil else { return }
            versions = await ShelfProvider(store: store).versions(of: route)
            versionsLoaded = true
        }
        .onDisappear { actions.cancelForDisappearance() }
    }

    // MARK: Hero

    private var cover: some View {
        let content: HomeCardContent.Cover = if case .copy(let id) = route.opening, let book = copy(id) {
            .shelf(book)
        } else {
            .reference(route.summary.cover, session: HomeCardContent.session(for: route.opening, connections: .shared))
        }
        return HomeCoverArtwork(cover: content, title: route.summary.title, author: author,
                                size: CGSize(width: DSLayout.bookCoverHeroWidth, height: DSLayout.bookCoverHeroHeight))
    }

    private var primaryAction: BookDetailAction {
        guard let version = primaryVersion else {
            return BookDetailAction(title: localized("開始閱讀"), systemImage: "book", isEnabled: false, action: {})
        }
        if case .onlineBook = version.opening {
            return BookDetailAction(title: localized("查看來源詳情"), systemImage: "book",
                                    isEnabled: actions.action == nil, action: { pushed = .source(version) })
        }
        return BookDetailAction(title: localized(hasBeenOpened(version) ? "繼續閱讀" : "開始閱讀"), systemImage: "book",
                                isBusy: actions.action == .read, isEnabled: actions.action == nil,
                                action: { read(version) })
    }

    /// 加入書架 for the version the main button reads; 已加入書架 once a copy is on the shelf.
    private var secondaryAction: BookDetailAction? {
        if shelfCopy != nil {
            return BookDetailAction(title: localized("已加入書架"), systemImage: "checkmark.circle", isEnabled: false, action: {})
        }
        guard let version = primaryVersion else { return nil }
        switch version.opening {
        case .copy, .onlineBook:
            return nil
        case .opdsEntry, .webDAVFile, .gutenberg, .aozora:
            return BookDetailAction(title: localized("加入書架"), systemImage: "plus",
                                    isBusy: actions.action == .addToShelf, isEnabled: actions.action == nil,
                                    action: { addToShelf(version) })
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

    private var versionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookDetailSectionHeader(title: localized("可用來源"))
                .accessibilityIdentifier("work.versions")
            ForEach(versions, id: \.nodeKey) { version in
                WorkVersionRow(name: sourceName(of: version), status: status(of: version),
                               opensReader: version.opening.isCopy) {
                    if case .copy(let id) = version.opening { openCopy(id) } else { pushed = .source(version) }
                }
                .disabled(actions.action != nil)
                .accessibilityIdentifier(version.opening.isCopy ? "work.version.shelf"
                                         : "work.version.\(version.record.key.instance.type.rawValue)")
            }
            if !versionsLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, DSSpacing.md)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    private func sourceName(of version: WorkDetailRoute) -> String {
        switch version.opening {
        case .copy: localized("書架")
        case .opdsEntry(_, let id), .webDAVFile(_, let id):
            RemoteLibraryConnectionStore.shared.connection(id: id)?.name ?? id
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

    // MARK: Actions

    private func read(_ version: WorkDetailRoute) {
        switch version.opening {
        case .copy(let id):
            openCopy(id)
        case .opdsEntry(let entry, let connectionID):
            begin(.read, item: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)
        case .webDAVFile(let entry, let connectionID):
            begin(.read, item: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)
        case .gutenberg(let book):
            beginGutenberg(.read, book: book)
        case .aozora(let work):
            actions.begin(.read) { [dependencies, store] in
                let book = try await dependencies.aozoraLibrary.addToShelf(work: work, store: store)
                try Task.checkCancellation()
                openCopy(book.id)
                return nil
            }
        case .onlineBook:
            pushed = .source(version)
        }
    }

    private func addToShelf(_ version: WorkDetailRoute) {
        switch version.opening {
        case .opdsEntry(let entry, let connectionID):
            begin(.addToShelf, item: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)
        case .webDAVFile(let entry, let connectionID):
            begin(.addToShelf, item: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)
        case .gutenberg(let book):
            beginGutenberg(.addToShelf, book: book)
        case .aozora(let work):
            actions.begin(.addToShelf) { [dependencies, store] in
                _ = try await dependencies.aozoraLibrary.addToShelf(work: work, store: store)
                return localized("已加入書架")
            }
        case .copy, .onlineBook:
            break
        }
    }

    private func openCopy(_ id: UUID) {
        pushed = .reader(id)
    }

    private func begin(_ action: RemoteLibraryActionModel.Action, item: RemoteLibraryItem) {
        guard let format = RemoteLibraryBrowsePresentation.preferredFormat(in: item), format.isSupported else { return }
        actions.begin(action, item: item, format: format, service: dependencies.remoteLibrary, store: store,
                      onRead: openCopy)
    }

    /// A Gutenberg book's formats are in its catalog entry, read on the first action through
    /// the store's own page model (one fetch path), then acted on as a library item.
    private func beginGutenberg(_ action: RemoteLibraryActionModel.Action, book: GutenbergBook) {
        let known = gutenbergItems[book.id]
        actions.begin(action) { [dependencies, store] in
            let item: RemoteLibraryItem
            if let known {
                item = known
            } else {
                let model = GutenbergBookPageModel(book: book)
                await model.load()
                try Task.checkCancellation()
                guard let detail = model.detail else {
                    throw SourceFailure.Message(text: model.errorMessage ?? localized("此格式暫不支援閱讀"))
                }
                item = detail.item
                gutenbergItems[book.id] = item
            }
            guard let format = RemoteLibraryBrowsePresentation.preferredFormat(in: item), format.isSupported else {
                throw SourceFailure.Message(text: localized("此格式暫不支援閱讀"))
            }
            switch action {
            case .read:
                let copy = try await dependencies.remoteLibrary.read(item: item, format: format, store: store)
                try Task.checkCancellation()
                openCopy(copy.id)
                return nil
            case .addToShelf:
                _ = try dependencies.remoteLibrary.addToShelf(item: item, format: format, store: store)
                return localized("已加入書架")
            case .download:
                _ = try await dependencies.remoteLibrary.downloadOffline(item: item, format: format, store: store)
                return localized("下載完成")
            }
        }
    }
}

private extension ItemOpening {
    var isCopy: Bool { if case .copy = self { true } else { false } }
}

/// One version in 可用來源: its source and how far this device has it. A shelf copy opens the
/// reader; any other version opens its source's own page.
private struct WorkVersionRow: View {
    let name: String
    let status: String?
    let opensReader: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(name)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1)
                    if let status {
                        Text(status)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DSSpacing.sm)
                Image(systemName: opensReader ? "book" : "chevron.right")
                    .font(DSFont.caption.weight(.semibold))
                    .foregroundStyle(opensReader ? DSColor.accent : DSColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, DSSpacing.md)
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(status ?? "")
        .accessibilityHint(localized(opensReader ? "開啟" : "查看來源詳情"))
    }
}

/// A version's own page, pushed from 作品詳情: the page its source opens it on elsewhere.
private struct WorkSourcePage: View {
    let version: WorkDetailRoute
    let readerNavigator: ReaderNavigationCoordinator?
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    var body: some View {
        switch version.opening {
        case .opdsEntry(let entry, let connectionID):
            RemoteLibraryBookDetailView(item: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)
        case .webDAVFile(let entry, let connectionID):
            RemoteLibraryBookDetailView(item: RemoteLibraryBookRoute(entry: entry, connectionID: connectionID).item)
        case .gutenberg(let book):
            GutenbergSourcePage(book: book)
        case .aozora(let work):
            if let index = aozora.catalog {
                AozoraWorkDetailView(work: work, index: index)
            } else {
                ProgressView(localized("正在載入書庫")).task { await aozora.load() }
            }
        case .onlineBook(let frozen):
            OnlineBookDetailDestination(.book(frozen.book), textPageReaderNavigator: readerNavigator)
        case .copy:
            // A copy opens the reader instead (`WorkVersionRow`).
            EmptyView()
        }
    }
}

/// A Gutenberg book's library page, pushed rather than shown in the store's card: the card's
/// page (`storefront`) reads and opens authors through the card, which is not there.
private struct GutenbergSourcePage: View {
    @StateObject private var model: GutenbergBookPageModel

    init(book: GutenbergBook) {
        _model = StateObject(wrappedValue: GutenbergBookPageModel(book: book))
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                RemoteLibraryBookDetailView(item: detail.item)
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    UnavailableLabel(localized("Project Gutenberg"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(localized("重試")) { Task { await model.load(force: true) } }
                }
            } else {
                ProgressView(localized("正在載入書庫"))
            }
        }
        .task { await model.load() }
    }
}

#Preview("作品詳情") {
    let book = PublicLibraryCollection.chinese.books[0]
    NavigationStack {
        WorkDetailView(route: WorkDetailRoute(.gutenberg(book)), host: WorkDetailHost())
    }
    .environmentObject(BookStore())
}
