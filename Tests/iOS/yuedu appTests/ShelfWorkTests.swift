import Foundation
import Testing
@testable import yuedu_app

/// One book per work on the shelf (feedback #16, maintainer 2026-10-18): adding a work that is
/// already on the shelf switches that book's source through 換源; copies already on the shelf
/// merge into the most recently read one.
@MainActor
@Suite("One book per work on the shelf", .serialized)
struct ShelfWorkTests {
    private let sourceA = BookSource(bookSourceUrl: "https://shelf-work-a.test", bookSourceName: "來源甲")
    private let sourceB = BookSource(bookSourceUrl: "https://shelf-work-b.test", bookSourceName: "來源乙")

    private let listA = [
        OnlineChapterRef(index: 0, title: "序章", url: "https://shelf-work-a.test/0"),
        OnlineChapterRef(index: 1, title: "第一章 開始", url: "https://shelf-work-a.test/1"),
        OnlineChapterRef(index: 2, title: "第二章 相遇", url: "https://shelf-work-a.test/2"),
        OnlineChapterRef(index: 3, title: "第三章 離別", url: "https://shelf-work-a.test/3"),
    ]
    private let listB = [
        OnlineChapterRef(index: 0, title: "第一章 開始", url: "https://shelf-work-b.test/1"),
        OnlineChapterRef(index: 1, title: "第二章 相遇", url: "https://shelf-work-b.test/2"),
        OnlineChapterRef(index: 2, title: "第三章 離別", url: "https://shelf-work-b.test/3"),
    ]

    // MARK: - Adding

