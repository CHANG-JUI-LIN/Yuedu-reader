import SwiftUI

private typealias BookSearchResultRoute = SearchResultRoute<SearchBook>

/// Navigation route for one frozen search-result snapshot.
///
/// Value-based navigation is deliberate. The closure form
/// `NavigationLink { destination } label: { … }` builds its destination for every
/// visible row on *every* list body evaluation. Before search-row presentation
/// snapshots were introduced, that repeatedly ran audio/text inference over
/// unbounded metadata such as full-page HTML intros. Value routing also keeps
/// destination creation out of the streaming list's redraw path.
///
/// The discover page never had this: it routes through `.navigationDestination`,
/// which resolves the destination once, on tap. The route retains that tapped
/// snapshot so later `SearchAggregator` publications cannot replace the data
/// under an active iOS 17 destination.

/// Installs value routing for results where the native SwiftUI list pushes them by
/// value (iOS 18 and later). The UIKit list iOS 17 uses has no `NavigationLink`, so its
/// results go through the page's one item-based destination instead
/// (`SearchPagePush.result`). Delete the iOS 17 branch together with the native iOS 17
/// table when the deployment target reaches iOS 18.
private struct SearchResultNavigationModifier<Destination: View>: ViewModifier {
    let mode: SearchResultNavigationMode
    let destination: (BookSearchResultRoute) -> Destination

    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .selectedItem:
            content
        case .valueRoute:
            content
                .navigationDestination(
                    for: BookSearchResultRoute.self,
                    destination: destination
                )
                // The tab root's works (unified search 4c-3).
                .navigationDestination(for: UnifiedSearchResultRoute.self, destination: UnifiedSearchDestination.init(route:))
        }
    }
}

/// Everything the search page pushes through its one item-based destination.
///
/// One destination, never one per kind. TestFlight build 5 gave 最近閱讀's reader a
/// second `navigationDestination(item:)` beside the results' own, and on iOS 17 the
/// result's detail then lost its own reader push: the second time through, the manga
/// reader would not open from the detail, or would not leave it on Back (iOS 17.5
/// simulator; `DetailReaderBackSwipeUITests.testSearchTabMangaResultOpensEveryTime`).
/// With this page still reading `DismissAction`, the same build froze on the first tap of
/// a result instead (Technotes/iOS17ReaderNavigationWatchdog.md). 最近閱讀's reader is
/// no longer pushed at all — see `recentReaderRoute`.
private enum SearchPagePush: Hashable {
    /// A search result. Pushed this way on iOS 17 only; later systems push results by
    /// value from the list's `NavigationLink`.
    case result(BookSearchResultRoute)
    /// A work of the tab root's one list (unified search 4c-3), on iOS 17 likewise.
    case work(UnifiedSearchResultRoute)
}

/// Resolves a push without capturing `BookSearchView` or its live `SearchAggregator`
/// (Technotes/iOS17SearchWatchdogPostmortem.md, guardrail 3).
private struct SearchPagePushDestination: View {
    let push: SearchPagePush

    var body: some View {
        switch push {
        case .result(let route):
            SearchResultDestination(route: route)
        case .work(let route):
            UnifiedSearchDestination(route: route)
        }
    }
}

/// Resolves a frozen route without capturing `BookSearchView` or its live
/// `SearchAggregator`. The inherited store is forwarded explicitly to preserve
/// the existing detail-view environment contract.
///
/// A result opens 作品詳情 (unified library 5f-4c, decision 29: a work has one page wherever it
/// is opened from), made in `init` from the route's snapshot: SwiftUI may build the destination
/// again as the page updates, so it reads only the snapshot and an indexed source lookup. Its
/// version is drawn as the result's own page, with the work's known reading sources first in 換源.
private struct SearchResultDestination: View {
    let route: BookSearchResultRoute
    private let work: WorkDetailRoute?
    @EnvironmentObject private var bookStore: BookStore

    init(route: BookSearchResultRoute) {
        self.route = route
        work = WorkDetailRoute(searchResult: route.snapshot)
    }

