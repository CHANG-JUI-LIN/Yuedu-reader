import Foundation
import os
import Testing
@testable import yuedu_app

/// Legado's `book` from the detail stage through the TOC to the content, and the parts of
/// `BookInfo`, `BookChapterList` and `BookContent` that read or write it (legado-E, MD3 and
/// upstream agree). Each test follows sources in the YCK 1329–1331 packs.
@Suite("Legado book state across stages", .serialized)
struct LegadoBookStateTests {

    // MARK: - Detail stage

    /// `WebBook.getBookInfoAwait` runs the detail rules against the book the search made, and
    /// `analyzeBookInfo` writes each field into it as it reads it. A known name stays unless the
    /// source allows renaming, so the author rule here still reads the search result's name.
    @Test("detail rules read the search result as book, and a known name stays without canReName")
    func detailReadsSearchBook() async throws {
        var source = Self.source()
        source.ruleBookInfo.name = "tag.h1@text"
        source.ruleBookInfo.author = "@js:book.name + '的作者'"
        source.ruleBookInfo.tocUrl = "@js:'/toc?k=' + book.kind"

        let package = try await Self.detail(source: source, html: "<h1>詳情書名</h1>")

        #expect(package.name == "搜尋書名")
        let runtime = try #require(package.runtimeVariables)
        #expect(runtime["book.name"] == "搜尋書名")
        #expect(runtime["book.author"] == "搜尋作者")
        #expect(runtime["book.kind"] == "玄幻")
        #expect(package.tocUrl.removingPercentEncoding == source.bookSourceUrl + "/toc?k=玄幻")
        #expect(runtime["book.tocUrl"] == package.tocUrl)
        #expect(runtime["book.origin"] == source.bookSourceUrl)
    }

    @Test("with canReName the detail name replaces the search one before the next rule runs")
    func detailRenamesWithCanReName() async throws {
        var source = Self.source()
        source.ruleBookInfo.canReName = "1"
        source.ruleBookInfo.name = "tag.h1@text"
        source.ruleBookInfo.author = "@js:book.name + '的作者'"

        let package = try await Self.detail(source: source, html: "<h1>詳情書名</h1>")

        #expect(package.name == "詳情書名")
        #expect(package.author == "詳情書名的作者")
        #expect(package.runtimeVariables?["book.name"] == "詳情書名")
    }

    // MARK: - TOC stage

    /// 就去看网 (YCK 1329 #228) calls `book.setReverseToc(true)` from its detail rules; Legado
    /// then reverses the TOC it parses. The TOC also tells the book its chapter count.
    @Test("setReverseToc in the detail stage reverses the TOC, and the TOC counts the chapters")
    func reverseTocFromDetail() async throws {
        var source = Self.source()
        source.ruleBookInfo.name = "@js:book.setReverseToc(true); String(book.getReverseToc())"
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"

        let detail = try await Self.detail(source: source, html: "<p></p>")
        #expect(detail.runtimeVariables?[LegadoBookBridge.reverseTocRuntimeKey] == "true")

        let toc = try await Self.toc(
            Self.dataURL(Self.tocPage(["一", "二", "三"])), source: source,
            runtimeVariables: detail.runtimeVariables
        )

        #expect(toc.chapters.map(\.title) == ["三", "二", "一"])
        #expect(toc.chapters.map(\.index) == [0, 1, 2])
        #expect(toc.runtimeVariables?["book.totalChapterNum"] == "3")
        #expect(toc.runtimeVariables?["book.latestChapterTitle"] == "一")
    }

    /// 书文小说 / 九五看书 / 搜读中文: a newest-first TOC split over pages. Legado reverses the
    /// chapters of every page together; reversing each page gave [3, 4, 1, 2].
    @Test("a leading - reverses the whole TOC, every page together")
    func reversePrefixSpansPages() async throws {
        var source = Self.source()
        source.ruleToc.chapterList = "-#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        source.ruleToc.nextTocUrl = "class.next@href"
        let page2 = Self.dataURL(Self.tocPage(["2", "1"]))
        let page1 = Self.dataURL(Self.tocPage(["4", "3"], extra: "<a class=\"next\" href=\"\(page2)\">下一頁</a>"))

        let toc = try await Self.toc(page1, source: source, runtimeVariables: nil)

        #expect(toc.chapters.map(\.title) == ["1", "2", "3", "4"])
    }

