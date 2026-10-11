import SwiftUI

/// 探索's root since unified library 5c-3 (design §13.3): the reader's sections, in their order,
/// across every source — Emby's model under Apple Books' covers (Phase 5 plan, settled
/// decision 11). 範圍 narrows the same home to one source's books, as switching Emby's library
/// does (5d-3b, decision 19), and holds every other way in: the custom pages and the browser
/// (5d-1, settled decision 12, which took 我的書庫 off the home). The full catalogs are one tap
/// from the top of the home: 瀏覽書庫, or the chosen library's 瀏覽完整目錄 (decision 20).
///
/// - One stack for everything the home opens (decision 5): Explore's routes, the libraries'
///   feeds, folders and books, the store's pages, and the store's card carousel over it all.
/// - The page is read once the book-source library is read (`ExploreTabRoot` waits for
///   that), and the defaults are saved then, for good (`HomePageStore.pageOrDefaults`).
/// - Rows are built again when the page, the sources, the connections, the custom pages or
///   the region change. Rows read from this device load again when the home comes back into
///   view, never on a shelf change: a page turn is one.
/// - Books are searched from the 搜索 tab. The field that narrowed 我的書庫's book sources went
///   with it.
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
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @AppStorage(ExploreSettings.scopeKey) private var storedScope = ExploreScope.all.rawValue
    @AppStorage(ExploreSettings.modeKey) private var storedMode = ExploreMode.publicLibraries.rawValue
    @AppStorage(ExploreSettings.showsBrowserKey) private var showsBrowser = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path = NavigationPath()
    @State private var selection: PublicLibraryBookSelection?
    @State private var coverFrames = PublicLibraryCoverFrames()
    @State private var exploreSources: [BookSource] = []
    @State private var browserPresentation: BrowserPresentation?
    @State private var pagePrompt: CustomExplorePagePrompt?
    /// 編輯首頁: the sections drawn as cards to show, hide, reorder and open (5d-2).
    @State private var isEditing = false

    private struct BrowserPresentation: Identifiable {
        let id = UUID()
        let entry: BrowserEntry
    }

    init(store: BookStore, browser: BrowserState) {
        self.store = store
        self.browser = browser
        _model = StateObject(wrappedValue: HomeModel(
            providers: { SourceProviderRegistry.shared.homeProviders(shelf: store) },
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

    /// The source 範圍 keeps; nil for 全部.
    private var scopeKey: SourceInstanceKey? {
        if case .source(let key) = scope { return key }
        return nil
    }

    /// The sections drawn: under 範圍, only the chosen source's books; in the reader's
    /// languages' order (聚合設定, 5d-3d).
    private var groups: [HomeSectionGroup] {
        model.groups(in: scopeKey, languages: aggregation.readingLanguages)
    }

    /// What the rows are built from; any change builds them again.
    private var syncKey: [AnyHashable] {
        [pageStore.page, connections.catalogs.map(\.id), exploreSources.map(\.bookSourceUrl), availability.isAvailable,
         aozora.catalog != nil]
    }

    /// Every section is settled with nothing in it, so the home would be blank: a China
    /// storefront with no source and nothing read yet, or a source no section draws from.
    private var showsNothing: Bool {
        groups.allSatisfy(\.isSettledEmpty)
    }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            home
            .toolbar { toolbar }
            .customExplorePagePrompts($pagePrompt)
            .fullScreenCover(item: $browserPresentation) { presentation in
                NavigationStack {
                    BrowserPage(browser: browser, entry: presentation.entry)
                }
                .environmentObject(store)
            }
            .exploreRouteDestinations(openBrowser: openBrowser)
            .homeEditDestinations(model: model)
            .navigationDestination(for: HomeLibrariesRoute.self) { _ in
                HomeLibrariesPage(connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                                  sources: exploreSources)
            }
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
        }
        .onReceive(sourceStore.sourcesPublisher) { _ in
            exploreSources = DiscoverViewModel.exploreSources(in: sourceStore)
        }
    }

    // MARK: 全部

    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                if isEditing {
                    // Every section, whatever 範圍 keeps: 編輯首頁 edits the home itself.
                    HomeEditingSections(sections: pageStore.page?.editableSections ?? [], groups: model.groups(in: nil, languages: aggregation.readingLanguages),
                                        openSettings: { path.append(HomeEditRoute.section($0)) }) { group in
                        groupHost(group)
                    }
                } else {
                    if model.isReady { catalogEntry }
                    ForEach(groups) { group in groupHost(group) }
                }
                if model.isReady {
                    // At the end of the home (maintainer, 2026-10-11, decision 18).
                    Button(localized(isEditing ? "完成" : "編輯首頁")) { setEditing(!isEditing) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(isEditing ? "home.editDone" : "home.edit")
                }
            }
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rootTabTitleScrollAnchor()
        }
        .overlay {
            if !model.isReady {
                ProgressView()
            } else if showsNothing, !isEditing {
                ContentUnavailableView {
                    UnavailableLabel(localized("探索還沒有內容"), systemImage: "rectangle.stack")
                } description: {
                    if scopeKey == nil {
                        Text(localized("從右上角的範圍打開書庫或來源配置。")).foregroundStyle(DSColor.textSecondary)
                    }
                }
                // The catalog entry above it stays tappable.
                .allowsHitTesting(false)
            }
        }
        .refreshable { model.reload() }
        // Again when a sync changes the rows (a Gutenberg row added while the home shows), or
        // 範圍 brings other rows in.
        .task(id: [AnyHashable(model.rows.map(\.id)), AnyHashable(scopeKey)]) { model.homeAppeared(in: scopeKey) }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
        .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: groups.map(\.id))
    }

    /// 瀏覽書庫 under 全部, 瀏覽完整目錄 under one library (decision 20).
    @ViewBuilder
    private var catalogEntry: some View {
        if let key = scopeKey {
            let name = ExploreHomeScope.name(of: key, sources: sourceStore.sources, connections: connections)
            if let page = ExplorePlace.page(of: key, name: name) {
                ExplorePushLink(push: page) {
                    HomeCatalogEntryLabel(title: localized("瀏覽完整目錄"), systemImage: "books.vertical")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.catalog")
                .padding(.horizontal, DSSpacing.lg)
            }
        } else if !connections.catalogs.isEmpty || availability.isAvailable || !exploreSources.isEmpty {
            NavigationLink(value: HomeLibrariesRoute()) {
                HomeCatalogEntryLabel(title: localized("瀏覽書庫"), systemImage: "books.vertical")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.libraries")
            .padding(.horizontal, DSSpacing.lg)
        }
    }

    private func groupHost(_ group: HomeSectionGroup) -> some View {
        HomeRowHost(group: group, store: store, aozoraIndex: aozora.catalog, model: model,
                    push: push, select: { selection = $0 },
                    openSettings: { path.append(HomeEditRoute.section(group.section.id)) })
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) { isEditing = editing }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("完成")) { setEditing(false) }
                    .accessibilityIdentifier("home.editDoneBar")
            }
        } else {
            scopeAndPageItems
        }
    }

    @ToolbarContentBuilder
    private var scopeAndPageItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ExploreScopeMenu(scope: Binding(get: { scope }, set: { storedScope = $0.rawValue }),
                             connections: connections.catalogs, librariesAvailable: availability.isAvailable,
                             sources: exploreSources, customPages: customPages.pages, showsBrowser: showsBrowser,
                             openPage: { path.append(ExploreNavigationRoute.customPage(id: $0)) },
                             openBrowser: { openBrowser(.resume) })
        }
        if scope == .all {
            ToolbarItem(placement: .topBarTrailing) {
                Button { pagePrompt = .create } label: {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("新增自訂頁"))
            }
        }
    }

    // MARK: Opening

    private func push(_ push: ExplorePush) {
        push.append(to: &path)
    }

    private func openBrowser(_ entry: BrowserEntry) {
        browserPresentation = BrowserPresentation(entry: entry)
    }
}