    var body: some View {
        if let work {
            WorkDetailView(route: work, searchResults: [work.nodeKey: route.snapshot])
                .environmentObject(bookStore)
        } else {
            ContentUnavailableView {
                UnavailableLabel(localized("來源配置已被刪除"), systemImage: "books.vertical")
            }
        }
    }
}

/// A work of the tab root's one list (unified search 4c-3): 作品詳情 of its lead, with every
/// other member as a version and each book-source member's result for its page's 換源. Made
/// in `init` from the selection frozen at the tap, as `SearchResultDestination` is.
private struct UnifiedSearchDestination: View {
    private let parts: UnifiedSearchDestinationParts?
    @EnvironmentObject private var bookStore: BookStore

    init(route: UnifiedSearchResultRoute) {
        parts = route.snapshot.destination()
    }

    var body: some View {
        if let parts {
            WorkDetailView(route: parts.route, searchResults: parts.searchResults, searchVersions: parts.versions)
                .environmentObject(bookStore)
        } else {
            ContentUnavailableView {
                UnavailableLabel(localized("來源配置已被刪除"), systemImage: "books.vertical")
            }
        }
    }
}

/// 搜索's title: a tab root's at the root of its tab, `.inline` where it is pushed.
private struct SearchPageTitle: ViewModifier {
    let isTabRoot: Bool

    func body(content: Content) -> some View {
        if isTabRoot {
            content.rootTabTitle(localized("搜索"), onScroll: .minimizesBar)
        } else {
            content
                .navigationTitle(localized("搜索"))
                .toolbarTitleDisplayMode(.inline)
        }
    }
}

/// iOS 17's results in the native table: at the tab's root, the one list of works (unified
/// search 4c-3); elsewhere, the sources' results. A view of its own, so the search page never
/// reads the parts' changing finds (postmortem guardrail 13).
private struct IOS17SearchResults: View {
    /// The tab root's works; `nil` shows the sources' `rows` instead.
    let works: UnifiedSearchModel?
    var libraries: LibrarySearchModel? = nil
    var bibliographic: LibrarySearchModel? = nil
    let rows: [IOS17SearchResultTableRow]
    let showsLoadMore: Bool
    var sourcesSearching = false
    var sourcesPaused = false
    /// The query submitted, while it is still the one in the field.
    var submittedQuery: String? = nil
    /// The query Gutenberg is offered for; nil where the public libraries are not.
    var gutenbergQuery: String? = nil
    let onSelect: (UUID) -> Void
    let onLoadMore: () -> Void
    let submitGutenberg: () -> Void
    /// Pushes a work's 作品詳情 through the page's one item destination.
    var openWork: (UnifiedSearchResultRoute) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(FilledCoverIndex.self) private var filledCovers: FilledCoverIndex?

    var body: some View {
        let workRows = works?.rows ?? []
        IOS17SearchResultTable(
            content: IOS17SearchResultTableContent(
                rows: works == nil ? rows : [],
                showsLoadMore: showsLoadMore,
                works: works.map { works in
                    IOS17SearchWorksSection(
                        rows: workRows.map {
                            IOS17SearchResultTableRow(unified: $0, colorScheme: colorScheme,
                                                      filledCover: { filledCovers?.path(for: $0) })
                        },
                        status: UnifiedSearchStatus(
                            hasRows: !workRows.isEmpty, isSearching: sourcesSearching || works.isResolving,
                            isPaused: sourcesPaused,
                            othersSearching: (libraries?.isSearching ?? false) || (bibliographic?.isSearching ?? false),
                            submittedQuery: submittedQuery,
                            failures: (libraries?.failures ?? []) + (bibliographic?.failures ?? [])),
                        offersGutenberg: gutenbergQuery != nil,
                        query: gutenbergQuery ?? ""
                    )
                }
            ),
            onSelect: onSelect,
            onLoadMore: onLoadMore,
            onSearchGutenberg: submitGutenberg,
            onSelectWork: { id in
                guard let row = workRows.first(where: { $0.id == id }) else {
                    AppLogger.error("⟐ search tap found no work", context: ["id": id.uuidString, "rows": workRows.count])
                    return
                }
                openWork(UnifiedSearchResultRoute(id: row.id, snapshot: row.selection))
            }
        )
    }
}

