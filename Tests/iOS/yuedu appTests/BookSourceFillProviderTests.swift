import Foundation
import Testing
@testable import yuedu_app

/// Unified library Phase 3b: the reader's book sources fill a local copy's description and
/// categories (level B: title and author). Maintainer, 2026-10-17: a copy with no cover takes
/// the match's, and a copy with no author is matched by title when every match names one
/// author.
@MainActor
@Suite("Book source fill provider", .serialized)
struct BookSourceFillProviderTests {
    private let sourceA = UUID()
    private let sourceB = UUID()
    private var urls: [UUID: String] { [sourceA: "https://a.example", sourceB: "https://b.example"] }

    @Test("only a copy that did not come from a book source, with a title, is looked up; with no author too")
    func whoIsLookedUp() {
        let provider = BookSourceFillProvider(search: { _, _, _ in .init(origins: [], answered: 1, queried: 1) }, hasSources: { true })
        #expect(provider.canLookUp(query()))
        #expect(!provider.canLookUp(query(copySource: SourceInstanceKey(type: .bookSource, id: "https://a.example"))))
        #expect(provider.canLookUp(query(authors: ["  "])))
        #expect(provider.canLookUp(query(authors: ["未知作者"])))
        #expect(!provider.canLookUp(query(title: " ")))
        #expect(!provider.canLookUp(query(missing: [.language, .publisher])))
        let sourceless = BookSourceFillProvider(search: { _, _, _ in .init(origins: [], answered: 0, queried: 0) }, hasSources: { false })
        #expect(!sourceless.canLookUp(query()), "no source to ask: not asked, and nothing recorded")
    }

    @Test("the first match with a description gives it and its categories, as that source")
    func firstDescription() async throws {
        let provider = BookSourceFillProvider(search: { [sourceA, sourceB] _, _, _ in
            .init(origins: [
                origin(sourceA, "https://a.example", intro: "", kind: "科幻"),
                origin(sourceB, "https://b.example", intro: "<p>地球文明與三體文明</p>", kind: "科幻,連載,88萬字"),
            ], answered: 2, queried: 2)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true })

        let result = try await provider.lookUp(query())

        #expect(result.values[.intro] == .text("地球文明與三體文明"))
        #expect(result.values[.tags] == .texts(["科幻", "連載"]))
        #expect(result.place == SourceInstanceKey(type: .bookSource, id: "https://b.example"))
        #expect(result.sourceItem?.item == "https://b.example/book")
    }

    @Test("with no description anywhere, the first match with categories gives those")
    func categoriesOnly() async throws {
        let provider = BookSourceFillProvider(search: { [sourceA] _, _, _ in
            .init(origins: [origin(sourceA, "https://a.example", intro: " ", kind: "奇幻、冒險")], answered: 1, queried: 1)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true })

        let result = try await provider.lookUp(query())

        #expect(result.values == [.tags: .texts(["奇幻", "冒險"])])
    }

    @Test("sources that answered without the book are an empty answer; none answering is a failure")
    func emptyVersusFailed() async throws {
        let empty = BookSourceFillProvider(search: { _, _, _ in .init(origins: [], answered: 3, queried: 3) }, hasSources: { true })
        #expect(try await empty.lookUp(query()).values.isEmpty)

        let failed = BookSourceFillProvider(search: { _, _, _ in .init(origins: [], answered: 0, queried: 3) }, hasSources: { true })
        await #expect(throws: BookSourceFillProvider.LookupError.self) { try await failed.lookUp(query()) }
    }

    @Test("with no author, the title's matches give values only when they all name one author")
    func unknownAuthor() async throws {
        let agreeing = BookSourceFillProvider(search: { [sourceA, sourceB] _, author, _ in
            #expect(author == "", "a placeholder is not searched for")
            return .init(origins: [
                origin(sourceA, "https://a.example", intro: "唐門外門弟子唐三", kind: "", author: "唐家三少"),
                origin(sourceB, "https://b.example", intro: "", kind: "玄幻", author: "唐家三少 著"),
            ], answered: 2, queried: 2)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true })
        let filled = try await agreeing.lookUp(query(authors: ["未知作者"]))
        #expect(filled.values[.intro] == .text("唐門外門弟子唐三"))

        let disagreeing = BookSourceFillProvider(search: { [sourceA, sourceB] _, _, _ in
            .init(origins: [
                origin(sourceA, "https://a.example", intro: "唐門外門弟子唐三", kind: "", author: "唐家三少"),
                origin(sourceB, "https://b.example", intro: "另一本同名書", kind: "", author: "某某"),
            ], answered: 2, queried: 2)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true })
        #expect(try await disagreeing.lookUp(query(authors: ["Unknown Author"])).values.isEmpty)
    }

    @Test("a search stops at the first match with everything wanted only when the author is known")
    func stopsEarly() async throws {
        let withIntro = [origin(sourceA, "https://a.example", intro: "簡介", kind: "", author: "劉慈欣", cover: "https://a.example/c.jpg")]
        var known: Bool?
        var unknown: Bool?
        _ = try await BookSourceFillProvider(search: { _, _, isEnough in
            known = isEnough(withIntro)
            return .init(origins: [], answered: 1, queried: 1)
        }, hasSources: { true }).lookUp(query())
        _ = try await BookSourceFillProvider(search: { _, _, isEnough in
            unknown = isEnough(withIntro)
            return .init(origins: [], answered: 1, queried: 1)
        }, hasSources: { true }).lookUp(query(authors: []))
        #expect(known == true)
        #expect(unknown == false, "every source's answer is needed to tell one author from two")

        var noCoverYet: Bool?
        _ = try await BookSourceFillProvider(search: { [sourceA] _, _, isEnough in
            noCoverYet = isEnough([origin(sourceA, "https://a.example", intro: "簡介", kind: "", author: "劉慈欣")])
            return .init(origins: [], answered: 1, queried: 1)
        }, hasSources: { true }).lookUp(query())
        #expect(noCoverYet == false, "a cover is still wanted")
    }

