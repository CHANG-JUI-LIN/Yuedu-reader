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
        content
            .navigationDestination(for: ExploreNavigationRoute.self, destination: destination)
            // 訂閱的最新文章's articles (5g): the RSS tab's own article page, which marks it read.
            .navigationDestination(for: SubscriptionArticleRoute.self) { route in
                RSSArticleReaderView(articleID: route.articleID)
            }
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
        case .aggregationSettings:
            AggregationSettingsView()
        case .subscriptions:
            RSSListView()
        case .library(let key):
            LibraryHomePageView(key: key)
        case .sources(let group):
            LibrarySourcesView(group: group)
        case .module(let id):
            RuleModuleDetailView(moduleID: id)
        }
    }

    private var deletedSourceState: some View {
        ContentUnavailableView {
            UnavailableLabel(localized("來源配置已被刪除"), systemImage: "books.vertical")
        }
    }
}

/// Where tapping a home item went before 作品詳情 (5f): the page that item's source opens it on
/// from its own screens, and the store's carousel for a public-library book. Unused while
/// every card opens 作品詳情 (Phase 5 plan, decision 27); kept with the carousel, which the
/// maintainer asked to keep for now.
enum ExploreItemTarget {
    /// Pushed on Explore's stack.
    case push(ExplorePush)
    /// The store's card carousel, as the storefront's covers open it. The row builds the
    /// selection from its other public-library books, so a swipe moves along the row.
    case publicLibraryBook(PublicLibraryBook)