/// The tab root's one list on iOS 18 and later: its status computed here, so the search page
/// never reads the parts' changing finds (guardrail 13).
@available(iOS 18.0, *)
private struct ModernUnifiedSearchRows: View {
    let works: UnifiedSearchModel
    let libraries: LibrarySearchModel
    let bibliographic: LibrarySearchModel
    let sourcesSearching: Bool
    let sourcesPaused: Bool
    let submittedQuery: String?
    let canLoadMore: Bool
    let loadMore: () -> Void
    let gutenbergQuery: String?
    let submitGutenberg: () -> Void

    var body: some View {
        UnifiedSearchRows(
            model: works,
            status: UnifiedSearchStatus(
                hasRows: !works.rows.isEmpty, isSearching: sourcesSearching || works.isResolving,
                isPaused: sourcesPaused, othersSearching: libraries.isSearching || bibliographic.isSearching,
                submittedQuery: submittedQuery, failures: libraries.failures + bibliographic.failures),
            canLoadMore: canLoadMore, loadMore: loadMore,
            gutenbergQuery: gutenbergQuery, submitGutenberg: submitGutenberg)
    }
}

/// The results' scroll edge: a tab root's under the 搜索 tab's minimizing bar, the app's
/// soft edge where the page is pushed.
private struct SearchResultsScrollEdges: ViewModifier {
    let isTabRoot: Bool

    func body(content: Content) -> some View {
        if isTabRoot {
            content.rootTabSearchScrollEdges()
        } else {
            content.softScrollEdges()
        }
    }
}

// MARK: - Book Search View

struct BookSearchView: View {
    var initialQuery: String = ""
    /// A scope for this search page only, never saved — Legado's 搜索 on one source
    /// (`searchScope.update(scope, save = false)`). `nil` uses the saved scope.
    var sessionScope: SearchSourceScope?
    /// The 搜索 tab's own root, which carries a tab root's title; pushed from elsewhere,
    /// the page is `.inline` like any other.
    var isTabRoot = false

    @EnvironmentObject var bookStore: BookStore
    @StateObject private var aggregator = SearchAggregator()
    @StateObject private var scopeStore = SearchSourceScopeStore.shared
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    // No `@Environment(\.dismiss)` here: iOS 17 replaces DismissAction over and over
    // while a result's detail is pushed above this page, and every replacement re-runs
    // this body (Technotes/iOS17ReaderNavigationWatchdog.md).
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab's stack, which Gutenberg's results are pushed onto. A reference that never
    /// changes (postmortem guardrail 13).
    @Environment(\.searchTabNavigation) private var tabNavigation

    @State private var query = ""
    @State private var errorMsg: String? = nil
    @State private var submittedQuery = ""
    @State private var showsSourceScopeSheet = false
    @State private var needsSearchResubmission = false
    /// The session scope as the reader changes it on this page.
    @State private var editedSessionScope: SearchSourceScope?
    /// What this page has pushed through its one item-based destination: a result on
    /// iOS 17.
    @State private var pushed: SearchPagePush?
    /// A book opened from 最近閱讀, full screen over the search, as Apple Books opens a
    /// book from its search; closing it comes back to the list as it was left. 最近閱讀
    /// shows only while the search field is active, and pushed onto this stack the reader
    /// lost its hidden navigation bar: the active `UISearchController` puts back the bar
    /// it had collapsed as the push starts (`_navigationControllerWillShowViewController:`,
    /// right after SwiftUI hid it), which left a bar-high band above the classic top bar.
    @State private var recentReaderRoute: DetailReaderRoute?
    /// The shelf's matches as you type (unified search 4b-1); read only by the views that
    /// draw them.
    @State private var shelfSearch = ShelfSearchModel()
    /// The saved OPDS and Calibre libraries' answers (unified search 4b-2) and the modules' (Phase
    /// 6g), asked on submit.
    @State private var librarySearch = LibrarySearchModel()
    /// Open Library's, asked on submit when 搜尋時也查 Open Library is on (4b-3).
    @State private var openLibrarySearch = LibrarySearchModel.openLibrary()
    /// Every part's finds merged into one list of works (4c-3); read only by the views that
    /// draw it.
    @State private var unifiedSearch = UnifiedSearchModel()
    @AppStorage(RecentSearchQueries.storageKey) private var recentQueries = RecentSearchQueries()

