import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3f: 顯示在最新 in 聚合設定 replaces the 最新 section's own 排除的來源
/// (Phase 5 plan, decision 21).
@MainActor
@Suite("Show in latest")
struct ShowInLatestTests {
    private let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
    private let opds = SourceInstanceKey(type: .opds, id: "c1")
    private let source = SourceInstanceKey(type: .bookSource, id: "https://source.test")

    private func freshStore() -> (AggregationSettingsStore, UserDefaults, String) {
        let suite = "ShowInLatestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AggregationSettingsStore(defaults: defaults), defaults, suite)
    }

    /// A home saved before 5d-3f: 最新 with its own list.
    private let legacyHome = """
    {"schemaVersion":1,"sections":[
      {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"row","title":"",
       "binding":{"type":"latest","excluded":[{"type":"opds","id":"c1"},{"type":"bookSource","id":"https://source.test"}]},
       "isEnabled":true,"parameters":{}},
      {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A12","layout":"row","title":"",
       "binding":{"type":"continueReading"},"isEnabled":true,"parameters":{}}
    ]}
    """

    @Test("an old home still reads; its 最新 list is handed over, and is gone once saved")
    func legacyFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("show-in-latest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("explore_home.json")
        try Data(legacyHome.utf8).write(to: url)

        let store = HomePageStore(fileURL: url)
        #expect(store.page?.sections.map(\.binding) == [.latest, .continueReading])
        #expect(store.legacyLatestExcluded == [opds, source])

        store.save(try #require(store.page))
        store.waitForPendingWritesForTesting()
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("excluded"))
        #expect(HomePageStore(fileURL: url).legacyLatestExcluded.isEmpty)
    }

    @Test("the libraries of the old list move in once, and only while 顯示在最新 was never set")
    func adopt() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.adoptLegacyLatestExcluded([opds, source])
        #expect(store.settings.hiddenFromLatest == [opds], "a book source leaves 最新 by its section's category")
        #expect(!store.isShownInLatest(opds))
        #expect(store.isShownInLatest(gutenberg))

        store.setShownInLatest(true, for: opds)
        store.adoptLegacyLatestExcluded([opds])
        #expect(store.isShownInLatest(opds), "the reader's choice is not overwritten")
        #expect(store.settings.hiddenFromLatest == [])
    }

    @Test("顯示在最新 is saved and read back")
    func saved() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.settings.hiddenFromLatest == nil)
        store.setShownInLatest(false, for: gutenberg)
        store.setShownInLatest(false, for: gutenberg)
        #expect(AggregationSettingsStore(defaults: defaults).settings.hiddenFromLatest == [gutenberg])
    }
}
