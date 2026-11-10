import Foundation
import Testing
@testable import yuedu_app

/// Legado reads a book's own pages (`BookInfo`, `BookChapterList`, `BookContent`) with two URLs:
/// `baseUrl`, the URL the rule gave — options and all — which the scripts see and an empty `isUrl`
/// read answers, and `redirectUrl`, the response's, which relative links resolve against.
@Suite("Legado page base URL")
struct LegadoPageBaseURLTests {
    private static let postURL =
        #"https://api.page-base.test/detail.api?product=x,{"method":"POST","body":"postid=7"}"#
    private static let pageURL = "https://api.page-base.test/detail.api?product=x"

    @Test("老福特: an empty tocUrl is the book's URL with its POST options, as the scripts see it")
    func emptyTOCURLKeepsPostOptions() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://page-base-info.test"
        source.ruleBookInfo.name = "$.name"
        source.ruleBookInfo.intro = "<js>baseUrl</js>"
        source.ruleBookInfo.tocUrl = "$.missing\n<js>result</js>"
        source.ruleBookInfo.coverUrl = "$.cover"
        let info = try ModernParserBridge(source: source).parseBookInfo(
            html: #"{"name":"书","cover":"/c.png"}"#,
            bookUrl: Self.postURL, baseURL: Self.pageURL, source: source
        )
        #expect(info.tocUrl == Self.postURL)
        #expect(info.intro == Self.postURL)
        #expect(info.coverUrl == "https://api.page-base.test/c.png")
    }

    @Test("a TOC page: the scripts' baseUrl is the TOC's rule URL, links resolve against the page")
    func tocReadsRuleURLAndResolvesAgainstPage() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://page-base-toc.test"
        source.ruleToc.chapterList = "a"
        source.ruleToc.chapterName = "@text"
        source.ruleToc.chapterUrl = "@href@js:result == '' ? baseUrl : result"
        let chapters = try ModernParserBridge(source: source).parseTOC(
            html: #"<a href="/c/1">One</a><a href="">Two</a>"#,
            baseURL: "https://www.page-base-toc.test/book/1/",
            ruleURL: Self.postURL,
            source: source
        )
        #expect(chapters.map(\.url) == ["https://www.page-base-toc.test/c/1", Self.postURL])
    }

    @Test("嬉皮漫画: a page URL keeps its characters, so a chain meets the same URL again")
    func redirectKeepsCharacters() {
        let page = #"https://chain.test/v1/manga/%7B%22code%22:200}"x"#
        let html = #"<a id="self" href='%7B%22code%22:200}"x'>s</a><a id="tag" href='<html>'>t</a>"#
        let engine = ModernRuleEngine()
        engine.setContent(html, baseUrl: page)
        engine.setRedirectUrl(page)
        #expect(engine.getString(ruleStr: "id.self@href", isUrl: true) == page)
        #expect(engine.getStringList(ruleStr: "id.tag@href", isUrl: true)
                == ["https://chain.test/v1/manga/<html>"])
    }

    @Test("a URL without a scheme leaves the page before as the one links resolve against")
    func schemelessRedirectIgnored() {
        let engine = ModernRuleEngine()
        engine.setContent(#"<a href="c">c</a>"#, baseUrl: "https://keep.test/a/b")
        engine.setRedirectUrl("https://keep.test/a/b")
        engine.setRedirectUrl("not a url")
        #expect(engine.getString(ruleStr: "a@href", isUrl: true) == "https://keep.test/a/c")
    }

    @Test("without a rule URL the page's URL is both")
    func pageURLStandsInForMissingRuleURL() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://page-base-none.test"
        source.ruleToc.chapterList = "a"
        source.ruleToc.chapterName = "@text"
        source.ruleToc.chapterUrl = "@js:baseUrl"
        let chapters = try ModernParserBridge(source: source).parseTOC(
            html: #"<a href="/c/1">One</a>"#,
            baseURL: "https://www.page-base-none.test/book/1/",
            source: source
        )
        #expect(chapters.map(\.url) == ["https://www.page-base-none.test/book/1/"])
    }
}