    /// The scope this page searches: its own session scope, else the saved one.
    private var activeScope: SearchSourceScope {
        editedSessionScope ?? sessionScope ?? scopeStore.scope
    }

    var enabledSources: [BookSource] { sourceStore.enabledSources }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only the tab's root searches the public libraries too: its stack carries the store's
    /// pages and 作品詳情. Never in China.
    private var offersPublicLibraries: Bool {
        isTabRoot && tabNavigation != nil && availability.isAvailable
    }

    /// One search for all (Phase 5 plan decision 17, as amended 2026-10-11; unified search
    /// 4b, 4c-3): one list of works from the shelf, the saved libraries, 青空文庫 where the
    /// public libraries are offered, the sources and Open Library, as soon as there is a
    /// query. Only the tab's root: its stack carries 作品詳情.
    private var showsCombinedResults: Bool {
        isTabRoot && tabNavigation != nil && !trimmedQuery.isEmpty
    }

    /// What the sources' part says while it has no result.
    private var sourcesNotice: String? {
        guard aggregator.results.isEmpty else { return nil }
        if aggregator.isSearching { return localized("搜索中…") }
        if aggregator.isPaused { return localized("已暫停") }
        if shouldShowEmptyResult { return String(format: localized("沒有找到「%@」"), submittedQuery) }
        return nil
    }

    private var shouldShowEmptyResult: Bool {
        !submittedQuery.isEmpty && trimmedQuery == submittedQuery
    }

