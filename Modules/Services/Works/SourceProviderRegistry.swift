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

    /// The manifest of every source that can be browsed now, in `browsableProviders`' order
    /// (Phase 6a).
    func manifests(shelf: BookStore? = nil) async -> [ProviderManifest] {
        var manifests: [ProviderManifest] = []
        for provider in browsableProviders(shelf: shelf) { manifests.append(await provider.manifest()) }
        return manifests
    }

    /// The manifest of every enabled 來源配置, in the library's order (Phase 6b). Callers wait
    /// for `BookSourceStore.waitUntilLoaded()` first.
    func sourceManifests(in store: BookSourceStore = .shared) async -> [ProviderManifest] {
        await Self.sourceManifests(of: store.enabledSources)
    }

    /// Derived off the main actor: a library can hold 50,000 sources.
    nonisolated static func sourceManifests(of sources: [BookSource]) async -> [ProviderManifest] {
        let started = SourcePerfTrace.now
        let manifests = await Task.detached(priority: .utility) { sources.map(BookSourceManifest.derive) }.value
        SourcePerfTrace.record("works.registry.sourceManifests", "sources=\(sources.count)", since: started, thresholdMs: 0)
        return manifests
    }

    /// One provider per installed module, oldest install first (Phase 6f).
    static func moduleProviders(in library: RuleModuleLibrary) -> [ModuleProvider] {
        library.modules.map { ModuleProvider(module: $0.module) }
    }

    /// Every source that can put rows on the Explore home (5b), in the order 「最新」 lists
    /// them: the shelf (and 訂閱的最新文章, which serves no 最新), saved connections, Gutenberg,
    /// Aozora, the installed modules, then the explore sources as 探索 lists them. WebDAV connections read `shelf.remoteRecords` for their 「最新」.
    ///
    /// Callers wait for `BookSourceStore.waitUntilLoaded()` first: before the library is read
    /// every source would look deleted.
    ///
    /// - Parameters:
    ///   - firstPages: the home's own, kept for as long as the home (Discovery Phase 7a-1), so
    ///     its rows and 為你推薦 share one queue per source across syncs.
    ///   - home: the home 為你推薦 reads its library rows from (7a-4).
    ///   - modules: the installed modules (Phase 6f); callers wait for its first read.
    func homeProviders(shelf: BookStore, sources: BookSourceStore = .shared, modules: RuleModuleLibrary = .shared,
                       firstPages: DiscoverFirstPages, home: (any ForYouHomeRows)? = nil) -> [any HomeSectionProviding] {
        firstPages.beginSync()
        var providers: [any HomeSectionProviding] = [ShelfProvider(store: shelf), SubscriptionArticlesProvider()]
        for connection in connections.catalogs {
            switch connection.kind {
            case .webDAV: providers.append(WebDAVProvider(connection: connection, store: connections, records: shelf.remoteRecords))
            case .opds, .calibre: providers.append(OPDSProvider(connection: connection, store: connections))
            }
        }
        providers.append(gutenberg)
        providers.append(aozoraProvider)
        providers += Self.moduleProviders(in: modules)
        providers.append(ForYouProvider(firstPages: firstPages, home: home, shelf: shelf))
        providers.append(AIRecommendationProvider())
        providers += DiscoverViewModel.exploreSources(in: sources).map { BookSourceProvider(source: $0, firstPages: firstPages) }
        return providers.filter { $0.availability != .hiddenInRegion }
    }
}
