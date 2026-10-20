import Foundation
import Testing
@testable import yuedu_app

/// 目錄跟書分開存，像 legado 的 `books` 表和 `chapters` 表。
///
/// 2026-10-04 一位測試者 110 本線上書的 `books_meta.json` 是 138 MB：每本書的完整目錄都在裡面，
/// 而聽書每念一段就排一次存檔。App 離開前景時那次存檔在主執行緒把 138 MB 整份重新編碼，
/// 超過 scene-update 看門狗的 10 秒，被 0x8BADF00D 殺掉（build 113 的 MetricKit 堆疊：
/// `flushPendingMetadataSave` → `encodeBooksMetadata`）。
@Suite("Book chapter storage", .serialized)
@MainActor
struct BookChapterStorageTests {

    @Test("the shelf file carries no table of contents")
    func shelfFileCarriesNoTableOfContents() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)

        store.replaceBooksFromSync([onlineBook(title: "長篇", chapterCount: 3)])

        let shelf = try shelfObjects(at: metadataURL)
        #expect(shelf.count == 1)
        #expect(shelf.first?["onlineChapters"] == nil)
    }

    @Test("a reading-position save leaves every table of contents untouched")
    func positionSaveLeavesTablesOfContentsUntouched() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let first = onlineBook(title: "第一本", chapterCount: 40)
        let second = onlineBook(title: "第二本", chapterCount: 40)
        store.replaceBooksFromSync([first, second])
        let before = try [first.id, second.id].map { try fileNumber(of: chapterFile(for: $0, metadataURL: metadataURL)) }

        store.updatePosition(bookId: first.id, position: 0.5, forceSave: true)
        store.waitForQueuedWrites()

        let after = try [first.id, second.id].map { try fileNumber(of: chapterFile(for: $0, metadataURL: metadataURL)) }
        #expect(after == before)
        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(saved.first { $0.id == first.id }?.currentPosition == 0.5)
    }

    @Test("marking one chapter cached rewrites only that book's table of contents")
    func cachedChapterMarkRewritesOnlyItsBook() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let read = onlineBook(title: "正在聽", chapterCount: 40)
        let other = onlineBook(title: "沒動", chapterCount: 40)
        store.replaceBooksFromSync([read, other])
        let readBefore = try fileNumber(of: chapterFile(for: read.id, metadataURL: metadataURL))
        let otherBefore = try fileNumber(of: chapterFile(for: other.id, metadataURL: metadataURL))

        // 聽書每念完一章就會標記快取；離開前景時寫下。
        store.updateCachedChapter(bookId: read.id, chapterIndex: 7, filename: "chapter-7.html")
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()

        #expect(try fileNumber(of: chapterFile(for: read.id, metadataURL: metadataURL)) != readBefore)
        #expect(try fileNumber(of: chapterFile(for: other.id, metadataURL: metadataURL)) == otherBefore)
        let reopened = BookStore(metadataFileURL: metadataURL)
        #expect(reopened.readingBook(id: read.id)?.onlineChapters?[7].cachedFilename == "chapter-7.html")
    }

    @Test("a shelf saved with its tables of contents inside opens complete and moves them out")
    func inlineShelfOpensCompleteAndMovesListsOut() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        var chapters = Self.chapters(count: 12)
        chapters[4].cachedFilename = "chapter-4.html"
        chapters[9].runtimeVariables = ["sign": "abc"]
        let book = onlineBook(title: "舊版書架", chapterCount: 0)
        try writeInlineShelf([(book, chapters)], to: metadataURL)

        let store = BookStore(metadataFileURL: metadataURL)
        store.waitForQueuedWrites()

        #expect(describe(store.readingBook(id: book.id)?.onlineChapters) == describe(chapters))
        #expect(try shelfObjects(at: metadataURL).first?["onlineChapters"] == nil)
        #expect(FileManager.default.fileExists(atPath: chapterFile(for: book.id, metadataURL: metadataURL).path))
        let reopened = BookStore(metadataFileURL: metadataURL)
        #expect(describe(reopened.readingBook(id: book.id)?.onlineChapters) == describe(chapters))
    }

    @Test("a table of contents an older build wrote into the shelf wins over the list file it left behind")
    func inlineListFromOlderBuildWinsOverStaleFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let book = onlineBook(title: "降版又升版", chapterCount: 5)
        BookStore(metadataFileURL: metadataURL).replaceBooksFromSync([book])
        // The older build re-fetched the list, found two more chapters and wrote them inline.
        let newer = Self.chapters(count: 7)
        try writeInlineShelf([(book, newer)], to: metadataURL)

        let store = BookStore(metadataFileURL: metadataURL)

        #expect(describe(store.readingBook(id: book.id)?.onlineChapters) == describe(newer))
    }

    @Test("deleting a book deletes its table of contents")
    func deletingBookDeletesItsTableOfContents() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let book = onlineBook(title: "要刪的書", chapterCount: 5)
        store.replaceBooksFromSync([book])
        let file = chapterFile(for: book.id, metadataURL: metadataURL)
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.delete(bookId: book.id)
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a shelf record carries only a summary; the book opened by id brings its list")
    func recordsCarrySummaryAndOpenedBookCarriesList() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        var book = onlineBook(title: "有卷名的書", chapterCount: 0)
        var chapters = Self.chapters(count: 30)
        chapters.append(OnlineChapterRef(index: 30, title: "第二卷 完", url: "", isVolume: true))
        book.onlineChapters = chapters
        store.replaceBooksFromSync([book])

        let record = try #require(store.books.first)
        #expect(record.onlineChapters == nil)
        #expect(record.totalChapterNum == 31)
        // legado's latestChapterTitle: the newest readable chapter, not the closing volume header.
        #expect(record.latestChapterDisplayTitle == "第30章 武魂二次覺醒")
        #expect(store.readingBook(id: book.id)?.onlineChapters == chapters)
        #expect(store.chapters(for: book.id) == chapters)

        // 啟動時檢查更新 finds two new chapters: the summary follows the list.
        store.updateOnlineChapters(bookId: book.id, chapters: Self.chapters(count: 33))
        #expect(store.books.first?.totalChapterNum == 33)
        #expect(store.books.first?.latestChapterDisplayTitle == "第33章 武魂二次覺醒")
        store.flushPendingMetadataSave()
        let reopened = BookStore(metadataFileURL: metadataURL)
        #expect(reopened.books.first?.totalChapterNum == 33)
        #expect(reopened.chapters(for: book.id)?.count == 33)
    }

    @Test("a book read without shelving keeps its list on its own too")
    func readingRecordKeepsItsListOutsideItsFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        var unlisted = onlineBook(title: "沒加書架", chapterCount: 20)
        unlisted.isInBookshelf = false
        store.saveReadingBook(unlisted)
        store.waitForQueuedWrites()

        let readingFile = metadataURL.deletingPathExtension().appendingPathExtension("reading.json")
        #expect(try shelfObjects(at: readingFile).first?["onlineChapters"] == nil)
        let reopened = BookStore(metadataFileURL: metadataURL)
        #expect(reopened.readingBook(id: unlisted.id)?.onlineChapters == unlisted.onlineChapters)
    }

    @Test("sync carries neither the list nor its summary, and applying it keeps this device's")
    func syncLeavesTableOfContentsLocal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let book = onlineBook(title: "兩台裝置", chapterCount: 50)
        store.replaceBooksFromSync([book])
        let local = try #require(store.books.first)
        #expect(local.withoutTableOfContents().totalChapterNum == nil)
        #expect(local.strippedForSync().latestChapterTitle == nil)

        // Another device's copy: newer progress, and — uploaded by a build before the chapter
        // store — an older list of 10 chapters inside it.
        var remote = local
        remote.currentPosition = 0.8
        remote.onlineChapters = Self.chapters(count: 10)
        remote.totalChapterNum = 10
        let snapshot = try #require(store.snapshotForSync([remote], expectedMutationRevision: store.mutationRevision))
        #expect(store.applySyncSnapshot(try await BookStore.encodeSyncSnapshot(snapshot)))

        let applied = try #require(store.books.first)
        #expect(applied.currentPosition == 0.8)
        #expect(applied.totalChapterNum == 50)
        #expect(store.chapters(for: book.id)?.count == 50)
        #expect(BookStore(metadataFileURL: metadataURL).chapters(for: book.id)?.count == 50)
    }

    @Test("a shelf restored without the summary gets it back from the lists on disk")
    func restoredShelfRegainsSummaryFromStoredLists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let book = onlineBook(title: "備份還原", chapterCount: 25)
        store.replaceBooksFromSync([book])
        // WebDAV 還原 writes the backup, which carries books without either.
        let backup = try #require(store.books.first).strippedForSync()
        try JSONEncoder().encode([backup]).write(to: metadataURL, options: .atomic)

        await store.reloadFromDisk()

        #expect(store.books.first?.totalChapterNum == 25)
        #expect(BookStore(metadataFileURL: metadataURL).books.first?.totalChapterNum == 25)
    }

    @Test("a shelf that could not be read leaves every table of contents alone")
    func unreadableShelfLeavesTablesOfContentsAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let book = onlineBook(title: "讀不到的書架裡的書", chapterCount: 8)
        BookStore(metadataFileURL: metadataURL).replaceBooksFromSync([book])
        let list = chapterFile(for: book.id, metadataURL: metadataURL)
        let listBytes = try Data(contentsOf: list)
        try Data("{ not json".utf8).write(to: metadataURL)

        let store = BookStore(metadataFileURL: metadataURL)
        store.replaceBooksFromSync([onlineBook(title: "新書", chapterCount: 3)])

        #expect(try Data(contentsOf: list) == listBytes)
    }

    /// Before/after measurement on the tester's scale: 22 books of 2,000 chapters with
    /// ~2,000-character URLs (七猫聽書) and 88 of 900 with ~330-character `data:` URLs
    /// (光遇聚合) — about the 138 MB shelf of 2026-10-04. Set
    /// `TEST_RUNNER_YUEDU_SHELF_BENCHMARK=1` to run it; it is minutes long under Debug.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YUEDU_SHELF_BENCHMARK"] != nil))
    func benchmarkLeavingForegroundWithTesterSizedShelf() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        var shelf: [(ReadingBook, [OnlineChapterRef])] = []
        for index in 0..<22 {
            shelf.append((onlineBook(title: "七猫 \(index)", chapterCount: 0), Self.chapters(count: 2_000, urlLength: 2_000)))
        }
        for index in 0..<88 {
            shelf.append((onlineBook(title: "光遇 \(index)", chapterCount: 0), Self.chapters(count: 900, urlLength: 330, dataURL: true)))
        }
        let target = shelf[0].0.id
        try writeInlineShelf(shelf, to: metadataURL)
        let bytes = try Data(contentsOf: metadataURL).count

        var t0 = SourcePerfTrace.now
        let store = BookStore(metadataFileURL: metadataURL)
        let load = milliseconds(since: t0)

        var flushes: [Double] = []
        for chapter in 0..<3 {
            store.updateCachedChapter(bookId: target, chapterIndex: chapter, filename: "chapter-\(chapter).html")
            t0 = SourcePerfTrace.now
            store.flushPendingMetadataSave()
            flushes.append(milliseconds(since: t0))
        }

        t0 = SourcePerfTrace.now
        let reopened = BookStore(metadataFileURL: metadataURL)
        let reopen = milliseconds(since: t0)
        t0 = SourcePerfTrace.now
        let opened = reopened.readingBook(id: target)?.onlineChapters?.count
        let openBook = milliseconds(since: t0)

        let report = "⏱ bench.shelf inlineBytes=\(bytes) load=\(Int(load))ms "
            + "flush=\(flushes.map { Int($0) })ms reopen=\(Int(reopen))ms openBook=\(Int(openBook))ms"
        print(report)
        AppLogger.parse(report)
        #expect(opened == 2_000)
    }

    // MARK: - Helpers

    /// Every chapter of an audiobook is fetched by its entry in the table of contents. The
    /// player looked the book up on the shelf, where a record carries none, and every
    /// chapter of a shelf audiobook failed with 找不到章節 (caught before release, 2026-10-05).
    @Test("the audiobook player plays the book with its table of contents")
    func audiobookPlayerSeesTheTableOfContents() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        var audiobook = onlineBook(title: "有聲書", chapterCount: 12)
        audiobook.contentPipelineKind = .audio
        store.replaceBooksFromSync([audiobook])
        #expect(store.books.first?.onlineChapters == nil, "a shelf record carries no list")

        let playing = AudiobookPlayer.playingBook(id: audiobook.id, store: store, startedWith: nil)
        #expect(playing?.onlineChapters?.count == 12)

        // Not on the shelf — 立即閱讀 from a detail page — the store still has it.
        var trial = onlineBook(title: "試聽", chapterCount: 5)
        trial.contentPipelineKind = .audio
        trial.isInBookshelf = false
        store.saveReadingBook(trial)
        #expect(AudiobookPlayer.playingBook(id: trial.id, store: store, startedWith: nil)?.onlineChapters?.count == 5)
    }

    private func onlineBook(title: String, chapterCount: Int) -> ReadingBook {
        var book = ReadingBook(title: title, author: "作者", source: "https://example.com/\(UUID().uuidString)", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.bookSourceId = UUID()
        book.bookInfoURL = book.source
        if chapterCount > 0 {
            book.onlineChapters = Self.chapters(count: chapterCount)
        }
        return book
    }

    private static func chapters(count: Int, urlLength: Int = 40, dataURL: Bool = false) -> [OnlineChapterRef] {
        (0..<count).map { index in
            let prefix = dataURL
                ? "data:;base64,"
                : "https://api-ks.wtzw.com/api/v1/chapter/content?chapter_id=\(index)&sign="
            let url = prefix + String(repeating: "Q", count: max(0, urlLength - prefix.count))
            return OnlineChapterRef(index: index, title: "第\(index + 1)章 武魂二次覺醒", url: url)
        }
    }

    /// Writes a shelf the way every build before the chapter store did: each book's
    /// `onlineChapters` inside its own record.
    private func writeInlineShelf(_ shelf: [(ReadingBook, [OnlineChapterRef])], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = shelf.map { book, chapters -> InlineShelfRecord in
            var bare = book
            bare.onlineChapters = nil
            return InlineShelfRecord(book: bare, chapters: chapters)
        }
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    /// Every stored field of each chapter, so two lists compare without `Equatable`.
    private func describe(_ chapters: [OnlineChapterRef]?) -> [String] {
        (chapters ?? []).map { String(describing: $0) }
    }

    private func chapterFile(for bookID: UUID, metadataURL: URL) -> URL {
        metadataURL.deletingPathExtension()
            .appendingPathExtension("chapters")
            .appendingPathComponent("\(bookID.uuidString).json")
    }

    private func fileNumber(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? Int)
    }

    private func shelfObjects(at url: URL) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }

    private func milliseconds(since start: TimeInterval) -> Double {
        (SourcePerfTrace.now - start) * 1000
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookChapterStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// One book as builds before the chapter store wrote it: the record's own keys plus
/// `onlineChapters`, in a single JSON object.
private struct InlineShelfRecord: Encodable {
    private enum InlineKey: String, CodingKey { case onlineChapters }

    let book: ReadingBook
    let chapters: [OnlineChapterRef]

    func encode(to encoder: Encoder) throws {
        try book.encode(to: encoder)
        var container = encoder.container(keyedBy: InlineKey.self)
        try container.encode(chapters, forKey: .onlineChapters)
    }
}
