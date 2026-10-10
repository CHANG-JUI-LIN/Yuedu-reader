import SwiftUI

// Unified library 5c, decision 5: one navigation path for Explore. Each kind of page is
// registered once per stack through these modifiers, `remoteLibraryDestinations()` and
// `publicLibraryDestinations()`, and the home maps what an item opens onto those same pages.

extension View {
    /// The pages `ExploreNavigationRoute` opens. `openBrowser` takes a source page's link out
    /// to the in-app browser.
    func exploreRouteDestinations(openBrowser: @escaping (BrowserEntry) -> Void) -> some View {
        modifier(ExploreRouteDestinations(openBrowser: openBrowser))
    }
}

private struct ExploreRouteDestinations: ViewModifier {
    let openBrowser: (BrowserEntry) -> Void
    @EnvironmentObject private var store: BookStore
    @ObservedObject private var sourceStore = BookSourceStore.shared

    func body(content: Content) -> some View {
        content.navigationDestination(for: ExploreNavigationRoute.self, destination: destination)
    }

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
            BookSourceListView()
        }
    }

    private var deletedSourceState: some View {
        ContentUnavailableView {
            UnavailableLabel(localized("來源配置已被刪除"), systemImage: "books.vertical")
        }
    }
}

/// Where tapping a home item goes: the page that item's source already opens from its own
/// screens, so the home adds no second detail page or reader entry.
enum ExploreItemTarget {
    /// Pushed on Explore's stack.
    case push(ExplorePush)
    /// The store's card carousel, as the storefront's covers open it. The row builds the
    /// selection from its other public-library books, so a swipe moves along the row.
    case publicLibraryBook(PublicLibraryBook)

    /// - Parameter aozoraIndex: the catalog an Aozora work is shown with; nil when it is not
    ///   read, and then an Aozora item opens nothing.
    init?(_ opening: ItemOpening, aozoraIndex: AozoraCatalogIndex?) {
        switch opening {
        case .copy(let id):
            // Explore's own reader route, as the storefront's cards push it (the shelf's card
            // transition belongs to the shelf's stack).
            self = .push(.reader(PublicLibraryReaderRoute(bookID: id)))
        case .opdsEntry(let entry, let connectionID):
            self = .push(.remoteBook(RemoteLibraryBookRoute(entry: entry, connectionID: connectionID)))
        case .webDAVFile(let entry, let connectionID):
            self = .push(.remoteBook(RemoteLibraryBookRoute(entry: entry, connectionID: connectionID)))
        case .gutenberg(let book):
            self = .publicLibraryBook(.gutenberg(book))
        case .aozora(let work):
            guard let aozoraIndex else { return nil }
            self = .publicLibraryBook(.aozora(work, aozoraIndex))
        case .onlineBook(let frozen):
            self = .push(.explore(.book(frozen.book)))
        }
    }
}

/// A page pushed from a home item, each registered on Explore's stack.
enum ExplorePush: Hashable {
    case reader(PublicLibraryReaderRoute)
    case remoteBook(RemoteLibraryBookRoute)
    case explore(ExploreNavigationRoute)

    /// Appends the route itself, so it reaches the destination registered for its type.
    func append(to path: inout NavigationPath) {
        switch self {
        case .reader(let route): path.append(route)
        case .remoteBook(let route): path.append(route)
        case .explore(let route): path.append(route)
        }
    }
}
