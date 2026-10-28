import Foundation
import Testing
@testable import yuedu_app

/// Bytes the shelf's own files take on each thing that happens while someone reads: a trip to
/// the background, a sync, a chapter check, a page further on.
///
/// 3.0.0 (136) MetricKit disk-write exception, 1073 MB within a day (Crashlytics
/// 00f6a2e72aee18fee23a5e7d8d963f20): the sampled write was `BookStore.writeMetadata`'s, on a
/// 55-book shelf (40 online, 12 MB of tables of contents) whose iCloud sync ran on every one of
/// dozens of trips to and from the background while a 430-chapter online book was read. Each
/// chapter cached then wrote its book's whole table of contents again (385 KB for 2000
/// chapters); a cached chapter now writes none of these files (`ModuleBookTests`). Each probe
/// prints one `DISKWRITE …` line.
@Suite("BookStore disk writes", .serialized)
@MainActor
struct BookStoreDiskWriteTests {
    /// The shelf directory's files, each by inode and size. An atomic write replaces the
    /// inode, so a changed inode is a whole file written again.
    private struct DiskSnapshot {
        let files: [String: (inode: UInt64, size: Int)]

        init(_ directory: URL) {
            var files: [String: (inode: UInt64, size: Int)] = [:]
            let enumerator = FileManager.default.enumerator(atPath: directory.path)
            while let relative = enumerator?.nextObject() as? String {
                let path = directory.appendingPathComponent(relative).path
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                files[relative] = (
                    (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    (attributes[.size] as? NSNumber)?.intValue ?? 0
                )
            }
            self.files = files
        }

        /// Bytes written since `earlier`, per file that was written.
        func written(since earlier: DiskSnapshot) -> [String: Int] {
            files.reduce(into: [:]) { result, entry in
                guard let before = earlier.files[entry.key] else {
                    result[entry.key] = entry.value.size
                    return
                }
                if before.inode != entry.value.inode || before.size != entry.value.size {
                    result[entry.key] = entry.value.size
                }
            }
        }
    }

    private struct Shelf {
        let directory: URL
        let store: BookStore
        let source: BookSource
        let longBook: ReadingBook
        let onlineBooks: [ReadingBook]
        let restoreSources: [BookSource]
    }

    private static func chapters(_ count: Int, book: Int) -> [OnlineChapterRef] {
        (0..<count).map {
            OnlineChapterRef(
                index: $0,
                title: "第\($0 + 1)章 風起雲湧 之 \($0 % 17)",
                url: "https://example.com/book/\(book)/\($0 + 1).html"
            )
        }
    }

    /// The field report's shelf: 40 online books, one of them a 2000-chapter list still
    /// carrying the cache marks a 3.0.0 (136) build wrote, three downloads, book variables,
    /// bookmarks and groups; and 15 local books. Written out and settled.
    private static func makeShelf() throws -> Shelf {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "寫入測試")
        let restoreSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([source])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStoreDiskWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let added = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var books: [ReadingBook] = (0..<40).map { index in
            var book = ReadingBook(title: "線上書 \(index)", author: "作者 \(index)",
                                   source: "https://example.com/book/\(index)", contentFilename: "")
            book.addedDate = added.addingTimeInterval(Double(index))
            book.isOnline = true
            book.contentPipelineKind = .html
            book.bookSourceId = source.id
            book.bookInfoURL = "https://example.com/book/\(index)"
            book.tocURL = "https://example.com/toc/\(index)"
            book.coverUrl = "https://example.com/cover/\(index).jpg"
            book.group = index % 3 == 0 ? "追更" : ""
            var list = chapters(index == 0 ? 2_000 : 400, book: index)
            if index == 0 {
                for chapter in 0..<431 { list[chapter].cachedFilename = "\(chapter).txt" }
                book.lastOpenedDate = added.addingTimeInterval(10_000)
                book.currentPosition = 0.215
                book.bookmarks = (0..<5).map {
                    Bookmark(chapterIndex: $0 * 80, chapterTitle: list[$0 * 80].title,
                             position: CoreTextReadingPosition(spineIndex: $0 * 80, charOffset: 120), excerpt: "摘錄 \($0)")
                }
            }
            if index % 5 == 1 {
                book.runtimeVariables = ["token": "t\(index)", "uid": "\(index * 7)", "domain": "m.example.com", "page": "1"]
            }
            if (1...3).contains(index) {
                // One download done, one done but for a failed chapter, one stopped midway.
                var task = BookOfflineDownloadTask(requestedIndices: Set(0..<400), now: added)
                for chapter in 0..<(index == 3 ? 270 : 399) { task.markCompleted(chapter, now: added) }
                if index == 1 { task.markCompleted(399, now: added) }
                if index == 2 {
                    task.markFailed(OfflineChapterFailure(chapterIndex: 399, title: list[399].title, category: .network,
                                                          message: "timed out", occurredAt: added))
                }
                book.offlineDownloadTask = task
                book.offlineDownloadState = task.derivedState(isRunning: false)
                book.downloadedChapterCount = task.completedChapterCount
            }
            book.onlineChapters = list
            book.applyChapterSummary(from: list)
            return book
        }
        let onlineBooks = books
        books += (0..<15).map {
            var book = ReadingBook(title: "本機書 \($0)", author: "作者", contentFilename: "local-\($0).txt")
            book.addedDate = added.addingTimeInterval(Double(100 + $0))
            return book
        }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        store.replaceBooksFromSync(books)
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
        return Shelf(
            directory: directory, store: store, source: source, longBook: onlineBooks[0],
            onlineBooks: onlineBooks, restoreSources: restoreSources
        )
    }

    private static func tearDown(_ shelf: Shelf) {
        shelf.store.waitForQueuedWrites()
        BookSourceStore.shared.replaceSources(shelf.restoreSources)
        try? FileManager.default.removeItem(at: shelf.directory)
    }

