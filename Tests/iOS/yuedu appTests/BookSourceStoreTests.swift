import Combine
import Foundation
import Testing
@testable import yuedu_app

@Suite("BookSourceStore", .serialized)
@MainActor
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

    @Test("dedupedByURL breaks a clock tie the same way whatever the order")
    func dedupedByURLBreaksATieByID() throws {
        var a = BookSource()
        a.bookSourceUrl = "https://dup.test/a"
        a.lastUpdateTime = 100
        var b = a
        b.id = UUID()   // another device's copy, on the same clock

        // A merge lists this device's copies first, so each device would keep its own.
        let one = BookSourceStore.dedupedByURL([a, b])
        let other = BookSourceStore.dedupedByURL([b, a])

        #expect(one.count == 1)
        #expect(one.map(\.id) == other.map(\.id))
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

    // MARK: - Import merge
    //
    // The merge indexes the existing sources by `bookSourceUrl` instead of running a
    // `firstIndex(where:)` scan per imported source, and inserts the genuinely new ones in
    // one batch instead of one at a time. These lock in the four behaviours that made the
    // old shape observable: update-in-place, order, intra-pack dedupe, and the 置底 boundary.

    @Test("re-importing a pack updates matching sources in place and keeps list order")
    func reimportUpdatesInPlaceKeepingOrder() throws {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let existing = (0..<3).map(makeSource)
        store.replaceSourcesFromSync(existing)

        var updated = makeSource(index: 1)      // same bookSourceUrl as existing[1]
        updated.bookSourceName = "Renamed"
        let newcomer = makeSource(index: 9)

        _ = try store.importFromJSON(try encodeSources([updated, newcomer]))

        #expect(store.sources.count == 4)
        #expect(store.sources.map(\.bookSourceUrl)
            == existing.map(\.bookSourceUrl) + [newcomer.bookSourceUrl])
        // The stored id must survive the update, or the iCloud merge sees a different source.
        #expect(store.sources[1].id == existing[1].id)
        #expect(store.sources[1].bookSourceName == "Renamed")
    }

    @Test("the same URL twice inside one imported pack collapses to the last entry")
    func duplicateURLWithinOnePackCollapses() throws {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }
        store.replaceSourcesFromSync([])

        var first = makeSource(index: 0)
        first.bookSourceName = "First"
        var second = makeSource(index: 0)       // same URL
        second.bookSourceName = "Second"

        _ = try store.importFromJSON(try encodeSources([first, second]))

        #expect(store.sources.count == 1)
        #expect(store.sources.first?.bookSourceName == "Second")
    }

    @Test("a whole imported batch lands above the 置底 group, in import order")
    func importBatchStaysAboveBottomPin() throws {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let existing = (0..<2).map(makeSource)
        store.replaceSourcesFromSync(existing)
        store.pinToBottom(id: existing[1].id)

        let newcomers = (5..<8).map(makeSource)
        _ = try store.importFromJSON(try encodeSources(newcomers))

        #expect(store.sources.map(\.bookSourceUrl)
            == [existing[0].bookSourceUrl] + newcomers.map(\.bookSourceUrl)
                + [existing[1].bookSourceUrl])
        #expect(store.pinRecord(for: existing[1].id)?.position == .bottom)
    }

    @Test("exportToJSON(ids:) exports exactly the selected sources, in list order")
    func exportSelectedSources() throws {
        let store = BookSourceStore.shared
        let previousSources = store.sources
        defer { store.replaceSourcesFromSync(previousSources) }

        let sources = (0..<4).map(makeSource)
        store.replaceSourcesFromSync(sources)

        let json = store.exportToJSON(ids: [sources[3].id, sources[1].id])
        let exported = try #require(BookSourceStore.parseSources(json))

        #expect(exported.map(\.bookSourceUrl)
            == [sources[1].bookSourceUrl, sources[3].bookSourceUrl])
    }

    // MARK: - Large libraries (temporary stores; the shared library is untouched)

    @Test("bulk writes publish once instead of once per source")
    func bulkWritesPublishOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreBulk-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        store.replaceSourcesFromSync((0..<2_000).map(makeSource))
        let ids = Set(store.sources.map(\.id))
        var sends = 0
        let subscription = store.objectWillChange.sink { sends += 1 }
        defer { subscription.cancel() }

        store.setRespondTimes(Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(1_234)) }))
        #expect(sends == 1)
        sends = 0
        store.setEnabledByUser(ids: ids, enabled: false)
        #expect(sends == 1)
        sends = 0
        store.setEnabled(ids: ids, enabled: true)
        #expect(sends == 1)
        sends = 0
        store.replaceGroup("", with: "新分組", ids: ids)
        #expect(sends == 1)
        sends = 0
        #expect(store.groupByDomain() == 2_000)
        #expect(sends == 1)
        sends = 0
        store.toggle(id: store.sources[0].id)
        #expect(sends == 1)

        #expect(store.sources.allSatisfy { $0.respondTime == 1_234 })
        #expect(store.sources.dropFirst().allSatisfy { $0.enabled })
        #expect(store.sources[0].enabled == false)
    }

    // MARK: - Several groups per source (Legado's `bookSourceGroup`)

    @Test("group edits change only the group they name and keep the source's other groups")
    func replaceGroupKeepsOtherGroups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreGroups-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        var fantasy = makeSource(index: 0)
        fantasy.bookSourceGroup = "玄幻,搜索失效"
        var mixed = makeSource(index: 1)
        // Legado splits on `,;，；` (`AppPattern.splitGroupRegex`) and trims each name.
        mixed.bookSourceGroup = " 都市 ；玄幻"
        var plain = makeSource(index: 2)
        plain.bookSourceGroup = "玄幻"
        let none = makeSource(index: 3)
        store.replaceSourcesFromSync([fantasy, mixed, plain, none])
        func group(_ source: BookSource) -> String? {
            store.sources.first { $0.id == source.id }?.bookSourceGroup
        }
        var sends = 0
        let subscription = store.objectWillChange.sink { sends += 1 }
        defer { subscription.cancel() }

        // Leaving a group a source is in for one it already has rewrites nothing.
        store.replaceGroup("都市", with: "都市", ids: [mixed.id])
        #expect(group(mixed) == " 都市 ；玄幻")
        #expect(sends == 0)

        // 重命名分組 玄幻 → 奇幻: each source keeps the new name where the old one was, and
        // keeps every other group — the 搜索失效 a 書源驗證 wrote included.
        store.replaceGroup("玄幻", with: "奇幻", ids: [fantasy.id, mixed.id, plain.id])
        #expect(group(fantasy) == "奇幻,搜索失效")
        #expect(group(mixed) == "都市,奇幻")
        #expect(group(plain) == "奇幻")
        #expect(group(none) == "")
        #expect(sends == 1)
        // Group membership is synced source content: changed sources advance their clock.
        #expect(store.sources.first { $0.id == fantasy.id }?.lastUpdateTime ?? 0 > 0)
        #expect(store.sources.first { $0.id == none.id }?.lastUpdateTime == 0)

        // 合併到其他分組 奇幻 → 搜索失效: a source already in 搜索失效 just leaves 奇幻.
        store.replaceGroup("奇幻", with: "搜索失效", ids: [fantasy.id, mixed.id, plain.id])
        #expect(group(fantasy) == "搜索失效")
        #expect(group(mixed) == "都市,搜索失效")
        #expect(group(plain) == "搜索失效")

        // 移出分組, or merging into 默認分組: leave, join nothing. With no group left the
        // source is back in 默認分組.
        store.replaceGroup("搜索失效", with: "", ids: [mixed.id, plain.id])
        #expect(group(mixed) == "都市")
        #expect(group(plain) == "")

        // 加入分組 leaves nothing; a typed 「甲，乙;都市」 joins each group once.
        store.replaceGroup("", with: "甲，乙;都市", ids: [mixed.id, none.id])
        #expect(group(mixed) == "都市,甲,乙")
        #expect(group(none) == "甲,乙,都市")

        // A source no longer in the group a frozen menu named is left alone.
        sends = 0
        let before = store.sources.map(\.bookSourceGroup)
        store.replaceGroup("不存在", with: "丙", ids: Set(store.sources.map(\.id)))
        #expect(store.sources.map(\.bookSourceGroup) == before)
        #expect(sends == 0)
    }

    @Test("a source counts once in each of its groups when a group picker opens")
    func groupCountsSplitTheField() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreGroupCounts-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        let fields = ["玄幻,搜索失效", "搜索失效；玄幻;玄幻", " 都市 ", "", ",;"]
        store.replaceSourcesFromSync(fields.enumerated().map { index, field in
            var source = makeSource(index: index)
            source.bookSourceGroup = field
            return source
        })

        let counts = store.groupCounts()
        #expect(counts.map(\.name) == ["玄幻", "搜索失效", "都市"])
        #expect(counts.map(\.count) == [2, 2, 1])
        let joining = store.groupCounts(excluding: ["玄幻", "搜索失效"])
        #expect(joining.map(\.name) == ["都市"])
    }

    // FB-123: 資源庫 recomputed its explore sources from the store inside
    // `onReceive(sourcesPublisher)`, and lagged one edit behind 來源配置管理.
    @Test("a sourcesPublisher subscriber sees the toggled library in the published value")
    func sourcesPublisherSendsTheNewLibrary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStorePublisher-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        let sources = (0..<3).map { index in
            var source = makeSource(index: index)
            source.exploreUrl = "https://example.com/explore-\(index)"
            return source
        }
        store.replaceSourcesFromSync(sources)
        #expect(DiscoverViewModel.exploreSources(in: store).count == 3)

        var fromValue: [Int] = []
        var fromStore: [Int] = []
        let subscription = store.sourcesPublisher.dropFirst().sink { library in
            fromValue.append(DiscoverViewModel.exploreSources(in: library).count)
            fromStore.append(DiscoverViewModel.exploreSources(in: store).count)
        }
        defer { subscription.cancel() }

        store.toggle(id: sources[0].id)

        #expect(fromValue == [2])
        #expect(DiscoverViewModel.exploreSources(in: store).count == 2)
        // Why the subscriber must not read the store: it still holds the library before the edit.
        #expect(fromStore == [3])
    }

    @Test("bulk writes stay linear on a 20,000-source library")
    func bulkWritesStayLinear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreLinear-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        store.replaceSourcesFromSync((0..<20_000).map(makeSource))
        store.waitForQueuedWrites()
        let ids = store.sources.map(\.id)

        let startedAt = ProcessInfo.processInfo.systemUptime
        store.setRespondTimes(Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            ($0.element, Int64($0.offset))
        }))
        store.setEnabledByUser(ids: Set(ids), enabled: false)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        // Per-element writes to the `@Published` array took 117 s and 228 s here.
        #expect(elapsed < 5, "bulk writes took \(elapsed) s")
    }

    @Test("a burst of edits persists the newest library")
    func burstOfEditsPersistsTheNewestLibrary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreBurst-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.replaceSourcesFromSync((0..<50).map(makeSource))

        for index in 0..<5 {
            store.toggle(id: store.sources[index].id)
        }
        store.pinToTop(id: store.sources[40].id)
        store.waitForQueuedWrites()

        let reloaded = BookSourceStore(directory: directory)
        #expect(reloaded.sources.map(\.id) == store.sources.map(\.id))
        #expect(reloaded.sources.map(\.enabled) == store.sources.map(\.enabled))
        #expect(reloaded.pinRecord(for: store.sources[0].id)?.position == .top)
    }

    @Test("the streamed library file holds exactly the sources written")
    func streamedLibraryMatchesOneShotEncode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreStream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // ≈4 KB of rules each, so the write crosses the 1 MB chunk boundary several times.
        let sources = (0..<1_200).map { index -> BookSource in
            var source = makeSource(index: index)
            source.bookSourceComment = String(repeating: "規則說明 \(index) ", count: 300)
            return source
        }
        let url = directory.appendingPathComponent("book_sources.json")

        let bytes = try BookSourceStore.writeLibrary(sources, to: url)
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(bytes == fileSize, "the count `DiskWriteTally` records is the file's size")

        // Compared through sorted keys: `JSONEncoder` orders keys differently on every call
        // (the one-shot encode the writer replaced did too), so equal files are equal JSON,
        // not equal bytes.
        let written = try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: url))
        #expect(try sortedJSON(written) == sortedJSON(sources))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            == ["book_sources.json"], "no temporary file may be left behind")

        try BookSourceStore.writeLibrary([], to: url)
        #expect(try Data(contentsOf: url) == Data("[]".utf8))
    }

    @Test("a store reloads the library its streamed save wrote")
    func storeReloadsStreamedSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreStreamReload-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.replaceSourcesFromSync((0..<300).map(makeSource))
        store.waitForQueuedWrites()

        let reloaded = BookSourceStore(directory: directory)
        #expect(try sortedJSON(reloaded.sources) == sortedJSON(store.sources))
    }

    @Test("saving a source unchanged does not rewrite the library")
    func unchangedUpdateDoesNotRewrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreUnchanged-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.replaceSourcesFromSync((0..<50).map(makeSource))
        store.waitForQueuedWrites()
        // Every write renames a new file over the library, so the file number names the write.
        let url = directory.appendingPathComponent("book_sources.json")
        func fileNumber() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        }
        let firstWrite = try #require(try fileNumber())
        let clock = store.sources[3].lastUpdateTime

        var same = store.sources[3]
        same.lastUpdateTime += 1
        store.update(same)
        store.waitForQueuedWrites()
        #expect(try fileNumber() == firstWrite)
        #expect(store.sources[3].lastUpdateTime == clock)

        var edited = store.sources[3]
        edited.bookSourceComment = "edited"
        store.update(edited)
        store.waitForQueuedWrites()
        #expect(try fileNumber() != firstWrite)
        #expect(store.sources[3].lastUpdateTime > clock)
    }

    @Test("re-importing an unchanged pack keeps every source's sync clock")
    func reimportingUnchangedPackKeepsTheClock() throws {
        let store = BookSourceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceStoreReimport-\(UUID().uuidString)"))
        let pack = (0..<20).map { index -> BookSource in
            var source = makeSource(index: index)
            source.searchUrl = "https://example.com/search?q={{key}}&i=\(index)"
            source.ruleSearch.bookList = ".book"
            source.header = #"{"User-Agent":"Fixture"}"#
            return source
        }
        store.replaceSourcesFromSync(pack.map { source -> BookSource in
            var stamped = source
            stamped.lastUpdateTime = 1_000
            return stamped
        })
        var edited = pack[3]
        edited.bookSourceComment = "改過了"

        _ = try store.importFromJSON(try encodeSources(pack.enumerated().map { $0.offset == 3 ? edited : $0.element }))

        let clocks = store.sources.map(\.lastUpdateTime)
        #expect(clocks.filter { $0 == 1_000 }.count == 19, "unchanged sources must keep their clock")
        #expect(store.sources.first { $0.bookSourceUrl == edited.bookSourceUrl }?.lastUpdateTime != 1_000)
    }

    @Test("hasSameContent ignores key order and the sync clock, not the rules")
    func sameContentComparison() {
        var source = makeSource(index: 1)
        source.ruleSearch.bookList = ".book"
        source.header = #"{"User-Agent":"Fixture"}"#
        var reclocked = source
        reclocked.lastUpdateTime = 42
        var edited = source
        edited.ruleSearch.bookList = ".other"

        for _ in 0..<20 {
            #expect(source.hasSameContent(as: source))
        }
        #expect(source.hasSameContent(as: reclocked))
        #expect(!source.hasSameContent(as: edited))
    }

    private func sortedJSON(_ sources: [BookSource]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(sources)
    }

    private func encodeSources(_ sources: [BookSource]) throws -> String {
        String(decoding: try JSONEncoder().encode(sources), as: UTF8.self)
    }

    private func makeSource(index: Int) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Source \(index)"
        source.bookSourceUrl = "https://example.com/source-\(index)"
        return source
    }
}
