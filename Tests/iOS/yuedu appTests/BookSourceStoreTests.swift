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

    @Test("stale sync result cannot restore a source deleted during the network merge")
    func staleSyncResultCannotRestoreDeletedSource() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let source = makeSource(index: 99)
        store.replaceSourcesFromSync([source])
        let snapshotRevision = store.mutationRevision

        store.delete(id: source.id)
        let applied = store.replaceSourcesFromSync(
            [source],
            expectedMutationRevision: snapshotRevision
        )

        #expect(applied == false)
        #expect(store.sources.isEmpty)
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

    @Test("置頂／置底 move a source to either end without disturbing the others")
    func pinToTopAndBottomReorderSources() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<4).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[2].id)
        #expect(store.sources.map(\.id)
            == [sources[2].id, sources[0].id, sources[1].id, sources[3].id])

        store.pinToBottom(id: sources[0].id)
        #expect(store.sources.map(\.id)
            == [sources[2].id, sources[1].id, sources[3].id, sources[0].id])
    }

    @Test("置頂／置底 leave the sync clock alone — position isn't source content")
    func pinDoesNotAdvanceLastUpdateTime() throws {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        var sources = (0..<3).map(makeSource)
        for index in sources.indices {
            sources[index].lastUpdateTime = 1000
        }
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[2].id)
        store.pinToBottom(id: sources[0].id)

        #expect(store.sources.allSatisfy { $0.lastUpdateTime == 1000 })
    }

    @Test("unknown ids are no-ops; re-pinning a pinned source refreshes its timestamp")
    func unknownIDsAreNoOpsAndRepinRefreshesTimestamp() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<3).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[0].id)
        let firstPin = store.pinRecord(for: sources[0].id)
        store.pinToBottom(id: sources[2].id)

        store.pinToTop(id: sources[0].id)      // re-pin: newest-first, timestamp refreshes
        store.pinToBottom(id: sources[2].id)   // re-pin: same
        store.pinToTop(id: UUID())             // unknown ids must not reorder anything
        store.pinToBottom(id: UUID())
        store.unpin(id: UUID())

        let secondPin = store.pinRecord(for: sources[0].id)
        #expect(secondPin?.position == .top)
        #expect(secondPin?.pinnedAt ?? .distantPast >= firstPin?.pinnedAt ?? .distantPast)
        #expect(store.sources.first?.id == sources[0].id)
        #expect(store.pinRecord(for: sources[2].id)?.position == .bottom)
    }

    @Test("置頂 pins to the head and 取消置頂 restores the original position")
    func pinToTopThenUnpinRestoresPosition() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<5).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[3].id)
        #expect(store.pinRecord(for: sources[3].id)?.position == .top)
        #expect(store.pinRecord(for: sources[3].id)?.originalIndex == 3)
        #expect(store.sources.map(\.id)
            == [sources[3].id, sources[0].id, sources[1].id, sources[2].id, sources[4].id])

        store.unpin(id: sources[3].id)
        #expect(store.pinRecord(for: sources[3].id) == nil)
        #expect(store.sources.map(\.id) == sources.map(\.id))
    }

    @Test("置底 pins to the tail and 取消置底 restores the original position")
    func pinToBottomThenUnpinRestoresPosition() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<5).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToBottom(id: sources[1].id)
        #expect(store.pinRecord(for: sources[1].id)?.position == .bottom)
        #expect(store.sources.map(\.id)
            == [sources[0].id, sources[2].id, sources[3].id, sources[4].id, sources[1].id])

        store.unpin(id: sources[1].id)
        #expect(store.pinRecord(for: sources[1].id) == nil)
        #expect(store.sources.map(\.id) == sources.map(\.id))
    }

    @Test("multiple 置頂 pins coexist, newest first")
    func pinToTopKeepsNewestFirst() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<4).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[2].id)
        store.pinToTop(id: sources[1].id)   // newer pin lands above the older one

        #expect(store.sources.map(\.id)
            == [sources[1].id, sources[2].id, sources[0].id, sources[3].id])
        #expect(store.pinRecord(for: sources[1].id)?.position == .top)
        #expect(store.pinRecord(for: sources[2].id)?.position == .top)
        let newer = store.pinRecord(for: sources[1].id)?.pinnedAt ?? .distantPast
        let older = store.pinRecord(for: sources[2].id)?.pinnedAt ?? .distantPast
        #expect(newer >= older)
    }

    @Test("multiple 置底 pins coexist, newest first")
    func pinToBottomKeepsNewestFirst() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<4).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToBottom(id: sources[0].id)
        store.pinToBottom(id: sources[1].id)   // newer pin sits above the older one

        #expect(store.sources.map(\.id)
            == [sources[2].id, sources[3].id, sources[1].id, sources[0].id])
        #expect(store.pinRecord(for: sources[1].id)?.position == .bottom)
        #expect(store.pinRecord(for: sources[0].id)?.position == .bottom)
    }

    @Test("取消置頂 clamps to the list when sources were deleted meanwhile")
    func unpinClampsWhenListShrank() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<5).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[4].id)   // originalIndex = 4
        store.delete(ids: [sources[1].id, sources[2].id, sources[3].id])
        store.unpin(id: sources[4].id)

        #expect(store.sources.map(\.id) == [sources[0].id, sources[4].id])
    }

    @Test("deleting a pinned source clears its pin record")
    func deleteClearsPinRecord() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<3).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[2].id)
        store.delete(id: sources[2].id)

        #expect(store.pinRecord(for: sources[2].id) == nil)
        #expect(store.sources.map(\.id) == [sources[0].id, sources[1].id])
    }

    @Test("add() never lands above a 置頂 source")
    func addRespectsTopPin() {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<3).map(makeSource)
        store.replaceSourcesFromSync(sources)

        store.pinToTop(id: sources[2].id)
        var newcomer = BookSource()
        newcomer.bookSourceName = "New"
        newcomer.bookSourceUrl = "https://example.com/new"
        store.add(newcomer)

        #expect(store.sources.map(\.id)
            == [sources[2].id, newcomer.id, sources[0].id, sources[1].id])
        #expect(store.pinRecord(for: sources[2].id)?.position == .top)
    }

    private func makeSource(index: Int) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Source \(index)"
        source.bookSourceUrl = "https://example.com/source-\(index)"
        return source
    }
}
