import Foundation
import Testing
@testable import yuedu_app

/// Phase 6a: every built-in provider describes itself with a `ProviderManifest` computed from
/// what it already knows. The registry's lists are pinned first, so the manifests change
/// nothing about which providers are listed or in what order.
@MainActor
@Suite("Provider manifests", .serialized)
struct ProviderManifestTests {
    private struct Fixture {
        let folder: URL
        let connections: OPDSCatalogStore
        let availability: PublicLibraryAvailability
        let registry: SourceProviderRegistry
        let shelf: BookStore
        let sources: BookSourceStore
        let opds: OPDSCatalog
        let calibre: OPDSCatalog
        let dav: OPDSCatalog
    }

    private func makeFixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderManifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false)
        let opds = connections.add(name: "OPDS", url: "https://opds.example/catalog", username: nil, password: nil, kind: .opds)
        let calibre = connections.add(name: "Calibre", url: "http://192.168.1.5:8080/opds", username: nil, password: nil,
                                      kind: .calibre)
        let dav = connections.add(name: "DAV", url: "https://dav.example/books/", username: nil, password: nil, kind: .webDAV)
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "manifest-\(UUID().uuidString)")!)
        let aozora = AozoraCatalogStore(directory: folder.appendingPathComponent("aozora"),
                                        defaults: UserDefaults(suiteName: "manifest-aozora-\(UUID().uuidString)")!)
        let registry = SourceProviderRegistry(connections: connections, availability: availability, aozora: aozora)
        let shelf = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let sources = BookSourceStore(directory: folder.appendingPathComponent("sources"))
        var explore = BookSource()
        explore.bookSourceUrl = "https://explore.example"
        explore.bookSourceName = "發現源"
        explore.exploreUrl = "熱門::/hot"
        var searchOnly = BookSource()
        searchOnly.bookSourceUrl = "https://search.example"
        searchOnly.bookSourceName = "搜尋源"
        sources.replaceSourcesFromSync([explore, searchOnly])
        return Fixture(folder: folder, connections: connections, availability: availability, registry: registry, shelf: shelf,
                       sources: sources, opds: opds, calibre: calibre, dav: dav)
    }

    private func firstPages(_ folder: URL) -> DiscoverFirstPages {
        DiscoverFirstPages(pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in },
                           store: ForYouCandidateStore(directory: folder.appendingPathComponent("ForYou")),
                           lanes: DiscoverRequestLanes())
    }

    // MARK: - The registry's lists, as they are

    @Test("browsable providers: the shelf, connections in their order, then Gutenberg and 青空文庫; the region hides the last two")
    func browsableOrder() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        #expect(f.registry.browsableProviders(shelf: f.shelf).map(\.instance) == [
            .localLibrary,
            SourceInstanceKey(type: .opds, id: f.opds.id),
            SourceInstanceKey(type: .calibre, id: f.calibre.id),
            SourceInstanceKey(type: .webDAV, id: f.dav.id),
            SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue),
            SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue),
        ])
        f.availability.receive(countryCode: "CHN")
        #expect(f.registry.browsableProviders(shelf: f.shelf).map(\.instance) == [.localLibrary] + [f.opds, f.calibre, f.dav].map {
            SourceInstanceKey(type: ProviderType($0.kind), id: $0.id)
        })
        #expect(f.registry.opdsProvider(catalogID: PublicLibraryID.gutenberg.rawValue) != nil)
    }

    @Test("home providers: the shelf, 訂閱, connections, Gutenberg, 青空文庫, 為你推薦, AI 推薦, then the explore sources")
    func homeOrder() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        let providers = f.registry.homeProviders(shelf: f.shelf, sources: f.sources, firstPages: firstPages(f.folder))
        #expect(providers.map(\.instance) == [
            .localLibrary,
            SubscriptionArticlesProvider.instanceKey,
            SourceInstanceKey(type: .opds, id: f.opds.id),
            SourceInstanceKey(type: .calibre, id: f.calibre.id),
            SourceInstanceKey(type: .webDAV, id: f.dav.id),
            SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue),
            SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue),
            ForYouProvider.instanceKey,
            AIRecommendationProvider.instanceKey,
            SourceInstanceKey(type: .bookSource, id: "https://explore.example"),
        ], "a source with no explore rule puts nothing on the home")
        f.availability.receive(countryCode: "CHN")
        let inChina = f.registry.homeProviders(shelf: f.shelf, sources: f.sources, firstPages: firstPages(f.folder))
        #expect(!inChina.contains { [.gutenberg, .aozora].contains($0.instance.type) })
        #expect(inChina.count == providers.count - 2)
    }

    // MARK: - Manifests

    @Test("each built-in provider's manifest is what it already reports")
    func builtInManifests() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let manifests = await f.registry.manifests(shelf: f.shelf)
        func manifest(_ type: ProviderType) throws -> ProviderManifest {
            try #require(manifests.first { $0.instance.type == type })
        }

        #expect(manifests.map(\.instance) == f.registry.browsableProviders(shelf: f.shelf).map(\.instance),
                "one manifest per listed provider, in the list's order")

        let shelf = try #require(manifests.first { $0.instance == .localLibrary })
        #expect(shelf.capabilities == [.browse, .homeSections, .search(.asYouType)])
        #expect(shelf.hosts.isEmpty, "on-device")

        let opds = try manifest(.opds)
        #expect(opds.displayName == "OPDS")
        #expect(opds.capabilities == [.browse, .homeSections, .search(.unknown)], "its search is known once the root answers")
        #expect(opds.hosts == ["opds.example"])
        #expect(try manifest(.calibre).hosts == ["192.168.1.5"])

        let dav = try manifest(.webDAV)
        #expect(dav.capabilities == [.browse, .homeSections], "WebDAV has no search")
        #expect(dav.hosts == ["dav.example"])

        let gutenberg = try manifest(.gutenberg)
        #expect(gutenberg.capabilities == [.browse, .homeSections, .search(.explicitRequestOnly)])
        #expect(gutenberg.hosts == [URL(string: PublicLibrary.gutenberg.url)!.host!])
        #expect(gutenberg.availability == .available)

        let aozora = try manifest(.aozora)
        #expect(aozora.capabilities.contains(.browse) && aozora.capabilities.contains(.homeSections))
        #expect(aozora.hosts == ["yuedureader.com", "www.aozora.gr.jp"], "its catalog, then its books")
        #expect(aozora.availability == .catalogNotReady)
        #expect(manifests.allSatisfy { $0.rateLimit == nil }, "no built-in provider declares a rate")
    }

    @Test("manifests of the providers only the home lists")
    func homeOnlyManifests() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let providers = f.registry.homeProviders(shelf: f.shelf, sources: f.sources, firstPages: firstPages(f.folder))
        let subscriptions = try #require(providers.first { $0.instance == SubscriptionArticlesProvider.instanceKey })
        let forYou = try #require(providers.first { $0.instance == ForYouProvider.instanceKey })

        let articles = await subscriptions.manifest()
        #expect(articles.capabilities == [.homeSections])
        #expect(articles.hosts.isEmpty, "reads the articles already fetched")
        let recommended = await forYou.manifest()
        #expect(recommended.capabilities == [.homeSections])
        #expect(recommended.hosts.isEmpty, "reads the pages the home already fetched")
    }
}
