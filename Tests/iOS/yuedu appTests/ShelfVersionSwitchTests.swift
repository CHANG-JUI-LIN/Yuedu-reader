import Foundation
import Testing
@testable import yuedu_app

/// 換源 between versions of one work (maintainer 2026-10-26: an imported book changes source like
/// any other): the shelf moves to another copy, the one it leaves is kept beside it, and the
/// place is found again in the other copy's chapter list.
@MainActor
@Suite("換源 between versions of a work", .serialized)
struct ShelfVersionSwitchTests {
    private let sourceA = BookSource(bookSourceUrl: "https://version-switch-a.test", bookSourceName: "來源甲")
    private let sourceB = BookSource(bookSourceUrl: "https://version-switch-b.test", bookSourceName: "來源乙")

    /// An EPUB's table of contents: entries point into the spine, two share spine item 2, and
    /// front matter comes first.
    private let epubList = [
        OnlineChapterRef(index: 0, title: "封面", url: "cover.xhtml"),
        OnlineChapterRef(index: 2, title: "第一章 開始", url: "text.xhtml"),
        OnlineChapterRef(index: 2, title: "第二章 相遇", url: "text.xhtml#s2"),
        OnlineChapterRef(index: 5, title: "第三章 離別", url: "c3.xhtml"),
    ]
    /// A 來源配置's list: an entry's index is its place in the list.
    private let sourceList = [
        OnlineChapterRef(index: 0, title: "第一章 開始", url: "https://version-switch-a.test/1"),
        OnlineChapterRef(index: 1, title: "第二章 相遇", url: "https://version-switch-a.test/2"),
        OnlineChapterRef(index: 2, title: "第三章 離別", url: "https://version-switch-a.test/3"),
    ]

    // MARK: - Places

