import Foundation
import Testing
@testable import yuedu_app

/// Search 9d: 聚合設定's 數據來源 — 搜尋來源 n/m, its switches kept with the settings, and a
/// place unchecked there not asked by the search.
@MainActor
@Suite("Aggregation data sources")
struct AggregationDataSourcesTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)

    private func freshStore() -> (AggregationSettingsStore, UserDefaults, String) {
        let suite = "AggregationDataSourcesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AggregationSettingsStore(defaults: defaults), defaults, suite)
    }

    @Test("搜尋來源 is kept with the settings; settings saved before it read as all checked")
    func roundTrip() throws {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.isShownInSearch(gutenberg))
        store.setShownInSearch(false, for: gutenberg)
        #expect(!AggregationSettingsStore(defaults: defaults).isShownInSearch(gutenberg))
        #expect(AggregationSettingsStore(defaults: defaults).isShownInSearch(aozora))
        store.setShownInSearch(true, for: gutenberg)
        #expect(AggregationSettingsStore(defaults: defaults).isShownInSearch(gutenberg))

        // A value from before 9d: no such field.
        defaults.set(Data(#"{"hidesRead":false}"#.utf8), forKey: AggregationSettingsStore.defaultsKey)
        let old = AggregationSettingsStore(defaults: defaults)
        #expect(old.settings.hiddenFromSearch == nil)
        #expect(old.isShownInSearch(gutenberg))
        #expect(!old.hidesRead, "the rest of the value still reads")
    }

    @Test("搜尋來源 lists the libraries but WebDAV, then the modules that search")
    func places() {
        let opds = RemoteLibraryConnection(id: "c1", name: "家裡", url: "https://home.test/opds", kind: .opds)
        let dav = RemoteLibraryConnection(id: "d1", name: "雲端", url: "https://dav.test/", kind: .webDAV)
        let places = SearchSourcePlaces.places(connections: [opds, dav], librariesAvailable: true, order: nil, modules: [])
        #expect(places.map(\.key) == [SourceInstanceKey(type: .opds, id: "c1"), gutenberg, aozora])
        let count = SearchSourcePlaces.count(places, shown: { $0 != gutenberg })
        #expect(count == DataSourceCount(checked: 2, total: 3))
        #expect(count.text == "2/3")
        #expect(SearchSourcePlaces.places(connections: [], librariesAvailable: false, order: nil, modules: []).isEmpty,
                "no public library in China")
    }

    @Test("the old 搜尋時也查 Open Library switch, once: off unchecks the module, on or never set leaves it checked; the switch is gone after")
    func openLibrarySwitchMigration() throws {
        let module = ModuleProvider.instanceKey(moduleID: OfficialRuleModules.openLibraryID)
        for (stored, shown) in [(false as Bool?, false), (true, true), (nil, true)] {
            let (store, defaults, suite) = freshStore()
            defer { defaults.removePersistentDomain(forName: suite) }
            if let stored { defaults.set(stored, forKey: AggregationSettingsStore.legacyOpenLibrarySearchKey) }
            store.adoptLegacyOpenLibrarySearch()
            #expect(store.isShownInSearch(module) == shown, "stored \(String(describing: stored))")
            #expect(defaults.object(forKey: AggregationSettingsStore.legacyOpenLibrarySearchKey) == nil)
            store.setShownInSearch(true, for: module)
            store.adoptLegacyOpenLibrarySearch()
            #expect(store.isShownInSearch(module), "once: checking it again stays")
        }
    }

    @Test("a library unchecked in 搜尋來源 is not asked")
    func uncheckedNotAsked() async {
        var requested: [URL] = []
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "data-sources-\(UUID().uuidString)")!)
        let provider = GutenbergProvider(availability: availability) { url in
            requested.append(url)
            return OPDSFeed()
        }
        func libraries(_ shown: @escaping (SourceInstanceKey) -> Bool) -> [any OPDSFeedProviding] {
            LibrarySearch.libraries(catalogs: [], gutenberg: provider, shown: shown) { _ in nil }
        }
        #expect(libraries { _ in true }.map(\.instance) == [gutenberg])
        let unchecked = libraries { $0 != gutenberg }
        #expect(unchecked.isEmpty)
        let search = LibrarySearch(providers: { unchecked })
        #expect(!search.isAvailable)
        await search.search("austen") { _ in }
        #expect(requested.isEmpty)
    }
}