// MARK: - A section

/// One section, resolved against the shelf when it draws. Its own view, so a section that did
/// not change is not drawn again when another one loads.
private struct HomeRowHost: View {
    let group: HomeSectionGroup
    let store: BookStore
    let aozoraIndex: AozoraCatalogIndex?
    let model: HomeModel
    let push: (ExplorePush) -> Void
    let select: (PublicLibraryBookSelection) -> Void
    let openSettings: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        HomeRowView(group: group, content: content,
                    load: { for row in group.rows { model.load(row.id) } },
                    request: {
                        for row in group.rows { if case .failed = row.state { model.request(row.id) } }
                    },
                    showAll: showAll,
                    open: open,
                    openLocation: { location in
                        // Places come from a section of one source: an index's groups, a feed's.
                        guard let row = group.rows.first else { return }
                        ExplorePlace.page(of: location, in: row, aozoraIndex: aozoraIndex).map(push)
                    },
                    actions: HomeSectionActions(
                        setLayout: { layout in
                            withAnimation(DSAnimation.standard) {
                                HomePageStore.shared.edit { $0.setLayout(layout, section: group.section.id) }
                            }
                        },
                        hide: { HomePageStore.shared.edit { $0.setEnabled(false, section: group.section.id) } },
                        openSettings: openSettings,
                        delete: { confirmsDelete = true }),
                    bookActions: bookActions)
            .homeSectionDeleteConfirmation(isPresented: $confirmsDelete, title: group.section.editorTitle()) {
                HomePageStore.shared.edit { $0.removeSection(group.section.id) }
            }
    }

    private var content: HomeRowContent? {
        guard case .loaded(let entries) = group.state else { return nil }
        return HomeRowContent(entries: entries, store: store)
    }

    /// A shelf copy's ••• (5d-3c). The shelf's rows load again at once, so the card leaves
    /// 繼續閱讀 and 相關 sees the change.
    private var bookActions: HomeBookActions {
        let isContinueReading = group.section.binding == .continueReading
        return HomeBookActions(
            removeFromContinueReading: isContinueReading ? { book in
                store.removeFromContinueReading(bookId: book.id)
                model.reloadLocal()
            } : nil,
            markFinished: { book in
                store.markFinished(bookId: book.id)
                model.reloadLocal()
            })
    }

    /// The page of a section of one source. 最新 across several has none: no one page lists
    /// them all.
    private var showAll: (() -> Void)? {
        guard group.rows.count == 1,
              let target = ExplorePlace.showAll(group.rows[0], aozoraIndex: aozoraIndex) else { return nil }
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
/// submenu of their own: a reader can have thousands. Below the picker, what is pushed rather
/// than shown in place: the custom pages and the browser (5d-1).
private struct ExploreScopeMenu: View {
    @Binding var scope: ExploreScope
    let connections: [RemoteLibraryConnection]
    let librariesAvailable: Bool
    let sources: [BookSource]
    let customPages: [CustomExplorePage]
    let showsBrowser: Bool
    let openPage: (UUID) -> Void
    let openBrowser: () -> Void

    var body: some View {
        Menu {
            Picker(localized("範圍"), selection: $scope) {
                Label(localized("全部"), systemImage: "square.grid.2x2").tag(ExploreScope.all)
            }
            if !connections.isEmpty || librariesAvailable {
                Picker(localized("範圍"), selection: $scope) {
                    ForEach(connections) { connection in
                        Label(connection.name, systemImage: SourceKindSymbol.symbol(for: ProviderType(connection.kind)) ?? "books.vertical")
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
            if !customPages.isEmpty || showsBrowser {
                Section {
                    if !customPages.isEmpty {
                        Menu {
                            ForEach(customPages) { page in
                                Button(page.name) { openPage(page.id) }
                            }
                        } label: {
                            Label(localized("自訂頁"), systemImage: "rectangle.3.group")
                        }
                    }
                    if showsBrowser {
                        Button(action: openBrowser) {
                            Label(localized("瀏覽器"), systemImage: "safari")
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
