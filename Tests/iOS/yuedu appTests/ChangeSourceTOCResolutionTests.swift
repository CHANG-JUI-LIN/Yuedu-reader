import Testing
import Foundation
@testable import yuedu_app

/// 換源 tapped every origin and came back `Invalid URL:` with nothing after the
/// colon.
///
/// A search result almost never carries a `tocUrl` — it belongs to the book's DETAIL
/// page, so `parseSearchResults` leaves it empty on purpose (an empty rule would
/// otherwise resolve to the site root and the homepage would get scraped as a TOC).
/// `prepareTOCPackage` handed that empty string straight to `fetchTOCPackage`, whose
/// `safeURL` rejects it. Legado has always guarded this in
/// `ChangeBookSourceViewModel.getToc`:
///
/// ```kotlin
/// if (book.tocUrl.isEmpty()) { WebBook.getBookInfoAwait(source, book) }
/// val toc = WebBook.getChapterListAwait(source, book).getOrThrow()
/// ```
///
/// These tests pin both halves of that guard: fetch the detail page when the TOC url
/// is missing, and *don't* when it isn't.
@Suite("Change source TOC resolution")
struct ChangeSourceTOCResolutionTests {

    @Test("an origin with no tocUrl resolves one from the detail page")
    @MainActor
    func emptyTocUrlFetchesBookInfoFirst() async throws {
        let source = BookSource(bookSourceUrl: "https://novel.example", bookSourceName: "測試書源")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer { BookSourceStore.shared.sources = previousSources }

        let fetcher = RecordingChangeSourceFetcher(
            detailTocUrl: "https://novel.example/book/42/toc",
            detailRuntimeVariables: ["token": "from-detail"]
        )
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChangeSourceChapterFetcher(),
            bookCoordinator: NoopChangeSourceCoordinator(),
            bookSourceFetcher: fetcher
        )

        let origin = BookOrigin(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookUrl: "https://novel.example/book/42",
            tocUrl: "",                       // exactly what a search result carries
            coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "",
            runtimeVariables: nil
        )

        let package = try await viewModel.prepareTOCPackage(for: origin)

        #expect(await fetcher.bookInfoRequests == ["https://novel.example/book/42"])
        // The TOC request must use the url the detail page produced, not the empty one.
        #expect(await fetcher.tocRequests == ["https://novel.example/book/42/toc"])
        // Runtime variables the detail request stashed have to travel with it: a
        // source's bookInfo JS is where chapter-list state gets set up.
        #expect(await fetcher.tocRuntimeVariables == [["token": "from-detail"]])
        #expect(package.chapters.count == 1)
    }

    /// The other half of Legado's guard. A source whose search rule *does* fill
    /// tocUrl must not pay for an extra detail-page round trip on every tap.
    @Test("an origin that already has a tocUrl skips the detail page")
    @MainActor
    func presentTocUrlSkipsBookInfo() async throws {
        let source = BookSource(bookSourceUrl: "https://novel.example", bookSourceName: "測試書源")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer { BookSourceStore.shared.sources = previousSources }

        let fetcher = RecordingChangeSourceFetcher(
            detailTocUrl: "https://novel.example/should-not-be-used",
            detailRuntimeVariables: nil
        )
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChangeSourceChapterFetcher(),
            bookCoordinator: NoopChangeSourceCoordinator(),
            bookSourceFetcher: fetcher
        )

        let origin = BookOrigin(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookUrl: "https://novel.example/book/42",
            tocUrl: "https://novel.example/book/42/catalog",
            coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "",
            runtimeVariables: ["token": "from-search"]
        )

        _ = try await viewModel.prepareTOCPackage(for: origin)

        #expect(await fetcher.bookInfoRequests.isEmpty)
        #expect(await fetcher.tocRequests == ["https://novel.example/book/42/catalog"])
        #expect(await fetcher.tocRuntimeVariables == [["token": "from-search"]])
    }
}

// MARK: - Stubs

/// Records which urls each stage was asked for, so the tests can assert the ORDER
/// and the hand-off between them rather than just the final package.
private actor RecordingChangeSourceFetcher: BookSourceFetching {
    private(set) var bookInfoRequests: [String] = []
    private(set) var tocRequests: [String] = []
    private(set) var tocRuntimeVariables: [[String: String]?] = []

    private let detailTocUrl: String
    private let detailRuntimeVariables: [String: String]?

    init(detailTocUrl: String, detailRuntimeVariables: [String: String]?) {
        self.detailTocUrl = detailTocUrl
        self.detailRuntimeVariables = detailRuntimeVariables
    }

    nonisolated func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        await record(bookInfo: url)
        return BookInfoPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookURL: url,
            name: "測試書",
            author: "測試作者",
            intro: "",
            coverUrl: "",
            tocUrl: detailTocUrl,
            wordCount: "",
            lastChapter: "",
            kind: "",
            runtimeVariables: detailRuntimeVariables,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    nonisolated func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        await record(toc: tocUrl, variables: runtimeVariables)
        return TOCPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            tocURL: tocUrl,
            runtimeVariables: runtimeVariables,
            chapters: [OnlineChapterRef(index: 0, title: "第一章", url: "\(tocUrl)/1")],
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    private func record(bookInfo url: String) {
        bookInfoRequests.append(url)
    }

    private func record(toc url: String, variables: [String: String]?) {
        tocRequests.append(url)
        tocRuntimeVariables.append(variables)
    }

    nonisolated func isChapterCached(
        bookId: UUID, chapterIndex: Int,
        expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> Bool { false }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    nonisolated func clearAllChapterCache(bookId: UUID) {}
    nonisolated func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }

    nonisolated func loadChapterPackageSync(
        bookId: UUID, chapterIndex: Int,
        expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> ChapterPackage? { nil }

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID, chapterIndex: Int,
        expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> String? { nil }
}

private struct NoopChangeSourceChapterFetcher: ChapterFetching {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool { false }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        throw CancellationError()
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}
    func cancelAll(for bookId: UUID) async {}
}

private final class NoopChangeSourceCoordinator: OnlineBookCoordinating {
    func downloadBook(_ book: ReadingBook, store: BookStore?) {}
    func downloadBook(
        _ book: ReadingBook, store: BookStore?,
        startChapterIndex: Int, chapterCount: Int?
    ) {}
    func pauseDownload(book: ReadingBook, store: BookStore?) {}
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {}
}
