import Foundation
import Testing
@testable import yuedu_app

@Suite("Book source persistence and identity", .serialized)
struct BookSourcePersistenceTests {
    @Test("source switching persists the selected source immediately")
    @MainActor
    func sourceSwitchPersistsImmediately() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let oldSource = BookSource(bookSourceUrl: "https://old.example", bookSourceName: "舊書源")
        let newSource = BookSource(bookSourceUrl: "https://new.example", bookSourceName: "新書源")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [oldSource, newSource]
        defer { BookSourceStore.shared.sources = previousSources }

        var book = ReadingBook(
            title: "換源持久化測試",
            author: "測試作者",
            source: "https://old.example/book",
            contentFilename: ""
        )
        book.isOnline = true
        book.contentPipelineKind = .html
        book.bookSourceId = oldSource.id
        book.bookInfoURL = "https://old.example/book"
        book.tocURL = "https://old.example/book/toc"
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "第一章", url: "https://old.example/chapter/1")
        ]
        store.replaceBooksFromSync([book])

        let newChapters = [
            OnlineChapterRef(index: 0, title: "第一章", url: "https://new.example/chapter/1"),
            OnlineChapterRef(index: 1, title: "第二章", url: "https://new.example/chapter/2")
        ]
        let fetcher = SourceSwitchBookSourceFetcher(
            package: TOCPackage(
                sourceId: newSource.id,
                sourceName: newSource.bookSourceName,
                tocURL: "https://new.example/book/toc",
                runtimeVariables: nil,
                chapters: newChapters,
                rawHTMLFilename: nil,
                savedAt: Date()
            )
        )
        let roots = OfflineStorageRoots(
            textRoot: directory.appendingPathComponent("text", isDirectory: true),
            mangaRoot: directory.appendingPathComponent("manga", isDirectory: true)
        )
        let origin = BookOrigin(
            sourceId: newSource.id,
            sourceName: newSource.bookSourceName,
            bookUrl: "https://new.example/book",
            tocUrl: "https://new.example/book/toc",
            coverUrl: "",
            intro: "",
            lastChapter: "第二章",
            wordCount: "",
            kind: "",
            runtimeVariables: nil
        )

        try await store.updateOnlineBookSource(
            bookId: book.id,
            origin: origin,
            bookSourceFetcher: fetcher,
            offlineChapterStore: OfflineChapterStore(roots: roots)
        )

        let reloaded = BookStore(metadataFileURL: metadataURL)
        let persistedBook = try #require(reloaded.books.first)
        #expect(persistedBook.id == book.id)
        #expect(persistedBook.bookSourceId == newSource.id)
        #expect(persistedBook.bookInfoURL == "https://new.example/book")
        #expect(persistedBook.tocURL == "https://new.example/book/toc")
        #expect(persistedBook.onlineChapters?.map(\.url) == newChapters.map(\.url))
    }

    @Test("same URL books from different sources remain distinct shelf items")
    @MainActor
    func sourceQualifiedShelfIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let firstSource = BookSource(bookSourceUrl: "https://first.example", bookSourceName: "第一書源")
        let secondSource = BookSource(bookSourceUrl: "https://second.example", bookSourceName: "第二書源")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [firstSource, secondSource]
        defer { BookSourceStore.shared.sources = previousSources }

        let sharedBookURL = "https://novel.example/book/42"
        let firstBook = store.addOnlineBook(
            name: "同名書",
            author: "同名作者",
            sourceId: firstSource.id,
            bookInfoURL: sharedBookURL,
            chapters: []
        )
        let secondBook = store.addOnlineBook(
            name: "同名書",
            author: "同名作者",
            sourceId: secondSource.id,
            bookInfoURL: sharedBookURL,
            chapters: []
        )

        #expect(firstBook.id != secondBook.id)
        #expect(store.onlineBook(sourceId: firstSource.id, bookInfoURL: sharedBookURL)?.id == firstBook.id)
        #expect(store.onlineBook(sourceId: secondSource.id, bookInfoURL: sharedBookURL)?.id == secondBook.id)
    }

    @Test("origin failure keys include the source identity")
    func originFailureKeysSeparateSources() {
        let url = "https://novel.example/book/42#toc"
        let firstKey = ChangeSourceCache.originKey(sourceId: UUID(), bookUrl: url)
        let secondKey = ChangeSourceCache.originKey(sourceId: UUID(), bookUrl: url)

        #expect(firstKey != secondKey)
        #expect(firstKey.hasSuffix("|https://novel.example/book/42"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourcePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct SourceSwitchBookSourceFetcher: BookSourceFetching {
    let package: TOCPackage

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        throw NSError(
            domain: "SourceSwitchBookSourceFetcher",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "fetchBookInfoPackage should not be called in this test"]
        )
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        #expect(source.id == package.sourceId)
        #expect(tocUrl == package.tocURL)
        onFirstPageReady?(package.chapters)
        return package
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        false
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        nil
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        nil
    }
}
