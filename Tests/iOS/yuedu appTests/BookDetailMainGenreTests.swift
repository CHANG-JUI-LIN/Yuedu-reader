import Testing
@testable import yuedu_app

// The detail page shows one genre (maintainer, 2026-11-15: 「詳情頁顯示主分類就行」): a source's
// `kind` has no main and sub genre, so the main one is the first that is not about the book's state.

@Suite("Book detail main genre")
struct BookDetailMainGenreTests {
    @Test("the first genre, alone; state words before it are passed over, in either script")
    func tags() {
        #expect(BookDetailMainGenre.main(of: ["玄幻", "東方玄幻", "連載"]) == ["玄幻"])
        #expect(BookDetailMainGenre.main(of: ["连载中", "完結", "VIP", "都市"]) == ["都市"])
        #expect(BookDetailMainGenre.main(of: ["已完结", " "]).isEmpty)
        #expect(BookDetailMainGenre.main(of: [String]()).isEmpty)
    }

    @Test("links keep the first genre and the series, which is not a genre")
    func links() {
        func link(_ id: String, _ title: String) -> BookDetailLink {
            BookDetailLink(id: id, title: title, action: {})
        }
        let shown = BookDetailMainGenre.main(of: [link("genre.完本", "完本"), link("genre.科幻", "科幻"),
                                                 link("genre.硬科幻", "硬科幻"), link("series", "三體 · 第 2 冊")])
        #expect(shown.map(\.id) == ["genre.科幻", "series"])
        #expect(BookDetailMainGenre.main(of: [link("series", "三體")]).map(\.id) == ["series"])
    }
}