    @Test("TOC rules read the book's name from the detail stage")
    func tocReadsBookName() async throws {
        var source = Self.source()
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "@js:book.name + '：' + result.select('a').text()"
        source.ruleToc.chapterUrl = "a@href"

        let toc = try await Self.toc(
            Self.dataURL(Self.tocPage(["一"])), source: source,
            runtimeVariables: ["book.name": "書甲"]
        )

        #expect(toc.chapters.map(\.title) == ["書甲：一"])
    }

    // MARK: - Content stage

    /// 神漫画 / 爱优漫 (YCK 1329) number a chapter's pages from the end:
    /// `parseInt(book.totalChapterNum) - (chapter.index + 1)`.
    @Test("content rules read the book's chapter count and name, and the chapter's title")
    func contentReadsBookAndChapter() throws {
        var source = Self.source()
        source.ruleContent.content =
            "@js:book.name + '|' + (parseInt(book.totalChapterNum) - (chapter.index + 1)) + '|' + chapter.title"
        let ref = OnlineChapterRef(index: 2, title: "第三章", url: source.bookSourceUrl + "/c/3")

        let payload = try ModernParserBridge(source: source).parseChapterResult(
            html: "<p>x</p>", baseURL: ref.url, source: source,
            runtimeVariables: ["book.name": "書甲", "book.totalChapterNum": "12"], chapterRef: ref
        )

        #expect(payload.content.contains("書甲|9|第三章"))
    }

    // MARK: - Script API

