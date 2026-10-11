import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5c-4: Explore's 「相關」 row — the latest copy's work from another place, then
/// its series, then its authors — and the one work index behind it.
@Suite("Related works")
struct RelatedWorksTests {
    private static let dav = SourceInstanceKey(type: .webDAV, id: "dav")

    private static func copy(_ title: String, _ author: String, series: String? = nil,
                             source: SourceItemKey? = nil) -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(key: source ?? .copy(id), title: title, authors: [author], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, series: series)
    }

    private static func file(_ path: String, _ title: String, _ author: String, series: String? = nil) -> WorkIndexEntry {
        let record = SourceRecord(key: SourceItemKey(instance: dav, item: path), title: title, authors: [author], language: nil,
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.download(format: "epub")])
        return WorkIndexEntry(record: record, series: series)
    }

    @Test("the seed's work from elsewhere, then its series, then its author; never the seed or its own file")
    func order() {
        let ownFile = SourceItemKey(instance: Self.dav, item: "三體.epub")
        let seed = Self.copy("三體", "劉慈欣", series: "地球往事", source: ownFile)
        let ownFileEntry = Self.file("三體.epub", "三體", "劉慈欣", series: "地球往事")
        let otherEdition = Self.file("另一版/三体.epub", "三体", "刘慈欣")
        let sequel = Self.copy("黑暗森林", "劉慈欣", series: "地球往事")
        let sameAuthor = Self.copy("球狀閃電", "劉慈欣")
        let unrelated = Self.copy("紅樓夢", "曹雪芹")
        let entries = [seed, ownFileEntry, otherEdition, sequel, sameAuthor, unrelated]
        let index = WorkIndex.build(entries: entries)
        let shown = Set(entries.map(\.nodeKey))

        let picked = RelatedWorks.pick(in: index, seed: seed.nodeKey, continueReading: [], shown: shown, limit: 20)
        #expect(picked == [otherEdition.nodeKey, sequel.nodeKey, sameAuthor.nodeKey])
    }

    @Test("an item matching series and author appears once; no 繼續閱讀 copy is shown; the limit holds")
    func dedupeAndLimit() {
        let first = Self.copy("黑暗森林", "劉慈欣", series: "地球往事")
        let second = Self.copy("死神永生", "劉慈欣", series: "地球往事")
        let more = (0..<5).map { Self.copy("短篇\($0)", "劉慈欣") }
        let entries = [first, second] + more
        let index = WorkIndex.build(entries: entries)
        let shown = Set(entries.map(\.nodeKey))

        let picked = RelatedWorks.pick(in: index, seed: first.nodeKey, continueReading: [first.nodeKey, second.nodeKey],
                                       shown: shown, limit: 20)
        #expect(!picked.contains(first.nodeKey))
        #expect(!picked.contains(second.nodeKey))
        #expect(Set(picked).count == picked.count)
        #expect(Set(picked) == Set(more.map(\.nodeKey)))
        #expect(RelatedWorks.pick(in: index, seed: first.nodeKey, continueReading: [], shown: shown, limit: 3).count == 3)
    }

    @Test("one card a work, a shelf copy before a file; a node not shown is left out")
    func oneCardAWork() {
        let seed = Self.copy("球狀閃電", "劉慈欣")
        let shelfCopy = Self.copy("超新星紀元", "劉慈欣")
        let file = Self.file("超新星紀元.epub", "超新星紀元", "劉慈欣")
        let offShelf = Self.copy("流浪地球", "劉慈欣")
        let entries = [seed, shelfCopy, file, offShelf]
        let index = WorkIndex.build(entries: entries)
        let shown = Set([seed, shelfCopy, file].map(\.nodeKey))

        #expect(RelatedWorks.pick(in: index, seed: seed.nodeKey, continueReading: [], shown: shown, limit: 20)
                == [shelfCopy.nodeKey])
        #expect(RelatedWorks.pick(in: index, seed: seed.nodeKey, continueReading: [], shown: shown, limit: 0).isEmpty)
    }

    /// Maintainer, 2026-10-11: one seed, the copy opened most recently.
    @Test("only the latest copy seeds the row; an older 繼續閱讀 copy adds nothing of its own")
    func latestCopyOnly() {
        let latest = Self.copy("三體", "劉慈欣")
        let older = Self.copy("紅樓夢", "曹雪芹")
        let sameAuthor = Self.copy("球狀閃電", "劉慈欣")
        let olderAuthor = Self.copy("石頭記補", "曹雪芹")
        let entries = [latest, older, sameAuthor, olderAuthor]
        let index = WorkIndex.build(entries: entries)
        let shown = Set(entries.map(\.nodeKey))

        let picked = RelatedWorks.pick(in: index, seed: latest.nodeKey, continueReading: [latest.nodeKey, older.nodeKey],
                                       shown: shown, limit: 20)
        #expect(picked == [sameAuthor.nodeKey])
    }
}

