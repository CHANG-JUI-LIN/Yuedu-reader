import Foundation
import Testing
@testable import yuedu_app

/// Unified library Phase 3b: the reader's book sources fill a local copy's description and
/// categories (level B: title and author).
@MainActor
@Suite("Book source fill provider", .serialized)
struct BookSourceFillProviderTests {
    private let sourceA = UUID()
    private let sourceB = UUID()
    private var urls: [UUID: String] { [sourceA: "https://a.example", sourceB: "https://b.example"] }

    @Test("only a copy that did not come from a book source, with a title and an author, is looked up")
    func whoIsLookedUp() {
        let provider = BookSourceFillProvider(search: { _, _ in .init(origins: [], answered: 1, queried: 1) }, hasSources: { true })
        #expect(provider.canLookUp(query()))
        #expect(!provider.canLookUp(query(copySource: SourceInstanceKey(type: .bookSource, id: "https://a.example"))))
        #expect(!provider.canLookUp(query(authors: ["  "])))
        #expect(!provider.canLookUp(query(missing: [.language, .publisher])))
        let sourceless = BookSourceFillProvider(search: { _, _ in .init(origins: [], answered: 0, queried: 0) }, hasSources: { false })
        #expect(!sourceless.canLookUp(query()), "no source to ask: not asked, and nothing recorded")
    }

    @Test("the first match with a description gives it and its categories, as that source")
    func firstDescription() async throws {
        let provider = BookSourceFillProvider(search: { [sourceA, sourceB] _, _ in
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
        let provider = BookSourceFillProvider(search: { [sourceA] _, _ in
            .init(origins: [origin(sourceA, "https://a.example", intro: " ", kind: "奇幻、冒險")], answered: 1, queried: 1)
        }, sourceURL: { [urls] in urls[$0] }, hasSources: { true })

        let result = try await provider.lookUp(query())

        #expect(result.values == [.tags: .texts(["奇幻", "冒險"])])
    }

    @Test("sources that answered without the book are an empty answer; none answering is a failure")
    func emptyVersusFailed() async throws {
        let empty = BookSourceFillProvider(search: { _, _ in .init(origins: [], answered: 3, queried: 3) }, hasSources: { true })
        #expect(try await empty.lookUp(query()).values.isEmpty)

        let failed = BookSourceFillProvider(search: { _, _ in .init(origins: [], answered: 0, queried: 3) }, hasSources: { true })
        await #expect(throws: BookSourceFillProvider.LookupError.self) { try await failed.lookUp(query()) }
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
        let provider = BookSourceFillProvider(search: { [sourceA] _, _ in
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

    // MARK: - Helpers

    private func query(copySource: SourceInstanceKey = .localLibrary, authors: [String] = ["劉慈欣"],
                       missing: Set<MetadataField> = [.intro, .tags, .cover]) -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: "三體", authors: authors, identifiers: [], copySource: copySource, missing: missing)
    }
}

private func origin(_ sourceID: UUID, _ sourceURL: String, intro: String, kind: String) -> BookOrigin {
    BookOrigin(sourceId: sourceID, sourceName: "來源", bookUrl: "\(sourceURL)/book", tocUrl: "",
               coverUrl: "", intro: intro, lastChapter: "", wordCount: "", kind: kind, runtimeVariables: nil)
}