    /// Rhino gives every bean property its accessor methods; 番茄听书 (YCK 1330) calls
    /// `book.setType(32)` in its TOC rule.
    @Test("book and chapter answer Rhino's accessor methods for their properties")
    func beanAccessorMethods() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        book.setType(32);
        chapter.setTitle('第一章');
        [book.getType(), book.type, chapter.getTitle(), chapter.title, typeof book.getVariable,
         String(chapter.isVip())].join('|')
        """)
        #expect(value == "32|32|第一章|第一章|function|false")
        #expect(engine.lastError == nil)
    }

    /// 黄果短剧 (YCK 1330) reads `source.getBookSourceUrl()`; the source switch that injects a
    /// new `source` keeps the methods, as they live on the shared prototype.
    @Test("source answers Rhino's accessor methods, after a source switch too")
    func sourceAccessorMethods() {
        let engine = JSCoreEngine()
        var first = BookSource()
        first.bookSourceUrl = "https://first.test"
        engine.bookSource = first
        var second = BookSource()
        second.bookSourceUrl = "https://second.test"
        second.bookSourceName = "第二"
        engine.bookSource = second
        let value = engine.evaluate("[source.getBookSourceUrl(), source.getBookSourceName(), source.getKey()].join('|')")
        #expect(value == "https://second.test|第二|https://second.test")
        #expect(engine.lastError == nil)
    }

    /// 瀚海书阁 (YCK 1330): `a@href` hands the link as written to a script that prefixes the
    /// host itself, as Legado's AnalyzeByJSoup does. Resolved first, it fetched
    /// `https://hosthttps://host/…`.
    @Test("an attribute reaches the next script as written; the URL read resolves at the end")
    func attributeReachesScriptAsWritten() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://toc.test"
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href@js:'https://toc.test' + result"
        let prefixed = try ModernParserBridge(source: source).parseTOC(
            html: Self.tocPage(["1"]), baseURL: "https://toc.test/book/1/", source: source
        )
        #expect(prefixed.map(\.url) == ["https://toc.test/c/1"])

        source.ruleToc.chapterUrl = "a@href"
        let plain = try ModernParserBridge(source: source).parseTOC(
            html: Self.tocPage(["1"]), baseURL: "https://toc.test/book/1/", source: source
        )
        #expect(plain.map(\.url) == ["https://toc.test/c/1"])
    }

    /// 桔纸书屋 (YCK 1330) cleans a copy of the chapter box and reads it:
    /// `c = box.clone(); c.select('a,script,style').remove()`.
    @Test("jsoup clone() is a copy the script edits without touching the page")
    func jsoupClone() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var doc = org.jsoup.Jsoup.parse('<div id="c"><p>正文</p><script>x()</script></div>');
        var box = doc.selectFirst('#c');
        var copy = box.clone();
        copy.select('script').remove();
        var list = doc.select('p').clone();
        list.get(0).text('改');
        [copy.html().replace(/\\s+/g, ''), doc.select('script').size(), doc.selectFirst('p').text(),
         list.get(0).text()].join('|');
        """)
        #expect(value == "<p>正文</p>|1|正文|改")
        #expect(engine.lastError == nil)
    }

    // MARK: - Content pages

    /// 故事族 (YCK 1330): its 「下一篇」 link is the next chapter. Legado ends the chain there
    /// (`BookContent.getContent`); following it read the whole book until the site answered 429.
    @Test("a chapter's page chain stops at the next chapter's URL, relative or not")
    func pageChainStopsAtNextChapter() async throws {
        let site = "https://pages.yuedu.test"
        let result = try await Self.paginate(
            nextChapterURL: site + "/c/2",
            links: ["p1": [site + "/c/1_2"], "p2": ["/c/2"], "c2": []],
            pages: [site + "/c/1_2": "p2", site + "/c/2": "c2"]
        )
        #expect(result.content == "p1\np2")
        #expect(result.fetched == [site + "/c/1_2"])
    }

    /// 得齐小说网 (feedback mail 2026-11-07): 《清光宝鉴》 chapter 247 is thirteen pages, and a
    /// cap of ten next pages cut off the last two.
    @Test("a chapter's page chain reads every page, however many")
    func pageChainHasNoPageCap() async throws {
        let site = "https://pages.yuedu.test"
        var links: [String: [String]] = [:]
        var pages: [String: String] = [:]
        for page in 1...13 {
            links["p\(page)"] = page < 13 ? [site + "/c/1_\(page + 1)"] : [site + "/c/2"]
            if page > 1 { pages[site + "/c/1_\(page)"] = "p\(page)" }
        }
        let result = try await Self.paginate(nextChapterURL: site + "/c/2", links: links, pages: pages)
        #expect(result.content == (1...13).map { "p\($0)" }.joined(separator: "\n"))
        #expect(result.fetched == (2...13).map { site + "/c/1_\($0)" })
    }

    @Test("a chapter's page chain stops at a page already read")
    func pageChainStopsAtRevisit() async throws {
        let site = "https://pages.yuedu.test"
        let result = try await Self.paginate(
            nextChapterURL: nil,
            links: ["p1": [site + "/c/1_2"], "p2": [site + "/c/1"]],
            pages: [site + "/c/1_2": "p2", site + "/c/1": "p1"]
        )
        #expect(result.content == "p1\np2")
        #expect(result.fetched == [site + "/c/1_2"])
    }

    /// Several links on the first page are the chapter's pages: each is read once, and their
    /// own links are not followed.
    @Test("several next links on the first page are read once each, without their links")
    func pageSetReadsEachOnce() async throws {
        let site = "https://pages.yuedu.test"
        let result = try await Self.paginate(
            nextChapterURL: nil,
            links: ["p1": [site + "/c/1_2", site + "/c/1_3"], "p2": [site + "/c/1_4"], "p3": [site + "/c/1_4"]],
            pages: [site + "/c/1_2": "p2", site + "/c/1_3": "p3", site + "/c/1_4": "p4"]
        )
        #expect(result.content == "p1\np2\np3")
        #expect(result.fetched == [site + "/c/1_2", site + "/c/1_3"])
    }

    /// The runtime chapter route read the first page only, so a source's `nextContentUrl`
    /// never ran there. `data:` URLs take that route without the network.
    @Test("the runtime chapter route reads the next pages too")
    func runtimeChapterRouteReadsNextPages() async throws {
        var source = Self.source()
        source.ruleContent.content = "#c@text"
        source.ruleContent.nextContentUrl = "a.next@href"
        let page2 = Self.dataURL(#"<div id="c">第二頁</div>"#)
        let page1 = Self.dataURL(#"<div id="c">第一頁</div><a class="next" href="\#(page2)">下一頁</a>"#)
        #expect(source.shouldUseLegadoRuntimeFetch(for: page1))
        let bookID = UUID()
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: bookID) }

        let package = try await BookSourceFetcher.shared.fetchChapterPackage(
            ref: OnlineChapterRef(index: 0, title: "第一章", url: page1), bookId: bookID, source: source
        )

        #expect(package.content.contains("第一頁"))
        #expect(package.content.contains("第二頁"))
    }

    // MARK: - Fixtures

    private static func source() -> BookSource {
        BookSource(
            bookSourceUrl: "https://book-state-\(UUID().uuidString.prefix(8).lowercased()).yuedu.test",
            bookSourceName: "book state fixture"
        )
    }

    /// The detail stage on a search result whose page was its own page (`infoHtml`), so no
    /// request is made.
    private static func detail(source: BookSource, html: String) async throws -> BookInfoPackage {
        let searchBook = OnlineBook(
            name: "搜尋書名", author: "搜尋作者", intro: "", coverUrl: "",
            bookUrl: source.bookSourceUrl + "/book/1", tocUrl: "", wordCount: "", lastChapter: "",
            kind: "玄幻", sourceId: source.id, sourceName: source.bookSourceName
        ).withInfoHTML(html)
        return try await BookSourceFetcher.shared.fetchBookInfoPackage(
            url: searchBook.bookUrl, source: source, knownBook: searchBook, usesCache: false
        )
    }

    private static func toc(
        _ tocURL: String, source: BookSource, runtimeVariables: [String: String]?
    ) async throws -> TOCPackage {
        try await BookSourceFetcher.shared.fetchTOCPackage(
            tocUrl: tocURL, source: source, runtimeVariables: runtimeVariables,
            forceRefresh: true, runPreUpdateJs: false, writesCache: false
        )
    }

    private static func tocPage(_ titles: [String], extra: String = "") -> String {
        let items = titles.map { "<dd><a href=\"/c/\($0)\">\($0)</a></dd>" }.joined()
        return "<html><body><dl id=\"list\">\(items)</dl>\(extra)</body></html>"
    }

    private static func dataURL(_ html: String) -> String {
        "data:text/html;base64," + Data(html.utf8).base64EncodedString()
    }

    /// Chapter `/c/1` read as page "p1", with `links` giving each page's next links and `pages`
    /// the page each URL answers. Returns the merged content and the URLs fetched, in order.
    private static func paginate(
        nextChapterURL: String?, links: [String: [String]], pages: [String: String]
    ) async throws -> (content: String, fetched: [String]) {
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        let first = try #require(URL(string: "https://pages.yuedu.test/c/1"))
        let result = try await ChapterFetcher.shared.fetchPaginatedContent(
            initialHTML: "p1", initialURL: first, initialBaseURL: first.absoluteString,
            nextChapterURL: nextChapterURL,
            parsePage: { html, _, _ in
                ChapterParsePayload(content: html, title: "", sourceMatched: true, isPay: false)
            },
            extractNextURLs: { html, _, _ in links[html] ?? [] },
            fetchNextPageHTML: { link in
                fetched.withLock { $0.append(link) }
                return pages[link] ?? ""
            }
        )
        return (result.payload.content, fetched.withLock { $0 })
    }
}
