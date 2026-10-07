import SwiftUI

struct PublicLibraryHomeView: View {
    var modeMenu: ExploreModeMenu? = nil
    @State private var path = NavigationPath()
    @State private var query = ""
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trimmedQuery.isEmpty { librarySections }
                else {
                    PublicLibrarySearchResults(query: trimmedQuery, index: aozora.catalog, submitGutenberg: submitSearch)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: localized("搜尋公有書庫"))
            .onSubmit(of: .search, submitSearch)
            .task { await aozora.load() }
            .refreshable { await aozora.load(forceRefresh: true) }
            .navigationDestination(for: OPDSFeedRoute.self) { OPDSFeedView(route: $0) }
            .navigationDestination(for: RemoteLibraryBookRoute.self) { RemoteLibraryBookDetailView(item: $0.item) }
            .listStyle(.insetGrouped)
            .rootTabSearchScrollEdges()
            .themedAppSurface(for: .explore)
            .rootTabTitle(localized("探索"), onScroll: .minimizesBar)
            .toolbar {
                if let modeMenu {
                    ToolbarItem(placement: .topBarTrailing) { modeMenu }
                }
            }
        }
    }

    private func submitSearch() {
        guard !trimmedQuery.isEmpty else { return }
        path.append(OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                                 url: PublicLibrary.gutenbergSearchURL(query: trimmedQuery).absoluteString,
                                 title: String(trimmedQuery.prefix(500))))
    }

    @ViewBuilder private var librarySections: some View {
                Section {
                    ForEach(GutenbergShelf.shelves(language: Bundle.main.preferredLocalizations.first ?? "en")) { shelf in
                        NavigationLink(value: OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
                                                          url: shelf.url.absoluteString, title: localized(shelf.titleKey))) {
                            Label(localized(shelf.titleKey), systemImage: shelf.symbol)
                        }
                    }
                } header: {
                    Text(localized("Project Gutenberg"))
                } footer: {
                    Text(localized("Project Gutenberg 的書在美國屬於公有領域；所在地區的著作權規定可能不同。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
                .rootTabTitleScrollAnchor()
                if let index = aozora.catalog {
                    Section {
                        ForEach(AozoraBrowseMode.allCases) { mode in
                            NavigationLink { AozoraCatalogView(index: index, mode: mode) } label: {
                                Label(localized(mode.titleKey), systemImage: mode.symbol)
                            }
                        }
                        if aozora.isRefreshing { ProgressView(localized("正在更新目錄")) }
                        if case .failed = aozora.state {
                            Button(localized("重試")) { Task { await aozora.load(forceRefresh: true) } }
                                .disabled(aozora.isRefreshing)
                        }
                    } header: { Text(localized("青空文庫")) } footer: {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(.init(localized("書誌資料：青空文庫（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）")))
                            if case .failed = aozora.state {
                                Text(localized("目錄更新失敗，仍顯示已儲存的目錄。"))
                            }
                        }.dsSectionFooter()
                    }.interfaceSectionSurface()
                }
    }

}

#Preview { PublicLibraryHomeView().environmentObject(BookStore()) }
