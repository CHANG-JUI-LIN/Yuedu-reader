import Foundation
import Testing
@testable import yuedu_app

@Suite("BookSourceStore", .serialized)
struct BookSourceStoreTests {
    @Test("batch delete removes selected sources and keeps the rest ordered")
    func batchDeleteRemovesSelectedSources() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<5).map(makeSource)
        store.replaceSourcesFromSync(sources)

        let idsToDelete = Set([sources[1].id, sources[3].id])
        let removedCount = store.delete(ids: idsToDelete)

        #expect(removedCount == 2)
        #expect(store.sources.map(\.id) == [sources[0].id, sources[2].id, sources[4].id])
    }

    @Test("batch delete ignores missing IDs")
    func batchDeleteIgnoresMissingIDs() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<2).map(makeSource)
        store.replaceSourcesFromSync(sources)

        let removedCount = store.delete(ids: Set([UUID()]))

        #expect(removedCount == 0)
        #expect(store.sources.map(\.id) == sources.map(\.id))
    }

    @Test("dedupedByURL collapses same-URL copies to the newest, keeping order")
    func dedupedByURLKeepsNewestPerURL() throws {
        var older = BookSource()
        older.bookSourceName = "older"
        older.bookSourceUrl = "https://dup.test/a"
        older.lastUpdateTime = 100

        var newer = BookSource()
        newer.bookSourceName = "newer"
        newer.bookSourceUrl = "https://dup.test/a"   // same URL as `older`, different random id
        newer.lastUpdateTime = 200

        var other = BookSource()
        other.bookSourceName = "other"
        other.bookSourceUrl = "https://dup.test/b"

        let result = BookSourceStore.dedupedByURL([older, other, newer])

        #expect(result.map(\.bookSourceUrl) == ["https://dup.test/a", "https://dup.test/b"])
        let a = try #require(result.first { $0.bookSourceUrl == "https://dup.test/a" })
        #expect(a.bookSourceName == "newer")   // newest lastUpdateTime wins the collision
    }

    @Test("importing a source stamps lastUpdateTime so the local import wins the sync merge")
    func importStampsLastUpdateTime() throws {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }
        store.replaceSourcesFromSync([])

        let before = Int64(Date().timeIntervalSince1970 * 1000)
        // JSON declares an ancient lastUpdateTime; the import must overwrite it with ~now, or an
        // older cloud copy would win the last-write-wins merge and revert the source.
        let json = #"[{"bookSourceName":"Stamp","bookSourceUrl":"https://stamp.test/x","lastUpdateTime":1000}]"#
        _ = try store.importFromJSON(json)

        let imported = try #require(store.sources.first { $0.bookSourceUrl == "https://stamp.test/x" })
        #expect(imported.lastUpdateTime >= before)
    }

    private func makeSource(index: Int) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Source \(index)"
        source.bookSourceUrl = "https://example.com/source-\(index)"
        return source
    }
}
