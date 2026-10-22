import SwiftUI

/// 探索's root since unified library 5c-3 (design §13.3): the reader's sections, in their order,
/// across every source — Emby's model under Apple Books' covers (Phase 5 plan, settled
/// decision 11). Its one ••• (decision 36, 2026-10-13, which took 範圍 away) holds every other
/// way in: 編輯首頁, the 首頁配置 (5d-4, decision 22), 聚合設定, and the browser (5d-1, settled
/// decision 12, which took 我的書庫 off the home). A library's own page in the home's layouts
/// (`LibraryHomePage`, decision 35) is 資源庫's (5h, `LibraryHomePageView`). There is no
/// catalog entry at the top (decision 20's, removed 2026-10-11 by the maintainer): a reader adds the sections
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
    @ObservedObject private var pageStore = HomePageStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var tabModel = ExploreTabModel.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    /// Its installs, updates and removals change the rows (Phase 6f).
    @ObservedObject private var modules = RuleModuleLibrary.shared
    @AppStorage(ExploreSettings.modeKey) private var storedMode = ExploreMode.publicLibraries.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var path = NavigationPath()
    @State private var exploreSources: [BookSource] = []
    @State private var browserPresentation: BrowserPresentation?
    @State private var configurationPrompt: HomeConfigurationPrompt?
    /// 編輯首頁: the sections drawn as cards to show, hide, reorder and open (5d-2).
    @State private var isEditing = false
    /// 編輯首頁's bars, the bar's 完成 and the ＋ where the tab bar was: `isEditing`, but set
    /// without the morph's animation (`setEditing(_:)`).
    @State private var showsEditorBars = false
    /// 新增欄目's sheet (5d-5).
    @State private var addsSection = false
    /// The section 新增欄目 just added, brought into view: it is at the end of the home.
    @State private var addedSection: UUID?
    /// iOS 17: ••• is a chooser sheet, and what was picked runs once it is gone
    /// (Technotes/iOS17MenuModalPresentation.md).
    @State private var showsMoreChooser = false
    @State private var moreSequence = DismissalSequencedPresentation<ExploreMoreAction>()
    /// Set as the home is edited or done, until the reader drags the page: the page keeps to
    /// its end, where 編輯首頁 and 完成 are, while the other mode lays out.
    @State private var followsEnd = false
    /// The safe area under the page: the tab bar's, or the ＋'s bar while the home is edited.
    @State private var bottomInset: CGFloat = 0
    /// The page's width, which each section keeps in its card while the home is edited.
    @State private var pageWidth: CGFloat = 0

    private struct BrowserPresentation: Identifiable {
        let id = UUID()
        let entry: BrowserEntry
    }

    init(store: BookStore, browser: BrowserState) {
        self.store = store
        self.browser = browser
        _model = StateObject(wrappedValue: HomeModel.live(shelf: store))
    }

    // MARK: State

    private var mode: ExploreMode {
        ExploreMode.effective(stored: .storedValue(storedMode, hasImportedSources: tabModel.hasSources),
                              hasImportedSources: tabModel.hasSources, librariesAvailable: availability.isAvailable)
    }

    /// The sections drawn, in the reader's languages' order (聚合設定, 5d-3d).
    private var groups: [HomeSectionGroup] {
        let lookup = store.copyLookup()
        return model.groups(in: nil, languages: aggregation.readingLanguages,
                            libraryOrder: aggregation.settings.libraryOrder,
                            readFilter: HomeReadFilter(hides: aggregation.hidesRead, isRead: lookup.isRead))
    }

    /// The home's sections, each one view in and out of 編輯首頁 (`HomeSectionSlot`): one list
    /// in both, the sections drawn and every section 編輯首頁 lists, so the morph changes no
    /// section's place in it, and its cards the home's books, so it changes no row either.
    private var sectionEntries: [HomeSectionEntry] {
        let drawn = groups
        let home = Dictionary(drawn.map { ($0.section.id, $0) }, uniquingKeysWith: { first, _ in first })
        let editable = pageStore.page?.editableSections.map(\.id) ?? []
        // The page before its first read saves it: what the home draws.
        return (pageStore.page?.sections ?? drawn.map(\.section)).compactMap { section in
            let editableIndex = editable.firstIndex(of: section.id)
            guard home[section.id] != nil || editableIndex != nil else { return nil }
            return HomeSectionEntry(section: section, homeGroup: home[section.id], editableIndex: editableIndex)
        }
    }

    /// What the rows are built from; any change builds them again.
    private var syncKey: [AnyHashable] {
        [pageStore.page, connections.catalogs.map(\.id), exploreSources.map(\.bookSourceUrl), availability.isAvailable,
         aozora.catalog != nil, aggregation.settings.hiddenFromLatest,
         modules.modules.map { "\($0.module.id)@\($0.module.version)" }]
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
            home
            .toolbar { toolbar }
            // 編輯首頁 hides the tab bar while the home is being edited, as 書架's 選取 does, and
            // its ＋ takes the bar's place (maintainer, 2026-10-17).
            .hidesRootTabBar(showsEditorBars)
            .homeConfigurationPrompts($configurationPrompt)
            // Full screen, as Forward's 選擇模板: the gallery's previews run to the screen's edges.
            .fullScreenCover(isPresented: $addsSection) {
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
        .environment(\.explorePush) { $0.append(to: &path) }
        .task(id: syncKey) {
            // Saved here, not while drawing: the first read saves the defaults.
            await model.sync(with: pageStore.pageOrDefaults(mode: mode, publicLibrariesAvailable: availability.isAvailable,
                                                            languages: aggregation.readingLanguages.languages),
                             hiddenFromLatest: Set(aggregation.settings.hiddenFromLatest ?? []))
        }
        .task { await aozora.load() }
        // 編輯首頁 edits one 首頁配置; deleting it, the one 預設 takes the place of, ends the edit.
        // Another 首頁配置 picked from ••• opens where the page is, not at its end.
        .onChange(of: pageStore.selectedConfiguration) { _, _ in
            if isEditing { setEditing(false) } else { followsEnd = false }
        }
        .onReceive(sourceStore.sourcesPublisher) { _ in
            exploreSources = DiscoverViewModel.exploreSources(in: sourceStore)
        }
    }

    // MARK: 全部

    private var home: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Each section has the gap after it (`HomeSectionSlot`), going with it where only the
            // home or only the editor gives it room.
            VStack(alignment: .leading, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let entries = sectionEntries
                    let editableCount = entries.count(where: { $0.editableIndex != nil })
                    ForEach(entries) { entry in
                        HomeSectionSlot(entry: entry, isEditing: isEditing, pageWidth: pageWidth, count: editableCount,
                                        openSettings: { path.append(HomeEditRoute.section($0)) }) { group in
                            groupHost(group, model: model, isEditable: true)
                        }
                        .id(entry.id)
                    }
                }
                // Over a home with nothing drawn, the button is the empty state's own.
                if model.isReady, isEditing || !showsNothing {
                    // At the end of the home (maintainer, 2026-10-11, decision 18). Out of the lazy
                    // stack, so it is always there to scroll to.
                    Button { setEditing(!isEditing) } label: { HomeEditButtonTitle(isEditing: isEditing) }
                        .buttonStyle(.bordered)
                        // One piece moving with the page through the morph. Without it the button just
                        // tapped moved by its press's animation instead, sinking under the ＋'s bar and
                        // coming back, and its new title was drawn where it ends up while the page was
                        // still scrolling there, below its capsule (iOS 27 simulator).
                        .geometryGroup()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(localized(isEditing ? "完成" : "編輯首頁"))
                        .accessibilityIdentifier(isEditing ? "home.editDone" : "home.edit")
                }
            }
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .homeEditMorph(isEditing)
            .rootTabTitleScrollAnchor()
            // Both ways the home opens at its end, where 編輯首頁 and 完成 are (maintainer,
            // 2026-10-17). The cards are taller than the rows, and the offset the scroll view
            // kept showed the editor's middle on the way in and, past the end of the shorter
            // home, nothing at all on the way out. The page travels to its end with the morph,
            // frame by frame, from as far above it as it was, then follows it through the passes
            // the other mode lays out over, its lazy stack measuring the cards it reaches (884,
            // 1505, 1773, 1749 and 1727 points tall within 100 ms, iOS 27 simulator), until the
            // reader scrolls it off its end — a drag, or VoiceOver's or the status bar's scroll,
            // which no section changing its size afterwards takes back. And through the bars
            // that come and go with the editor: the tab bar, back after the ＋'s bar was gone,
            // covered 編輯首頁 the page had just followed (iOS 18.6 simulator).
            .pinsScrollToEnd(followsEnd, through: isEditing, bottomInset: bottomInset) { followsEnd = false }
            // A drag lets go at once, the morph's hold too.
            .onScrollDragBegan { followsEnd = false }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        .onChange(of: addedSection) { _, added in
            guard let added else { return }
            followsEnd = false
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
        // While the home is edited the bar stays, for its 完成 (maintainer, 2026-10-17).
        .rootTabTitle(localized("探索"), onScroll: isEditing ? .fadesTitle : .minimizesBar)
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

    /// The sections morph into their cards and back (`HomeSectionSlot`, maintainer, 2026-10-21),
    /// the page taken to its end along the way (`pinsScrollToEnd`). Reduce Motion switches at once.
    private func setEditing(_ editing: Bool) {
        // The bars change at the tap, outside the morph. Changed in it, the page drew another
        // offset than the one it was set to: after 完成 the drawn one stayed some 400 points past
        // the end the page is pinned to for 0.2 s, blank under 編輯首頁, then jumped, with no
        // animation on the scroll view's layer (iOS 26.5 simulator; 27 and 17 drew the set one).
        // Changed outside, the drawn offset is the set one, a frame behind, though the safe area
        // still eases into the tab bar's there.
        withAnimation(nil) { showsEditorBars = editing }
        // In the morph's own update: set before it, the page was put at its end a frame early.
        withAnimation(reduceMotion ? nil : DSAnimation.homeEditMorph) {
            followsEnd = true
            isEditing = editing
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if showsEditorBars {
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("完成")) { setEditing(false) }
                    .accessibilityIdentifier("home.editDoneBar")
            }
            // 新增欄目: a ＋ in the middle, where the tab bar was, as in the maintainer's reference
            // app (2026-10-17).
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button { addsSection = true } label: {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("新增欄目"))
                .accessibilityIdentifier("homeEditor.addSection")
                Spacer()
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
                            configurations: pageStore.configurations, perform: perform)
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
        actions.append(DismissalSequencedAction(route: .newConfiguration, title: localized("新增首頁配置"), systemImage: "plus"))
        if let current = selectedConfiguration, !current.id.isBuiltIn {
            let subtitle = [localized("首頁配置"), current.name].joined(separator: " · ")
            actions += [
                DismissalSequencedAction(route: .renameConfiguration(current), title: localized("重新命名"),
                                         systemImage: "pencil", subtitle: subtitle),
                DismissalSequencedAction(route: .deleteConfiguration(current), title: localized("刪除"),
                                         systemImage: "trash", isDestructive: true, subtitle: subtitle),
            ]
        }
        actions += [
            DismissalSequencedAction(route: .readingLanguages, title: localized("中繼資料語言偏好推薦"), systemImage: "globe"),
            DismissalSequencedAction(route: .aggregatedSources, title: localized("參與聚合的來源"),
                                     systemImage: "square.stack.3d.up"),
            DismissalSequencedAction(route: .refresh, title: localized("重新整理"), systemImage: "arrow.clockwise"),
            DismissalSequencedAction(route: .browser, title: localized("瀏覽器"), systemImage: "safari"),
        ]
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
        case .renameConfiguration(let configuration):
            configurationPrompt = .rename(configuration)
        case .deleteConfiguration(let configuration):
            configurationPrompt = .delete(configuration)
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
struct HomeRowHost: View {
    let group: HomeSectionGroup
    let store: BookStore
    let aozoraIndex: AozoraCatalogIndex?
    let model: HomeModel
    /// A section of the reader's home: its long press edits the 首頁配置. A library's own sections
    /// are made, not saved, and have nothing to edit.
    let isEditable: Bool
    let push: (ExplorePush) -> Void
    let openSettings: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        row
            .homeSectionDeleteConfirmation(isPresented: $confirmsDelete, title: group.section.editorTitle()) {
                HomePageStore.shared.edit { $0.removeSection(group.section.id) }
            }
    }

    @ViewBuilder
    private var row: some View {
        if group.section.binding == .aiRecommendations {
            AIRecommendationRow(section: group.section, title: group.title, actions: actions, open: open)
        } else {
            rowView
        }
    }

    private var rowView: some View {
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
    /// them all. 訂閱的最新文章's is RSS 訂閱 (decision 29), pushed since RSS left the tabs (5h).
    private var showAll: (() -> Void)? {
        if group.section.binding == .subscriptionArticles {
            return { push(.explore(.subscriptions)) }
        }
        guard group.rows.count == 1,
              let target = ExplorePlace.showAll(group.rows[0], aozoraIndex: aozoraIndex) else { return nil }
        return { push(target) }
    }

    /// Every card opens 作品詳情 first, as Emby's posters open the item's page (Phase 5 plan,
    /// decision 27); a shelf copy on 繼續閱讀 or 書架 opens its reader (`ExplorePush.card`).
    private func open(_ card: HomeCardContent, _ cards: [HomeCardContent]) {
        guard let route = card.route else { return }
        push(.card(route, in: group.section.binding))
    }
}

// MARK: - 範圍

/// Which sources 範圍 offers, and whether a stored one is still there (design §13.3: 全部, or
/// any book source, library connection, Gutenberg or Aozora; no public library in China).
enum ExploreHomeScope {
    @MainActor
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
        case .library, .bibliographic, .module:
            return false
        }
    }

    @MainActor
    static func name(of key: SourceInstanceKey, sources: [BookSource], connections: RemoteLibraryConnectionStore) -> String {
        switch key.type {
        case .bookSource: sources.first { $0.bookSourceUrl == key.id }?.bookSourceName ?? key.id
        case .opds, .calibre, .webDAV: connections.connection(id: key.id)?.name ?? key.id
        case .gutenberg: localized("Project Gutenberg")
        case .aozora: localized("青空文庫")
        case .library, .bibliographic, .module: key.id
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
    /// The reader's own 首頁配置, here since 編輯首頁 dropped its card (maintainer, 2026-10-17).
    case renameConfiguration(HomeConfigurationListing)
    case deleteConfiguration(HomeConfigurationListing)
    case readingLanguages
    case aggregatedSources
    case refresh
    case browser
}

/// 編輯首頁 and 完成 crossfading on the button at the home's end, each centred on the capsule
/// as it narrows or widens to the new title. Changed in place, the outgoing title kept to the
/// capsule's leading edge and ran out past its trailing one, reading as one word with the other.
private struct HomeEditButtonTitle: View {
    let isEditing: Bool

    var body: some View {
        // The title shown sizes the capsule; both are drawn over it. The button reads its own label.
        Text(localized(isEditing ? "完成" : "編輯首頁"))
            .hidden()
            .overlay {
                ZStack {
                    Text(localized("編輯首頁")).opacity(isEditing ? 0 : 1)
                    Text(localized("完成")).opacity(isEditing ? 1 : 0)
                }
                .fixedSize()
                .accessibilityHidden(true)
            }
    }
}

/// 探索's ••• from iOS 18: 編輯首頁, the 首頁配置 submenu (a picker, then 新增首頁配置, and for the
/// reader's own 重新命名 and 刪除), the two entries into 聚合設定, 重新整理, and the browser, which
/// is presented rather than shown in place (5d-1) and always offered (maintainer, 2026-10-17).
private struct ExploreMoreMenu: View {
    @Binding var configuration: HomeConfigurationID
    let configurations: [HomeConfigurationListing]
    let perform: (ExploreMoreAction) -> Void

    /// The reader's own 首頁配置, when it is the one shown: 預設 and 空白 keep their names.
    private var ownConfiguration: HomeConfigurationListing? {
        configurations.first { $0.id == configuration && !$0.id.isBuiltIn }
    }

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
                if let own = ownConfiguration {
                    Section {
                        Button { perform(.renameConfiguration(own)) } label: {
                            Label(localized("重新命名"), systemImage: "pencil")
                        }
                        Button(role: .destructive) { perform(.deleteConfiguration(own)) } label: {
                            Label(localized("刪除"), systemImage: "trash")
                        }
                    }
                }
            } label: {
                Label(localized("首頁配置"), systemImage: "square.stack")
                Text(configurations.first { $0.id == configuration }?.name ?? "")
            }
            Section {
                Button { perform(.readingLanguages) } label: {
                    Label(localized("中繼資料語言偏好推薦"), systemImage: "globe")
                }
                Button { perform(.aggregatedSources) } label: {
                    Label(localized("參與聚合的來源"), systemImage: "square.stack.3d.up")
                }
            }
            Section {
                Button { perform(.refresh) } label: {
                    Label(localized("重新整理"), systemImage: "arrow.clockwise")
                }
                Button { perform(.browser) } label: {
                    Label(localized("瀏覽器"), systemImage: "safari")
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

#Preview("編輯首頁／完成") {
    @Previewable @State var isEditing = false
    Button { withAnimation(DSAnimation.homeEditMorph) { isEditing.toggle() } } label: {
        HomeEditButtonTitle(isEditing: isEditing)
    }
    .buttonStyle(.bordered)
    .geometryGroup()
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
                                    perform: { _ in })
                }
            }
    }
}
