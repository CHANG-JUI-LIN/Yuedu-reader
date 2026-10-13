import SwiftUI

/// 探索's root since unified library 5c-3 (design §13.3): the reader's sections, in their order,
/// across every source — Emby's model under Apple Books' covers (Phase 5 plan, settled
/// decision 11). Its one ••• (decision 36, 2026-10-13, which took 範圍 away) holds every other
/// way in: 編輯首頁, the 首頁配置 (5d-4, decision 22), 聚合設定, and the browser (5d-1, settled
/// decision 12, which took 我的書庫 off the home). A library's own page in the home's layouts
/// (`LibraryHomePage`, decision 35), which 範圍 showed in place of the home, waits for 資源庫
/// (5h) to open it. There is no catalog entry at
/// the top (decision 20's, removed 2026-10-11 by the maintainer): a reader adds the sections
/// they want, and a row's 查看全部 opens the rest of what it shows.
///
/// - One stack for everything the home opens (decision 5): Explore's routes, the libraries'
///   feeds, folders and books, the store's pages, and the store's card carousel over it all.
/// - The page is read once the book-source library is read (`ExploreTabRoot` waits for
///   that), and the defaults are saved then, for good (`HomePageStore.pageOrDefaults`).
/// - Rows are built again when the page (or the 首頁配置 chosen), the sources, the connections or
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
    /// 範圍's public library's own sections, apart from the home's rows, which stay loaded.
    @StateObject private var libraryModel: HomeModel
    @ObservedObject private var pageStore = HomePageStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var tabModel = ExploreTabModel.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @AppStorage(ExploreSettings.modeKey) private var storedMode = ExploreMode.publicLibraries.rawValue
    @AppStorage(ExploreSettings.showsBrowserKey) private var showsBrowser = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path = NavigationPath()
    @State private var exploreSources: [BookSource] = []
    @State private var browserPresentation: BrowserPresentation?
    @State private var configurationPrompt: HomeConfigurationPrompt?
    /// 編輯首頁: the sections drawn as cards to show, hide, reorder and open (5d-2).
    @State private var isEditing = false
    /// 新增欄目's sheet (5d-5).
    @State private var addsSection = false
    /// The section 新增欄目 just added, brought into view: it is at the end of the home.
    @State private var addedSection: UUID?
    /// iOS 17: ••• is a chooser sheet, and what was picked runs once it is gone
    /// (Technotes/iOS17MenuModalPresentation.md).
    @State private var showsMoreChooser = false
    @State private var moreSequence = DismissalSequencedPresentation<ExploreMoreAction>()

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
        _libraryModel = StateObject(wrappedValue: HomeModel(
            providers: { SourceProviderRegistry.shared.homeProviders(shelf: store) },
            waitForSources: { await BookSourceStore.shared.waitUntilLoaded() }))
    }

    // MARK: State

    private var mode: ExploreMode {
        ExploreMode.effective(stored: .storedValue(storedMode, hasImportedSources: tabModel.hasSources),
                              hasImportedSources: tabModel.hasSources, librariesAvailable: availability.isAvailable)
    }


    /// 範圍 left 探索 (Phase 5 plan, decision 36): 探索 is always the home, and a stored scope
    /// is no longer read (the value stays stored). The library pages below (`libraryHome`,
    /// `placePage`) have no entry until 資源庫 (5h) opens them.
    private var scopeKey: SourceInstanceKey? { nil }

    /// The sections drawn, in the reader's languages' order (聚合設定, 5d-3d).
    private var groups: [HomeSectionGroup] {
        groups(of: model, in: nil)
    }

    private func groups(of model: HomeModel, in scope: SourceInstanceKey?) -> [HomeSectionGroup] {
        let lookup = store.copyLookup()
        return model.groups(in: scope, languages: aggregation.readingLanguages,
                            libraryOrder: aggregation.settings.libraryOrder,
                            readFilter: HomeReadFilter(hides: aggregation.hidesRead, isRead: lookup.isRead))
    }

    /// 範圍's public library's sections; nil for 全部, a connection or a book source.
    private var libraryPage: HomePage? {
        scopeKey.flatMap { LibraryHomePage.page(for: $0, languages: aggregation.readingLanguages.languages) }
    }

    /// What the library's rows are built from: its page, and whether its provider serves (青空文庫
    /// serves nothing until its catalog is read).
    private var librarySyncKey: [AnyHashable] {
        [libraryPage, availability.isAvailable, aozora.catalog != nil]
    }

    /// What the rows are built from; any change builds them again.
    private var syncKey: [AnyHashable] {
        [pageStore.page, connections.catalogs.map(\.id), exploreSources.map(\.bookSourceUrl), availability.isAvailable,
         aozora.catalog != nil, aggregation.settings.hiddenFromLatest]
    }

    /// Every section is settled with nothing in it, so the home would be blank: a China
    /// storefront with no source and nothing read yet, a source no section draws from, or a
    /// 首頁配置 with no section shown.
    private var showsNothing: Bool {
        groups.allSatisfy(\.isSettledEmpty)
    }

    /// The selected 首頁配置 shows no section at all: 空白, or one whose sections are all hidden.
    private var hasNoSections: Bool {
        !(pageStore.page?.sections.contains { $0.isEnabled && $0.isEditable } ?? false)
    }

    private var selectedConfiguration: HomeConfigurationListing? {
        pageStore.configurations.first { $0.id == pageStore.selectedConfiguration }
    }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            root
            .toolbar { toolbar }
            .homeConfigurationPrompts($configurationPrompt)
            .sheet(isPresented: $addsSection) {
                HomeNewSectionSheet(added: { addedSection = $0; addsSection = false }, close: { addsSection = false })
                    .environmentObject(store)
            }
            .fullScreenCover(item: $browserPresentation) { presentation in
                NavigationStack {
                    BrowserPage(browser: browser, entry: presentation.entry)
                }
                .environmentObject(store)
            }
            .exploreRouteDestinations(openBrowser: openBrowser)
            .homeEditDestinations()
            .remoteLibraryDestinations()
            .publicLibraryDestinations()
        }
        // The store's card carousel is off the home for now (Phase 5 plan, decision 27): a store
        // page's book opens 作品詳情 as the home's cards do. `PublicLibraryBookSheet` stays.
        .environment(\.openPublicLibraryBooks) { selection in
            if let book = selection.selectedBook { path.append(WorkDetailRoute(book)) }
        }
        .task(id: syncKey) {
            // Saved here, not while drawing: the first read saves the defaults.
            await model.sync(with: pageStore.pageOrDefaults(mode: mode, publicLibrariesAvailable: availability.isAvailable),
                             hiddenFromLatest: Set(aggregation.settings.hiddenFromLatest ?? []))
        }
        .task(id: librarySyncKey) {
            guard let libraryPage else { return }
            await libraryModel.sync(with: libraryPage)
        }
        .task { await aozora.load() }
        // 編輯首頁 edits one 首頁配置; deleting it, the one 預設 takes the place of, ends the edit.
        .onChange(of: pageStore.selectedConfiguration) { _, _ in
            if isEditing { setEditing(false) }
        }
        .onReceive(sourceStore.sourcesPublisher) { _ in
            exploreSources = DiscoverViewModel.exploreSources(in: sourceStore)
        }
    }

    // MARK: One library

    /// 範圍's library or source in place of the home (decision 35): a public library's own
    /// sections, or a connection's or a book source's own page, the one its 查看全部 opens.
    @ViewBuilder
    private var root: some View {
        if let key = scopeKey, libraryPage != nil {
            libraryHome(key)
        } else if let key = scopeKey,
           let place = ExplorePlace.page(of: key, name: scopeName(key)) {
            placePage(place)
                .id(key)
                .showsRootTabBarOnlyHere()
        } else {
            home
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
        default:
            // `ExplorePlace.page(of:name:)` names no other page; a public library has its sections.
            EmptyView()
        }
    }

    private func scopeName(_ key: SourceInstanceKey) -> String {
        ExploreHomeScope.name(of: key, sources: sourceStore.sources, connections: connections)
    }

    /// A public library's sections, drawn as the home draws its own: read-only, since they are
    /// made, not a 首頁配置.
    private func libraryHome(_ key: SourceInstanceKey) -> some View {
        let groups = groups(of: libraryModel, in: key)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                ForEach(groups) { group in
                    groupHost(group, model: libraryModel, isEditable: false).id(group.section.id)
                }
                libraryFooter(key)
                    .padding(.horizontal, DSSpacing.lg)
            }
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rootTabTitleScrollAnchor()
        }
        .overlay {
            if key.type == .aozora, aozora.catalog == nil {
                if case .failed(let error, _) = aozora.state {
                    ContentUnavailableView {
                        UnavailableLabel(localized("青空文庫"), systemImage: "books.vertical")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button(localized("重試")) { Task { await aozora.load(forceRefresh: true) } }
                            .disabled(aozora.isRefreshing)
                    }
                } else {
                    ProgressView(localized("正在更新目錄"))
                }
            } else if !libraryModel.isReady {
                ProgressView()
            }
        }
        .refreshable {
            libraryModel.reload()
            if key.type == .aozora { await aozora.load(forceRefresh: true) }
        }
        // Gutenberg's shelves load with the page, those below the fold too.
        .task(id: libraryModel.rows.map(\.id)) { libraryModel.homeAppeared(in: key) }
        .onAppear { libraryModel.reloadLocal() }
        .id(key)
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
        .rootTabTitle(scopeName(key), onScroll: .minimizesBar)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: groups.map(\.id))
    }

    /// Where the library's books come from, as its store page said it.
    @ViewBuilder
    private func libraryFooter(_ key: SourceInstanceKey) -> some View {
        switch key.type {
        case .aozora:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(.init(localized("書誌資料：青空文庫（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）")))
                if aozora.catalog != nil, case .failed = aozora.state { Text(localized("目錄更新失敗，仍顯示已儲存的目錄。")) }
            }
            .dsSectionFooter()
        case .gutenberg:
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                // Gutenberg's subjects and bookshelves, as its store page offered them. Not in the
                // toolbar: beside 範圍 and the library's name, it put both under 「更多」.
                NavigationLink(value: PublicLibraryRoute.categories(aozora.catalog)) {
                    Label(localized("瀏覽所有分類"), systemImage: "books.vertical")
                }
                .accessibilityIdentifier("publicLibrary.categories")
                Text(localized("Project Gutenberg 的書在美國屬於公有領域；所在地區的著作權規定可能不同。"))
                    .dsSectionFooter()
            }
        default:
            EmptyView()
        }
    }

    // MARK: 全部

    private var home: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                if isEditing {
                    HomeEditingSections(sections: pageStore.page?.editableSections ?? [], groups: model.groups(in: nil, languages: aggregation.readingLanguages),
                                        configuration: selectedConfiguration,
                                        openSettings: { path.append(HomeEditRoute.section($0)) },
                                        prompt: { configurationPrompt = $0 },
                                        addSection: { addsSection = true }) { group in
                        groupHost(group, model: model, isEditable: true)
                    }
                } else {
                    ForEach(groups) { group in groupHost(group, model: model, isEditable: true).id(group.section.id) }
                }
                // Over a home with nothing drawn, the button is the empty state's own.
                if model.isReady, isEditing || !showsNothing {
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
        .onChange(of: addedSection) { _, added in
            guard let added else { return }
            withAnimation(reduceMotion ? nil : DSAnimation.standard) { proxy.scrollTo(added, anchor: .center) }
            addedSection = nil
        }
        }
        .overlay {
            if !model.isReady {
                ProgressView()
            } else if showsNothing, !isEditing {
                ContentUnavailableView {
                    if hasNoSections {
                        UnavailableLabel(localized("這個首頁配置還沒有欄目"), systemImage: "rectangle.stack")
                    } else {
                        UnavailableLabel(localized("探索還沒有內容"), systemImage: "rectangle.stack")
                    }
                } actions: {
                    if hasNoSections {
                        Button(localized("新增欄目")) { addsSection = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("home.addSection")
                    }
                    Button(localized("編輯首頁")) { setEditing(true) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("home.edit")
                }
            }
        }
        .refreshable { await refresh() }
        // Again when a sync changes the rows: a Gutenberg row added while the home shows.
        .task(id: model.rows.map(\.id)) { model.homeAppeared(in: nil) }
        // On the stack's root, not the stack: coming back from a page the home pushed is coming
        // back into view too. An article read there reads as read; a book read from 作品詳情
        // moves in 繼續閱讀.
        .onAppear {
            model.reloadLocal()
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .pageBackgroundToolbar(for: .explore)
        .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: groups.map(\.id))
    }

    private func groupHost(_ group: HomeSectionGroup, model: HomeModel, isEditable: Bool) -> some View {
        HomeRowHost(group: group, store: store, aozoraIndex: aozora.catalog, model: model, isEditable: isEditable,
                    push: push,
                    openSettings: { path.append(HomeEditRoute.section(group.section.id)) })
    }

    /// Pull to refresh, and ••• → 重新整理.
    private func refresh() async {
        model.reload()
        // 訂閱的最新文章 shows what the RSS tab stored; refreshing fetches the feeds too, as the
        // RSS tab's own refresh does (decision 29), then reads them again.
        async let feeds: Void = refreshSubscriptions()
        // 青空文庫's rows are read from its catalog. Refreshing checks for it again, as 青空文庫's
        // own page does, instead of waiting out the daily check: a device that found none (the
        // catalog went unpublished until 2026-10-11) would wait a day.
        if availability.isAvailable { await aozora.load(forceRefresh: true) }
        await feeds
    }

    /// Only when a section the home shows reads the feeds: a home without one sends nothing.
    private func refreshSubscriptions() async {
        guard groups.contains(where: { $0.section.binding == .subscriptionArticles }) else { return }
        await RSSFeedRefreshService.refreshAll()
        model.reloadLocal()
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) { isEditing = editing }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addsSection = true } label: {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("新增欄目"))
                .accessibilityIdentifier("home.addSectionBar")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("完成")) { setEditing(false) }
                    .accessibilityIdentifier("home.editDoneBar")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { moreControl }
        }
    }

    /// 探索's one ••• (Phase 5 plan, decisions 30 and 36). A native menu from iOS 18; on iOS 17
    /// a chooser sheet, since 新增首頁配置's alert and the browser's cover would be dropped while
    /// the menu dismisses.
    @ViewBuilder
    private var moreControl: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                moreSequence.cancel()
                showsMoreChooser = true
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(localized("更多"))
            .accessibilityIdentifier("explore.more")
            .sheet(isPresented: $showsMoreChooser, onDismiss: {
                moreSequence.consumeAfterDismissal().map(perform)
            }) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(title: localized("更多"), actions: moreChoices,
                                                    onSelect: { moreSequence.select($0) })
                }
            }
        } else {
            ExploreMoreMenu(configuration: Binding(get: { pageStore.selectedConfiguration },
                                                   set: { pageStore.select($0) }),
                            configurations: pageStore.configurations, showsBrowser: showsBrowser,
                            perform: perform)
        }
    }

    /// The chooser's rows: the menu's items, with each 首頁配置 a row of its own.
    private var moreChoices: [DismissalSequencedAction<ExploreMoreAction>] {
        var actions = [DismissalSequencedAction(route: ExploreMoreAction.editHome, title: localized("編輯首頁"),
                                                systemImage: "pencil")]
        actions += pageStore.configurations.map { configuration in
            let isSelected = configuration.id == pageStore.selectedConfiguration
            return DismissalSequencedAction(
                route: .selectConfiguration(configuration.id), title: configuration.name,
                systemImage: isSelected ? "checkmark" : "square.stack",
                // The menu's check mark, said in words: the chooser's rows have no selected state.
                subtitle: isSelected ? [localized("首頁配置"), localized("使用中")].joined(separator: " · ") : localized("首頁配置"))
        }
        actions += [
            DismissalSequencedAction(route: .newConfiguration, title: localized("新增首頁配置"), systemImage: "plus"),
            DismissalSequencedAction(route: .readingLanguages, title: localized("偏好閱讀語言"), systemImage: "globe"),
            DismissalSequencedAction(route: .aggregatedSources, title: localized("參與聚合的來源"),
                                     systemImage: "square.stack.3d.up"),
            DismissalSequencedAction(route: .refresh, title: localized("重新整理"), systemImage: "arrow.clockwise"),
        ]
        if showsBrowser {
            actions.append(DismissalSequencedAction(route: .browser, title: localized("瀏覽器"), systemImage: "safari"))
        }
        return actions
    }

    private func perform(_ action: ExploreMoreAction) {
        switch action {
        case .editHome:
            setEditing(true)
        case .selectConfiguration(let id):
            pageStore.select(id)
        case .newConfiguration:
            configurationPrompt = .create
        case .readingLanguages, .aggregatedSources:
            // Both are 聚合設定's (decision 36): the languages are its first section.
            path.append(ExploreNavigationRoute.aggregationSettings)
        case .refresh:
            Task { await refresh() }
        case .browser:
            openBrowser(.resume)
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
    /// A section of the reader's home: its long press edits the 首頁配置. A library's own sections
    /// are made, not saved, and have nothing to edit.
    let isEditable: Bool
    let push: (ExplorePush) -> Void
    let openSettings: () -> Void
    @Environment(\.openRSSTab) private var openRSSTab
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
                    openCollection: { push(ExplorePlace.page(of: $0)) },
                    openArticle: { push(.article(SubscriptionArticleRoute(articleID: $0.id))) },
                    actions: actions,
                    bookActions: bookActions)
            .homeSectionDeleteConfirmation(isPresented: $confirmsDelete, title: group.section.editorTitle()) {
                HomePageStore.shared.edit { $0.removeSection(group.section.id) }
            }
    }

    private var actions: HomeSectionActions? {
        guard isEditable else { return nil }
        return HomeSectionActions(
            setLayout: { layout in
                withAnimation(DSAnimation.standard) {
                    HomePageStore.shared.edit { $0.setLayout(layout, section: group.section.id) }
                }
            },
            hide: { HomePageStore.shared.edit { $0.setEnabled(false, section: group.section.id) } },
            openSettings: openSettings,
            delete: { confirmsDelete = true })
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
    /// them all. 訂閱的最新文章's is the RSS tab itself (decision 29), when it is shown.
    private var showAll: (() -> Void)? {
        if group.section.binding == .subscriptionArticles {
            return openRSSTab.map { open in { open() } }
        }
        guard group.rows.count == 1,
              let target = ExplorePlace.showAll(group.rows[0], aozoraIndex: aozoraIndex) else { return nil }
        return { push(target) }
    }

    /// Every card opens 作品詳情 first, 繼續閱讀's too, as Emby's posters open the item's page
    /// (Phase 5 plan, decision 27); reading starts from there.
    private func open(_ card: HomeCardContent, _ cards: [HomeCardContent]) {
        guard let route = card.route else { return }
        push(.work(route))
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

/// A library as 範圍 and 書庫順序 list it.
struct LibraryListing: Identifiable, Hashable {
    let key: SourceInstanceKey
    let name: String
    let systemImage: String

    var id: SourceInstanceKey { key }

    /// The libraries there are now (saved connections; Gutenberg and 青空文庫 where offered),
    /// in 書庫順序.
    static func ordered(connections: [RemoteLibraryConnection], librariesAvailable: Bool,
                        order: [SourceInstanceKey]?) -> [LibraryListing] {
        let names = Dictionary(connections.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let keys = LibraryOrder.defaultKeys(connections: connections, librariesAvailable: librariesAvailable)
        return LibraryOrder.arrange(keys, by: order, key: { $0 }).map { key in
            let name = switch key.type {
            case .gutenberg: localized("Project Gutenberg")
            case .aozora: localized("青空文庫")
            default: names[key.id] ?? key.id
            }
            return LibraryListing(key: key, name: name, systemImage: SourceKindSymbol.symbol(for: key.type) ?? "books.vertical")
        }
    }
}

/// What 探索's ••• does (Phase 5 plan, decisions 30 and 36), from the menu or iOS 17's chooser.
enum ExploreMoreAction: Hashable {
    case editHome
    case selectConfiguration(HomeConfigurationID)
    case newConfiguration
    case readingLanguages
    case aggregatedSources
    case refresh
    case browser
}

/// 探索's ••• from iOS 18: 編輯首頁, the 首頁配置 submenu (a picker, then 新增首頁配置), the two
/// entries into 聚合設定, 重新整理, and the browser, which is presented rather than shown in
/// place (5d-1).
private struct ExploreMoreMenu: View {
    @Binding var configuration: HomeConfigurationID
    let configurations: [HomeConfigurationListing]
    let showsBrowser: Bool
    let perform: (ExploreMoreAction) -> Void

    var body: some View {
        Menu {
            Button { perform(.editHome) } label: {
                Label(localized("編輯首頁"), systemImage: "pencil")
            }
            // A submenu: inline, its check mark would read as a choice of the whole menu. The
            // current one is the subtitle.
            Menu {
                Picker(localized("首頁配置"), selection: $configuration) {
                    ForEach(configurations) { configuration in
                        Text(configuration.name).tag(configuration.id)
                    }
                }
                Section {
                    Button { perform(.newConfiguration) } label: {
                        Label(localized("新增首頁配置"), systemImage: "plus")
                    }
                }
            } label: {
                Label(localized("首頁配置"), systemImage: "square.stack")
                Text(configurations.first { $0.id == configuration }?.name ?? "")
            }
            Section {
                Button { perform(.readingLanguages) } label: {
                    Label(localized("偏好閱讀語言"), systemImage: "globe")
                }
                Button { perform(.aggregatedSources) } label: {
                    Label(localized("參與聚合的來源"), systemImage: "square.stack.3d.up")
                }
            }
            Section {
                Button { perform(.refresh) } label: {
                    Label(localized("重新整理"), systemImage: "arrow.clockwise")
                }
                if showsBrowser {
                    Button { perform(.browser) } label: {
                        Label(localized("瀏覽器"), systemImage: "safari")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("更多"))
        .accessibilityIdentifier("explore.more")
    }
}

#Preview("Explore home") {
    ExploreHome(browser: BrowserState())
        .environmentObject(BookStore())
}

#Preview("•••，iOS 18 起的選單") {
    @Previewable @State var configuration = HomeConfigurationID.defaults
    NavigationStack {
        Text(configuration.rawValue)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ExploreMoreMenu(configuration: $configuration,
                                    configurations: [.init(id: .defaults, name: localized("預設")),
                                                     .init(id: .blank, name: localized("空白"))],
                                    showsBrowser: true, perform: { _ in })
                }
            }
    }
}
