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

    private func makeSource(index: Int) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Source \(index)"
        source.bookSourceUrl = "https://example.com/source-\(index)"
        return source
    }
}
