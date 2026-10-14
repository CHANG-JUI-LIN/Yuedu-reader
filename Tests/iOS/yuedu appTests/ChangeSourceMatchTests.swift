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

    @Test("author containment (e.g. 作者 + 著) still matches")
    func authorContainmentMatches() {
        #expect(SearchBook.isLikelySameBook(
            name: "斗罗大陆", author: "唐家三少",
            name: "斗罗大陆", author: "唐家三少著"))
    }

    @Test("title must match exactly — suffix/sequel variations are rejected")
    func titleMustMatchExactly() {
        // A status suffix is treated as a different title (avoids false merges).
        #expect(!SearchBook.isLikelySameBook(
            name: "星辰之海", author: "旅人",
            name: "星辰之海（完結）", author: "旅人"))
        // Sequels by the same author must NOT be offered as an alternative source.
        #expect(!SearchBook.isLikelySameBook(
            name: "斗罗大陆", author: "唐家三少",
            name: "斗罗大陆3", author: "唐家三少"))
        #expect(!SearchBook.isLikelySameBook(
            name: "斗罗大陆", author: "唐家三少",
            name: "斗罗大陆之笔", author: "修罗界"))
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
        // A title of punctuation alone folds to nothing (4d).
        #expect(!SearchBook.isLikelySameBook(
            name: "！！", author: "旅人",
            name: "？", author: "旅人"))
    }

    // MARK: - Unified search 4d (maintainer, 2026-10-14): titles by `WorkMatchKey`

    @Test("Traditional, Simplified and punctuation variants of a title are the same book")
    func workKeyTitlesMatch() {
        #expect(SearchBook.isLikelySameBook(
            name: "三體", author: "劉慈欣",
            name: "三体", author: "刘慈欣"))
        #expect(SearchBook.isLikelySameBook(
            name: "三體", author: "劉慈欣",
            name: "三體！", author: "劉慈欣"))
        #expect(SearchBook.isLikelySameBook(
            name: "斗羅大陸", author: "唐家三少",
            name: "斗罗大陆", author: "唐家三少著"))
    }

    @Test("a folded title without an author on one side still matches")
    func workKeyTitleWithoutAuthorMatches() {
        #expect(SearchBook.isLikelySameBook(
            name: "三體", author: "劉慈欣",
            name: "三体", author: ""))
        #expect(SearchBook.isLikelySameBook(
            name: "三体", author: " ",
            name: "三體！", author: "劉慈欣"))
    }

    @Test("folding does not join different authors or sequels")
    func workKeyStillRejects() {
        #expect(!SearchBook.isLikelySameBook(
            name: "三體", author: "劉慈欣",
            name: "三体", author: "王晉康"))
        #expect(!SearchBook.isLikelySameBook(
            name: "三體", author: "劉慈欣",
            name: "三体II", author: "刘慈欣"))
        #expect(!SearchBook.isLikelySameBook(
            name: "斗羅大陸", author: "唐家三少",
            name: "斗罗大陆3", author: "唐家三少"))
    }
}