    /// Runs `operation`, lets every write it queued land, and returns what it wrote.
    private static func measure(
        _ name: String, _ shelf: Shelf, _ operation: () async throws -> Void
    ) async rethrows -> [String: Int] {
        let before = DiskSnapshot(shelf.directory)
        try await operation()
        shelf.store.flushPendingMetadataSave()
        shelf.store.waitForQueuedWrites()
        let written = DiskSnapshot(shelf.directory).written(since: before)
        let total = written.values.reduce(0, +)
        let detail = written.sorted { $0.value > $1.value }.prefix(4)
            .map { "\($0.key.split(separator: "/").last ?? "")=\($0.value)" }
            .joined(separator: " ")
        print("DISKWRITE op=\(name) bytes=\(total) files=\(written.count) \(detail)")
        return written
    }

    @Test("a trip to the background with nothing changed writes nothing")
    func unchangedSceneTripWritesNothing() async throws {
        let shelf = try Self.makeShelf()
        defer { Self.tearDown(shelf) }
        let position = try #require(shelf.store.books.first { $0.id == shelf.longBook.id }?.currentPosition)
        let written = await Self.measure("sceneTrip", shelf) {
            // What the reader and the app do on `.inactive` and `.background`.
            shelf.store.updatePosition(bookId: shelf.longBook.id, position: position, forceSave: true)
            shelf.store.flushPendingMetadataSave()
        }
        #expect(written.isEmpty, "\(written)")
    }

    /// The sync merges the shelf on every trip to and from the background; only a merge that
    /// differs from the shelf reaches `applySyncSnapshot` and its write.
    @Test("a sync that brings nothing new is not applied")
    func unchangedSyncIsNotApplied() throws {
        let shelf = try Self.makeShelf()
        defer { Self.tearDown(shelf) }
        let id: (ReadingBook) -> String = { $0.id.uuidString }
        let hash: (ReadingBook) -> String = { ICloudSyncManager.stableHash($0.strippedForSync()) }
        let updatedAt: (ReadingBook) -> Date = { $0.lastOpenedDate ?? $0.addedDate }
        // The sync before: this shelf against an empty cloud, uploaded as `uploadRecords` does.
        let local = shelf.store.syncedBooks.map { $0.withoutTableOfContents() }
        let previous = ICloudSyncManager.resolveMerge(
            local: local, remote: [], shadow: [:], id: id, hash: hash, fallbackUpdatedAt: updatedAt
        )
        let values = Dictionary(uniqueKeysWithValues: previous.values.map { (id($0), $0) })
        let blob = try ICloudSyncManager.encodeCloudSyncRecords(previous.shadow.map {
            CloudSyncRecord(id: $0.key, value: values[$0.key], updatedAt: $0.value.updatedAt, deleted: $0.value.deleted)
        })
        let remote = try ICloudSyncManager.decodeCloudSyncBlob(
            blob, recordName: "books", id: id, fallbackUpdatedAt: updatedAt
        ).records

        let merge = ICloudSyncManager.resolveMerge(
            local: shelf.store.syncedBooks.map { $0.withoutTableOfContents() }, remote: remote,
            shadow: previous.shadow, id: id, hash: hash, fallbackUpdatedAt: updatedAt
        )
        #expect(!merge.shouldApplyLocally)
    }

    @Test("a chapter check that finds every list unchanged writes nothing")
    func unchangedRefreshWritesNothing() async throws {
        let shelf = try Self.makeShelf()
        defer { Self.tearDown(shelf) }
        let written = try await Self.measure("unchangedRefresh", shelf) {
            for (index, book) in shelf.onlineBooks.enumerated() {
                // A parser hands every chapter a fresh id and no cache mark; the list is
                // otherwise the same.
                _ = try await shelf.store.refreshOnlineBookMetadata(
                    bookId: book.id,
                    bookSourceFetcher: FixedTOCFetcher(package: TOCPackage(
                        sourceId: shelf.source.id, sourceName: shelf.source.bookSourceName,
                        tocURL: "https://example.com/toc/\(index)", runtimeVariables: nil,
                        chapters: Self.chapters(index == 0 ? 2_000 : 400, book: index),
                        rawHTMLFilename: nil, savedAt: Date()
                    ))
                )
            }
        }
        #expect(written.isEmpty, "\(written)")
    }

    @Test("reading on writes the shelf alone, once per real move")
    func readingOnWritesTheShelfAlone() async throws {
        let shelf = try Self.makeShelf()
        defer { Self.tearDown(shelf) }
        var bytes = 0
        for step in 1...10 {
            let written = await Self.measure("progress", shelf) {
                shelf.store.updatePosition(bookId: shelf.longBook.id, position: 0.215 + Double(step) * 0.003)
            }
            #expect(Array(written.keys) == ["books_meta.json"], "\(written)")
            bytes += written.values.reduce(0, +)
        }
        print("DISKWRITE summary progressAvg=\(bytes / 10)")
    }
}

/// Answers a table-of-contents refresh with a fixed package, handed over as the first page
/// first, as the runtime fetch does.
private struct FixedTOCFetcher: BookSourceFetching {
    let package: TOCPackage

    func fetchBookInfoPackage(
        url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "FixedTOCFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool
    ) async throws -> TOCPackage {
        onFirstPageReady?(package.chapters)
        return package
    }

    func isChapterCached(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> Bool { false }
    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }
    func search(
        query: String, in source: BookSource, earlyFilter: ((String, String) -> Bool)?
    ) async throws -> [OnlineBook] { [] }
    func loadChapterPackageSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> ChapterPackage? { nil }
    func loadNormalizedChapterHTMLSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> String? { nil }
}
