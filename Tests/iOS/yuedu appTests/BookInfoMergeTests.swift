import Foundation
import Testing

@testable import yuedu_app

/// The detail-page merge contract, mirrored from legado's `BookInfo.analyzeBookInfo`.
///
/// legado updates the `Book` it was handed instead of building a new one:
///
///     BookHelp.formatBookName(analyzeRule.getString(infoRule.name)).let {
///         if (it.isNotEmpty() && (mCanReName || book.name.isEmpty())) { book.name = it }
///     }
///     analyzeRule.getString(infoRule.coverUrl).let { if (it.isNotEmpty()) book.coverUrl = … }
///
/// 431 of 1912 real sources (22.5%) ship an empty `ruleBookInfo.name` because they rely on that.
/// Parsing into a standalone value dropped it: books opened with a blank title and 校驗書源
/// reported 詳情為空.
@Suite("Book info merge")
struct BookInfoMergeTests {

    private func package(
        name: String = "",
        author: String = "",
        intro: String = "",
        coverUrl: String = "",
        tocUrl: String = "",
        lastChapter: String = ""
    ) -> BookInfoPackage {
        BookInfoPackage(
            sourceId: UUID(),
            sourceName: "s",
            bookURL: "https://example.com/b",
            name: name,
            author: author,
            intro: intro,
            coverUrl: coverUrl,
            tocUrl: tocUrl,
            wordCount: "",
            lastChapter: lastChapter,
            kind: "",
            runtimeVariables: nil,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    private func searchResult(
        name: String = "搜索書名",
        author: String = "搜索作者",
        intro: String = "搜索簡介",
        coverUrl: String = "https://example.com/search.jpg",
        tocUrl: String = "https://example.com/search-toc",
        lastChapter: String = "搜索最新章"
    ) -> OnlineBook {
        OnlineBook(
            name: name,
            author: author,
            intro: intro,
            coverUrl: coverUrl,
            bookUrl: "https://example.com/b",
            tocUrl: tocUrl,
            wordCount: "",
            lastChapter: lastChapter,
            kind: "",
            sourceId: UUID(),
            sourceName: "s"
        )
    }

    @Test("an empty detail name keeps the name the search result carried")
    func emptyDetailNameKeepsSearchName() {
        let merged = package().merging(searchResult: searchResult(), canReName: false)
        #expect(merged.name == "搜索書名")
        #expect(merged.author == "搜索作者")
    }

    @Test("without canReName a detail name does not overwrite a known one")
    func detailNameDoesNotOverwriteWithoutCanReName() {
        // legado: `mCanReName || book.name.isEmpty()`. A source that did not declare canReName is
        // not allowed to rename a book the user already picked by title.
        let merged = package(name: "詳情書名", author: "詳情作者")
            .merging(searchResult: searchResult(), canReName: false)
        #expect(merged.name == "搜索書名")
        #expect(merged.author == "搜索作者")
    }

    @Test("with canReName the detail name wins")
    func detailNameWinsWithCanReName() {
        let merged = package(name: "詳情書名", author: "詳情作者")
            .merging(searchResult: searchResult(), canReName: true)
        #expect(merged.name == "詳情書名")
        #expect(merged.author == "詳情作者")
    }

    @Test("a detail name fills in when the search result had none, even without canReName")
    func detailNameFillsEmptySearchName() {
        let merged = package(name: "詳情書名")
            .merging(searchResult: searchResult(name: "", author: ""), canReName: false)
        #expect(merged.name == "詳情書名")
    }

    @Test("non-name fields take the detail value whenever it is non-empty")
    func nonNameFieldsPreferDetail() {
        let merged = package(
            intro: "詳情簡介",
            coverUrl: "https://example.com/detail.jpg",
            tocUrl: "https://example.com/detail-toc",
            lastChapter: "詳情最新章"
        ).merging(searchResult: searchResult(), canReName: false)
        #expect(merged.intro == "詳情簡介")
        #expect(merged.coverUrl == "https://example.com/detail.jpg")
        #expect(merged.tocUrl == "https://example.com/detail-toc")
        #expect(merged.lastChapter == "詳情最新章")
    }

    @Test("non-name fields fall back to the search result when the detail page omits them")
    func nonNameFieldsFallBack() {
        let merged = package().merging(searchResult: searchResult(), canReName: false)
        #expect(merged.intro == "搜索簡介")
        #expect(merged.coverUrl == "https://example.com/search.jpg")
        #expect(merged.tocUrl == "https://example.com/search-toc")
        #expect(merged.lastChapter == "搜索最新章")
    }

    @Test("whitespace-only detail values count as empty")
    func whitespaceOnlyDetailValuesAreEmpty() {
        let merged = package(name: "   ", coverUrl: "\n\t")
            .merging(searchResult: searchResult(), canReName: true)
        #expect(merged.name == "搜索書名")
        #expect(merged.coverUrl == "https://example.com/search.jpg")
    }

    @Test("with no search result the parsed package passes through untouched")
    func noSearchResultPassesThrough() {
        let parsed = package(name: "詳情書名", intro: "詳情簡介")
        let merged = parsed.merging(searchResult: nil, canReName: false)
        #expect(merged.name == "詳情書名")
        #expect(merged.intro == "詳情簡介")
        #expect(merged.author.isEmpty)
    }
}
