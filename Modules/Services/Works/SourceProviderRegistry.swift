import Foundation

/// Unified library 2a: the providers of the content sources available now (design §9).
///
/// - Lookups resolve from the connection store at each call, as the browse models always
///   did; nothing is cached. `OPDSCatalogStore` is not `@MainActor`, and a registry rebuilt
///   from `$catalogs` could lag behind an add or a removal.
/// - Availability shapes the list only. A lookup by id still answers for Gutenberg in the
///   China region, so an open storefront never turns into 「書庫連線已移除」.
/// - The shelf is listed only when a store is passed: `BookStore` is the app's
///   `@StateObject`, not a singleton.
@MainActor
final class SourceProviderRegistry {
    static let shared = SourceProviderRegistry()

    private let connections: OPDSCatalogStore
    private let availability: PublicLibraryAvailability
    private let aozora: AozoraCatalogStore

    init(
        connections: OPDSCatalogStore = .shared,
        availability: PublicLibraryAvailability = .shared,
        aozora: AozoraCatalogStore = .shared
    ) {
        self.connections = connections
        self.availability = availability
        self.aozora = aozora
    }

    /// The OPDS-speaking provider of a feed route: the built-in Gutenberg, or a saved OPDS or
    /// Calibre connection. Nil when the connection was removed.
    func opdsProvider(catalogID: String) -> (any OPDSFeedProviding)? {
        // The same lookup the browse models made before 2a (`connection(id:)`, which also
        // answers for the built-in Gutenberg), then a branch on what it found.
        guard let connection = connections.connection(id: catalogID) else { return nil }
        if connection.id == PublicLibraryID.gutenberg.rawValue { return gutenberg }
        guard connection.kind != .webDAV else { return nil }
        return OPDSProvider(connection: connection, store: connections)
    }

    /// Nil when the connection was removed.
    func webDAVProvider(connectionID: String) -> WebDAVProvider? {
        guard let connection = connections.connection(id: connectionID), connection.kind == .webDAV else { return nil }
        return WebDAVProvider(connection: connection, store: connections)
    }

    var gutenberg: GutenbergProvider { GutenbergProvider(availability: availability) }

    var aozoraProvider: AozoraProvider { AozoraProvider(store: aozora, availability: availability) }

    /// Every source that can be browsed now, in a stable order: the shelf (when given), saved
    /// connections by their sort order, then Gutenberg and Aozora when the region allows.
    func browsableProviders(shelf: BookStore? = nil) -> [any CollectionBrowsing] {
        var providers: [any CollectionBrowsing] = []
        if let shelf { providers.append(ShelfProvider(store: shelf)) }
        for connection in connections.catalogs {
            switch connection.kind {
            case .webDAV: providers.append(WebDAVProvider(connection: connection, store: connections))
            case .opds, .calibre: providers.append(OPDSProvider(connection: connection, store: connections))
            }
        }
        providers.append(gutenberg)
        providers.append(aozoraProvider)
        return providers.filter { $0.availability != .hiddenInRegion }
    }

    /// Every source that can put rows on the Explore home (5b), in the order 「最新」 lists
    /// them: the shelf, saved connections, Gutenberg, Aozora, then the explore sources as
    /// 探索 lists them. WebDAV connections read `shelf.remoteRecords` for their 「最新」.
    ///
    /// Callers wait for `BookSourceStore.waitUntilLoaded()` first: before the library is read
    /// every source would look deleted.
    func homeProviders(shelf: BookStore, sources: BookSourceStore = .shared) -> [any HomeSectionProviding] {
        var providers: [any HomeSectionProviding] = [ShelfProvider(store: shelf)]
        for connection in connections.catalogs {
            switch connection.kind {
            case .webDAV: providers.append(WebDAVProvider(connection: connection, store: connections, records: shelf.remoteRecords))
            case .opds, .calibre: providers.append(OPDSProvider(connection: connection, store: connections))
            }
        }
        providers.append(gutenberg)
        providers.append(aozoraProvider)
        providers += DiscoverViewModel.exploreSources(in: sources).map { BookSourceProvider(source: $0) }
        return providers.filter { $0.availability != .hiddenInRegion }
    }
}
