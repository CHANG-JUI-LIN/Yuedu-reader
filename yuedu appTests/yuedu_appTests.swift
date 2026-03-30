//
//  yuedu_appTests.swift
//  yuedu appTests
//
//  Created by 張瑞麟 on 2026/2/27.
//

import Testing
import Foundation
import CoreText
import UIKit
@testable import yuedu_app

struct yuedu_appTests {

    private func loadSource(named name: String) throws -> BookSource {
        let sourceFile = "/Users/zhangruilin/Library/Mobile Documents/com~apple~CloudDocs/书源(856)-已测试并去重.json"
        let json = try String(contentsOfFile: sourceFile, encoding: .utf8)
        let sources = try JSONDecoder().decode([BookSource].self, from: Data(json.utf8))
        return try #require(sources.first(where: { $0.bookSourceName == name }))
    }

    private func fetchFirstChapter(sourceName: String, keyword: String, expectedTitle: String) async throws
        -> ChapterPackage
    {
        let source = try loadSource(named: sourceName)
        let books = try await BookSourceFetcher.shared.search(query: keyword, in: source)
        let exactMatch = books.first(where: { $0.name == expectedTitle })
        let partialMatch = books.first(where: { $0.name.contains(expectedTitle) })
        let book = try #require(exactMatch ?? partialMatch)
        let info = try await BookSourceFetcher.shared.fetchBookInfo(
            url: book.bookUrl,
            source: source,
            runtimeVariables: book.runtimeVariables
        )
        let tocUrl = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let chapters = try await BookSourceFetcher.shared.fetchTOC(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: info.runtimeVariables
        )
        let first = try #require(chapters.first)
        return try await BookSourceFetcher.shared.fetchChapterPackage(
            ref: first,
            bookId: UUID(),
            source: source,
            chapterReferer: tocUrl
        )
    }

    @Test func txtChapterIngestBuildsOneSpinePerChapter() async throws {
        let package = try TXTBookIngester(
            chapters: [
                .init(title: "第一章", body: "段落一\n\n段落二"),
                .init(title: "第二章", body: "段落三"),
            ],
            title: "測試書",
            author: "測試作者",
            originalSourceURL: nil
        ).ingest()

        #expect(package.manifest.spine.count == 2)
        #expect(package.parsedBook.chapters.first?.html.contains("id=\"reader-content\"") == true)
    }

    @Test func onlineCoordinatorUsesCachedChapterAndPlaceholder() async throws {
        let book = ReadingBook(title: "線上書", author: "作者", source: "https://example.com", contentFilename: "")
        let bookId = book.id
        let refs = [
            OnlineChapterRef(index: 0, title: "章一", url: "https://example.com/1"),
            OnlineChapterRef(index: 1, title: "章二", url: "https://example.com/2"),
        ]
        var onlineBook = book
        onlineBook.isOnline = true
        onlineBook.onlineChapters = refs

        _ = BookSourceFetcher.shared.saveToCache(content: "已快取內容", bookId: bookId, chapterIndex: 0)

        let package = try OnlineBookCoordinator.shared.buildPackage(for: onlineBook, preferredChapter: 1)

        #expect(package.parsedBook.chapters.count == 2)
        #expect(package.parsedBook.chapters[0].html.contains("已快取內容"))
        #expect(package.parsedBook.chapters[1].html.contains("載入章節中…"))

        BookSourceFetcher.shared.clearAllChapterCache(bookId: bookId)
    }

    @Test func readerLocatorRoundTripsAndSupportsLegacyKeys() throws {
        let locator = ReaderLocator(
            spineHref: "Text/chapter-3.xhtml",
            chapterIndex: 2,
            pageInChapter: 4,
            totalPagesInChapter: 9,
            globalPage: 18,
            progression: 0.42,
            generationId: 7,
            title: "第三章",
            chapterProgression: 0.5,
            totalProgression: 0.42,
            locatorJSON: "{\"href\":\"Text/chapter-3.xhtml\"}",
            cssSelector: "#p-12",
            partialCFI: "/4/2[p12]",
            domRangeJSON: "{\"start\":12}",
            highlightedText: "測試段落",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(locator)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReaderLocator.self, from: data)

        #expect(decoded == locator)

        let legacyJSON = """
        {
          "href": "Text/legacy.xhtml",
          "position": 3,
          "spineIndex": 1
        }
        """
        let legacy = try decoder.decode(ReaderLocator.self, from: Data(legacyJSON.utf8))
        #expect(legacy.spineHref == "Text/legacy.xhtml")
        #expect(legacy.chapterIndex == 1)
        #expect(legacy.pageInChapter == 3)
        #expect(legacy.totalPagesInChapter == 1)
    }

