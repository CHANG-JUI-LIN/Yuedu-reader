import Foundation
import Testing
@testable import yuedu_app

/// Unified search 4b-3: Open Library in 搜索, on submit, data only, behind its own setting.
/// Requests go to `OpenLibraryStub` (shared with `OpenLibraryFillProviderTests`).
@MainActor
@Suite("Open Library search", .serialized)
struct OpenLibrarySearchTests {
    @Test("a work becomes a data-only item under Phase 3's key, with its cover and a few ISBNs")
    func dataOnlyItems() async throws {
        OpenLibraryStub.install(["/search.json": .json(Self.twoDocs)])
        var answers: [LibrarySearchAnswer] = []
        await makeSearch().search("三體") { answers.append($0) }

        let answer = try #require(answers.first)
        #expect(answers.count == 1)
        #expect(answer.outcome == .results)
        #expect(answer.entries.count == 1, "a doc without a work key is left out")
        let route = try #require(answer.entries.first.flatMap(WorkDetailRoute.init))
        #expect(route.record.key == SourceItemKey(instance: OpenLibrary.key, item: "/works/OL17267881W"))
        #expect(route.record.acquisitions == [.viewOnly])
        #expect(route.opening == .bibliographic)
        #expect(!route.isReadable && !route.readsItsCopies)
        #expect(route.record.language == "zh")
        #expect(route.summary.authors == ["劉慈欣"])
        let workID = try #require(ExternalIdentifier.normalized(.openLibraryWork, "OL17267881W"))
        #expect(route.record.identifiers.contains(workID))
        #expect(route.record.identifiers.filter { $0.scheme == .isbn13 }.count == OpenLibrarySearch.isbnLimit)
        guard case .remote(let cover, let headers) = route.summary.cover else {
            Issue.record("expected a remote cover, got \(String(describing: route.summary.cover))")
            return
        }
        #expect(cover.absoluteString == "https://covers.openlibrary.org/b/id/8245041-M.jpg")
        #expect(headers["User-Agent"] == RemoteLibraryHTTPClient.userAgent)

        let request = try #require(OpenLibraryStub.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "q" }?.value == "三體")
        #expect(items.first { $0.name == "limit" }?.value == "20")
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        #expect(!agent.isEmpty && !agent.contains("@"), "the app's User-Agent, never an email")
    }

    @Test("with the setting off, nothing is sent")
    func toggleOff() async {
        OpenLibraryStub.install(["/search.json": .json(Self.twoDocs)])
        let search = makeSearch(enabled: false)
        #expect(!search.isAvailable)
        var answers: [LibrarySearchAnswer] = []
        await search.search("三體") { answers.append($0) }
        #expect(answers.isEmpty)
        #expect(OpenLibraryStub.requests.isEmpty)
    }

    @Test("no work is empty, a server error fails with its reason")
    func emptyAndFailed() async {
        OpenLibraryStub.install(["/search.json": .json(#"{"numFound": 0, "docs": []}"#)])
        var answers: [LibrarySearchAnswer] = []
        await makeSearch().search("zzzz") { answers.append($0) }
        #expect(answers.map(\.outcome) == [.empty])

        OpenLibraryStub.install(["/search.json": .status(503)])
        answers = []
        await makeSearch().search("三體") { answers.append($0) }
        guard case .failed(let reason) = answers.first?.outcome else {
            Issue.record("a 503 should fail, got \(answers)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("its rows say 只有資料 and open 作品詳情 with nothing to read")
    func rows() async throws {
        OpenLibraryStub.install(["/search.json": .json(Self.twoDocs)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLibrarySearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let model = LibrarySearchModel.openLibrary(makeSearch())

        model.start("三體", store: store)
        await model.waitForTesting()

        let match = try #require(model.matches.first)
        #expect(match.rowContent.detail == localized("只有資料"))
        #expect(match.rowContent.title == "三體")
        #expect(match.route.opening == .bibliographic)
    }

    @Test("Search with no source: the others answer instead of an alert")
    func submitPlan() {
        // Search 9b: Gutenberg is one of the others now (`LibrarySearch`), not a plan of its own.
        #expect(SearchSubmitPlan.decide(hasSources: true, sourcesLoaded: true, othersAnswer: true) == .sources)
        #expect(SearchSubmitPlan.decide(hasSources: false, sourcesLoaded: true, othersAnswer: true) == .othersOnly)
        #expect(SearchSubmitPlan.decide(hasSources: false, sourcesLoaded: true, othersAnswer: false) == .sources,
                "nothing at all: the search says there is no source")
        #expect(SearchSubmitPlan.decide(hasSources: false, sourcesLoaded: false, othersAnswer: true) == .waitForSources)
    }

    @Test("MARC language codes read as the other sources' tags")
    func languages() {
        #expect(LanguageTag("chi")?.identifier == "zh")
        #expect(LanguageTag("jpn")?.identifier == "ja")
        #expect(LanguageTag("eng")?.identifier == "en")
    }

    // MARK: - Helpers

    @Test("AI 推薦's lookup: by title and author, matched only when both agree; the search setting is not read")
    func workByTitleAndAuthor() async throws {
        OpenLibraryStub.install(["/search.json": .json(#"""
        {"numFound": 2, "docs": [
          {"key": "/works/OL1W", "title": "三體 II", "author_name": ["劉慈欣"]},
          {"key": "/works/OL17267881W", "title": "三体", "author_name": ["刘慈欣"], "cover_i": 8245041}
        ]}
        """#)])
        let search = makeSearch(enabled: false)
        let found = try #require(try await search.work(title: "三體", author: "劉慈欣"))
        #expect(found.record.key.item == "/works/OL17267881W")
        guard case .remote(let cover, _) = found.cover else {
            Issue.record("expected a remote cover, got \(String(describing: found.cover))")
            return
        }
        #expect(cover.absoluteString == "https://covers.openlibrary.org/b/id/8245041-M.jpg")
        let items = URLComponents(url: try #require(OpenLibraryStub.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "title" }?.value == "三體")
        #expect(items.first { $0.name == "author" }?.value == "劉慈欣")
        #expect(items.first { $0.name == "q" } == nil)

        #expect(try await search.work(title: "三體", author: "別人") == nil, "a title alone never matches")
        OpenLibraryStub.install(["/search.json": .json(#"{"numFound": 1, "docs": [{"key": "/works/OL2W", "title": "球狀閃電", "author_name": ["劉慈欣"]}]}"#)])
        let uncovered = try #require(try await search.work(title: "球狀閃電", author: "劉慈欣"))
        #expect(uncovered.cover == nil, "no cover id is no cover, not a generated one")
    }

    private func makeSearch(enabled: Bool = true) -> OpenLibrarySearch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenLibraryStub.self]
        return OpenLibrarySearch(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                 pacer: RequestPacer(interval: 0), enabled: { enabled })
    }

    static let twoDocs = #"""
    {"numFound": 2, "docs": [
      {"key": "/works/OL17267881W", "title": "三體", "author_name": ["劉慈欣"], "cover_i": 8245041, "language": ["chi"],
       "isbn": ["9787536692930", "7536692935", "9787229030933", "9787229042066", "9787229100605", "9780765382030", "9781784971571"]},
      {"title": "No key"}
    ]}
    """#
}