@MainActor
@Suite("Related row and the one work index", .serialized)
struct RelatedRowTests {
    private func folder() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Related-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, { try? FileManager.default.removeItem(at: folder) })
    }

    private static let noContext: @MainActor ([ReadingBook]) -> SourceRecordContext = { _ in
        SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })
    }

    @Test("callers during a refresh share it and one more; the book sources are awaited once")
    func singleFlight() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        store.saveReadingBook(ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "a.epub"))
        var waits = 0
        let service = WorkIndexService(store: store, directory: folder.appendingPathComponent("Works"),
                                       makeContext: Self.noContext, waitForSources: { waits += 1 })
        var applies = 0
        service.willApplyForTesting = { applies += 1 }

        async let first = service.current()
        async let second = service.current()
        async let third = service.current()
        let results = await [first, second, third]
        #expect(results.allSatisfy { $0.works.count == 1 })
        #expect(waits == 1)
        // The first run, then one more for the callers that arrived during it.
        #expect(applies <= 2)

        _ = await service.current()
        #expect(waits == 1)
        WorkIndexService.waitForPendingSavesForTesting()
    }

    @Test("a refresh dropped by a shelf change is not retried; the last index stands")
    func droppedIsNotRetried() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        store.saveReadingBook(ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "a.epub"))
        let service = WorkIndexService(store: store, directory: folder.appendingPathComponent("Works"),
                                       makeContext: Self.noContext, waitForSources: {})
        var applies = 0
        service.willApplyForTesting = {
            applies += 1
            store.saveReadingBook(ReadingBook(title: "紅樓夢", author: "曹雪芹", source: "local_epub", contentFilename: "\(applies).epub"))
        }
        #expect(await service.current() == .empty)
        #expect(applies == 1)

        service.willApplyForTesting = nil
        #expect(await service.current().works.count == 2)
        WorkIndexService.waitForPendingSavesForTesting()
    }

    @Test("an index file from before series keys is rebuilt")
    func schemaTwoIsDiscarded() throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let url = folder.appendingPathComponent("index.json")
        let old = WorkIndexFile(schemaVersion: 2, inputs: [], remoteInputs: [], decisions: [], index: .empty)
        try JSONEncoder().encode(old).write(to: url)
        guard case .discarded = WorkIndexService.load(url) else {
            Issue.record("a schema-2 file is discarded")
            return
        }
    }

    @Test("「相關」 on the shelf: a sidecar's series and the author, around what was opened last")
    func shelfRow() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer {
            store.importedMetadata.waitForPendingWritesForTesting()
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        var seed = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "a.epub")
        seed.lastOpenedDate = Date()
        let sequel = ReadingBook(title: "黑暗森林", author: "另一位", source: "local_epub", contentFilename: "b.epub")
        let sameAuthor = ReadingBook(title: "球狀閃電", author: "劉慈欣", source: "local_epub", contentFilename: "c.epub")
        let unrelated = ReadingBook(title: "紅樓夢", author: "曹雪芹", source: "local_epub", contentFilename: "d.epub")
        [seed, sequel, sameAuthor, unrelated].forEach { store.saveReadingBook($0) }
        for book in [seed, sequel] {
            store.importedMetadata.write(ImportedMetadata(copyID: book.id, sourceItem: .copy(book.id), identifiers: [], values: [
                MetadataValue(field: .series, value: .text("地球往事"), provider: .localLibrary, sourceItem: .copy(book.id), fetchedAt: Date()),
            ]))
        }
        store.importedMetadata.waitForPendingWritesForTesting()

        let provider = ShelfProvider(store: store)
        #expect(provider.loadPolicy(for: HomeSection(layout: .row, binding: .related)) == .local)
        let entries = try await provider.load(HomeSection(layout: .row, binding: .related))
        let titles = entries.compactMap { entry -> String? in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
        #expect(titles == ["黑暗森林", "球狀閃電"])
    }

    @Test("「相關」 with nothing opened is empty, and its row is hidden")
    func nothingOpened() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        store.saveReadingBook(ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "a.epub"))
        #expect(await ShelfProvider(store: store).related(limit: HomeRow.limit).isEmpty)
        #expect(store.workIndex.index == nil)
    }

    /// Phase 2's measured size: 20,000 indexed files, and a shelf of 300 copies with 20 opened.
    @Test("「相關」 over a 20,000-file index")
    func atScale() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let shelf = folder.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: shelf)
        defer {
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        let connection = OPDSCatalog(name: "DAV", url: "https://dav.test/books/", kind: .webDAV)
        let instance = SourceInstanceKey(type: .webDAV, id: connection.id)
        var state = WebDAVIndexState(connectionID: connection.id, root: URL(string: connection.url)!)
        state.records = (0..<20_000).map { index in
            let record = SourceRecord(key: SourceItemKey(instance: instance, item: "d\(index / 10)/b\(index).epub"),
                                      title: "第\(index)部", authors: ["作者\(index % 1_000)"], language: nil, contentKind: .text,
                                      identifiers: [], copyID: nil, acquisitions: [.download(format: "epub")])
            var file = IndexedFile(record: record, etag: "\"\(index)\"", lastModified: nil, size: 1)
            if index % 4 == 0 {
                file.values = [MetadataValue(field: .series, value: .text("系列\(index % 500)"), provider: instance,
                                             sourceItem: record.key, fetchedAt: Date(timeIntervalSinceReferenceDate: 0))]
            }
            return file
        }
        store.remoteRecords.save(state)
        store.remoteRecords.waitForPendingWritesForTesting()
        for index in 0..<300 {
            var book = ReadingBook(title: "第\(index * 7)部", author: "作者\((index * 7) % 1_000)", source: "local_epub",
                                   contentFilename: "\(index).epub")
            if index < 20 { book.lastOpenedDate = Date(timeIntervalSinceReferenceDate: Double(1_000 - index)) }
            store.saveReadingBook(book)
        }

        let clock = ContinuousClock()
        var longestGap = Duration.zero
        let ticking = Task { @MainActor in
            var last = clock.now
            while !Task.isCancelled {
                await Task.yield()
                let now = clock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
        }
        let provider = ShelfProvider(store: store, webDAVRoots: { [connection.id: URL(string: connection.url)!] })
        var start = clock.now
        let cold = await provider.related(limit: HomeRow.limit)
        let coldTime = clock.now - start
        start = clock.now
        let warm = await provider.related(limit: HomeRow.limit)
        let warmTime = clock.now - start
        let index = await store.workIndex.current()
        let opened = store.books.filter { $0.lastOpenedDate != nil }.sorted { $0.lastOpenedDate! > $1.lastOpenedDate! }
        let continueReading = Set(opened.map { SourceItemKey.copy($0.id) })
        let seed = SourceItemKey.copy(opened[0].id)
        let shown = Set(index.entries.map(\.nodeKey))
        let pickTime = clock.measure {
            _ = RelatedWorks.pick(in: index, seed: seed, continueReading: continueReading, shown: shown, limit: HomeRow.limit)
        }
        ticking.cancel()
        print("⏱ home.related files=20000 copies=300 cold=\(coldTime) warm=\(warmTime) pick=\(pickTime) "
            + "works=\(index.works.count) mainActorLongestGap=\(longestGap)")
        #expect(cold.count == HomeRow.limit)
        #expect(warm.count == HomeRow.limit)
        #expect(longestGap < .milliseconds(100))
    }
}
