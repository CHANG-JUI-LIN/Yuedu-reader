import Foundation
import Testing
@testable import yuedu_app

struct BookshelfSearchTests {
    @Test("empty bookshelf search keeps the visible order")
    func emptyQueryKeepsVisibleOrder() {
        let books = [
            ReadingBook(title: "Alpha", author: "A", contentFilename: "alpha.txt"),
            ReadingBook(title: "Beta", author: "B", contentFilename: "beta.txt")
        ]

        let filtered = BookshelfSearchFilter.filter(books, query: "   ")

        #expect(filtered.map(\.title) == ["Alpha", "Beta"])
    }

    @Test("bookshelf search matches book titles only")
    func searchMatchesBookTitlesOnly() {
        let books = [
            ReadingBook(title: "星辰之海", author: "旅人", contentFilename: "sea.txt"),
            ReadingBook(title: "平凡故事", author: "星辰作者", contentFilename: "plain.txt"),
            ReadingBook(title: "月光筆記", author: "旅人", contentFilename: "moon.txt")
        ]

        let filtered = BookshelfSearchFilter.filter(books, query: "星辰")

        #expect(filtered.map(\.title) == ["星辰之海"])
    }
}