    /// - Parameter aozoraIndex: the catalog an Aozora work is shown with; nil when it is not
    ///   read, and then an Aozora item opens nothing.
    init?(_ route: WorkDetailRoute, aozoraIndex: AozoraCatalogIndex?) {
        switch route.opening {
        case .copy(let id):
            // Explore's own reader route, as the storefront's cards push it (the shelf's card
            // transition belongs to the shelf's stack).
            self = .push(.reader(PublicLibraryReaderRoute(bookID: id)))
        case .opdsEntry, .webDAVFile, .bibliographic:
            // A library item's own page is 作品詳情 since its list page went (decision 28); a
            // bibliographic record has no other.
            self = .push(.work(route))
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

/// A page pushed from the home, each registered on Explore's stack.
/// An article of 訂閱的最新文章 (unified library 5g), by the id the RSS tab stores it under.
struct SubscriptionArticleRoute: Hashable {
    let articleID: String
}

enum ExplorePush: Hashable {
    case work(WorkDetailRoute)
    case reader(PublicLibraryReaderRoute)
    case explore(ExploreNavigationRoute)
    case feed(OPDSFeedRoute)
    case folder(WebDAVDirectoryRoute)
    case publicLibrary(PublicLibraryRoute)
    case article(SubscriptionArticleRoute)

    /// Appends the route itself, so it reaches the destination registered for its type.
    func append(to path: inout NavigationPath) {
        switch self {
        case .work(let route): path.append(route)
        case .reader(let route): path.append(route)
        case .explore(let route): path.append(route)
        case .feed(let route): path.append(route)
        case .folder(let route): path.append(route)
        case .publicLibrary(let route): path.append(route)
        case .article(let route): path.append(route)
        }
    }
}

/// The pages 範圍, the home's row headers and its chips open: each the page its source already
/// shows from its own screens (unified library 5c-3). Nil where the source has no such page.
enum ExplorePlace {
    /// A source's own page: its discover page, its root feed or folder, or a public library's
    /// front page, which 範圍 shows in place (5d-1; 我的書庫's tiles pushed it before).
    static func page(of source: SourceInstanceKey, name: String,
                     connections: RemoteLibraryConnectionStore = .shared) -> ExplorePush? {
        switch source.type {
        case .bookSource:
            return .explore(.source(sourceURL: source.id))
        case .opds, .calibre:
            guard let connection = connections.connection(id: source.id) else { return nil }
            return .feed(OPDSFeedRoute(catalogID: connection.id, url: connection.url, title: name))
        case .webDAV:
            guard let connection = connections.connection(id: source.id),
                  let root = connections.webDAVClient(for: connection).rootURL else { return nil }
            return .folder(WebDAVDirectoryRoute(connectionID: connection.id, url: root, title: name))
        case .gutenberg:
            return .publicLibrary(.gutenbergHome)
        case .aozora:
            return .publicLibrary(.aozoraHome)
        case .module:
            return .explore(.module(id: source.id))
        case .library, .bibliographic:
            return nil
        }
    }

    /// 查看全部: the whole of what a row shows the start of.
    static func showAll(_ row: HomeModel.Row, aozoraIndex: AozoraCatalogIndex?,
                        connections: RemoteLibraryConnectionStore = .shared) -> ExplorePush? {
        let gutenbergID = PublicLibraryID.gutenberg.rawValue
        switch row.section.binding {
        case .latest:
            switch row.source.type {
            case .bookSource:
                return row.section.latestCategory(forSourceURL: row.source.id).map { .explore(.sourceCategory($0)) }
            case .opds, .calibre:
                // 「最新」 is the root's books, or its first feed's: the root is the whole.
                return page(of: row.source, name: row.sourceName, connections: connections)
            case .gutenberg:
                return .feed(OPDSFeedRoute(catalogID: gutenbergID, url: GutenbergEndpoint.current.latestURL.absoluteString,
                                           title: row.section.displayTitle(sourceName: row.sourceName), presentation: .storefront))
            case .aozora:
                return aozoraIndex.map { .publicLibrary(.aozoraCatalog(.newest, $0)) }
            case .webDAV, .library, .bibliographic, .module:
                // A WebDAV library's newest files are gathered from every folder; no page lists them.
                return nil
            }
        case .sourceCategories(let references):
            return references.first { $0.sourceURL == row.source.id }.map { .explore(.sourceCategory($0)) }
        case .opdsFeed(let connectionID, let url):
            return .feed(OPDSFeedRoute(catalogID: connectionID, url: url, title: row.section.displayTitle(sourceName: row.sourceName)))
        case .gutenbergCollection(let id):
            return .publicLibrary(.collection(id: id))
        // Each card opens its own list; no page lists the lists alone.
        case .gutenbergLists:
            return nil
        case .gutenbergFeed(let url):
            return .feed(OPDSFeedRoute(catalogID: gutenbergID, url: url, title: row.section.displayTitle(sourceName: row.sourceName), presentation: .storefront))
        case .gutenbergShelf(let id):
            return GutenbergShelf.shelf(id: id).map {
                .feed(OPDSFeedRoute(catalogID: gutenbergID, url: $0.url.absoluteString,
                                    title: row.section.displayTitle(sourceName: row.sourceName), presentation: .storefront))
            }
        case .aozoraNew:
            return aozoraIndex.map { .publicLibrary(.aozoraCatalog(.newest, $0)) }
        case .aozoraIndex(let kind):
            guard let aozoraIndex, let mode = AozoraBrowseMode(rawValue: kind) else { return nil }
            return .publicLibrary(.aozoraCatalog(mode, aozoraIndex))
        // 訂閱的最新文章: the rest is RSS 訂閱 (`ExploreNavigationRoute.subscriptions`).
        // 為你推薦 is mixed from many places; no page lists it whole. A module list's whole page
        // comes with the module rows on the home (Phase 6f).
        case .myLibrary, .continueReading, .related, .nextInSeries, .subscriptionArticles, .forYou, .module, .unknown:
            return nil
        }
    }

    /// A card of 專題集合: the whole list.
    static func page(of collection: CollectionSummary) -> ExplorePush {
        switch collection.opening {
        case .gutenbergCollection(let id): .publicLibrary(.collection(id: id))
        }
    }

    /// A chip in a row: a feed or folder inside the source, or one of Aozora's index groups.
    static func page(of location: CollectionLocation, in row: HomeModel.Row,
                     aozoraIndex: AozoraCatalogIndex?) -> ExplorePush? {
        switch row.source.type {
        case .opds, .calibre:
            return .feed(OPDSFeedRoute(catalogID: row.source.id, url: location.id, title: location.title))
        case .webDAV:
            guard let url = URL(string: location.id) else { return nil }
            return .folder(WebDAVDirectoryRoute(connectionID: row.source.id, url: url, title: location.title))
        case .aozora:
            guard let aozoraIndex else { return nil }
            let parts = location.id.split(separator: "/", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count) {
            case ("new", 1): return .publicLibrary(.aozoraCatalog(.newest, aozoraIndex))
            case ("authors", _): return .publicLibrary(.aozoraCatalog(.authors, aozoraIndex))
            case ("titles", 1): return .publicLibrary(.aozoraCatalog(.titles, aozoraIndex))
            case ("categories", 1): return .publicLibrary(.aozoraCatalog(.categories, aozoraIndex))
            case ("titles", 2), ("categories", 2):
                let groups = parts[0] == "titles" ? aozoraIndex.titleGroups : aozoraIndex.classificationGroups
                guard let group = groups.first(where: { $0.id == parts[1] }) else { return nil }
                return .publicLibrary(.aozoraWorks(title: location.title,
                                                   works: group.ids.compactMap { aozoraIndex.worksByID[$0] }, index: aozoraIndex))
            case ("person", 2):
                return .publicLibrary(.aozoraWorks(title: location.title, works: aozoraIndex.works(forPerson: parts[1]),
                                                   index: aozoraIndex))
            default: return nil
            }
        case .bookSource, .gutenberg, .library, .bibliographic, .module:
            // The shelf's groups have no page outside the shelf yet.
            return nil
        }
    }
}
