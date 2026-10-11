import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3e: 書庫順序 in 聚合設定 (Phase 5 plan, decision 21).
@MainActor
@Suite("Library order")
struct LibraryOrderTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)
    private let source = SourceInstanceKey(type: .bookSource, id: "https://source.test")

    private func item(_ title: String) -> CollectionEntry {
        let record = SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c"), item: title),
                                  title: title, authors: [], language: nil, contentKind: .text,
                                  identifiers: [], copyID: nil, acquisitions: [])
        return .item(record, WorkSummary(title: title, authors: [], cover: nil, blurb: nil, language: nil,
                                         contentKind: .text), .copy(UUID()))
    }

    private func titles(_ entries: [CollectionEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
    }

    @Test("before the reader orders them: connections as saved, then Gutenberg and 青空; none in China")
    func defaults() {
        let dav = OPDSCatalog(id: "dav", name: "DAV", url: "https://dav.test/", kind: .webDAV)
        let opds = OPDSCatalog(id: "opds", name: "Calibre", url: "https://opds.test/", kind: .opds)
        let listed = LibraryListing.ordered(connections: [dav, opds], librariesAvailable: true, order: nil)
        #expect(listed.map(\.key) == [SourceInstanceKey(type: .webDAV, id: "dav"), SourceInstanceKey(type: .opds, id: "opds"),
                                      gutenberg, aozora])
        #expect(listed.map(\.name) == ["DAV", "Calibre", localized("Project Gutenberg"), localized("青空文庫")])
        #expect(LibraryListing.ordered(connections: [dav], librariesAvailable: false, order: nil).map(\.key)
                    == [SourceInstanceKey(type: .webDAV, id: "dav")])
    }

    @Test("the reader's order; a library added since follows it; one gone is passed over")
    func ordered() {
        let dav = SourceInstanceKey(type: .webDAV, id: "dav")
        let added = SourceInstanceKey(type: .opds, id: "added")
        let removed = SourceInstanceKey(type: .opds, id: "removed")
        let keys = [dav, added, gutenberg, aozora]
        #expect(LibraryOrder.arrange(keys, by: [aozora, removed, gutenberg, dav], key: { $0 }) == [aozora, gutenberg, dav, added])
    }

    @Test("the shelf and book sources keep their places; only libraries move among theirs")
    func othersKeepTheirPlaces() {
        let keys = [SourceInstanceKey.localLibrary, gutenberg, aozora, source]
        #expect(LibraryOrder.arrange(keys, by: [aozora, gutenberg], key: { $0 }) == [.localLibrary, aozora, gutenberg, source])
    }

    @Test("最新's books take turns in 書庫順序; book sources after")
    func latestTakesTurnsInOrder() {
        let latest = HomeSection(layout: .row, binding: .latest)
        func row(_ key: SourceInstanceKey, _ entries: [CollectionEntry]) -> HomeModel.Row {
            HomeModel.Row(id: HomeModel.rowID(section: latest.id, source: key), section: latest, source: key,
                          sourceName: "", policy: .parallel, state: .loaded(entries))
        }
        let rows = [row(gutenberg, [item("g1"), item("g2")]), row(aozora, [item("a1"), item("a2")]),
                    row(source, [item("s1")])]
        let unordered = HomeScopeFilter.groups(rows, in: nil)
        let ordered = HomeScopeFilter.groups(rows, in: nil, libraryOrder: [aozora, gutenberg])
        guard case .loaded(let before) = unordered[0].state, case .loaded(let after) = ordered[0].state else {
            Issue.record("not loaded"); return
        }
        #expect(titles(before) == ["g1", "a1", "s1", "g2", "a2"])
        #expect(titles(after) == ["a1", "g1", "s1", "a2", "g2"])
        #expect(ordered[0].rows.map(\.source) == [aozora, gutenberg, source])
    }

    @Test("settings saved before 書庫順序 still read; the order is saved and read back")
    func store() throws {
        let saved = try JSONEncoder().encode(["readingLanguages": ReadingLanguagePreferences(languages: ["ja"], scope: .only)])
        let decoded = try JSONDecoder().decode(AggregationSettings.self, from: saved)
        #expect(decoded.readingLanguages?.languages == ["ja"])
        #expect(decoded.libraryOrder == nil)

        let suite = "LibraryOrderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: AggregationSettingsStore.defaultsKey)
        let store = AggregationSettingsStore(defaults: defaults)
        store.setLibraryOrder([aozora, gutenberg])
        let reread = AggregationSettingsStore(defaults: defaults)
        #expect(reread.settings.libraryOrder == [aozora, gutenberg])
        #expect(reread.settings.readingLanguages?.languages == ["ja"])
    }
}
