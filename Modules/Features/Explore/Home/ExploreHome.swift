import SwiftUI

/// 探索's root since unified library 5c-3 (design §13.3): the reader's sections, in their order,
/// across every source — Emby's model under Apple Books' covers (Phase 5 plan, settled
/// decision 11). 範圍 narrows it to one source, whose own page then shows in place.
///
/// - One stack for everything the home opens (decision 5): Explore's routes, the libraries'
///   feeds, folders and books, the store's pages, and the store's card carousel over it all.
/// - The page is read once the book-source library is read (`ExploreTabRoot` waits for
///   that), and the defaults are saved then, for good (`HomePageStore.pageOrDefaults`).
/// - Rows are built again when the page, the sources, the connections, the custom pages or
///   the region change. Rows read from this device load again when the home comes back into
///   view, never on a shelf change: a page turn is one.
/// - The search field narrows 我的書庫's book sources, as 探索's did; books are searched from
///   the 搜索 tab.
struct ExploreHome: View {
    @ObservedObject var browser: BrowserState
    @EnvironmentObject private var store: BookStore

    var body: some View {
        // The store is handed down, not observed: every reading-position save publishes it.
        ExploreHomeRoot(store: store, browser: browser)
    }
}

private struct ExploreHomeRoot: View {
    let store: BookStore
    @ObservedObject var browser: BrowserState

    @StateObject private var model: HomeModel
    @ObservedObject private var pageStore = HomePageStore.shared
    @ObservedObject private var customPages = CustomExplorePageStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var tabModel = ExploreTabModel.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @AppStorage(ExploreSettings.scopeKey) private var storedScope = ExploreScope.all.rawValue
    @AppStorage(ExploreSettings.modeKey) private var storedMode = ExploreMode.publicLibraries.rawValue
    @AppStorage(ExploreSettings.landingKey) private var landing = ExploreLanding.off.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path = NavigationPath()
    @State private var selection: PublicLibraryBookSelection?
    @State private var coverFrames = PublicLibraryCoverFrames()
    @State private var query = ""
    @State private var group: String?
    @State private var exploreSources: [BookSource] = []
    @State private var sourceActionSheet: BookSourceActionSheet?
    @State private var sourcePendingDeletion: BookSource?
    @State private var browserPresentation: BrowserPresentation?
    @State private var showsSettings = false
    @State private var pagePrompt: CustomExplorePagePrompt?
    /// 首屏配置 opens its page once, the first time 探索 shows; going back stays here.
    @State private var appliedLanding = false

    private struct BrowserPresentation: Identifiable {
        let id = UUID()
        let entry: BrowserEntry
    }

    init(store: BookStore, browser: BrowserState) {
        self.store = store
        self.browser = browser
        _model = StateObject(wrappedValue: HomeModel(
            providers: { SourceProviderRegistry.shared.homeProviders(shelf: store) },
            customPages: { CustomExplorePageStore.shared.pages },
            waitForSources: { await BookSourceStore.shared.waitUntilLoaded() }))
    }

    // MARK: State

    private var mode: ExploreMode {
        ExploreMode.effective(stored: .storedValue(storedMode, hasImportedSources: tabModel.hasSources),
                              hasImportedSources: tabModel.hasSources, librariesAvailable: availability.isAvailable)
    }


    /// The stored scope while its source is still there; 全部 otherwise.
    private var scope: ExploreScope {
        let stored = ExploreScope(rawValue: storedScope)
        guard case .source(let key) = stored else { return .all }
        return ExploreHomeScope.isAvailable(key, sources: sourceStore.enabledSources, connections: connections,
                                            librariesAvailable: availability.isAvailable) ? stored : .all
    }