    var body: some View {
        AdaptiveContentContainer(maxWidth: DSLayout.readableExpandedWidth) {
            VStack(spacing: 0) {
                // No rule under the scope row: as in Apple Books' search, the content
                // starts below the controls, and on iOS 26 the list's soft scroll edge
                // marks where it slides out of view.
                if !enabledSources.isEmpty {
                    sourceScopeBar
                }

                ZStack {
                    if showsCombinedResults || !aggregator.results.isEmpty {
                        resultList
                    } else if aggregator.isSearching {
                        // Progress and the pause control sit in the scope row above.
                        ProgressView(localized("搜索中…"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .rootTabTitleScrollAnchor()
                    } else if aggregator.isPaused {
                        pausedPlaceholder
                            .rootTabTitleScrollAnchor()
                    } else if shouldShowEmptyResult {
                        emptyResultView
                            .rootTabTitleScrollAnchor()
                    } else {
                        SearchIdleContent(
                            isQueryEmpty: trimmedQuery.isEmpty,
                            onSearch: searchAgain,
                            onOpenBook: openRecentBook
                        ) {
                            hintView
                                .rootTabTitleScrollAnchor()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PageBackgroundView(scope: .search))
            .background {
                UnifiedSearchFeed(query: showsCombinedResults ? trimmedQuery : "", shelf: shelfSearch,
                                  libraries: librarySearch, bibliographic: openLibrarySearch, aggregator: aggregator,
                                  offersPublicLibraries: offersPublicLibraries, model: unifiedSearch)
            }
        }
        .background(PageBackgroundView(scope: .search).ignoresSafeArea())
        .pageBackgroundToolbar(for: .search)
        .modifier(SearchPageTitle(isTabRoot: isTabRoot))
        // Declared here, outside the lazy result containers, so the navigation
        // stack can always see the active destination.
        .modifier(
            SearchResultNavigationModifier(
                mode: .current,
                destination: SearchResultDestination.init(route:)
            )
        )
        // The page's only item-based destination (see `SearchPagePush`).
        .navigationDestination(item: $pushed, destination: SearchPagePushDestination.init(push:))
        .fullScreenCover(item: $recentReaderRoute) { route in
            BookReaderView(bookId: route.id)
                .environmentObject(bookStore)
                .environment(\.readerNavigator, nil)
        }
        // At the tab root on iOS 27 the field rises to the top as the bar slides away.
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: localized("輸入書名或作者")
        )
        .sheet(isPresented: $showsSourceScopeSheet) {
            SearchSourceScopeSheet(
                enabledSources: enabledSources,
                initialScope: activeScope,
                onSave: applySearchSourceScope
            )
        }
        .onSubmit(of: .search) { submit() }
        .task(id: showsCombinedResults ? trimmedQuery : "") {
            await shelfSearch.search(showsCombinedResults ? trimmedQuery : "", in: bookStore)
        }
        .task {
            // The modules a submit asks are known only once their library has been read, and
            // 搜索 may be the first page opened.
            await RuleModuleLibrary.shared.loadIfNeeded()
        }
        .task(id: offersPublicLibraries) {
            // 青空文庫's catalog may not have been read yet when 探索 was never opened.
            if offersPublicLibraries, AozoraCatalogStore.shared.catalog == nil {
                await AozoraCatalogStore.shared.load()
            }
        }
        .onChange(of: query) { _, newValue in
            // Mirror the old clear button: emptying the field resets the search.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submittedQuery = ""
                needsSearchResubmission = false
                aggregator.cancelAndClear()
                librarySearch.clear()
                openLibrarySearch.clear()
                unifiedSearch.clear()
            }
        }
        .alert(
            localized("搜索失敗"),
            isPresented: Binding(get: { errorMsg != nil }, set: { if !$0 { errorMsg = nil } })
        ) {
            Button(localized("確認")) { errorMsg = nil }
        } message: {
            Text(errorMsg ?? "")
        }
        .onAppear {
            aggregator.setResultPresentationActive(scenePhase == .active)
            if !initialQuery.isEmpty && query.isEmpty {
                query = initialQuery
                doSearch()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            aggregator.setResultPresentationActive(phase == .active)
        }
    }

    // Shown when a search was paused before any result came back. The ring in the
    // scope row above carries the search on.
    private var pausedPlaceholder: some View {
        ContentUnavailableView {
            UnavailableLabel(localized("已暫停"), systemImage: "pause.circle")
        } description: {
            Text(localized("點擊繼續搜索剩餘來源配置"))
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    // MARK: Source Scope

    /// The scope capsule, and at the other end, while a search runs or is paused, its
    /// progress ring — the one pause / resume control on the page. Manual companion to
    /// the network-settings auto-pause: tap to pause the in-flight search (battery,
    /// traffic) and again to resume the sources not yet asked. Auto-pause lands in the
    /// same paused state, so the same ring resumes an automatically paused search.
    private var sourceScopeBar: some View {
        HStack {
            SearchSourceScopeCapsule(
                title: sourceScopeSummary,
                isCustom: activeScope.mode == .custom,
                action: { showsSourceScopeSheet = true }
            )
            Spacer(minLength: DSSpacing.sm)
            if isSearchInProgress {
                SearchProgressControl(
                    progress: aggregator.progress,
                    isPaused: aggregator.isPaused,
                    onPause: { aggregator.pause() },
                    onResume: { aggregator.resume() }
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.xs)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: isSearchInProgress)
    }

    private var isSearchInProgress: Bool {
        aggregator.isSearching || aggregator.isPaused
    }

    private var sourceScopeSummary: String {
        switch activeScope.mode {
        case .all:
            return localized("全部來源配置")
        case .custom:
            return String(
                format: localized("已選 %d 個來源配置"),
                activeScope.resolvedSources(from: enabledSources).count
            )
        }
    }

    // MARK: Result List
    @ViewBuilder
    private var resultList: some View {
        if #available(iOS 18.0, *) {
            modernResultList
        } else {
            iOS17ResultList
        }
    }

    @available(iOS 18.0, *)
    private var modernResultList: some View {
        List {
            if showsCombinedResults {
                ModernUnifiedSearchRows(
                    works: unifiedSearch, libraries: librarySearch, bibliographic: openLibrarySearch,
                    sourcesSearching: aggregator.isSearching, sourcesPaused: aggregator.isPaused,
                    submittedQuery: shouldShowEmptyResult ? submittedQuery : nil,
                    canLoadMore: canLoadMore, loadMore: { aggregator.loadMore() },
                    gutenbergQuery: offersPublicLibraries ? trimmedQuery : nil, submitGutenberg: submitGutenberg)
            } else {
                sourceRows
            }
        }
        .modifier(SearchResultsScrollEdges(isTabRoot: isTabRoot))
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Apple Books' result rows carry no disclosure chevron; the whole row opens the book.
        .navigationLinkIndicatorVisibility(.hidden)
    }

    /// The sources' results where the page is not the tab's root, 載入更多, and while there is
    /// no result what the search is doing.
    @available(iOS 18.0, *)
    @ViewBuilder
    private var sourceRows: some View {
        if let sourcesNotice {
            Text(sourcesNotice)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden, edges: .top)
                .background { Color.clear.rootTabTitleScrollAnchor() }
        }
        ForEach(aggregator.results) { book in
            resultLink(for: book)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: DSLayout.searchListHorizontalInset,
                bottom: 0,
                trailing: DSLayout.searchListHorizontalInset
            ))
            .listRowBackground(Color.clear)
            // No rule over the first result: the scope row above has none either.
            .listRowSeparator(
                book.id == aggregator.results.first?.id ? .hidden : .automatic,
                edges: .top
            )
            .background {
                // The first result measures the list's scroll for the 搜索 tab's title.
                if book.id == aggregator.results.first?.id {
                    Color.clear.rootTabTitleScrollAnchor()
                }
            }
        }

        // 載入更多: fetch the next result page from every source that
        // answered the last round and hasn't been exhausted yet.
        if canLoadMore {
            loadMoreButton
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var iOS17ResultList: some View {
        IOS17SearchResults(
            works: showsCombinedResults ? unifiedSearch : nil,
            libraries: librarySearch,
            bibliographic: openLibrarySearch,
            rows: showsCombinedResults ? [] : aggregator.results.map(IOS17SearchResultTableRow.init(searchBook:)),
            showsLoadMore: canLoadMore,
            sourcesSearching: aggregator.isSearching,
            sourcesPaused: aggregator.isPaused,
            submittedQuery: shouldShowEmptyResult ? submittedQuery : nil,
            gutenbergQuery: offersPublicLibraries ? trimmedQuery : nil,
            onSelect: { id in
                guard let book = aggregator.results.first(where: { $0.id == id }) else {
                    // The row on screen is no longer among the results, so the tap opens
                    // nothing; logged rather than dropped without a trace.
                    AppLogger.error(
                        "⟐ search tap found no result",
                        context: ["id": id.uuidString, "results": aggregator.results.count]
                    )
                    return
                }
                pushed = .result(BookSearchResultRoute(id: id, snapshot: book))
            },
            onLoadMore: {
                aggregator.loadMore()
            },
            submitGutenberg: submitGutenberg,
            openWork: { route in pushed = .work(route) }
        )
    }

    private func resultLink(for book: SearchBook) -> some View {
        NavigationLink(
            value: BookSearchResultRoute(id: book.id, snapshot: book)
        ) {
            AggregatedResultRow(book: book)
        }
    }

    private var canLoadMore: Bool {
        aggregator.hasMoreResults && !aggregator.isSearching && !aggregator.isPaused
    }

    private var loadMoreButton: some View {
        Button {
            aggregator.loadMore()
        } label: {
            Label(localized("載入更多"), systemImage: "arrow.down.circle")
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.accent)
                .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
        }
    }

    // MARK: Empty State
    private var emptyResultView: some View {
        ContentUnavailableView {
            UnavailableLabel(
                String(format: localized("沒有找到「%@」"), submittedQuery),
                systemImage: "magnifyingglass"
            )
        } description: {
            Text(localized("嘗試換個關鍵字，或切換來源配置"))
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    @ViewBuilder
    private var hintView: some View {
        if enabledSources.isEmpty, !offersPublicLibraries {
            ContentUnavailableView {
                UnavailableLabel(localized("尚未設置來源配置"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(localized("請先在來源配置管理中新增並啟用來源配置"))
                    .foregroundStyle(DSColor.textSecondary)
            }
        } else {
            ContentUnavailableView {
                UnavailableLabel(
                    needsSearchResubmission
                        ? localized("搜索範圍已更新，請再次搜索")
                        : localized("輸入書名或作者搜索"),
                    systemImage: "text.magnifyingglass"
                )
            }
        }
    }

    // MARK: Search Logic
    private func applySearchSourceScope(_ newScope: SearchSourceScope) {
        guard newScope != activeScope else { return }
        if sessionScope != nil {
            editedSessionScope = newScope
        } else {
            scopeStore.save(newScope)
        }
        submittedQuery = ""
        needsSearchResubmission = !trimmedQuery.isEmpty
        aggregator.cancelAndClear()
    }

    private func doSearch() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        let sources = activeScope.resolvedSources(from: enabledSources)
        guard !sources.isEmpty else {
            errorMsg = activeScope.mode == .custom
                ? localized("請至少選擇一個可用來源配置")
                : localized("沒有可用的來源配置，請先啟用來源配置")
            return
        }

        needsSearchResubmission = false
        submittedQuery = q
        recentQueries = recentQueries.recording(q)
        aggregator.search(query: q, sources: sources)
    }

    /// The keyboard's Search: the saved libraries and the sources; with neither, Gutenberg
    /// where it is offered. Ignored while the source library is still being read, so a large
    /// library is not taken for none.
    private func submit() {
        // At the tab's root, the parts that answer on submit are asked first, whatever the
        // sources do.
        let atRoot = isTabRoot && tabNavigation != nil
        var othersAnswer = false
        if atRoot, !trimmedQuery.isEmpty {
            for part in [librarySearch, openLibrarySearch] where part.isAvailable {
                part.start(trimmedQuery, store: bookStore)
                othersAnswer = true
            }
        }
        switch SearchSubmitPlan.decide(hasSources: !enabledSources.isEmpty, sourcesLoaded: sourceStore.isLoaded,
                                       othersAnswer: othersAnswer, offersPublicLibraries: offersPublicLibraries) {
        case .sources:
            doSearch()
        case .othersOnly:
            // Nothing to ask of the sources; the list's empty state waits for the others.
            submittedQuery = trimmedQuery
            recentQueries = recentQueries.recording(trimmedQuery)
        case .gutenberg:
            submitGutenberg()
        case .waitForSources:
            break
        }
    }

    /// Gutenberg is asked only here, on an explicit submit (its terms; `PublicLibraries.md`).
    private func submitGutenberg() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        recentQueries = recentQueries.recording(q)
        // By value, onto the path a book in it pushes 作品詳情 onto (see `SearchTabNavigation`).
        tabNavigation?.path.append(OPDSFeedRoute(
            catalogID: PublicLibraryID.gutenberg.rawValue,
            url: PublicLibrary.gutenbergSearchURL(query: q).absoluteString,
            title: String(q.prefix(500)), presentation: .storefront))
    }

    /// 最近搜索: the same search again, as if typed and submitted.
    private func searchAgain(_ recent: String) {
        query = recent
        submit()
    }

    /// 最近閱讀: back into the book where it was left, moved to the front of 最近閱讀
    /// as opening it from the shelf does.
    private func openRecentBook(_ book: ReadingBook) {
        bookStore.updateLastOpened(bookId: book.id)
        recentReaderRoute = DetailReaderRoute(id: book.id)
    }
}

// MARK: - Aggregated Result Row

/// One search result as Apple Books lists one in its search (`SearchBookListRow`): the
/// cover, the title with the grey 有聲書 tag on audiobooks, the author, and the kind and
/// source count in grey — 「小說 · 3 源」. Mirrors `IOS17SearchResultTableCell`, which draws
/// the same row in UIKit on iOS 17.
struct AggregatedResultRow: View {
    let book: SearchBook

    var body: some View {
        SearchBookListRow(content: SearchBookListRowContent(result: book)) {
            BookCoverImage(
                coverURL: book.coverUrl,
                title: book.displayName,
                author: book.author
            )
        }
    }
}

// MARK: - OnlineBook Identifiable (for sheet item)
extension OnlineBook: Hashable {
    static func == (lhs: OnlineBook, rhs: OnlineBook) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - SearchBook Identifiable (for sheet item)
extension SearchBook: Hashable {
    static func == (lhs: SearchBook, rhs: SearchBook) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#Preview("搜索") {
    NavigationStack {
        BookSearchView()
            .environmentObject(BookStore())
    }
}