    @Test("a copy with no cover takes the match's, saved with its source; the match with both comes first")
    func cover() async throws {
        var saved: [(String, UUID)] = []
        let provider = BookSourceFillProvider(search: { [sourceA, sourceB] _, _, _ in
            .init(origins: [
                origin(sourceA, "https://a.example", intro: "簡介 A", kind: "", author: "劉慈欣"),
                origin(sourceB, "https://b.example", intro: "簡介 B", kind: "", author: "劉慈欣", cover: "https://b.example/c.jpg"),
            ], answered: 2, queried: 2)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true }, saveCover: { url, source in
            saved.append((url, source))
            return "bs-1.jpg"
        })

        let result = try await provider.lookUp(query())

        #expect(result.values[.cover] == .text("bs-1.jpg"))
        #expect(result.values[.intro] == .text("簡介 B"))
        #expect(saved.map(\.0) == ["https://b.example/c.jpg"])
        #expect(saved.map(\.1) == [sourceB])
        #expect(try await provider.lookUp(query(missing: [.intro])).values[.cover] == nil, "a copy with a cover is not given one")
    }

    @Test("categories drop word counts, dates and long phrases")
    func tagParsing() {
        #expect(BookSourceFillProvider.tags(from: "玄幻 / 東方玄幻|連載;2024-01-01,這是一段很長很長的不像分類的文字") == ["玄幻", "東方玄幻", "連載"])
        #expect(BookSourceFillProvider.tags(from: "") == [])
    }

    @Test("through the runner, a value keeps its source and is offered for removal")
    func throughTheRunner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FillProvider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt")
        store.saveReadingBook(book)
        let provider = BookSourceFillProvider(search: { [sourceA] _, _, _ in
            .init(origins: [origin(sourceA, "https://a.example", intro: "簡介", kind: "")], answered: 1, queried: 1)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true })
        let runner = MetadataFillRunner(providers: [provider], ledger: store.metadataFillLedger,
                                        write: { store.importedMetadata.write($0) })

        await runner.fill([MetadataFillCandidate(
            copyID: book.id, title: book.title, authors: [book.author], identifiers: [], copySource: .localLibrary,
            sidecarSourceItem: .copy(book.id), hasOwnCover: false, values: [], decisions: [])])
        store.importedMetadata.waitForPendingWritesForTesting()

        let filled = try #require(store.filledValue(.intro, of: book))
        #expect(filled.value == .text("簡介"))
        #expect(filled.provider == SourceInstanceKey(type: .bookSource, id: "https://a.example"))
    }

    @Test("through the runner, the book sources are asked for a missing cover, unlike another title match")
    func coverThroughTheRunner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FillProvider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = ReadingBook(title: "斗罗大陆", author: "未知作者", source: "local", contentFilename: "a.txt")
        store.saveReadingBook(book)
        var wanted: Set<MetadataField> = []
        let provider = BookSourceFillProvider(search: { [sourceA] _, _, _ in
            .init(origins: [origin(sourceA, "https://a.example", intro: "簡介", kind: "", author: "唐家三少",
                                   cover: "https://a.example/c.jpg")], answered: 1, queried: 1)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true }, saveCover: { _, _ in "bs-2.jpg" })
        let spy = WantedSpy { wanted = $0 }
        let runner = MetadataFillRunner(providers: [spy, provider], ledger: store.metadataFillLedger,
                                        write: { store.importedMetadata.write($0) })

        await runner.fill([MetadataFillCandidate(
            copyID: book.id, title: book.title, authors: [book.author], identifiers: [], copySource: .localLibrary,
            sidecarSourceItem: .copy(book.id), hasOwnCover: false, values: [], decisions: [])])
        store.importedMetadata.waitForPendingWritesForTesting()

        #expect(!wanted.contains(.cover), "another level-B place is not asked for a cover")
        #expect(store.filledValue(.cover, of: book)?.value == .text("bs-2.jpg"))
        #expect(store.filledValue(.intro, of: book)?.value == .text("簡介"))
    }

    // MARK: - Helpers

    private func query(copySource: SourceInstanceKey = .localLibrary, title: String = "三體", authors: [String] = ["劉慈欣"],
                       missing: Set<MetadataField> = [.intro, .tags, .cover]) -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: title, authors: authors, identifiers: [], copySource: copySource, missing: missing)
    }
}

/// A level-B place that records what it was asked for and finds nothing.
@MainActor
private final class WantedSpy: MetadataFillProvider {
    let key = SourceInstanceKey(type: .module, id: "spy")
    let grade: MetadataMatchGrade = .b
    let asked: (Set<MetadataField>) -> Void

    init(asked: @escaping (Set<MetadataField>) -> Void) { self.asked = asked }

    func canLookUp(_ query: MetadataFillQuery) -> Bool { true }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        asked(query.missing)
        return MetadataFillResult(values: [:])
    }
}

private func origin(_ sourceID: UUID, _ sourceURL: String, intro: String, kind: String, author: String = "劉慈欣",
                    cover: String = "") -> BookOrigin {
    BookOrigin(sourceId: sourceID, sourceName: "來源", bookUrl: "\(sourceURL)/book", tocUrl: "",
               coverUrl: cover, intro: intro, lastChapter: "", wordCount: "", kind: kind, runtimeVariables: nil, author: author)
}
