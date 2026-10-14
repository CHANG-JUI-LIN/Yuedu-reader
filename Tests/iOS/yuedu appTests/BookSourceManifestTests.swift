import Foundation
import Testing
@testable import yuedu_app

/// Phase 6b: a 來源配置 is described by the same `ProviderManifest` as the built-in providers,
/// derived from the rules it has. Derived on demand and off the main actor: a library can hold
/// 50,000 sources (`project_booksource_scale_50k`).
@MainActor
@Suite("來源配置 manifests", .serialized)
struct BookSourceManifestTests {
    private func source(_ url: String = "https://books.example", configure: (inout BookSource) -> Void = { _ in }) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = url
        source.bookSourceName = "測試源"
        configure(&source)
        return source
    }

    @Test("each rule gives its capability: search, explore, book info, table of contents with content")
    func capabilitiesFromRules() {
        let full = source {
            $0.searchUrl = "/search?q={{key}}"
            $0.exploreUrl = "熱門::/hot"
            $0.ruleBookInfo.intro = ".intro@text"
            $0.ruleToc.chapterList = ".chapters li"
            $0.ruleContent.content = "#content@html"
        }
        #expect(BookSourceManifest.capabilities(of: full) == [.search(.onSubmit), .homeSections, .metadata, .reading])

        #expect(BookSourceManifest.capabilities(of: source { $0.searchUrl = "/s" }) == [.search(.onSubmit)])
        #expect(BookSourceManifest.capabilities(of: source { $0.exploreUrl = "熱門::/hot" }) == [.homeSections])
        #expect(BookSourceManifest.capabilities(of: source { $0.ruleToc.chapterList = "li" }) == [],
                "a table of contents without a content rule reads nothing")
        #expect(BookSourceManifest.capabilities(of: source {
            $0.searchUrl = "  \n"
            $0.exploreUrl = " "
            $0.ruleBookInfo.name = " "
        }) == [], "whitespace is no rule")
        #expect(BookSourceManifest.capabilities(of: source()) == [])
    }

    @Test("hosts from the source's address, without its # comment; the rate as declared")
    func hostsAndRate() {
        let manifest = BookSourceManifest.derive(source("https://www.example.com#備註") { $0.concurrentRate = "2/1000" })
        #expect(manifest.instance == SourceInstanceKey(type: .bookSource, id: "https://www.example.com#備註"))
        #expect(manifest.displayName == "測試源")
        #expect(manifest.availability == .available)
        #expect(manifest.hosts == ["www.example.com"])
        #expect(manifest.rateLimit == "2/1000")
        #expect(BookSourceManifest.derive(source { $0.concurrentRate = "0" }).rateLimit == nil, "0 is unlimited")
        #expect(BookSourceManifest.derive(source { $0.concurrentRate = " " }).rateLimit == nil)
        #expect(BookSourceManifest.derive(source("")).hosts.isEmpty)
    }

    @Test("the Explore home's provider of a source reports the same manifest")
    func homeProviderAgrees() async {
        let explore = source {
            $0.exploreUrl = "熱門::/hot"
            $0.searchUrl = "/s"
            $0.concurrentRate = "3"
        }
        let provider = BookSourceProvider(source: explore, pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in })
        #expect(await provider.manifest() == BookSourceManifest.derive(explore))
    }

    @Test("the registry lists the enabled sources' manifests off the main actor, in the library's order")
    func registryLists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SourceManifests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookSourceStore(directory: folder)
        store.replaceSourcesFromSync([
            source("https://a.example") { $0.searchUrl = "/s" },
            source("https://b.example") { $0.enabled = false },
            source("https://c.example") { $0.exploreUrl = "熱門::/hot" },
        ])

        let manifests = await SourceProviderRegistry().sourceManifests(in: store)
        #expect(manifests.map(\.instance.id) == ["https://a.example", "https://c.example"], "a disabled source is not offered")
        #expect(manifests.map(\.capabilities) == [[.search(.onSubmit)], [.homeSections]])
    }

    @Test("measure: 50,000 sources")
    func measureFiftyThousand() async {
        let sources = (0..<50_000).map { index in
            source("https://s\(index).example.com#\(index)") {
                $0.searchUrl = index.isMultiple(of: 2) ? "/search?q={{key}}" : ""
                $0.exploreUrl = index.isMultiple(of: 3) ? "熱門::/hot" : ""
                $0.ruleBookInfo.intro = ".intro@text"
                $0.ruleToc.chapterList = "li"
                $0.ruleContent.content = "#content"
                $0.concurrentRate = index.isMultiple(of: 10) ? "1" : ""
            }
        }
        let started = SourcePerfTrace.now
        let manifests = await SourceProviderRegistry.sourceManifests(of: sources)
        let ms = (SourcePerfTrace.now - started) * 1000
        print("6b measure: \(manifests.count) source manifests in \(String(format: "%.1f", ms)) ms")
        #expect(manifests.count == 50_000)
        #expect(manifests.filter { $0.capabilities.contains(.homeSections) }.count == 16_667)
    }
}
