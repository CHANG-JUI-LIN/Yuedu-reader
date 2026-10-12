import Foundation
import Testing
@testable import yuedu_app

/// 作品詳情 · Editorial Minimalism (2026-10-12): 作者其他作品 lists only works the version's
/// own data ties to its author — 青空文庫's credits, the author's Gutenberg feed, the work
/// index's author keys — never the same work again or a series-mate by someone else.
@Suite("Author works")
struct AuthorWorksTests {
    private static let dav = SourceInstanceKey(type: .webDAV, id: "dav")

    private static func copy(_ title: String, _ author: String, series: String? = nil) -> WorkIndexEntry {
        let id = UUID()
        let record = SourceRecord(key: .copy(id), title: title, authors: [author], language: nil, contentKind: .text,
                                  identifiers: [], copyID: id, acquisitions: [])
        return WorkIndexEntry(record: record, series: series)
    }

    private static func file(_ path: String, _ title: String, _ author: String) -> WorkIndexEntry {
        let record = SourceRecord(key: SourceItemKey(instance: dav, item: path), title: title, authors: [author], language: nil,
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.download(format: "epub")])
        return WorkIndexEntry(record: record, series: nil)
    }

    @Test("other works by the author, one card a work, a shelf copy before a file, by title")
    func shelfByAuthor() {
        let shown = Self.copy("三體", "劉慈欣", series: "地球往事")
        let sameWorkFile = Self.file("三體.epub", "三體", "劉慈欣")
        let seriesByOther = Self.copy("三體X", "寶樹", series: "地球往事")
        let ballFile = Self.file("球狀閃電.epub", "球狀閃電", "劉慈欣")
        let ballCopy = Self.copy("球狀閃電", "劉慈欣")
        let supernova = Self.copy("超新星紀元", "劉慈欣")
        let unrelated = Self.copy("紅樓夢", "曹雪芹")
        let entries = [shown, sameWorkFile, seriesByOther, ballFile, ballCopy, supernova, unrelated]
        let index = WorkIndex.build(entries: entries)

        let picked = RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")],
                                            excluding: [shown.nodeKey], shown: Set(entries.map(\.nodeKey)), limit: 20)
        #expect(picked.count == 2)
        #expect(Set(picked) == [ballCopy.nodeKey, supernova.nodeKey])
        #expect(!picked.contains(sameWorkFile.nodeKey))
        #expect(!picked.contains(seriesByOther.nodeKey))
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")], excluding: [shown.nodeKey],
                                       shown: Set(entries.map(\.nodeKey)), limit: 1).count == 1)
    }

    @Test("no author, no works; a node not shown is left out")
    func shelfWithoutAuthor() {
        let shown = Self.copy("三體", "劉慈欣")
        let offShelf = Self.copy("流浪地球", "劉慈欣")
        let index = WorkIndex.build(entries: [shown, offShelf])
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [], excluding: [shown.nodeKey],
                                       shown: [shown.nodeKey, offShelf.nodeKey], limit: 20).isEmpty)
        #expect(RelatedWorks.byAuthors(in: index, authorKeys: [WorkMatchKey.author("劉慈欣")], excluding: [shown.nodeKey],
                                       shown: [shown.nodeKey], limit: 20).isEmpty)
    }

    private static func aozoraWork(_ id: String, _ title: String, credits: [AozoraWork.Credit]) -> AozoraWork {
        AozoraWork(id: id, title: title, yomi: "", sortYomi: title, subtitle: "", kanaStyle: "", ndc: "",
                   published: "", updated: "", card: "", text: "", textUpdated: "", credits: credits,
                   source: "", sourcePublisher: "")
    }

    @Test("青空文庫: the other works of the work's 著者, not of its translator, without the work itself")
    func aozoraAuthor() {
        let soseki = AozoraPerson(id: "1", name: "夏目 漱石", yomi: "", sortYomi: "", born: "", died: "")
        let translator = AozoraPerson(id: "2", name: "訳者", yomi: "", sortYomi: "", born: "", died: "")
        let cat = Self.aozoraWork("10", "吾輩は猫である", credits: [.init(person: "2", role: "翻訳者"), .init(person: "1", role: "著者")])
        let kokoro = Self.aozoraWork("11", "こころ", credits: [.init(person: "1", role: "著者")])
        let other = Self.aozoraWork("12", "訳書", credits: [.init(person: "2", role: "翻訳者")])
        let index = AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [soseki, translator],
                                                              works: [cat, kokoro, other]))
        #expect(AuthorWorks.aozoraPerson(of: cat, in: index)?.id == "1")
        let titles = AuthorWorks.aozora(cat, index: index, limit: 12).compactMap { entry -> String? in
            guard case .item(_, let summary, _) = entry else { return nil }
            return summary.title
        }
        #expect(titles == ["こころ"])
        #expect(AuthorWorksRequest.aozora(cat, index).authorPage == .aozora(soseki, index))
    }

    @Test("Gutenberg: the author's feed without the book on the page")
    func gutenbergExcludesTheBook() {
        let shown = GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Austen, Jane")
        let other = GutenbergBook(id: 158, title: "Emma", author: "Austen, Jane")
        let entries = [shown, other].map(CollectionEntry.bundledGutenberg)
        let kept = AuthorWorks.excluding(shown, from: entries, limit: 12)
        #expect(kept == [CollectionEntry.bundledGutenberg(other)])
    }
}

@MainActor
@Suite("Author works loading", .serialized, .timeLimit(.minutes(1)))
struct AuthorWorksModelTests {
    private struct FeedFailed: Error {}
    private let author = GutenbergAuthor(name: "Austen, Jane", url: URL(string: "https://www.gutenberg.org/ebooks/author/68")!)
    private let shown = GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Austen, Jane")

    @Test("a failed feed says so, and 重試 reads it again")
    func failureRetries() async {
        var calls = 0
        var fails = true
        let other = CollectionEntry.bundledGutenberg(GutenbergBook(id: 158, title: "Emma", author: "Austen, Jane"))
        let model = AuthorWorksModel(loadGutenberg: { _ in
            calls += 1
            if fails { throw FeedFailed() }
            return [other]
        }, loadShelf: { _, _ in [] })
        let request = AuthorWorksRequest.gutenberg(author, excluding: shown)
        let store = BookStore()
        await model.load(request, store: store)
        if case .failed = model.state {} else { Issue.record("expected a failure, got \(model.state)") }
        fails = false
        await model.retry(request, store: store)
        #expect(model.state == .loaded([other]))
        #expect(calls == 2)
    }

    @Test("the same request is not read again; a feed with only this book shows nothing")
    func sameRequestOnce() async {
        var calls = 0
        let shown = shown
        let model = AuthorWorksModel(loadGutenberg: { _ in
            calls += 1
            return [CollectionEntry.bundledGutenberg(shown)]
        }, loadShelf: { _, _ in [] })
        let request = AuthorWorksRequest.gutenberg(author, excluding: shown)
        let store = BookStore()
        await model.load(request, store: store)
        await model.load(request, store: store)
        #expect(model.state == .hidden)
        #expect(calls == 1)
        await model.load(nil, store: store)
        #expect(model.state == .hidden)
    }
}