    @Test func suduguSourceCanFetchFirstChapterEndToEnd() async throws {
        let package = try await fetchFirstChapter(
            sourceName: "速读谷",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
        #expect(package.content.contains("巴蜀"))
    }

    @Test func sixtyNineBookBarCanFetchFirstChapterEndToEnd() async throws {
        let package = try await fetchFirstChapter(
            sourceName: "69书吧👌",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
    }

    @Test func aiKanShuBaCanFetchFirstChapterEndToEnd() async throws {
        let package = try await fetchFirstChapter(
            sourceName: "爱看书吧",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
    }

    @Test func tuJiuSanCanFetchFirstChapterEndToEnd() async throws {
        let package = try await fetchFirstChapter(
            sourceName: "兔九三🐰",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
    }

    @Test func charOffsetStoreRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharOffsetStoreTest-\(UUID().uuidString)")
        let store = CharOffsetStore(directoryURL: dir)
        let record = CharOffsetRecord(
            bookId: "book-abc",
            spineIndex: 3,
            charOffset: 1024,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(record)
        store.flushSync()

        let loaded = store.load(bookId: "book-abc")
        #expect(loaded?.spineIndex == 3)
        #expect(loaded?.charOffset == 1024)
    }

    @Test func charOffsetStoreReturnsNilForUnknownBook() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharOffsetStoreTest-\(UUID().uuidString)")
        let store = CharOffsetStore(directoryURL: dir)
        #expect(store.load(bookId: "unknown") == nil)
    }

    @Test func htmlBuilderConvertsBasicParagraph() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white
        )
        let html = "<p>Hello <strong>world</strong></p>"
        let result = await builder.build(html: html, config: config)
        #expect(result.string.contains("Hello"))
        #expect(result.string.contains("world"))
    }

    @Test func htmlBuilderInsertsPlaceholderForImg() async {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in UIImage(systemName: "photo") }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18, lineSpacing: 6, paragraphSpacing: 8,
            firstLineIndent: 0, textColor: .black, backgroundColor: .white
        )
        let html = "<p>Before</p><img src='cover.jpg'><p>After</p>"
        let result = await builder.build(html: html, config: config)
        #expect(result.string.contains("\u{FFFC}"))
        var hasDelegate = false
        result.enumerateAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            in: NSRange(location: 0, length: result.length),
            options: []
        ) { value, _, _ in
            if value != nil { hasDelegate = true }
        }
        #expect(hasDelegate)
    }

    @Test func paginatorPageRangesTotalLengthEqualsAttrStrLength() async {
        let text = String(repeating: "一二三四五六七八九十", count: 200)
        let attrStr = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attrStr,
            renderSize: CGSize(width: 375, height: 600),
            fontSize: 18
        )
        let total = layout.pageRanges.reduce(0) { $0 + $1.length }
        #expect(total == attrStr.length)
        #expect(!layout.pageRanges.isEmpty)
    }

    @Test func paginatorBinarySearchFindsCorrectPage() async {
        let text = String(repeating: "Hello world ", count: 300)
        let attrStr = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attrStr,
            renderSize: CGSize(width: 375, height: 600),
            fontSize: 18
        )
        guard layout.pageRanges.count > 1 else { return }
        let secondPageStart = Int(layout.pageRanges[1].location)
        let foundPage = layout.pageIndex(for: secondPageStart)
        #expect(foundPage == 1)
    }

    @Test func charOffsetStoreProgressMigrationApproximatesPosition() async {
        let attrStr = NSAttributedString(
            string: String(repeating: "a", count: 1000),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let progression = 0.5
        let charOffset = Int(progression * Double(attrStr.length))
        #expect(charOffset == 500)
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attrStr,
            renderSize: CGSize(width: 375, height: 600),
            fontSize: 18
        )
        let page = layout.pageIndex(for: charOffset)
        #expect(page >= 0)
        #expect(page < layout.pageRanges.count)
    }

    @Test func charOffsetSurvivesFontSizeChange() async {
        // 同一段文字，字號從 18 改成 24，charOffset 指向同一個字符段落
        let text = String(repeating: "測試文字內容，這是一段較長的段落用於驗證重排後位置還原。", count: 50)
        let attrStr18 = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let attrStr24 = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 24)]
        )
        let paginator = CoreTextPaginator()
        let size = CGSize(width: 375, height: 600)

        let layout18 = await paginator.paginate(spineIndex: 0, attrStr: attrStr18, renderSize: size, fontSize: 18)
        let layout24 = await paginator.paginate(spineIndex: 1, attrStr: attrStr24, renderSize: size, fontSize: 24)

        // 字號 18 時讀到第 2 頁
        guard layout18.pageRanges.count > 2 else { return }
        let charOffset = Int(layout18.pageRanges[2].location)

        // 字號改成 24 後，charOffset 應仍落在 layout24 的某頁範圍內
        let page24 = layout24.pageIndex(for: charOffset)
        let range24 = layout24.pageRanges[page24]
        #expect(range24.location <= charOffset)
        #expect(charOffset < range24.location + range24.length)
    }

    @Test func refreshOnlineBookMetadataRepairsLegacyShelfEntry() async throws {
        let source = try loadSource(named: "速读谷")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer {
            BookSourceStore.shared.sources = previousSources
        }

        let books = try await BookSourceFetcher.shared.search(query: "斗罗大陆", in: source)
        let exactMatch = books.first(where: { $0.name == "斗罗大陆" })
        let partialMatch = books.first(where: { $0.name.contains("斗罗大陆") })
        let book = try #require(exactMatch ?? partialMatch)

        let store = BookStore()
        let stale = store.addOnlineBook(
            name: book.name,
            author: book.author,
            sourceId: source.id,
            bookInfoURL: book.bookUrl,
            tocURL: nil,
            runtimeVariables: nil,
            chapters: []
        )
        defer {
            store.delete(bookId: stale.id)
        }

        let refreshed = try await store.refreshOnlineBookMetadata(
            bookId: stale.id,
            forceInfoRefresh: true
        )
        #expect(!(refreshed.tocURL ?? "").isEmpty)
        #expect((refreshed.onlineChapters?.isEmpty ?? true) == false)

        let current = try #require(store.books.first(where: { $0.id == stale.id }))
        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: current,
            chapterIndex: 0,
            priority: .jump,
            store: store
        )
        #expect(!package.content.isEmpty)
        BookSourceFetcher.shared.clearAllChapterCache(bookId: stale.id)
    }

}
