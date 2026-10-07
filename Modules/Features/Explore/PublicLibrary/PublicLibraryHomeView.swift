import SwiftUI

struct PublicLibraryHomeView: View {
    var modeMenu: ExploreModeMenu? = nil
    @State private var path = NavigationPath()

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
            }
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
