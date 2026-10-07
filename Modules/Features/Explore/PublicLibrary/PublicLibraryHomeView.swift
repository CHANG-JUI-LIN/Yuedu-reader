import SwiftUI

struct PublicLibraryHomeView: View {
    var modeMenu: ExploreModeMenu? = nil
    @State private var path = NavigationPath()
    @ObservedObject private var aozora = AozoraCatalogStore.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
}

#Preview { PublicLibraryHomeView().environmentObject(BookStore()) }
