import Foundation
import Testing
@testable import yuedu_app

/// Discovery 7b-1: the books the reader's own sources already listed of a work, and the
/// 青空文庫 catalog's, join 作品詳情's versions with no request (maintainer, 2026-10-13).
@Suite("Work offers")
@MainActor
struct WorkOffersTests {
    private func source(_ name: String, enabled: Bool = true) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://\(name).example", bookSourceName: name)
        source.enabled = enabled
        return source
    }

    private func book(_ name: String, by author: String, in source: BookSource, path: String? = nil) -> OnlineBook {
        OnlineBook(name: name, author: author, intro: "", coverUrl: "",
                   bookUrl: "\(source.bookSourceUrl)/book/\(path ?? name)", tocUrl: "", wordCount: "", lastChapter: "",
                   kind: "", sourceId: source.id, sourceName: source.bookSourceName)
    }

    private func route(_ book: OnlineBook, in source: BookSource) -> WorkDetailRoute {
        WorkDetailRoute(.onlineBook(book, source: source))!
    }

    private func sources(_ list: BookSource...) -> [UUID: BookSource] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    @Test("a book of the same title by a compatible author joins, folded as WorkMatchKey folds")
    func sameWork() {
        let a = source("a"), b = source("b")
        let tapped = route(book("三體", by: "劉慈欣", in: a), in: a)
        let offers = WorkOffers.books(of: tapped, in: [book("三体", by: "刘慈欣 著", in: b)], sources: sources(a, b))
        #expect(offers.map(\.record.key.instance.id) == [b.bookSourceUrl])
        guard case .onlineBook(let frozen) = offers.first?.opening else {
            Issue.record("not a book-source version")
            return
        }
        #expect(frozen.book.bookUrl == "https://b.example/book/三体")
    }

    @Test("a work with an author: another author's book, or one with no author, never joins")
    func titleAlone() {
        let a = source("a"), b = source("b")
        let tapped = route(book("三體", by: "劉慈欣", in: a), in: a)
        #expect(WorkOffers.books(of: tapped, in: [book("三體", by: "王晉康", in: b), book("三體", by: "", in: b)],
                                 sources: sources(a, b)).isEmpty)
    }

    @Test("a work with no author: the title's books join when they all name one author (maintainer, 2026-10-17)")
    func noAuthor() {
        let a = source("a"), b = source("b"), c = source("c")
        let anonymous = route(book("斗罗大陆", by: "", in: a), in: a)
        let agreeing = WorkOffers.books(of: anonymous, in: [book("斗罗大陆", by: "唐家三少", in: b),
                                                             book("鬥羅大陸", by: "唐家三少 著", in: c)],
                                        sources: sources(a, b, c))
        #expect(agreeing.map(\.record.key.instance.id) == [b.bookSourceUrl, c.bookSourceUrl])
        #expect(WorkOffers.books(of: anonymous, in: [book("斗罗大陆", by: "唐家三少", in: b), book("斗罗大陆", by: "某某", in: c)],
                                 sources: sources(a, b, c)).isEmpty, "two authors, one each: not guessed")
        let d = source("d")
        let majority = WorkOffers.books(of: anonymous, in: [book("斗罗大陆", by: "某某", in: b),
                                                             book("斗罗大陆", by: "唐家三少", in: c),
                                                             book("斗罗大陆", by: "唐家三少", in: d)],
                                        sources: sources(a, b, c, d))
        #expect(majority.map(\.record.key.instance.id) == [c.bookSourceUrl, d.bookSourceUrl],
                "two of three name 唐家三少: only theirs are offered")
        #expect(WorkOffers.books(of: anonymous, in: [book("斗罗大陆", by: "", in: b)], sources: sources(a, b)).isEmpty,
                "a book naming no author tells nothing")
        let placeholder = route(book("斗罗大陆", by: "未知作者", in: a), in: a)
        #expect(WorkOffers.books(of: placeholder, in: [book("斗罗大陆", by: "唐家三少", in: b)], sources: sources(a, b)).count == 1,
                "「未知作者」 is no author")
    }

    @Test("an author placeholder is not an author")
    func placeholders() {
        #expect(WorkMatchKey.knownAuthors(["未知作者", "Unknown Author", " ", "唐家三少"]) == ["唐家三少"])
    }

    @Test("one version per source, its first book; the tapped book is not offered again")
    func onePerSource() {
        let a = source("a"), b = source("b")
        let tappedBook = book("三體", by: "劉慈欣", in: a)
        let tapped = route(tappedBook, in: a)
        let offers = WorkOffers.books(of: tapped, in: [tappedBook, book("三體", by: "劉慈欣", in: a, path: "2"),
                                                      book("三體", by: "劉慈欣", in: b, path: "1"),
                                                      book("三體", by: "劉慈欣", in: b, path: "2")],
                                      sources: sources(a, b))
        #expect(offers.compactMap(Self.url) == ["https://b.example/book/1"])
    }

    @Test("a source no longer installed or turned off offers nothing")
    func uninstalledOrDisabled() {
        let a = source("a"), off = source("off", enabled: false), gone = source("gone")
        let tapped = route(book("三體", by: "劉慈欣", in: a), in: a)
        #expect(WorkOffers.books(of: tapped, in: [book("三體", by: "劉慈欣", in: off), book("三體", by: "劉慈欣", in: gone)],
                                 sources: sources(a, off)).isEmpty)
    }

    @Test("a work from a library joins too: a shelf copy's or a Gutenberg book's")
    func fromALibrary() {
        let b = source("b")
        let tapped = WorkDetailRoute(.gutenberg(GutenbergBook(id: 2701, title: "Moby Dick", author: "Herman Melville")))
        let offers = WorkOffers.books(of: tapped, in: [book("Moby-Dick", by: "Melville, Herman", in: b),
                                                      book("Moby Dick", by: "Herman Melville", in: b)],
                                      sources: sources(b))
        #expect(offers.compactMap(Self.url) == ["https://b.example/book/Moby Dick"])
    }

    @Test("青空文庫's catalog offers its work of the same title and author, and nothing for 青空文庫's own work")
    func aozora() throws {
        let index = SeriesCardsTests.catalog(titles: ["三體", "球狀閃電"])
        let a = source("a")
        let tapped = route(book("三體", by: "劉慈欣", in: a), in: a)
        let offers = WorkOffers.aozora(of: tapped, in: index)
        let work = try #require(index.worksByID["1"])
        #expect(offers.map { $0.record.key } == [SourceRecord.derived(from: work).key])
        #expect(WorkOffers.aozora(of: route(book("三體", by: "王晉康", in: a), in: a), in: index).isEmpty)
        #expect(WorkOffers.aozora(of: try #require(offers.first), in: index).isEmpty)
        #expect(WorkOffers.aozora(of: route(book("三體", by: "未知作者", in: a), in: a), in: index).map { $0.record.key }
                == [SourceRecord.derived(from: work).key], "no author: the catalog's one author of the title")
    }

    private static func url(_ route: WorkDetailRoute) -> String? {
        guard case .onlineBook(let frozen) = route.opening else { return nil }
        return frozen.book.bookUrl
    }
}