    /// What the rows are built from; any change builds them again.
    private var syncKey: [AnyHashable] {
        [pageStore.page, customPages.pages.map(\.id), customPages.pages.map(\.name), connections.catalogs.map(\.id),
         exploreSources.map(\.bookSourceUrl), availability.isAvailable, aozora.catalog != nil]
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [String] {
        Array(Set(exploreSources.flatMap { ExploreHomeView.groupNames(of: $0) })).sorted()
    }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch scope {
                case .all:
                    home
                case .source(let key):
                    scopePage(key)
                        .id(key)
                        .showsRootTabBarOnlyHere()
                }
            }
            .toolbar { toolbar }
            .sheet(isPresented: $showsSettings) {
                ExploreSettingsSheet(sources: exploreSources)
            }
            .customExplorePagePrompts($pagePrompt)
            .bookSourceActionSheets(sheet: $sourceActionSheet, pendingDeletion: $sourcePendingDeletion)
            .fullScreenCover(item: $browserPresentation) { presentation in
                NavigationStack {
                    BrowserPage(browser: browser, entry: presentation.entry)
                }
                .environmentObject(store)
            }
            .exploreRouteDestinations(openBrowser: openBrowser)
            .remoteLibraryDestinations()
            .publicLibraryDestinations()
        }
        .publicLibraryBookCarousel(path: $path, request: $selection, coverFrames: coverFrames)
        .task(id: syncKey) {
            // Saved here, not while drawing: the first read saves the defaults.
            await model.sync(with: pageStore.pageOrDefaults(mode: mode, publicLibrariesAvailable: availability.isAvailable))
        }
        .task { await aozora.load() }
        .onAppear {
            model.reloadLocal()
            applyLandingIfNeeded()
        }
        .onReceive(sourceStore.sourcesPublisher) { _ in
            exploreSources = DiscoverViewModel.exploreSources(in: sourceStore)
            if let group, !groups.contains(group) { self.group = nil }
            applyLandingIfNeeded()
        }
        .onChange(of: storedScope) { _, _ in
            // Another source's page in place: what was pushed over the last one goes.
            path = NavigationPath()
        }
    }

    // MARK: 全部

    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                if trimmedQuery.isEmpty {
                    ForEach(model.items) { item in
                        switch item {
                        case .tiles(_, let tiles):
                            libraryTiles(tiles)
                        case .row(let row):
                            HomeRowHost(row: row, store: store, aozoraIndex: aozora.catalog, model: model,
                                        push: push, select: { selection = $0 })
                        }
                    }
                } else {
                    let found = libraryTilesMatching(query: trimmedQuery)
                    if !found.isEmpty { libraryTiles(found) }
                }
            }
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rootTabTitleScrollAnchor()
        }
        .overlay {
            if !model.isReady {
                ProgressView()
            } else if !trimmedQuery.isEmpty, libraryTilesMatching(query: trimmedQuery).isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
        .refreshable { model.reload() }
        .rootTabSearchScrollEdges()
        .scrollDismissesKeyboard(.immediately)
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
        .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: localized("搜索來源配置"))
        .animation(reduceMotion ? nil : DSAnimation.standard, value: model.items.map(\.id))
    }

    /// 我的書庫's tiles, its book sources narrowed to the 分組 picked.
    private func libraryTiles(_ tiles: [HomeModel.Tile]) -> some View {
        let shown = group.map { group in
            tiles.filter { tile in
                guard case .source(let key, _) = tile, key.type == .bookSource else { return true }
                return sourceByURL[key.id].map { ExploreHomeView.groupNames(of: $0).contains(group) } ?? false
            }
        } ?? tiles
        return HomeLibraryTiles(tiles: shown, open: open) { tile in
            switch tile {
            case .customPage(let id, _):
                if let page = customPages.page(id: id) {
                    CustomExplorePageMenuItems(page: page, prompt: $pagePrompt)
                }
            case .source(let key, _) where key.type == .bookSource:
                if let source = sourceByURL[key.id] { sourceActions(source) }
            default:
                EmptyView()
            }
        }
    }

    /// The book-source tiles whose name or group holds `query`, Legado's explore search.
    private func libraryTilesMatching(query: String) -> [HomeModel.Tile] {
        ExploreHomeView.sources(exploreSources, inGroup: group, matching: query).map {
            .source(SourceInstanceKey(type: .bookSource, id: $0.bookSourceUrl), name: $0.bookSourceName)
        }
    }

    private var sourceByURL: [String: BookSource] {
        Dictionary(exploreSources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: One source

    /// The page a 我的書庫 tile pushes, shown at the root.
    @ViewBuilder
    private func scopePage(_ key: SourceInstanceKey) -> some View {
        if let place = ExplorePlace.page(of: key, name: ExploreHomeScope.name(of: key, sources: sourceStore.sources,
                                                                             connections: connections)) {
            placePage(place)
        }
    }

    @ViewBuilder
    private func placePage(_ place: ExplorePush) -> some View {
        switch place {
        case .explore(.source(let sourceURL)):
            if let source = sourceStore.sources.first(where: { $0.bookSourceUrl == sourceURL }) {
                ExploreSourcePage(source: source) { address in openBrowser(.open(address)) }
            }
        case .feed(let route):
            OPDSFeedView(route: route)
        case .folder(let route):
            WebDAVDirectoryView(route: route)
        case .publicLibrary(.gutenbergHome):
            GutenbergHomePage()
        case .publicLibrary(.aozoraHome):
            AozoraHomePage()
        default:
            EmptyView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ExploreScopeMenu(scope: Binding(get: { scope }, set: { storedScope = $0.rawValue }),
                             connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                             sources: exploreSources)
        }
        if scope == .all {
            if groups.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { groupMenu }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { pagePrompt = .create } label: {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("新增自訂頁"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("探索設定"))
            }
        }
    }

    /// Legado's explore page narrows its list to one group from its menu.
    private var groupMenu: some View {
        Menu {
            Picker(localized("分組"), selection: $group) {
                Text(localized("全部")).tag(String?.none)
                ForEach(groups, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
        } label: {
            Image(systemName: group == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("分組"))
        .accessibilityValue(group ?? localized("全部"))
    }

    /// Legado's long-press actions on an explore source. 刷新 lives on the source's own
    /// page, where pulling down reloads it.
    private func sourceActions(_ source: BookSource) -> some View {
        BookSourceActionMenuItems(
            source: source,
            onEdit: { sourceActionSheet = .edit(source) },
            onPinToTop: {
                BookSourceStore.shared.pinToTop(id: source.id)
                UIAccessibility.post(notification: .announcement, argument: localized("已置頂"))
            },
            onLogin: { sourceActionSheet = .login(source) },
            onSearch: { path.append(ExploreNavigationRoute.searchInSource(sourceURL: source.bookSourceUrl)) },
            onRefresh: nil,
            onSetVariable: { sourceActionSheet = .variable(source) },
            onDelete: { sourcePendingDeletion = source }
        )
    }

    // MARK: Opening

    private func open(_ tile: HomeModel.Tile) {
        switch tile {
        case .browser:
            openBrowser(.resume)
        case .customPage(let id, _):
            path.append(ExploreNavigationRoute.customPage(id: id))
        case .source(let key, let name):
            ExplorePlace.page(of: key, name: name, connections: connections).map(push)
        }
    }

    private func push(_ push: ExplorePush) {
        push.append(to: &path)
    }

    private func openBrowser(_ entry: BrowserEntry) {
        browserPresentation = BrowserPresentation(entry: entry)
    }

    /// 首屏配置: the page 探索 opens straight onto, pushed the first time 探索 shows, as the old
    /// root did. A source's page waits for the sources, so it never opens on one that only
    /// looks deleted because the list was not there yet.
    private func applyLandingIfNeeded() {
        guard !appliedLanding, path.isEmpty, scope == .all else { return }
        switch ExploreLanding(rawValue: landing) {
        case .off:
            appliedLanding = true
        case .customPage(let id):
            appliedLanding = true
            if customPages.page(id: id) != nil { path.append(ExploreNavigationRoute.customPage(id: id)) }
        case .source(let url):
            guard !exploreSources.isEmpty else { return }
            appliedLanding = true
            if exploreSources.contains(where: { $0.bookSourceUrl == url }) {
                path.append(ExploreNavigationRoute.source(sourceURL: url))
            }
        }
    }
}

// MARK: - A row

/// One row, resolved against the shelf when it draws. Its own view, so a row that did not
/// change is not drawn again when another one loads.
private struct HomeRowHost: View {
    let row: HomeModel.Row
    let store: BookStore
    let aozoraIndex: AozoraCatalogIndex?
    let model: HomeModel
    let push: (ExplorePush) -> Void
    let select: (PublicLibraryBookSelection) -> Void

    var body: some View {
        HomeRowView(row: row, content: content,
                    load: { model.load(row.id) },
                    request: { model.request(row.id) },
                    showAll: showAll,
                    open: open,
                    openLocation: { location in
                        ExplorePlace.page(of: location, in: row, aozoraIndex: aozoraIndex).map(push)
                    })
    }

    private var content: HomeRowContent? {
        guard case .loaded(let entries) = row.state else { return nil }
        return HomeRowContent(entries: entries, sourceName: row.sourceName, store: store)
    }

    private var showAll: (() -> Void)? {
        guard let target = ExplorePlace.showAll(row, aozoraIndex: aozoraIndex) else { return nil }
        return { push(target) }
    }

    /// A card opens the page its source opens it on. A public-library book opens the store's
    /// carousel, the row's other public-library books beside it.
    private func open(_ card: HomeCardContent, _ cards: [HomeCardContent]) {
        guard let target = ExploreItemTarget(card.opening, aozoraIndex: aozoraIndex) else { return }
        switch target {
        case .push(let page):
            push(page)
        case .publicLibraryBook(let book):
            let books = cards.compactMap { other -> PublicLibraryBook? in
                guard case .publicLibraryBook(let book) = ExploreItemTarget(other.opening, aozoraIndex: aozoraIndex) else {
                    return nil
                }
                return book
            }
            PublicLibraryBookSelection(books: books, selectedID: book.id).map(select)
        }
    }
}

// MARK: - 範圍

/// Which sources 範圍 offers, and whether a stored one is still there (design §13.3: 全部, or
/// any book source, library connection, Gutenberg or Aozora; no public library in China).
enum ExploreHomeScope {
    static func isAvailable(_ key: SourceInstanceKey, sources: [BookSource], connections: RemoteLibraryConnectionStore,
                            librariesAvailable: Bool) -> Bool {
        switch key.type {
        case .bookSource:
            // The sources 探索 lists (`DiscoverViewModel.exploreSources`).
            return sources.contains {
                $0.bookSourceUrl == key.id && $0.enabledExplore
                    && !$0.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .opds, .calibre, .webDAV:
            return connections.connection(id: key.id).map { ProviderType($0.kind) } == key.type
        case .gutenberg, .aozora:
            return librariesAvailable
        case .library, .bibliographic:
            return false
        }
    }

    static func name(of key: SourceInstanceKey, sources: [BookSource], connections: RemoteLibraryConnectionStore) -> String {
        switch key.type {
        case .bookSource: sources.first { $0.bookSourceUrl == key.id }?.bookSourceName ?? key.id
        case .opds, .calibre, .webDAV: connections.connection(id: key.id)?.name ?? key.id
        case .gutenberg: localized("Project Gutenberg")
        case .aozora: localized("青空文庫")
        case .library, .bibliographic: key.id
        }
    }
}

/// 範圍, a picker in a menu (design §13.3), which opens nothing modal. Book sources sit in a
/// submenu of their own: a reader can have thousands.
private struct ExploreScopeMenu: View {
    @Binding var scope: ExploreScope
    let connections: [RemoteLibraryConnection]
    let librariesAvailable: Bool
    let sources: [BookSource]

    var body: some View {
        Menu {
            Picker(localized("範圍"), selection: $scope) {
                Label(localized("全部"), systemImage: "square.grid.2x2").tag(ExploreScope.all)
            }
            if !connections.isEmpty || librariesAvailable {
                Picker(localized("範圍"), selection: $scope) {
                    ForEach(connections) { connection in
                        Label(connection.name, systemImage: HomeLibraryTileSymbol.symbol(for: ProviderType(connection.kind)) ?? "books.vertical")
                            .tag(ExploreScope.source(SourceInstanceKey(type: ProviderType(connection.kind), id: connection.id)))
                    }
                    if librariesAvailable {
                        Label(localized("Project Gutenberg"), systemImage: "building.columns")
                            .tag(ExploreScope.source(SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)))
                        Label(localized("青空文庫"), systemImage: "building.columns")
                            .tag(ExploreScope.source(SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)))
                    }
                }
            }
            if !sources.isEmpty {
                Menu(localized("來源配置")) {
                    Picker(localized("來源配置"), selection: $scope) {
                        ForEach(sources) { source in
                            Text(source.bookSourceName)
                                .tag(ExploreScope.source(SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl)))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: scope == .all ? "rectangle.stack" : "rectangle.stack.fill")
                .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("範圍"))
        .accessibilityValue(valueName)
        .accessibilityIdentifier("explore.scopeMenu")
    }

    private var valueName: String {
        guard case .source(let key) = scope else { return localized("全部") }
        switch key.type {
        case .bookSource: return sources.first { $0.bookSourceUrl == key.id }?.bookSourceName ?? key.id
        case .gutenberg: return localized("Project Gutenberg")
        case .aozora: return localized("青空文庫")
        default: return connections.first { $0.id == key.id }?.name ?? key.id
        }
    }
}

#Preview("Explore home") {
    ExploreHome(browser: BrowserState())
        .environmentObject(BookStore())
}
