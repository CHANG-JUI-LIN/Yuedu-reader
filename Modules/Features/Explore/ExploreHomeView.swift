import Combine
import SwiftUI

// MARK: - Explore Home

/// The landing screen of the 探索 (Explore) tab, a grid of tiles as Apple Music lays out
/// its browse categories, or a list of cards: 瀏覽器 opens the in-app browser as it was
/// left, each of the reader's custom pages gathers categories of any sources in the
/// layouts they chose (＋ names a new one; a long press renames or deletes it), and each
/// explore source opens its whole discover page. A long press on a source offers the
/// actions Legado's explore page does. The browser opens full screen, as the reader does. The search field narrows
/// the sources as Legado's explore search does, in the page's own layout; books are
/// searched from the 搜索 tab.
///
/// On iOS 27 the bar, title and buttons together, slides away as the page scrolls and
/// the search field rises to the top in its place, as in Apple Music (`.minimizesBar`).
struct ExploreHomeView: View {
    @EnvironmentObject private var store: BookStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @AppStorage(ExploreSettings.showsGridKey) private var showsGrid = true
    @AppStorage(ExploreSettings.gridColumnCountKey) private var gridColumnCount = ExploreGridDensity.default.rawValue
    @AppStorage(ExploreSettings.landingKey) private var landing = ExploreLanding.off.rawValue
    /// The browser's page and history, kept by `BrowserView` across visits.
    @ObservedObject var browser: BrowserState
    var modeMenu: ExploreModeMenu? = nil

    @State private var query = ""
    @State private var exploreSources: [BookSource] = []
    @State private var group: String?
    @State private var showSourceManager = false
    @State private var navigation = ExploreNavigationPath()
    @State private var sourceActionSheet: BookSourceActionSheet?
    @State private var sourcePendingDeletion: BookSource?
    @State private var browserPresentation: BrowserPresentation?
    @State private var showsSettings = false
    /// 首屏配置 opens its page once, the first time 探索 shows; going back stays here.
    @State private var appliedLanding = false
    @ObservedObject private var pageStore = CustomExplorePageStore.shared
    /// 新增自訂頁's or 重新命名's name prompt, and the name typed into it.
    @State private var pageNamePrompt: PageNamePrompt?
    @State private var pageName = ""
    @State private var pagePendingDeletion: CustomExplorePage?

    private struct BrowserPresentation: Identifiable {
        let id = UUID()
        let entry: BrowserEntry
    }

