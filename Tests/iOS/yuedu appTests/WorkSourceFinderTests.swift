import Foundation
import Testing
@testable import yuedu_app

/// Discovery 7b-2: 「尋找可用來源」 searches the enabled sources for a work only when tapped,
/// and the books found of it join 作品詳情's 來源 (maintainer, 2026-10-13).
@Suite("Work source finder")
@MainActor
struct WorkSourceFinderTests {
    private func source(_ name: String, enabled: Bool = true) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://\(name).example", bookSourceName: name)
        source.enabled = enabled
        return source
    }

    private func origin(_ source: BookSource, path: String) -> BookOrigin {
        BookOrigin(sourceId: source.id, sourceName: source.bookSourceName, bookUrl: "\(source.bookSourceUrl)/book/\(path)",
                   tocUrl: "", coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
    }

    private func book(_ name: String, by author: String, in source: BookSource, path: String) -> OnlineBook {
        OnlineBook(name: name, author: author, intro: "", coverUrl: "", bookUrl: "\(source.bookSourceUrl)/book/\(path)",
                   tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName)
    }

    private func route(_ book: OnlineBook, in source: BookSource) -> WorkDetailRoute {
        WorkDetailRoute(.onlineBook(book, source: source))!
    }

    private func sources(_ list: BookSource...) -> [UUID: BookSource] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private static func url(_ route: WorkDetailRoute) -> String? {
        guard case .onlineBook(let frozen) = route.opening else { return nil }
        return frozen.book.bookUrl
    }

    @Test("a search's books of the work, one per source; another author's book of the title is not")
    func matches() {
        let b = source("b"), c = source("c"), off = source("off", enabled: false)
        let tapped = WorkDetailRoute(.gutenberg(GutenbergBook(id: 2701, title: "Moby Dick", author: "Herman Melville")))
        let results = [
            SearchBook(name: "Moby Dick", author: "Herman Melville",
                       origins: [origin(b, path: "1"), origin(b, path: "2"), origin(c, path: "9"), origin(off, path: "5")]),
            SearchBook(name: "Moby Dick", author: "Someone Else", origins: [origin(c, path: "other")]),
        ]
        let found = WorkSourceFinder.matches(of: tapped, in: results, sources: sources(b, c, off))
        #expect(found.compactMap(Self.url) == ["https://b.example/book/1", "https://c.example/book/9"])
    }

    @Test("a found book joins after the listed versions, unless its source is listed already")
    func joined() {
        let a = source("a"), b = source("b"), c = source("c")
        let tapped = route(book("三體", by: "劉慈欣", in: a, path: "1"), in: a)
        let cached = route(book("三體", by: "劉慈欣", in: b, path: "1"), in: b)
        let listed = [tapped, cached]
        let found = [route(book("三體", by: "劉慈欣", in: b, path: "2"), in: b),
                     route(book("三體", by: "劉慈欣", in: c, path: "1"), in: c),
                     route(book("三體", by: "劉慈欣", in: a, path: "1"), in: a)]
        let versions = WorkSourceFinder.joined(listed, found: found)
        #expect(versions.compactMap(Self.url) == ["https://a.example/book/1", "https://b.example/book/1",
                                                   "https://c.example/book/1"])
    }

    @Test("nothing found joins nothing")
    func joinedEmpty() {
        let a = source("a")
        let listed = [route(book("三體", by: "劉慈欣", in: a, path: "1"), in: a)]
        #expect(WorkSourceFinder.joined(listed, found: []).map(\.nodeKey) == listed.map(\.nodeKey))
    }

    @Test("how a search ends: paused with sources left, failed when no source answered, else done")
    func outcome() {
        typealias Progress = SearchAggregator.SearchProgress
        #expect(WorkSourceFinder.outcome(paused: true, progress: Progress(total: 9, completed: 3)) == .done(more: true))
        #expect(WorkSourceFinder.outcome(paused: false, progress: Progress(total: 3, completed: 0, failed: 2, timedOut: 1))
                == .failed)
        #expect(WorkSourceFinder.outcome(paused: false, progress: Progress(total: 3, completed: 1, failed: 2)) == .done(more: false))
        // A fetch that failed is counted as answered, with no results (Phase 0b); it is still a failure.
        #expect(WorkSourceFinder.outcome(paused: false, progress: Progress(total: 2, completed: 2, failed: 0, failedAsEmpty: 2))
                == .failed)
        #expect(WorkSourceFinder.outcome(paused: false, progress: Progress(total: 2, completed: 2, failedAsEmpty: 1))
                == .done(more: false))
        // Every source cooling down from timeouts: none was asked, which is not a failed search.
        #expect(WorkSourceFinder.outcome(paused: false, progress: Progress(total: 0, skipped: 4)) == .done(more: false))
    }

    @Test("no enabled source: says so without searching")
    func noSources() {
        let finder = WorkSourceFinder()
        let a = source("a")
        finder.find(route(book("三體", by: "劉慈欣", in: a, path: "1"), in: a), sources: [source("off", enabled: false)])
        #expect(finder.state == .noSources)
        #expect(finder.found.isEmpty)
    }
}
