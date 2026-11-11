import Foundation
import Testing
@testable import yuedu_app

/// FB-59 (回饋中心 #59, diagnostic YD-F846-VFX5): after a table-of-contents refresh gave chapters
/// new URLs, the next chapter sat on 載入中 until the reader left the book or tapped 下一章.
///
/// A refresh keeps the old chapter files (`BookStore` reconciles with `.preserveContent`), so a
/// body saved under the old URL is still on disk at the chapter's index. Everything that reads a
/// chapter judges that file against the ref's URL and title and rejects it (`urlMismatch`); the
/// only question is whether whatever decides "fetch the neighbour" judges it the same way. In
/// build 135 it did not: the neighbour prefetch asked a URL-blind probe, which called the stale
/// file cached, so nothing ever fetched the chapter.
@MainActor
@Suite("A refreshed chapter URL is fetched, not taken for cached (FB-59)", .serialized)
struct RefreshedChapterURLPrefetchTests {

    private static let bookURL = "https://ncode.syosetu.com/n0059fb/"

    private static func chapterURL(_ path: String) -> String { "\(bookURL)\(path)/" }

    private static let body = [
        "　　雨停了以後，街上的積水映著路燈，一格一格地亮著。林遠把傘收起來，站在書店門口抖了抖，才推門進去。",
        "　　店裡很安靜，只有老闆在櫃檯後面翻一本舊雜誌。他抬頭看了一眼，又低下頭去，像是早就知道他會來。",
        "　　林遠在靠窗的那排書架前停下，手指從書脊上一本一本滑過去，最後停在一本封面褪了色的小說上。",
        "　　那是他十年前買過的同一本書，後來搬家弄丟了。他把它抽出來，翻到扉頁，上面竟然還留著一行鉛筆字。",
    ].joined(separator: "\n")

    private static func episodePage(_ content: String) -> String {
        let paragraphs = content.components(separatedBy: "\n").map { "<p>\($0)</p>" }.joined()
        return "<html><body><div class=\"js-novel-text\">\(paragraphs)</div></body></html>"
    }

    /// A module book whose chapters are fetched through `ModuleStub`, a fetch manager reading it
    /// the way the reader does, and the store the book lives in.
    private struct Fixture {
        let book: ReadingBook
        let manager: ChapterFetchManager
        let store: BookStore
        let folder: URL
    }