    @Test("a place in an EPUB's spine is found again in a source's list")
    func epubPlaceMapsToSourceList() {
        // Spine item 5 is 第三章; the source lists it third.
        #expect(VersionPlaceMapping.target(forSpine: 5, from: epubList, to: sourceList)
                == ReaderTOCTarget(spineIndex: 2, fragment: nil))
        // Spine item 3 lies inside the entry starting at item 2's anchor: still 第二章.
        #expect(VersionPlaceMapping.target(forSpine: 3, from: epubList, to: sourceList)
                == ReaderTOCTarget(spineIndex: 1, fragment: nil))
    }

    @Test("a source's chapter opens at the EPUB entry's spine item and anchor")
    func sourcePlaceMapsToEPUBEntry() {
        #expect(VersionPlaceMapping.target(forSpine: 1, from: sourceList, to: epubList)
                == ReaderTOCTarget(spineIndex: 2, fragment: "s2"))
        #expect(VersionPlaceMapping.target(forSpine: 2, from: sourceList, to: epubList)
                == ReaderTOCTarget(spineIndex: 5, fragment: nil))
    }

    @Test("a TXT's chapter is its place in the list")
    func txtPlaceMapsToEPUB() {
        let txtList = [
            OnlineChapterRef(index: 0, title: "第一章 開始", url: "0"),
            OnlineChapterRef(index: 1, title: "第二章 相遇", url: "1"),
            OnlineChapterRef(index: 2, title: "第三章 離別", url: "2"),
        ]
        #expect(VersionPlaceMapping.target(forSpine: 2, from: txtList, to: epubList)
                == ReaderTOCTarget(spineIndex: 5, fragment: nil))
    }

    @Test("a source's first chapter is found past the other version's front matter")
    func firstChapterMapsPastFrontMatter() {
        #expect(VersionPlaceMapping.target(forSpine: 0, from: sourceList, to: epubList)
                == ReaderTOCTarget(spineIndex: 2, fragment: nil))
        // An imported TXT lists the text before its first chapter as its own entry.
        let txtList = [
            OnlineChapterRef(index: 0, title: "Preface", url: "0"),
            OnlineChapterRef(index: 1, title: "第1章", url: "1"),
            OnlineChapterRef(index: 2, title: "第2章", url: "2"),
        ]
        let fixtureList = [OnlineChapterRef(index: 0, title: "第1章", url: "https://version-switch-a.test/1")]
        #expect(VersionPlaceMapping.target(forSpine: 0, from: fixtureList, to: txtList)
                == ReaderTOCTarget(spineIndex: 1, fragment: nil))
    }

    @Test("with either list empty, nothing is found again")
    func emptyListMapsNothing() {
        #expect(VersionPlaceMapping.target(forSpine: 3, from: [], to: sourceList) == nil)
        #expect(VersionPlaceMapping.target(forSpine: 3, from: epubList, to: []) == nil)
    }

    @Test("a highlight becomes a bookmark at its chapter's start, keeping its id, excerpt and note")
    func highlightCarriedAsBookmark() {
        let highlight = Bookmark(
            chapterIndex: 5, chapterTitle: "第三章 離別",
            position: CoreTextReadingPosition(spineIndex: 5, charOffset: 812),
            length: 40, kind: .highlight, note: "重讀", excerpt: "揮手自茲去"
        )
        let carried = VersionPlaceMapping.carried(highlight, from: epubList, to: sourceList)
        #expect(carried.id == highlight.id)
        #expect(carried.kind == .bookmark)
        #expect(carried.position == CoreTextReadingPosition(spineIndex: 2, charOffset: 0))
        #expect(carried.chapterTitle == "第三章 離別")
        #expect(carried.note == "重讀")
        #expect(carried.excerpt == "揮手自茲去")
    }

    // MARK: - Switching

    @Test("the shelf moves to the version, and the imported book is kept beside it")
    func switchMovesShelfAndKeepsImport() async throws {
        try await withFixture { store, positions, switcher in
            var imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            imported.group = "科幻"
            imported.customIntro = "自己寫的簡介"
            imported.addedDate = Date(timeIntervalSince1970: 1_000)
            imported.lastOpenedDate = Date(timeIntervalSince1970: 2_000)
            imported.bookmarks = [Bookmark(
                chapterIndex: 2, chapterTitle: "第二章 相遇",
                position: CoreTextReadingPosition(spineIndex: 2, charOffset: 90), length: 0, kind: .bookmark
            )]
            store.saveReadingBook(imported)
            let copy = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList, isInBookshelf: false
            )

            let opening = try await switcher.commit(from: imported.id, to: copy.id, readingFrom: 5)

            #expect(opening == ReaderTOCTarget(spineIndex: 2, fragment: nil))
            #expect(store.books.map(\.id) == [copy.id])
            let taken = try #require(store.readingBook(id: copy.id))
            #expect(taken.isInBookshelf)
            #expect(taken.versionOf == nil)
            #expect(taken.group == "科幻")
            #expect(taken.customIntro == "自己寫的簡介")
            #expect(taken.addedDate == Date(timeIntervalSince1970: 1_000))
            #expect(taken.bookmarks.map(\.position.spineIndex) == [1])
            #expect(positions.loadSync(for: copy.id.uuidString) == CoreTextReadingPosition(spineIndex: 2, charOffset: 0))
            let kept = try #require(store.readingBook(id: imported.id))
            #expect(!kept.isInBookshelf)
            #expect(kept.versionOf == copy.id)
            #expect(kept.contentFilename == imported.contentFilename)
            #expect(store.keptVersions(of: copy.id).map(\.id) == [imported.id])
            // Kept beside the shelf book, it is never asked about as a copy read on its own.
            #expect(ReaderShelvePrompt.copy(imported.id, in: store) == nil)
        }
    }

    @Test("switching back takes the kept version, and every kept version follows the shelf book")
    func switchBackRelinksKeptVersions() async throws {
        try await withFixture { store, _, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            let copyA = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList, isInBookshelf: false
            )
            var module = ReadingBook(title: "三體", author: "劉慈欣", source: "https://module.test/b", contentFilename: "")
            module.isOnline = true
            module.isInBookshelf = false
            module.versionOf = imported.id
            store.saveReadingBook(module)

            try await switcher.commit(from: imported.id, to: copyA.id)
            #expect(Set(store.keptVersions(of: copyA.id).map(\.id)) == [imported.id, module.id])

            try await switcher.commit(from: copyA.id, to: imported.id)
            #expect(store.books.map(\.id) == [imported.id])
            #expect(Set(store.keptVersions(of: imported.id).map(\.id)) == [copyA.id, module.id])
            #expect(store.readingBook(id: imported.id)?.versionOf == nil)
        }
    }

    @Test("deleting the shelf book deletes the versions kept beside it")
    func deletingShelfBookDeletesKeptVersions() async throws {
        try await withFixture { store, _, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            let copy = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList, isInBookshelf: false
            )
            try await switcher.commit(from: imported.id, to: copy.id)

            store.delete(bookId: copy.id)

            #expect(store.readingBook(id: copy.id) == nil)
            #expect(store.readingBook(id: imported.id) == nil)
        }
    }

    @Test("a book read from elsewhere takes the work's kept 來源配置 copy, rebound to the origin picked")
    func sourceCopyRebindsKeptCopy() async throws {
        try await withFixture { store, positions, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            var kept = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList, isInBookshelf: false
            )
            kept.onlineChapters = nil
            kept.versionOf = imported.id
            store.saveReadingBook(kept)

            let origin = BookOrigin(
                sourceId: sourceB.id, sourceName: "來源乙", bookUrl: "https://version-switch-b.test/book",
                tocUrl: "https://version-switch-b.test/book/toc", coverUrl: "", intro: "",
                lastChapter: "第三章 離別", wordCount: "", kind: "", runtimeVariables: nil
            )
            let toc = TOCPackage(
                sourceId: sourceB.id, sourceName: "來源乙", tocURL: origin.tocUrl, runtimeVariables: nil,
                chapters: sourceList, rawHTMLFilename: nil, savedAt: Date()
            )
            let id = try await switcher.sourceCopy(of: imported.id, origin: origin, toc: toc,
                                                   sourceSwitch: sourceSwitch(store, positions))

            #expect(id == kept.id)
            let rebound = try #require(store.readingBook(id: kept.id))
            #expect(rebound.bookSourceId == sourceB.id)
            #expect(rebound.bookInfoURL == "https://version-switch-b.test/book")
            #expect(store.readingBooks.filter { $0.bookSourceId != nil }.count == 1)
        }
    }

    @Test("with no 來源配置 copy kept, a new one is made off the shelf")
    func sourceCopyMadeOffShelf() async throws {
        try await withFixture { store, positions, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            let origin = BookOrigin(
                sourceId: sourceA.id, sourceName: "來源甲", bookUrl: "https://version-switch-a.test/book",
                tocUrl: "", coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil
            )
            let toc = TOCPackage(
                sourceId: sourceA.id, sourceName: "來源甲", tocURL: origin.bookUrl, runtimeVariables: nil,
                chapters: sourceList, rawHTMLFilename: nil, savedAt: Date()
            )
            let id = try await switcher.sourceCopy(of: imported.id, origin: origin, toc: toc,
                                                   sourceSwitch: sourceSwitch(store, positions))

            let made = try #require(store.readingBook(id: id))
            #expect(!made.isInBookshelf)
            #expect(made.title == "三體")
            #expect(made.author == "劉慈欣")
            #expect(made.bookSourceId == sourceA.id)
            #expect(made.onlineChapters?.count == sourceList.count)
            #expect(store.books.map(\.id) == [imported.id])
        }
    }

    // MARK: - Launch merge, 加入書架, sync

    @Test("the launch merge keeps an imported book beside the copy read last, deleting nothing")
    func launchMergeKeepsImportBeside() async throws {
        try await withFixture { store, positions, _ in
            var imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            imported.lastOpenedDate = Date(timeIntervalSince1970: 1_000)
            imported.group = "科幻"
            store.saveReadingBook(imported)
            let copy = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList
            )
            setOpened(store, copy.id, Date(timeIntervalSince1970: 2_000))

            let reports = await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            #expect(reports == [ShelfWorkMerger.Report(survivor: copy.id, merged: [], movedBookmarks: 0, kept: [imported.id])])
            #expect(store.books.map(\.id) == [copy.id])
            #expect(store.readingBook(id: copy.id)?.group == "科幻")
            let kept = try #require(store.readingBook(id: imported.id))
            #expect(kept.versionOf == copy.id)
            #expect(kept.contentFilename == imported.contentFilename)
        }
    }

    @Test("a file imported today and never opened does not take the shelf from the copy being read")
    func neverOpenedImportStaysBeside() async throws {
        try await withFixture { store, positions, _ in
            let copy = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList
            )
            setOpened(store, copy.id, Date(timeIntervalSince1970: 2_000))
            var imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            imported.addedDate = Date()
            store.saveReadingBook(imported)

            await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            #expect(store.books.map(\.id) == [copy.id])
            #expect(store.readingBook(id: imported.id)?.versionOf == copy.id)
        }
    }

    @Test("two imported books of one title that name no author stay two books")
    func authorlessImportsStayApart() async throws {
        try await withFixture { store, positions, _ in
            // The EPUB importer writes 「未知」 for a package with no author.
            store.saveReadingBook(ReadingBook(title: "筆記", author: "未知", source: "local_epub", contentFilename: "\(UUID()).epub"))
            store.saveReadingBook(ReadingBook(title: "筆記", author: "未知", source: "local_epub", contentFilename: "\(UUID()).epub"))

            let reports = await ShelfWorkMerger(store: store, positionStore: positions).mergeDuplicates()

            #expect(reports.isEmpty)
            #expect(store.books.count == 2)
        }
    }

    @Test("加入書架 from a 來源配置 of a work on the shelf as an imported book: the source copy takes the shelf")
    func addingSourceCopyKeepsImportBeside() async throws {
        try await withFixture { store, positions, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            await positions.save(CoreTextReadingPosition(spineIndex: 5, charOffset: 30), for: imported.id.uuidString)
            let service = ShelfWorkService(store: store, sourceSwitch: sourceSwitch(store, positions), versions: switcher)

            let outcome = try await service.add(ShelfWorkService.OnlineCopy(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", tocURL: nil, runtimeVariables: nil, chapters: sourceList
            ))

            guard case .switchedSource(let book) = outcome else {
                Issue.record("expected the source copy to take the shelf, got \(outcome)")
                return
            }
            #expect(store.books.map(\.id) == [book.id])
            #expect(book.bookSourceId == sourceA.id)
            #expect(store.readingBook(id: imported.id)?.versionOf == book.id)
            #expect(positions.loadSync(for: book.id.uuidString) == CoreTextReadingPosition(spineIndex: 2, charOffset: 0))
        }
    }

    @Test("a sync keeps a version off the shelf, and drops one deleted on another device")
    func syncKeepsVersionsOffShelf() async throws {
        try await withFixture { store, _, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            let copy = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList, isInBookshelf: false
            )
            try await switcher.commit(from: imported.id, to: copy.id)
            #expect(Set(store.syncedBooks.map(\.id)) == [imported.id, copy.id])
            let kept = try #require(store.readingBook(id: imported.id))
            #expect(ICloudSyncManager.syncableContentFilename(for: kept) == imported.contentFilename)

            #expect(store.replaceBooksFromSync(store.syncedBooks))
            #expect(store.books.map(\.id) == [copy.id])
            #expect(store.readingBook(id: imported.id)?.versionOf == copy.id)
            #expect(store.readingBook(id: imported.id)?.isInBookshelf == false)

            // Deleted on another device: the merge no longer has it.
            #expect(store.replaceBooksFromSync(store.syncedBooks.filter { $0.id != imported.id }))
            #expect(store.readingBook(id: imported.id) == nil)
        }
    }

    @Test("a version whose shelf book a sync removed is a shelf book again")
    func orphanVersionReturnsToShelf() async throws {
        try await withFixture { store, _, switcher in
            let imported = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
            store.saveReadingBook(imported)
            let copy = store.addOnlineBook(
                name: "三體", author: "劉慈欣", sourceId: sourceA.id,
                bookInfoURL: "https://version-switch-a.test/book", chapters: sourceList, isInBookshelf: false
            )
            try await switcher.commit(from: imported.id, to: copy.id)

            #expect(store.replaceBooksFromSync(store.syncedBooks.filter { $0.id != copy.id }))

            #expect(store.books.map(\.id) == [imported.id])
            #expect(store.readingBook(id: imported.id)?.versionOf == nil)
        }
    }

    // MARK: - Fixture

    private func setOpened(_ store: BookStore, _ id: UUID, _ date: Date) {
        guard var record = store.shelfRecord(id: id) else {
            Issue.record("no shelf record \(id)")
            return
        }
        record.lastOpenedDate = date
        store.saveReadingBook(record)
    }

    private func withFixture(
        _ body: (BookStore, VersionSwitchPositions, ShelfVersionSwitch) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfVersionSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([sourceA, sourceB])
        defer { BookSourceStore.shared.replaceSources(previousSources) }

        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let positions = VersionSwitchPositions()
        let epub = epubList
        // An imported EPUB lists its own entries; every other copy here is a source's.
        let switcher = ShelfVersionSwitch(store: store, positionStore: positions) { book in
            book.isOnline ? book.onlineChapters : epub
        }
        try await body(store, positions, switcher)
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
    }

    private func sourceSwitch(_ store: BookStore, _ positions: VersionSwitchPositions) -> OnlineBookSourceSwitch {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfVersionSwitchTests-offline-\(UUID().uuidString)", isDirectory: true)
        return OnlineBookSourceSwitch(
            store: store, positionStore: positions,
            offlineChapterStore: OfflineChapterStore(roots: OfflineStorageRoots(
                textRoot: directory.appendingPathComponent("text", isDirectory: true),
                mangaRoot: directory.appendingPathComponent("manga", isDirectory: true)
            )),
            chapterFetcher: nil
        )
    }
}

private final class VersionSwitchPositions: ReadingPositionStore, @unchecked Sendable {
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
