import Foundation
import Testing
@testable import yuedu_app

/// Legado reads a search or explore row into a `SearchBook` that the row's scripts see as
/// `book`, writing each field as soon as it is read: name, author, kind, word count, latest
/// chapter, intro, cover, link (`BookList.getSearchItem`).
@Suite("Legado search book")
struct LegadoSearchBookTests {
    @Test("松鹤阅读: the link reads the kind the row already read")
    func linkReadsEarlierKind() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://search-book.test"
        source.ruleSearch.bookList = "$.data.state[*]"
        source.ruleSearch.name = "$.title"
        source.ruleSearch.kind = "$.groupID##.*_##"
        source.ruleSearch.bookUrl = "https://search-book.test/bookInfo?resourceId={{book.kind}}"
        source.ruleSearch.intro = "@js:book.name + '/' + book.author + '/' + book.wordCount"
        source.ruleSearch.author = "$.author"
        source.ruleSearch.wordCount = "$.size"
        let page = #"""
        {"data":{"state":[{"title":"一","author":"甲","groupID":"g_1100","size":"9"},
                          {"title":"二","author":"乙","groupID":"g_2200","size":"8"}]}}
        """#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: page, baseURL: "https://search-book.test/s", source: source
        )
        #expect(books.map(\.bookUrl) == [
            "https://search-book.test/bookInfo?resourceId=1100",
            "https://search-book.test/bookInfo?resourceId=2200",
        ])
        #expect(books.map(\.intro) == ["一/甲/9", "二/乙/8"])
    }

    @Test("a row's book starts empty: nothing of the row before it, the source's origin")
    func eachRowHasItsOwnBook() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://search-book-own.test"
        source.bookSourceName = "own"
        source.ruleSearch.bookList = "$.list[*]"
        source.ruleSearch.name = "$.name"
        source.ruleSearch.bookUrl = "$.url"
        source.ruleSearch.intro = "@js:(book.kind || 'none') + ':' + book.originName"
        source.ruleSearch.kind = "$.kind"
        let page = #"{"list":[{"name":"一","url":"/1","kind":"玄幻"},{"name":"二","url":"/2"}]}"#
        let books = try ModernParserBridge(source: source).parseSearchResults(
            html: page, baseURL: "https://search-book-own.test/s", source: source
        )
        #expect(books.map(\.intro) == ["玄幻:own", "none:own"])
    }
}