    private func makeFixture(chapters: [OnlineChapterRef]) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FB59-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                      store: RuleModuleStore(directory: folder.appendingPathComponent("modules")))
        var module = RuleModule(id: "test.fb59", title: "FB-59", description: nil, author: nil, site: nil, version: "1.0",
                                requiredVersion: "3.0", hosts: ["ncode.syosetu.com"], rateLimit: nil, modules: [], search: nil)
        module.reading = ModuleReadingTests.narouReading
        let readable = module
        let reader = ModuleBookReader(client: client, module: { id in id == readable.id ? readable : nil })
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let moduleBook = ModuleBook(reference: ModuleBookReference(moduleID: readable.id, bookURL: Self.bookURL),
                                    title: "雨夜書店", author: "林遠", coverURL: nil, contentKind: .text)
        let copy = store.addModuleBook(moduleBook, chapters: chapters, isInBookshelf: true)
        let book = try #require(store.readingBook(id: copy.id))
        return Fixture(book: book, manager: ChapterFetchManager(moduleReader: reader), store: store, folder: folder)
    }

    private func cleanUp(_ fixture: Fixture) {
        BookSourceFetcher.shared.clearAllChapterCache(bookId: fixture.book.id)
        try? FileManager.default.removeItem(at: fixture.folder)
    }

    /// What a refresh leaves behind: the chapter's body, saved before the refresh under the URL
    /// (and title) the chapter had then.
    private func cacheBeforeRefresh(bookId: UUID, chapterIndex: Int, url: String, title: String) throws {
        try BookSourceFetcher.shared.saveToCache(
            content: "舊線路的正文\n" + Self.body, bookId: bookId, chapterIndex: chapterIndex,
            sourceURL: url, tocTitle: title, storeNormalizedHTML: false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while await !condition() {
            if ContinuousClock.now - start > timeout { return false }
            await Task.yield()
        }
        return true
    }

    // MARK: - The reader's neighbour prefetch

    /// The path the reader takes since FB-155 (1a74cf7d): `ReaderView.prefetchAdjacentChapters`
    /// → `ReaderViewModel.prefetchAround` → `ensureChapterReady`, against the real fetch manager.
    @Test("the reader's neighbour prefetch fetches a chapter whose URL a refresh changed")
    func readerPrefetchFetchesRefreshedNeighbour() async throws {
        let newURL = Self.chapterURL("2")
        let fixture = try makeFixture(chapters: [
            OnlineChapterRef(index: 0, title: "第一章 雨夜", url: Self.chapterURL("1")),
            OnlineChapterRef(index: 1, title: "第二章 書店", url: newURL),
        ])
        defer { cleanUp(fixture) }
        // The source switched line (v3 → v4 in YD-F846-VFX5): the same chapter, another URL.
        try cacheBeforeRefresh(bookId: fixture.book.id, chapterIndex: 1,
                               url: "https://v3.example.com/chapter/2", title: "第二章 書店")
        ModuleStub.install(["ncode.syosetu.com/n0059fb/2": .html(Self.episodePage(Self.body))])
        let viewModel = ReaderViewModel(
            chapterFetcher: LiveChapterFetcher(chapterFetchManager: fixture.manager),
            bookSourceFetcher: StubBookSourceFetcher()
        )

        await viewModel.prefetchAround(book: fixture.book, center: 0, store: fixture.store)

        #expect(await waitUntil { viewModel.chapterStates[1] == .ready }, "the neighbour never became ready")
        #expect(ModuleStub.urls == [newURL])
        let package = try #require(await fixture.manager.cachedChapterPackage(book: fixture.book, chapterIndex: 1))
        #expect(!package.content.contains("舊線路"), "the reader reads the chapter at its new URL")
    }

    // MARK: - ChapterFetchManager's own prefetch gate

    @Test("a body saved under the chapter's old URL is missing, and prefetch fetches it")
    func gateFetchesChapterWithChangedURL() async throws {
        let newURL = Self.chapterURL("2")
        let fixture = try makeFixture(chapters: [
            OnlineChapterRef(index: 0, title: "第一章 雨夜", url: Self.chapterURL("1")),
            OnlineChapterRef(index: 1, title: "第二章 書店", url: newURL),
        ])
        defer { cleanUp(fixture) }
        try cacheBeforeRefresh(bookId: fixture.book.id, chapterIndex: 1,
                               url: "https://v3.example.com/chapter/2", title: "第二章 書店")
        ModuleStub.install(["ncode.syosetu.com/n0059fb/2": .html(Self.episodePage(Self.body))])

        #expect(await fixture.manager.chapterState(book: fixture.book, chapterIndex: 1) == .missing)

        await fixture.manager.prefetchChapters(book: fixture.book, indices: [1], priority: .prefetch,
                                               store: fixture.store)
        #expect(await waitUntil { ModuleStub.urls == [newURL] }, "prefetch never asked for the chapter")
        #expect(await waitUntil { await fixture.manager.isChapterCached(book: fixture.book, chapterIndex: 1) })
        #expect(await fixture.manager.chapterState(book: fixture.book, chapterIndex: 1) == .cached)
    }

    @Test("a refresh that inserts a chapter leaves the next one's file at the wrong index, and prefetch fetches it")
    func gateFetchesChapterAfterIndexShift() async throws {
        // Before the refresh: 第一章 at 0, 第二章 at 1. The source inserted 請假條 between them, so
        // 第二章 moved to 2 — and index 1's file still holds 第二章.
        let insertedURL = Self.chapterURL("1a")
        let fixture = try makeFixture(chapters: [
            OnlineChapterRef(index: 0, title: "第一章 雨夜", url: Self.chapterURL("1")),
            OnlineChapterRef(index: 1, title: "請假條", url: insertedURL),
            OnlineChapterRef(index: 2, title: "第二章 書店", url: Self.chapterURL("2")),
        ])
        defer { cleanUp(fixture) }
        try cacheBeforeRefresh(bookId: fixture.book.id, chapterIndex: 1,
                               url: Self.chapterURL("2"), title: "第二章 書店")
        ModuleStub.install(["ncode.syosetu.com/n0059fb/1a": .html(Self.episodePage(Self.body))])

        #expect(await fixture.manager.chapterState(book: fixture.book, chapterIndex: 1) == .missing)

        await fixture.manager.prefetchChapters(book: fixture.book, indices: [1], priority: .prefetch,
                                               store: fixture.store)
        #expect(await waitUntil { ModuleStub.urls == [insertedURL] }, "prefetch never asked for the chapter")
        #expect(await waitUntil { await fixture.manager.isChapterCached(book: fixture.book, chapterIndex: 1) })
    }

    @Test("a chapter cached under its current URL is cached, and prefetch leaves it alone")
    func gateSkipsChapterCachedUnderCurrentURL() async throws {
        let url = Self.chapterURL("2")
        let fixture = try makeFixture(chapters: [
            OnlineChapterRef(index: 0, title: "第一章 雨夜", url: Self.chapterURL("1")),
            OnlineChapterRef(index: 1, title: "第二章 書店", url: url),
        ])
        defer { cleanUp(fixture) }
        try cacheBeforeRefresh(bookId: fixture.book.id, chapterIndex: 1, url: url, title: "第二章 書店")
        ModuleStub.install([:])

        #expect(await fixture.manager.chapterState(book: fixture.book, chapterIndex: 1) == .cached)
        await fixture.manager.prefetchChapters(book: fixture.book, indices: [1], priority: .prefetch,
                                               store: fixture.store)
        #expect(ModuleStub.urls.isEmpty)
    }
}