    /// One alert for both prompts: two on one view compete for one presenter.
    private enum PageNamePrompt: Identifiable {
        case create
        case rename(CustomExplorePage)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let page): page.id.uuidString
            }
        }

        var title: String {
            switch self {
            case .create: localized("新增自訂頁")
            case .rename: localized("重新命名")
            }
        }
    }

    private var groups: [String] {
        Array(Set(exploreSources.flatMap(Self.groupNames))).sorted()
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFilteringSources: Bool { !trimmedQuery.isEmpty }

    private var visibleSources: [BookSource] {
        Self.sources(exploreSources, inGroup: group, matching: trimmedQuery)
    }

    /// The sources in `group` (all of them when `nil`) whose name or group holds
    /// `query` — Legado's explore search (`BookSourceDao.flowExplore(key)`).
    static func sources(_ sources: [BookSource], inGroup group: String?, matching query: String) -> [BookSource] {
        sources.filter { source in
            if let group, !groupNames(of: source).contains(group) { return false }
            return query.isEmpty
                || source.bookSourceName.localizedStandardContains(query)
                || source.bookSourceGroup.localizedStandardContains(query)
        }
    }

    private static func groupNames(of source: BookSource) -> [String] {
        source.bookSourceGroup
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The grid the reader chose, or the list. At accessibility text sizes a tile cannot
    /// hold its name, so the page is the list whatever the setting.
    private var entryLayout: ExploreEntryLabel.Layout {
        guard showsGrid, !dynamicTypeSize.isAccessibilitySize else { return .list }
        return .grid(.fitting(gridColumnCount, dynamicTypeSize: dynamicTypeSize))
    }

    var body: some View {
        NavigationStack(path: $navigation.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    // A search looks through the sources alone.
                    if !isFilteringSources {
                        entries {
                            browserEntry
                            ForEach(pageStore.pages) { page in
                                NavigationLink(value: ExploreNavigationRoute.customPage(id: page.id)) {
                                    ExploreEntryLabel(name: page.name, layout: entryLayout)
                                }
                                .buttonStyle(ExploreTileButtonStyle())
                                .accessibilityLabel(page.name)
                                .contextMenu { pageActions(page) }
                            }
                        }
                        .confirmationDialog(
                            String(format: localized("刪除「%@」？"), pagePendingDeletion?.name ?? ""),
                            isPresented: Binding(
                                get: { pagePendingDeletion != nil },
                                set: { if !$0 { pagePendingDeletion = nil } }
                            ),
                            titleVisibility: .visible,
                            presenting: pagePendingDeletion
                        ) { page in
                            Button(localized("刪除"), role: .destructive) { deletePage(page) }
                            Button(localized("取消"), role: .cancel) {}
                        } message: { _ in
                            Text(localized("頁面裡的元件會一起刪除。"))
                        }
                    }
                    sourcesBlock
                }
                .alert(
                    pageNamePrompt?.title ?? "",
                    isPresented: Binding(
                        get: { pageNamePrompt != nil },
                        set: { if !$0 { pageNamePrompt = nil } }
                    ),
                    presenting: pageNamePrompt
                ) { prompt in
                    TextField(localized("名稱"), text: $pageName)
                    switch prompt {
                    case .create:
                        Button(localized("新建")) { pageStore.createPage(named: pageName) }
                    case .rename(let page):
                        Button(localized("確定")) { pageStore.renamePage(id: page.id, to: pageName) }
                    }
                    Button(localized("取消"), role: .cancel) {}
                }
                // The page's full width even when a search finds no source: while the
                // search is active the scroll view takes its content's width, and an
                // empty stack left the page background and 「沒有結果」 a 32pt strip
                // (iOS 27 simulator).
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)
                .animation(reduceMotion ? nil : DSAnimation.standard, value: entryLayout)
                .rootTabTitleScrollAnchor()
            }
            .overlay {
                if isFilteringSources && !exploreSources.isEmpty && visibleSources.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .rootTabSearchScrollEdges()
            .scrollDismissesKeyboard(.immediately)
            .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
            .pageBackgroundToolbar(for: .explore)
            .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
            .toolbar {
                if let modeMenu {
                    ToolbarItem(placement: .topBarTrailing) { modeMenu }
                }
                if groups.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) { groupMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pageName = ""
                        pageNamePrompt = .create
                    } label: {
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
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜索來源配置")
            )
            .sheet(isPresented: $showsSettings) {
                ExploreSettingsSheet(sources: exploreSources)
            }
            .onAppear(perform: applyLandingIfNeeded)
            .onReceive(sourceStore.$sources) { _ in
                exploreSources = DiscoverViewModel.exploreSources(in: sourceStore)
                if let group, !groups.contains(group) { self.group = nil }
                applyLandingIfNeeded()
            }
            .sheet(isPresented: $showSourceManager) {
                // BookSourceListView already provides its own NavigationStack; wrapping
                // it in another NavigationStack stacks two nav bars (duplicate title on
                // iOS 18). Present it directly, matching SettingsView.
                BookSourceListView()
            }
            .bookSourceActionSheets(sheet: $sourceActionSheet, pendingDeletion: $sourcePendingDeletion)
            .fullScreenCover(item: $browserPresentation) { presentation in
                NavigationStack {
                    BrowserPage(browser: browser, entry: presentation.entry)
                }
                .environmentObject(store)
            }
            .navigationDestination(for: ExploreNavigationRoute.self, destination: destination)
        }
    }

    // MARK: Entries

    /// Entries laid out as the page is: tiles so many to a row, or cards one under another.
    @ViewBuilder
    private func entries<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch entryLayout {
        case .grid(let density):
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: DSSpacing.md),
                    count: density.rawValue
                ),
                spacing: DSSpacing.md,
                content: content
            )
        case .list:
            LazyVStack(spacing: DSSpacing.md, content: content)
        }
    }

    /// The browser as it was left — its page, or its start page when no page is open.
    private var browserEntry: some View {
        Button { openBrowser(.resume) } label: {
            ExploreEntryLabel(
                title: localized("瀏覽器"),
                artwork: .symbol("safari"),
                layout: entryLayout
            )
        }
        .buttonStyle(ExploreTileButtonStyle())
    }

    private func openBrowser(_ entry: BrowserEntry) {
        browserPresentation = BrowserPresentation(entry: entry)
    }

    /// A custom page's long-press actions.
    @ViewBuilder
    private func pageActions(_ page: CustomExplorePage) -> some View {
        Button {
            pageName = page.name
            pageNamePrompt = .rename(page)
        } label: {
            Label(localized("重新命名"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            pagePendingDeletion = page
        } label: {
            Label(localized("刪除"), systemImage: "trash")
        }
    }

    /// Deletes the page; 首屏配置 set to it goes back to off.
    private func deletePage(_ page: CustomExplorePage) {
        if ExploreLanding(rawValue: landing) == .customPage(id: page.id) {
            landing = ExploreLanding.off.rawValue
        }
        pageStore.deletePage(id: page.id)
    }

    /// The sources, or how to add some. A search that finds none leaves this out for
    /// the search's own empty state.
    @ViewBuilder
    private var sourcesBlock: some View {
        if exploreSources.isEmpty || !visibleSources.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                Text(group ?? localized("來源配置"))
                    .font(DSFont.title2.weight(.bold))
                    .foregroundStyle(DSColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if exploreSources.isEmpty {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        Text(localized("尚未啟用支援發現的來源配置"))
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                        Button(localized("前往來源配置管理"), action: openSourceManager)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    entries {
                        ForEach(visibleSources) { source in
                            NavigationLink(value: ExploreNavigationRoute.source(sourceURL: source.bookSourceUrl)) {
                                ExploreEntryLabel(source: source, layout: entryLayout)
                            }
                            .buttonStyle(ExploreTileButtonStyle())
                            .accessibilityLabel(source.bookSourceName)
                            .accessibilityIdentifier("explore.source.\(source.bookSourceName)")
                            .contextMenu { sourceActions(source) }
                        }
                    }
                }
            }
        }
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
            onSearch: { navigation.push(.searchInSource(sourceURL: source.bookSourceUrl)) },
            onRefresh: nil,
            onSetVariable: { sourceActionSheet = .variable(source) },
            onDelete: { sourcePendingDeletion = source }
        )
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
            Image(
                systemName: group == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("分組"))
        .accessibilityValue(group ?? localized("全部"))
    }

    /// 首屏配置: the page 探索 opens straight onto, pushed the first time 探索 shows. A
    /// source's page waits for 探索's sources to load, so it never opens on one that only
    /// looks deleted because the list was not there yet; a source that has since gone
    /// opens nothing.
    private func applyLandingIfNeeded() {
        guard !appliedLanding, navigation.path.isEmpty else { return }
        switch ExploreLanding(rawValue: landing) {
        case .off:
            appliedLanding = true
        case .customPage(let id):
            appliedLanding = true
            if pageStore.page(id: id) != nil {
                navigation.push(.customPage(id: id))
            }
        case .source(let url):
            guard !exploreSources.isEmpty else { return }
            appliedLanding = true
            if exploreSources.contains(where: { $0.bookSourceUrl == url }) {
                navigation.push(.source(sourceURL: url))
            }
        }
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(_ route: ExploreNavigationRoute) -> some View {
        switch route {
        case .source(let sourceURL):
            if let source = sourceStore.sources.first(where: { $0.bookSourceUrl == sourceURL }) {
                ExploreSourcePage(source: source) { address in
                    openBrowser(.open(address))
                }
            } else {
                deletedSourceState
            }
        case .customPage(let id):
            CustomExplorePageView(pageID: id)
        case .customPageEditor(let id):
            CustomExplorePageEditor(pageID: id)
        case .book(let book):
            OnlineBookDetailDestination(.book(book)).environmentObject(store)
        case .sourceCategory(let reference):
            if let source = reference.source, let item = reference.cardItem {
                DiscoverCategoryView(
                    section: DiscoverShowcaseSection(
                        item: item,
                        coverBaseURL: source.bookSourceUrl,
                        coverHeaders: source.parsedHeaders
                    ),
                    source: source
                )
            } else {
                deletedSourceState
            }
        case .searchInSource(let sourceURL):
            SearchView(sessionScope: SearchSourceScope(
                mode: .custom, selectedSourceURLs: [sourceURL]
            ))
            .environmentObject(store)
        case .sourceManager:
            BookSourceListView(embedsNavigationStack: false)
        }
    }

    private var deletedSourceState: some View {
        ContentUnavailableView {
            UnavailableLabel(localized("來源配置已被刪除"), systemImage: "books.vertical")
        }
    }

    /// 書源管理: pushed before iOS 18 so its importers have a first-level presenter,
    /// a sheet afterwards (`BookSourceManagementPresentationPolicy`).
    private func openSourceManager() {
        if BookSourceManagementPresentationPolicy.prefersNavigationDestination {
            navigation.push(.sourceManager)
        } else {
            showSourceManager = true
        }
    }
}

#Preview {
    ExploreHomeView(browser: BrowserState())
        .environmentObject(BookStore())
}
