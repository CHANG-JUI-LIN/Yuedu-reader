import Foundation
import Testing
@testable import yuedu_app

/// The libraries as 範圍, 顯示在最新 and 搜尋來源 list them, since 書庫順序 went (2026-10-25).
@MainActor
@Suite("Library keys")
struct LibraryKeysTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let aozora = SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue)

    @Test("connections as saved, then Gutenberg and 青空; none in China")
    func available() {
        let dav = OPDSCatalog(id: "dav", name: "DAV", url: "https://dav.test/", kind: .webDAV)
        let opds = OPDSCatalog(id: "opds", name: "Calibre", url: "https://opds.test/", kind: .opds)
        let listed = LibraryListing.available(connections: [dav, opds], librariesAvailable: true)
        #expect(listed.map(\.key) == [SourceInstanceKey(type: .webDAV, id: "dav"), SourceInstanceKey(type: .opds, id: "opds"),
                                      gutenberg, aozora])
        #expect(listed.map(\.name) == ["DAV", "Calibre", localized("Project Gutenberg"), localized("青空文庫")])
        #expect(LibraryListing.available(connections: [dav], librariesAvailable: false).map(\.key)
                    == [SourceInstanceKey(type: .webDAV, id: "dav")])
    }

    @Test("最新's books take turns in the rows' order: the libraries', then the book sources'")
    func latestTakesTurns() {
        let source = SourceInstanceKey(type: .bookSource, id: "https://source.test")
        let latest = HomeSection(layout: .row, binding: .latest)
        func item(_ title: String) -> CollectionEntry {
            let record = SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .opds, id: "c"), item: title),
                                      title: title, authors: [], language: nil, contentKind: .text,
                                      identifiers: [], copyID: nil, acquisitions: [])
            return .item(record, WorkSummary(title: title, authors: [], cover: nil, blurb: nil, language: nil,
                                             contentKind: .text), .copy(UUID()))
        }
        func row(_ key: SourceInstanceKey, _ entries: [CollectionEntry]) -> HomeModel.Row {
            HomeModel.Row(id: HomeModel.rowID(section: latest.id, source: key), section: latest, source: key,
                          sourceName: "", policy: .parallel, state: .loaded(entries))
        }
        let rows = [row(gutenberg, [item("g1"), item("g2")]), row(aozora, [item("a1"), item("a2")]),
                    row(source, [item("s1")])]
        let groups = HomeScopeFilter.groups(rows, in: nil)
        guard case .loaded(let entries) = groups[0].state else {
            Issue.record("not loaded"); return
        }
        let titles = entries.compactMap { entry -> String? in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
        #expect(titles == ["g1", "a1", "s1", "g2", "a2"])
        #expect(groups[0].rows.map(\.source) == [gutenberg, aozora, source])
    }

    @Test("a 書庫順序 saved before it went is kept as stored, for an older build, and orders nothing")
    func storedOrderKept() throws {
        let saved = try JSONEncoder().encode(AggregationSettings(libraryOrder: [aozora, gutenberg]))
        let suite = "LibraryKeysTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: AggregationSettingsStore.defaultsKey)
        let store = AggregationSettingsStore(defaults: defaults)
        store.setHidesRead(false)
        let reread = AggregationSettingsStore(defaults: defaults)
        #expect(reread.settings.libraryOrder == [aozora, gutenberg])
        #expect(!reread.hidesRead)
    }
}
