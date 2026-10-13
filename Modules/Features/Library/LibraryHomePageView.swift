import SwiftUI

/// A public library's own page (Phase 5 plan, decision 35): its sections, drawn as 探索's home
/// draws its own, read-only since they are made, not a 首頁配置. 範圍 showed it in 探索's place
/// until decision 36; 資源庫 opens it since 5h, pushed.
struct LibraryHomePageView: View {
    let key: SourceInstanceKey

    @EnvironmentObject private var store: BookStore

    var body: some View {
        // The store is handed down, not observed: every reading-position save publishes it.
        LibraryHomePageContent(key: key, store: store)
    }
}

private struct LibraryHomePageContent: View {
    let key: SourceInstanceKey
    let store: BookStore

    @StateObject private var model: HomeModel
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var connections = RemoteLibraryConnectionStore.shared
    @ObservedObject private var availability = PublicLibraryAvailability.shared
    @ObservedObject private var aozora = AozoraCatalogStore.shared
    @ObservedObject private var aggregation = AggregationSettingsStore.shared
    @Environment(\.explorePush) private var push
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(key: SourceInstanceKey, store: BookStore) {
        self.key = key
        self.store = store
        _model = StateObject(wrappedValue: HomeModel(
            providers: { SourceProviderRegistry.shared.homeProviders(shelf: store) },
            waitForSources: { await BookSourceStore.shared.waitUntilLoaded() }))
    }

    private var page: HomePage? {
        LibraryHomePage.page(for: key, languages: aggregation.readingLanguages.languages)
    }

    /// What the rows are built from: the page, and whether its provider serves (青空文庫 serves
    /// nothing until its catalog is read).
    private var syncKey: [AnyHashable] {
        [page, availability.isAvailable, aozora.catalog != nil]
    }

    private var groups: [HomeSectionGroup] {
        let lookup = store.copyLookup()
        return model.groups(in: key, languages: aggregation.readingLanguages,
                            libraryOrder: aggregation.settings.libraryOrder,
                            readFilter: HomeReadFilter(hides: aggregation.hidesRead, isRead: lookup.isRead))
    }

    private var title: String {
        ExploreHomeScope.name(of: key, sources: sourceStore.sources, connections: connections)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSSpacing.xxl) {
                ForEach(groups) { group in
                    HomeRowHost(group: group, store: store, aozoraIndex: aozora.catalog, model: model,
                                isEditable: false, push: { push?($0) }, openSettings: {})
                        .id(group.section.id)
                }
                footer
                    .padding(.horizontal, DSSpacing.lg)
            }
            .padding(.vertical, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            } else if !model.isReady {
                ProgressView()
            }
        }
        .refreshable {
            model.reload()
            if key.type == .aozora { await aozora.load(forceRefresh: true) }
        }
        .task(id: syncKey) {
            guard let page else { return }
            await model.sync(with: page)
        }
        .task { await aozora.load() }
        // Gutenberg's shelves load with the page, those below the fold too.
        .task(id: model.rows.map(\.id)) { model.homeAppeared(in: key) }
        .onAppear { model.reloadLocal() }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: groups.map(\.id))
    }

    /// Where the library's books come from, as its store page said it.
    @ViewBuilder
    private var footer: some View {
        switch key.type {
        case .aozora:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(.init(localized("書誌資料：青空文庫（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）")))
                if aozora.catalog != nil, case .failed = aozora.state { Text(localized("目錄更新失敗，仍顯示已儲存的目錄。")) }
            }
            .dsSectionFooter()
        case .gutenberg:
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                // Gutenberg's subjects and bookshelves, as its store page offered them.
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
}

extension EnvironmentValues {
    /// Pushes onto the stack that shows the page: 探索's or 資源庫's, each of which sets it to
    /// append to its own path.
    @Entry var explorePush: ((ExplorePush) -> Void)? = nil
}

#if DEBUG
#Preview("古騰堡") {
    NavigationStack {
        LibraryHomePageView(key: SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue))
    }
    .environmentObject(BookStore())
}
#endif