    @Test("adding a shelved work from another source switches that book and keeps its chapter")
    func addingSameWorkSwitchesSource() async throws {
        try await withFixture { store, positions, service in
            let shelved = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: listA
            )
            await positions.save(CoreTextReadingPosition(spineIndex: 2, charOffset: 500), for: shelved.id.uuidString)

            // Simplified title and author: still the same work (`WorkMatchKey`).
            let outcome = try await service.add(copyFromB(name: "三体", author: "刘慈欣"))

            guard case .switchedSource(let book) = outcome else {
                Issue.record("expected the shelf book to switch source, got \(outcome)")
                return
            }
            #expect(book.id == shelved.id)
            #expect(store.books.count == 1)
            let switched = try #require(store.readingBook(id: shelved.id))
            #expect(switched.bookSourceId == sourceB.id)
            #expect(switched.bookInfoURL == "https://shelf-work-b.test/book")
            #expect(switched.onlineChapters?.map(\.title) == listB.map(\.title))
            // 第二章 was index 2 in A and is index 1 in B; the offset belongs to A's text.
            #expect(positions.loadSync(for: shelved.id.uuidString) == CoreTextReadingPosition(spineIndex: 1, charOffset: 0))
            // The page now finds this source's copy on the shelf.
            #expect(store.onlineBook(sourceId: sourceB.id, bookInfoURL: "https://shelf-work-b.test/book")?.id == shelved.id)
        }
    }

    @Test("the same source and URL is already on the shelf")
    func sameSourceSameURLIsAlreadyOnShelf() async throws {
        try await withFixture { store, _, service in
            let shelved = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/book", chapters: listB
            )
            let outcome = try await service.add(copyFromB(name: "三體", author: "劉慈欣"))
            guard case .alreadyOnShelf(let book) = outcome else {
                Issue.record("expected alreadyOnShelf, got \(outcome)")
                return
            }
            #expect(book.id == shelved.id)
            #expect(store.books.count == 1)
        }
    }

    @Test("another work, or a copy without an author, is added as its own book")
    func differentWorksAreAdded() async throws {
        try await withFixture { store, _, service in
            _ = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: listA
            )
            let sequel = try await service.add(copyFromB(name: "三體II", author: "劉慈欣"))
            let otherAuthor = try await service.add(copyFromB(name: "三體", author: "王晉康", url: "https://shelf-work-b.test/2"))
            let noAuthor = try await service.add(copyFromB(name: "三體", author: "", url: "https://shelf-work-b.test/3"))

            for outcome in [sequel, otherAuthor, noAuthor] {
                guard case .added = outcome else {
                    Issue.record("expected a new book, got \(outcome)")
                    continue
                }
            }
            #expect(store.books.count == 4)
        }
    }

    @Test("a read copy joining the shelf merges into the work's shelf book with what was read")
    func readCopyJoinsTheShelfBook() async throws {
        try await withFixture { store, positions, service in
            let shelved = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: listA
            )
            setLastOpened(store, shelved.id, Date(timeIntervalSince1970: 1_000))
            await positions.save(CoreTextReadingPosition(spineIndex: 1, charOffset: 0), for: shelved.id.uuidString)

            let read = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/book", chapters: listB, isInBookshelf: false
            )
            store.updateLastOpened(bookId: read.id)
            await positions.save(CoreTextReadingPosition(spineIndex: 2, charOffset: 30), for: read.id.uuidString)
            store.addBookmark(bookId: read.id, bookmark: Bookmark(
                chapterIndex: 1, chapterTitle: "第二章 相遇",
                position: CoreTextReadingPosition(spineIndex: 1, charOffset: 12), note: "讀時記的"
            ))

            let joined = try #require(try await service.shelveReadCopy(id: read.id))

            #expect(joined.id == shelved.id)
            #expect(store.books.count == 1)
            #expect(store.readingBook(id: read.id) == nil)
            #expect(joined.bookSourceId == sourceB.id)
            // Read last, on the same list it now reads from: its place carries over as it is.
            #expect(positions.loadSync(for: shelved.id.uuidString) == CoreTextReadingPosition(spineIndex: 2, charOffset: 30))
            #expect(joined.bookmarks.map(\.note) == ["讀時記的"])
            #expect(joined.bookmarks.first?.position == CoreTextReadingPosition(spineIndex: 1, charOffset: 12))
        }
    }

    // MARK: - Reader settings (feedback #74)

    @Test("a read copy set to 條漫 and added to the shelf opens in 條漫 again")
    func readCopyAddedToShelfKeepsReaderSettings() async throws {
        try await withFixture { store, _, service in
            let read = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/manga", contentKind: .manga,
                chapters: listB, isInBookshelf: false
            )
            store.updateLastOpened(bookId: read.id)
            let webtoon = FixedPageReadingMode.webtoon.recommendedConfiguration
            store.readerSettings.setFixedPageConfiguration(webtoon, for: read.id)

            let shelved = try #require(try await service.shelveReadCopy(id: read.id))

            #expect(shelved.isInBookshelf)
            #expect(store.readerSettings.fixedPageConfiguration(for: shelved.id) == webtoon)
        }
    }

    @Test("a read copy set to 條漫 that joins its work's shelf book opens that book in 條漫")
    func readCopyMergedIntoShelfBookCarriesReaderSettings() async throws {
        try await withFixture { store, _, service in
            let shelved = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/manga", contentKind: .manga, chapters: listA
            )
            store.readerSettings.setFixedPageConfiguration(FixedPageReadingMode.ltr.recommendedConfiguration, for: shelved.id)
            let read = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/manga", contentKind: .manga,
                chapters: listB, isInBookshelf: false
            )
            store.updateLastOpened(bookId: read.id)
            // Chosen after the shelf book's own: the latest choice is the one the work keeps.
            let webtoon = FixedPageReadingMode.webtoon.recommendedConfiguration
            store.readerSettings.setFixedPageConfiguration(webtoon, for: read.id)

            let joined = try #require(try await service.shelveReadCopy(id: read.id))

            #expect(joined.id == shelved.id)
            #expect(store.readingBook(id: read.id) == nil)
            #expect(store.readerSettings.fixedPageConfiguration(for: shelved.id) == webtoon)
        }
    }

    @Test("加入書架 on the detail page shelves the copy read earlier and still here, with its 條漫")
    func addingShelvesTheLeftoverReadCopy() async throws {
        try await withFixture { store, _, service in
            // The app ended while its reader was open, or 作品詳情's prompt was declined.
            let read = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/manga", contentKind: .manga,
                chapters: listB, isInBookshelf: false
            )
            store.updateLastOpened(bookId: read.id)
            let webtoon = FixedPageReadingMode.webtoon.recommendedConfiguration
            store.readerSettings.setFixedPageConfiguration(webtoon, for: read.id)

            let outcome = try await service.add(copyFromB(
                name: "海賊王", author: "尾田榮一郎", url: "https://shelf-work-b.test/manga"
            ))

            guard case .added(let book) = outcome else {
                Issue.record("expected the read copy to join the shelf, got \(outcome)")
                return
            }
            #expect(book.id == read.id)
            #expect(store.books.map(\.id) == [read.id])
            #expect(store.readerSettings.fixedPageConfiguration(for: book.id) == webtoon)
        }
    }

    @Test("加入書架 of a work on the shelf from another source merges the copy read earlier into it")
    func addingMergesTheLeftoverReadCopyIntoTheShelfBook() async throws {
        try await withFixture { store, _, service in
            let shelved = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/manga", contentKind: .manga, chapters: listA
            )
            let read = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/manga", contentKind: .manga,
                chapters: listB, isInBookshelf: false
            )
            store.updateLastOpened(bookId: read.id)
            let webtoon = FixedPageReadingMode.webtoon.recommendedConfiguration
            store.readerSettings.setFixedPageConfiguration(webtoon, for: read.id)

            let outcome = try await service.add(copyFromB(
                name: "海賊王", author: "尾田榮一郎", url: "https://shelf-work-b.test/manga"
            ))

            guard case .switchedSource(let book) = outcome else {
                Issue.record("expected the shelf book to take this source, got \(outcome)")
                return
            }
            #expect(book.id == shelved.id)
            #expect(store.readingBook(id: read.id) == nil)
            #expect(store.readerSettings.fixedPageConfiguration(for: shelved.id) == webtoon)
        }
    }

    @Test("launch merge gives the kept copy the merged copy's reader settings when it has none")
    func launchMergeCarriesReaderSettings() async throws {
        try await withFixture { store, positions, _ in
            let older = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/manga", contentKind: .manga, chapters: listA
            )
            let newer = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/manga", contentKind: .manga, chapters: listB
            )
            setLastOpened(store, older.id, Date(timeIntervalSince1970: 1_000))
            setLastOpened(store, newer.id, Date(timeIntervalSince1970: 2_000))
            let webtoon = FixedPageReadingMode.webtoon.recommendedConfiguration
            store.readerSettings.setFixedPageConfiguration(webtoon, for: older.id)

            await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            #expect(store.books.map(\.id) == [newer.id])
            #expect(store.readerSettings.fixedPageConfiguration(for: newer.id) == webtoon)
        }
    }

    @Test("launch merge keeps the kept copy's own reader settings when they were changed last")
    func launchMergeKeepsNewerReaderSettings() async throws {
        try await withFixture { store, positions, _ in
            let older = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/manga", contentKind: .manga, chapters: listA
            )
            let newer = store.addOnlineBook(
                name: "海賊王", author: "尾田榮一郎", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/manga", contentKind: .manga, chapters: listB
            )
            setLastOpened(store, older.id, Date(timeIntervalSince1970: 1_000))
            setLastOpened(store, newer.id, Date(timeIntervalSince1970: 2_000))
            store.readerSettings.setFixedPageConfiguration(FixedPageReadingMode.webtoon.recommendedConfiguration, for: older.id)
            let ltr = FixedPageReadingMode.ltr.recommendedConfiguration
            store.readerSettings.setFixedPageConfiguration(ltr, for: newer.id)

            await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            #expect(store.books.map(\.id) == [newer.id])
            #expect(store.readerSettings.fixedPageConfiguration(for: newer.id) == ltr)
        }
    }

    // MARK: - Launch merge

    @Test("launch merge keeps the most recently read copy and moves the other's bookmarks")
    func launchMergeKeepsMostRecent() async throws {
        try await withFixture { store, positions, service in
            let older = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: listA
            )
            let newer = store.addOnlineBook(
                name: "三体", author: "刘慈欣", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/book", chapters: listB
            )
            setLastOpened(store, older.id, Date(timeIntervalSince1970: 1_000))
            setLastOpened(store, newer.id, Date(timeIntervalSince1970: 2_000))
            store.setGroup("科幻", for: older.id)
            // A chapter-start bookmark of 第二章 (index 2 in A) and a highlight in 第一章.
            let chapterMark = Bookmark(
                chapterIndex: 2, chapterTitle: "第二章 相遇",
                position: CoreTextReadingPosition(spineIndex: 2, charOffset: 0)
            )
            let highlight = Bookmark(
                chapterIndex: 1, chapterTitle: "第一章 開始",
                position: CoreTextReadingPosition(spineIndex: 1, charOffset: 40),
                length: 10, kind: .highlight, note: "要記得", excerpt: "一段文字"
            )
            store.addBookmark(bookId: older.id, bookmark: chapterMark)
            store.addBookmark(bookId: older.id, bookmark: highlight)
            await positions.save(CoreTextReadingPosition(spineIndex: 1, charOffset: 77), for: newer.id.uuidString)

            let merger = ShelfWorkMerger(store: store, positionStore: positions)
            let reports = await merger.mergeDuplicates()

            #expect(reports == [ShelfWorkMerger.Report(survivor: newer.id, merged: [older.id], movedBookmarks: 2)])
            #expect(store.books.map(\.id) == [newer.id])
            #expect(store.readingBook(id: older.id) == nil)
            let survivor = try #require(store.readingBook(id: newer.id))
            #expect(survivor.bookSourceId == sourceB.id)
            #expect(survivor.group == "科幻")
            let moved = Dictionary(uniqueKeysWithValues: survivor.bookmarks.map { ($0.id, $0) })
            // 第二章: index 2 in A, 1 in B.
            #expect(moved[chapterMark.id]?.position == CoreTextReadingPosition(spineIndex: 1, charOffset: 0))
            #expect(moved[chapterMark.id]?.chapterTitle == "第二章 相遇")
            // The highlight's offset is into A's text, and its chapter moved: it becomes a
            // bookmark at the start of 第一章 in B, note and excerpt kept.
            let carried = try #require(moved[highlight.id])
            #expect(carried.kind == .bookmark)
            #expect(carried.position == CoreTextReadingPosition(spineIndex: 0, charOffset: 0))
            #expect(carried.note == "要記得")
            #expect(carried.excerpt == "一段文字")
            // The kept copy was read last: its place is untouched.
            #expect(positions.loadSync(for: newer.id.uuidString) == CoreTextReadingPosition(spineIndex: 1, charOffset: 77))

            // Running it again finds nothing to merge.
            let again = await merger.mergeDuplicates()
            #expect(again.isEmpty)
            #expect(store.books.map(\.id) == [newer.id])
            #expect(store.readingBook(id: newer.id)?.bookmarks.count == 2)
            _ = service
        }
    }

    @Test("a copy without its chapter list never carries a highlight's range (synced or imported copy)")
    func copyWithoutListCarriesNoRange() async throws {
        try await withFixture { store, positions, _ in
            // A copy synced from another device or imported from Legado has no list here.
            let listless = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: []
            )
            let kept = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/book", chapters: listB
            )
            setLastOpened(store, listless.id, Date(timeIntervalSince1970: 1_000))
            setLastOpened(store, kept.id, Date(timeIntervalSince1970: 2_000))
            let highlight = Bookmark(
                chapterIndex: 1, chapterTitle: "第二章 相遇",
                position: CoreTextReadingPosition(spineIndex: 1, charOffset: 40),
                length: 10, kind: .highlight, note: "筆記", excerpt: "摘錄"
            )
            store.addBookmark(bookId: listless.id, bookmark: highlight)

            await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            let carried = try #require(store.readingBook(id: kept.id)?.bookmarks.first { $0.id == highlight.id })
            #expect(carried.kind == .bookmark)
            #expect(carried.position == CoreTextReadingPosition(spineIndex: 1, charOffset: 0))
            #expect(carried.note == "筆記")
            #expect(carried.excerpt == "摘錄")
        }
    }

    @Test("the merged copy's deletion becomes an iCloud tombstone")
    func mergedCopyIsTombstoned() async throws {
        try await withFixture { store, positions, _ in
            let older = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: listA
            )
            let newer = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/book", chapters: listB
            )
            setLastOpened(store, older.id, Date(timeIntervalSince1970: 1_000))
            setLastOpened(store, newer.id, Date(timeIntervalSince1970: 2_000))
            let synced = Date(timeIntervalSince1970: 3_000)
            // Both were synced before the merge; the cloud still has the older copy.
            let shadow = [
                older.id.uuidString: SyncShadowEntry(updatedAt: synced, hash: "old", deleted: false),
                newer.id.uuidString: SyncShadowEntry(updatedAt: synced, hash: "new", deleted: false),
            ]
            let remote = store.books.map {
                FirestoreSyncRecord(id: $0.id.uuidString, value: $0, updatedAt: synced, deleted: false)
            }

            await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            let result = ICloudSyncManager.resolveMerge(
                local: store.books,
                remote: remote,
                shadow: shadow,
                id: { $0.id.uuidString },
                hash: { $0.id == newer.id ? "new" : "old" },
                fallbackUpdatedAt: { $0.addedDate },
                now: Date(timeIntervalSince1970: 4_000)
            )
            #expect(result.shadow[older.id.uuidString]?.deleted == true)
            #expect(!result.values.contains { $0.id == older.id })
            #expect(result.values.contains { $0.id == newer.id })
        }
    }

    @Test("the survivor is the same whatever order the shelf is in; ties go to the lower id")
    func survivorIsDeterministic() async throws {
        try await withFixture { store, _, _ in
            let same = Date(timeIntervalSince1970: 5_000)
            let tiedA = makeBook(source: sourceA, opened: same)
            let tiedB = makeBook(source: sourceB, opened: same)
            let older = makeBook(source: sourceB, opened: Date(timeIntervalSince1970: 10))
            let books = [tiedA, older, tiedB]
            let forward = ShelfWork.duplicateSets(in: books, decisions: [])
            let backward = ShelfWork.duplicateSets(in: books.reversed(), decisions: [])
            #expect(forward.map { $0.map(\.id) } == backward.map { $0.map(\.id) })
            let expected = [tiedA, tiedB].min { $0.id.uuidString < $1.id.uuidString }!
            #expect(forward.first?.first?.id == expected.id)
            #expect(forward.first?.last?.id == older.id)
            #expect(forward.first?.count == 3)
            _ = store
        }
    }

    @Test("copies the reader split into different works are not merged")
    func splitWorksStayApart() async throws {
        try await withFixture { store, positions, _ in
            let first = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://shelf-work-a.test/book", chapters: listA
            )
            let second = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceB.id,
                bookInfoURL: "https://shelf-work-b.test/book", chapters: listB
            )
            store.workDecisions.record(.differentWorks(.copy(first.id), .copy(second.id), decidedAt: Date()))

            let reports = await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            #expect(reports.isEmpty)
            #expect(store.books.count == 2)
        }
    }

    // MARK: - Helpers

    private func withFixture(
        _ body: (BookStore, InMemoryShelfPositions, ShelfWorkService) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfWorkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([sourceA, sourceB])
        defer { BookSourceStore.shared.replaceSources(previousSources) }

        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let positions = InMemoryShelfPositions()
        let offline = OfflineChapterStore(roots: OfflineStorageRoots(
            textRoot: directory.appendingPathComponent("text", isDirectory: true),
            mangaRoot: directory.appendingPathComponent("manga", isDirectory: true)
        ))
        let service = ShelfWorkService(
            store: store,
            sourceSwitch: OnlineBookSourceSwitch(
                store: store, positionStore: positions, offlineChapterStore: offline, chapterFetcher: nil
            )
        )
        try await body(store, positions, service)
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
    }

    private func copyFromB(name: String, author: String, url: String = "https://shelf-work-b.test/book") -> ShelfWorkService.OnlineCopy {
        ShelfWorkService.OnlineCopy(
            name: name, author: author, sourceId: sourceB.id,
            bookInfoURL: url, tocURL: "\(url)/toc",
            runtimeVariables: nil, chapters: listB
        )
    }

    private func setLastOpened(_ store: BookStore, _ id: UUID, _ date: Date) {
        guard var record = store.shelfRecord(id: id) else {
            Issue.record("no shelf record \(id)")
            return
        }
        record.lastOpenedDate = date
        store.saveReadingBook(record)
    }

    private func makeBook(source: BookSource, opened: Date) -> ReadingBook {
        let url = "\(source.bookSourceUrl)/\(UUID().uuidString)"
        var book = ReadingBook(title: "三體", author: "劉慈欣", source: url, contentFilename: "")
        book.isOnline = true
        book.bookSourceId = source.id
        book.bookInfoURL = url
        book.lastOpenedDate = opened
        return book
    }
}

private final class InMemoryShelfPositions: ReadingPositionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CoreTextReadingPosition] = [:]

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        lock.withLock { storage[bookId] = position }
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        loadSync(for: bookId)
    }

    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        lock.withLock { storage[bookId] }
    }

    func flush(for bookId: String) async {}
}
