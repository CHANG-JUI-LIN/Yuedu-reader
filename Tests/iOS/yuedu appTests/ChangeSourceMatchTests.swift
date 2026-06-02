import Foundation
import Testing
@testable import yuedu_app

/// Covers the relaxed "same book" heuristic used by the reader's 換源 (source
/// switch) search. The previous exact `(name, author)` key match returned an
/// empty list whenever a source omitted the author or formatted the title
/// slightly differently.
struct ChangeSourceMatchTests {
    @Test("identical name and author match")
    func identicalMatches() {
        #expect(SearchBook.isLikelySameBook(
            name: "星辰之海", author: "旅人",
            name: "星辰之海", author: "旅人"))
    }

    @Test("empty author on either side still matches when names agree")
    func emptyAuthorStillMatches() {
        // Current book has an author, candidate source omitted it.
        #expect(SearchBook.isLikelySameBook(
            name: "星辰之海", author: "旅人",
            name: "星辰之海", author: ""))
        // Current book has no author, candidate source reports one.
        #expect(SearchBook.isLikelySameBook(
            name: "星辰之海", author: "",
            name: "星辰之海", author: "旅人"))
    }

    @Test("fullwidth/halfwidth and spacing differences are normalized")
    func normalizationMatches() {
        #expect(SearchBook.isLikelySameBook(
            name: "Ｓｔａｒ Ｓｅａ", author: "Ａｌｉｃｅ",
            name: "star sea", author: "alice"))
    }

    @Test("title subtitle/volume suffix variations match")
    func titleContainmentMatches() {
        #expect(SearchBook.isLikelySameBook(
            name: "星辰之海", author: "旅人",
            name: "星辰之海（完結）", author: "旅人"))
    }

    @Test("different authors on both sides are rejected")
    func differentAuthorsRejected() {
        #expect(!SearchBook.isLikelySameBook(
            name: "星辰之海", author: "旅人",
            name: "星辰之海", author: "另一位作者"))
    }

    @Test("different titles are rejected")
    func differentTitlesRejected() {
        #expect(!SearchBook.isLikelySameBook(
            name: "星辰之海", author: "旅人",
            name: "月光筆記", author: "旅人"))
    }

    @Test("empty names never match")
    func emptyNamesRejected() {
        #expect(!SearchBook.isLikelySameBook(
            name: "", author: "旅人",
            name: "星辰之海", author: "旅人"))
    }
}
