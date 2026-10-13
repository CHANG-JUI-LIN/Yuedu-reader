import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5f-4c (decision 29): 搜索's result opens 作品詳情, through a route made from
/// the snapshot frozen at the tap. The route names the origin the result's page opens on, as
/// Explore's row of the same book does.
@MainActor
@Suite("搜索 result's work route")
struct SearchWorkRouteTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SearchWorkRoute-\(UUID().uuidString)")

    private func source(_ url: String) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = url
        source.bookSourceName = url
        return source
    }

    private func origin(_ source: BookSource, url: String, intro: String = "") -> BookOrigin {
        BookOrigin(sourceId: source.id, sourceName: source.bookSourceName, bookUrl: url, tocUrl: "", coverUrl: "",
                   intro: intro, lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
    }

    private func dataURL(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "data:;base64,\(data.base64EncodedString()),{\"type\":\"qingtian\"}"
    }

    @Test("the first origin, keyed as Explore's row of the same book")
    func firstOrigin() throws {
        let first = source("https://a.test"), second = source("https://b.test")
        let store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync([first, second])
        let result = SearchBook(name: "三體", author: "劉慈欣",
                                origins: [origin(first, url: "/book/1", intro: "<p>地球往事</p>"), origin(second, url: "/book/9")])

        let route = try #require(WorkDetailRoute(searchResult: result, sources: store))
        let book = OnlineBook(detailOrigin: result.origins[0], in: result)
        let row = try #require(WorkDetailRoute(.onlineBook(book, source: first)))
        #expect(route.record.key == row.record.key)
        #expect(route.record.key.instance == SourceInstanceKey(type: .bookSource, id: "https://a.test"))
        #expect(route.summary.title == "三體")
        #expect(route.summary.blurb == result.displayIntro)
        guard case .onlineBook(let frozen) = route.opening else {
            Issue.record("a search result is a book-source version")
            return
        }
        // The id the result's own page gives its book (SearchResultDetailIdentity).
        #expect(frozen.book.id == book.id)
    }

    @Test("an audiobook opens on its audio origin, as its page does")
    func audioOrigin() throws {
        let aggregate = source("https://aggregate.test")
        let store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync([aggregate])
        let textURL = try dataURL(["book_id": "b1", "sources": "番茄", "tab": "小说", "url": ""])
        let audioURL = try dataURL(["book_id": "b1", "sources": "番茄", "tab": "听书", "url": ""])
        let result = SearchBook(name: "測試書", author: "作者",
                                origins: [origin(aggregate, url: textURL), origin(aggregate, url: audioURL)])

        let route = try #require(WorkDetailRoute(searchResult: result, sources: store))
        #expect(route.record.contentKind == .audio)
        #expect(route.record.key.item == OnlineBookURLKey.normalize(audioURL))
    }

    @Test("no route when the origin's source is gone")
    func sourceGone() {
        let store = BookSourceStore(directory: directory)
        let result = SearchBook(name: "三體", author: "", origins: [origin(source("https://gone.test"), url: "/book/1")])
        #expect(WorkDetailRoute(searchResult: result, sources: store) == nil)
    }
}
