import Foundation
import Testing
@testable import yuedu_app

/// AI 推薦 8b: 產生推薦 reads the shelf, asks the service once, keeps the works, then looks
/// them up in Open Library when 資料來源 has it checked. A failed run keeps the last list.
@Suite("AI recommendation service")
@MainActor
struct AIRecommendationServiceTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIRecommendationServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let answer = #"{"works":[{"title":"球狀閃電","author":"劉慈欣","reason":"同一位作者。"},{"title":"三體","author":"劉慈欣","reason":"在書架上。"},{"title":"銀河帝國","author":"艾西莫夫","reason":"經典科幻。"}]}"#

    private func shelf(opened: Int, unopened: [String] = []) -> BookStore {
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books-\(UUID().uuidString).json"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var books = (0..<opened).map { index -> ReadingBook in
            var book = ReadingBook(title: index == 0 ? "三體" : "書\(index)", author: index == 0 ? "劉慈欣" : "作者\(index)",
                                   contentFilename: "")
            book.lastOpenedDate = base.addingTimeInterval(Double(index) * 60)
            return book
        }
        books += unopened.map { ReadingBook(title: $0, author: "作者", contentFilename: "") }
        store.replaceBooksFromSync(books.shuffled())
        return store
    }

    private func service(provider: ScriptedProvider, resolver: StubResolver? = nil, lookup: Bool = false,
                         store: AIRecommendationStore? = nil, covers: StubCoverProvider? = nil,
                         genres: [String: Double] = ["科幻": 1, "懸疑": 0.4]) -> AIRecommendationService {
        AIRecommendationService(store: store ?? AIRecommendationStore(directory: directory),
                                activeService: { .success(.init(provider: provider, name: "我的服務")) },
                                resolver: resolver ?? StubResolver(), lookupEnabled: { lookup },
                                coverProviders: { covers.map { [$0] as [any MetadataFillProvider] } ?? [] }, genres: { genres },
                                language: .traditionalChinese, origin: .testFixture,
                                now: { Date(timeIntervalSince1970: 1_900_000_000) })
    }

    private func sentPayload(_ provider: ScriptedProvider) throws -> [String: Any] {
        let request = try #require(provider.requests.first)
        let user = try #require(request.messages.last { $0.role == .user })
        return try #require(try JSONSerialization.jsonObject(with: Data(user.content.utf8)) as? [String: Any])
    }

    @Test("sends the 30 most recently opened books, newest first, and the genres; nothing else of a book")
    func inputs() async throws {
        let provider = ScriptedProvider(reply: Self.answer)
        let subject = service(provider: provider)
        subject.generate(shelf: shelf(opened: 33, unopened: ["沒打開過"]))
        await subject.wait()
        let sent = try sentPayload(provider)
        let books = try #require(sent["books"] as? [[String: Any]])
        #expect(books.count == 30)
        #expect(books.first?["title"] as? String == "書32")
        #expect(books.last?["title"] as? String == "書3")
        #expect(!books.contains { $0["title"] as? String == "沒打開過" })
        #expect(Set(books.flatMap(\.keys)).isSubset(of: ["title", "author", "category"]))
        let genres = try #require(sent["genres"] as? [[String: Any]])
        #expect(genres.map { $0["name"] as? String } == ["科幻", "懸疑"])
        #expect(provider.requests.count == 1)
    }

    @Test("keeps the works not on the shelf, with the service and model")
    func saves() async throws {
        let store = AIRecommendationStore(directory: directory)
        let subject = service(provider: ScriptedProvider(reply: Self.answer), store: store)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        let list = try #require(store.list)
        #expect(list.entries.map(\.work.title) == ["球狀閃電", "銀河帝國"])
        #expect(list.service == "我的服務")
        #expect(list.model == "scripted-model")
        #expect(list.generatedAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(subject.state == .idle)
        #expect(store.revision == 1)
    }

    @Test("with Open Library unchecked, nothing is looked up")
    func lookupSkipped() async {
        let resolver = StubResolver()
        let subject = service(provider: ScriptedProvider(reply: Self.answer), resolver: resolver, lookup: false)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        #expect(resolver.asked.isEmpty)
    }

    @Test("with Open Library checked, each work is looked up; a failed lookup leaves that work as it was")
    func lookups() async throws {
        let store = AIRecommendationStore(directory: directory)
        let resolver = StubResolver()
        resolver.failing = ["銀河帝國"]
        let subject = service(provider: ScriptedProvider(reply: Self.answer), resolver: resolver, lookup: true, store: store)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        #expect(resolver.asked == ["球狀閃電", "銀河帝國"])
        let list = try #require(store.list)
        #expect(list.entries[0].openLibrary?.key.item == "/works/球狀閃電")
        #expect(list.entries[0].blurb == "簡介：球狀閃電")
        #expect(list.entries[1].openLibrary == nil)
        #expect(list.entries[1].cover == nil)
        #expect(subject.state == .idle)
    }

    @Test("a failed request keeps the last list and says why", arguments: [true, false])
    func failureKeepsList(requestFails: Bool) async throws {
        let store = AIRecommendationStore(directory: directory)
        let old = AIRecommendationList(entries: [.init(work: .init(title: "舊", author: "舊作者", reason: ""))],
                                       generatedAt: Date(timeIntervalSince1970: 1), service: "舊服務", model: "m")
        store.save(old)
        let provider = ScriptedProvider(reply: requestFails ? "" : "不是 JSON", error: requestFails ? LLMError.unauthorized : nil)
        let subject = service(provider: provider, store: store)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        #expect(store.list == old)
        let expected = requestFails ? LLMError.unauthorized.errorDescription : LLMError.invalidSchema.errorDescription
        #expect(subject.state == .failed(try #require(expected)))
    }

    @Test("a shelf with no book opened asks nothing")
    func nothingRead() async {
        let provider = ScriptedProvider(reply: Self.answer)
        let subject = service(provider: provider)
        subject.generate(shelf: shelf(opened: 0, unopened: ["書"]))
        await subject.wait()
        #expect(provider.requests.isEmpty)
        #expect(subject.state == .failed(AIRecommendationService.Failure.nothingRead.errorDescription!))
    }

    @Test("an answer whose works are all on the shelf keeps the last list")
    func nothingNew() async {
        let store = AIRecommendationStore(directory: directory)
        let subject = service(provider: ScriptedProvider(reply: #"{"works":[{"title":"三體","author":"劉慈欣","reason":"r"}]}"#),
                              store: store)
        subject.generate(shelf: shelf(opened: 1))
        await subject.wait()
        #expect(store.list == nil)
        #expect(subject.state == .failed(AIRecommendationService.Failure.nothingNew.errorDescription!))
    }

    @Test("without a configured service, says what is missing and asks nothing")
    func unavailable() {
        let subject = AIRecommendationService(store: AIRecommendationStore(directory: directory),
                                              activeService: { .failure(.noAPIKey) }, resolver: StubResolver(),
                                              lookupEnabled: { false }, genres: { [:] })
        subject.generate(shelf: shelf(opened: 1))
        #expect(subject.state == .failed(AIProviderAssembly.Unavailable.noAPIKey.message))
    }

    @Test("the list survives a relaunch, matches included; a match for a replaced list is dropped")
    func storeRoundTrip() throws {
        let store = AIRecommendationStore(directory: directory)
        let generated = Date(timeIntervalSince1970: 1_900_000_000)
        let work = AIRecommendation.Work(title: "球狀閃電", author: "劉慈欣", reason: "同一位作者。")
        store.save(AIRecommendationList(entries: [.init(work: work)], generatedAt: generated, service: "s", model: "m"))
        let record = StubResolver.record(for: "球狀閃電")
        let entryID = try #require(store.list?.entries.first?.id)
        store.setMatch(record: record, cover: nil, blurb: "簡介", for: entryID, generatedAt: generated)
        store.setMatch(record: record, cover: nil, blurb: "別的", for: entryID, generatedAt: Date(timeIntervalSince1970: 5))
        let reopened = AIRecommendationStore(directory: directory)
        #expect(reopened.list == store.list)
        #expect(reopened.list?.entries.first?.blurb == "簡介")
        #expect(reopened.list?.entries.first?.openLibrary == record)
    }

    // MARK: - Covers (feedback #10)

    private static func shownCover(_ list: AIRecommendationList, _ index: Int) -> CoverReference? {
        guard case .item(_, let summary, _) = AIRecommendationProvider.entries(from: list)[index] else { return nil }
        return summary.cover
    }

    private static func filledPath(_ name: String) -> CoverReference {
        .copyFile(FilledMetadata.coverDirectory.appendingPathComponent(name).path)
    }

    @Test("a work Open Library matched without a cover takes the one the book sources give")
    func coverFilledAfterOpenLibrary() async throws {
        let store = AIRecommendationStore(directory: directory)
        let resolver = StubResolver()
        let covers = StubCoverProvider(covers: ["球狀閃電": "bs-ball.jpg"])
        let subject = service(provider: ScriptedProvider(reply: Self.answer), resolver: resolver, lookup: true,
                              store: store, covers: covers)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        let list = try #require(store.list)
        #expect(list.entries[0].openLibrary?.key.item == "/works/球狀閃電")
        #expect(list.entries[0].cover == nil)
        #expect(list.entries[0].coverFill == .file("bs-ball.jpg"))
        #expect(Self.shownCover(list, 0) == Self.filledPath("bs-ball.jpg"))
        #expect(list.entries[1].coverFill == .notFound)
        #expect(Self.shownCover(list, 1) == .generated(seed: "銀河帝國"))
        #expect(covers.asked == ["球狀閃電", "銀河帝國"])
        #expect(covers.queries.allSatisfy { $0.missing == [.cover] && $0.authors.count == 1 })
        #expect(subject.state == .idle)
    }

    @Test("with Open Library unchecked, the covers are still filled from the book sources")
    func coverFilledWithoutOpenLibrary() async throws {
        let store = AIRecommendationStore(directory: directory)
        let resolver = StubResolver()
        let covers = StubCoverProvider(covers: ["球狀閃電": "bs-ball.jpg", "銀河帝國": "bs-empire.jpg"])
        let subject = service(provider: ScriptedProvider(reply: Self.answer), resolver: resolver, lookup: false,
                              store: store, covers: covers)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        #expect(resolver.asked.isEmpty)
        let list = try #require(store.list)
        #expect(Self.shownCover(list, 0) == Self.filledPath("bs-ball.jpg"))
        #expect(Self.shownCover(list, 1) == Self.filledPath("bs-empire.jpg"))
    }

    @Test("a work Open Library gave a cover is not asked of the book sources")
    func openLibraryCoverKept() async throws {
        let store = AIRecommendationStore(directory: directory)
        let resolver = StubResolver()
        let remote = CoverReference.remote(URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg")!, headers: [:])
        resolver.covers = ["球狀閃電": remote]
        let covers = StubCoverProvider(covers: ["球狀閃電": "bs-ball.jpg"])
        let subject = service(provider: ScriptedProvider(reply: Self.answer), resolver: resolver, lookup: true,
                              store: store, covers: covers)
        subject.generate(shelf: shelf(opened: 2))
        await subject.wait()
        let list = try #require(store.list)
        #expect(covers.asked == ["銀河帝國"])
        #expect(Self.shownCover(list, 0) == remote)
        #expect(list.entries[0].coverFill == nil)
    }

    @Test("a list saved before covers were filled is filled once, and kept across a relaunch")
    func persistedListFilledOnce() async throws {
        let store = AIRecommendationStore(directory: directory)
        let old = AIRecommendationList(
            entries: [.init(work: .init(title: "球狀閃電", author: "劉慈欣", reason: ""), openLibrary: StubResolver.record(for: "球狀閃電")),
                      .init(work: .init(title: "銀河帝國", author: "艾西莫夫", reason: ""))],
            generatedAt: Date(timeIntervalSince1970: 1_850_000_000), service: "s", model: "m")
        store.save(old)
        let covers = StubCoverProvider(covers: ["球狀閃電": "bs-ball.jpg"])
        let subject = service(provider: ScriptedProvider(reply: Self.answer), store: store, covers: covers)
        await subject.fillMissingCovers()
        #expect(covers.asked == ["球狀閃電", "銀河帝國"])
        let reopened = AIRecommendationStore(directory: directory)
        let list = try #require(reopened.list)
        #expect(list.entries[0].coverFill == .file("bs-ball.jpg"))
        #expect(list.entries[1].coverFill == .notFound)
        #expect(Self.shownCover(list, 0) == Self.filledPath("bs-ball.jpg"))

        let relaunched = service(provider: ScriptedProvider(reply: Self.answer), store: reopened, covers: covers)
        await relaunched.fillMissingCovers()
        #expect(covers.asked == ["球狀閃電", "銀河帝國"])
    }

    @Test("a failed cover lookup is kept unanswered: asked again after a relaunch, not on every showing")
    func failedCoverLookupAskedAgain() async throws {
        let store = AIRecommendationStore(directory: directory)
        store.save(AIRecommendationList(entries: [.init(work: .init(title: "球狀閃電", author: "劉慈欣", reason: ""))],
                                        generatedAt: Date(timeIntervalSince1970: 1_850_000_000), service: "s", model: "m"))
        let covers = StubCoverProvider(covers: ["球狀閃電": "bs-ball.jpg"])
        covers.failing = ["球狀閃電"]
        let subject = service(provider: ScriptedProvider(reply: Self.answer), store: store, covers: covers)
        await subject.fillMissingCovers()
        await subject.fillMissingCovers()
        #expect(covers.asked == ["球狀閃電"])
        #expect(store.list?.entries[0].coverFill == nil)

        covers.failing = []
        let relaunched = service(provider: ScriptedProvider(reply: Self.answer), store: store, covers: covers)
        await relaunched.fillMissingCovers()
        #expect(covers.asked == ["球狀閃電", "球狀閃電"])
        #expect(store.list?.entries[0].coverFill == .file("bs-ball.jpg"))
    }

    @Test("a list saved before coverFill existed still decodes")
    func legacyListDecodes() throws {
        let json = #"{"entries":[{"work":{"title":"球狀閃電","author":"劉慈欣","reason":""}}],"generatedAt":0,"service":"s","model":"m"}"#
        let list = try JSONDecoder().decode(AIRecommendationList.self, from: Data(json.utf8))
        #expect(list.entries[0].coverFill == nil)
        #expect(Self.shownCover(list, 0) == .generated(seed: "球狀閃電"))
    }

    // MARK: - Doubles

    /// The reader's book sources as 資料來源 asks them: level B, a cover by title.
    @MainActor
    final class StubCoverProvider: MetadataFillProvider {
        let key = BookSourceFillProvider.allSourcesKey
        let grade: MetadataMatchGrade = .b
        let fillsCoverByTitle = true
        let covers: [String: String]
        var failing: Set<String> = []
        private(set) var asked: [String] = []
        private(set) var queries: [MetadataFillQuery] = []

        init(covers: [String: String]) {
            self.covers = covers
        }

        func canLookUp(_ query: MetadataFillQuery) -> Bool { true }

        func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
            asked.append(query.title)
            queries.append(query)
            if failing.contains(query.title) { throw BookSourceFillProvider.LookupError.noSourceAnswered(queried: 3) }
            return MetadataFillResult(values: covers[query.title].map { [.cover: .text($0)] } ?? [:])
        }
    }

    private final class ScriptedProvider: LLMProviding, @unchecked Sendable {
        let identifier = "scripted"
        let defaultModel = "scripted-model"
        private let reply: String
        private let error: Error?
        private(set) var requests: [LLMGenerationRequest] = []

        init(reply: String, error: Error? = nil) {
            self.reply = reply
            self.error = error
        }

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            requests.append(request)
            if let error { throw error }
            return LLMRawResponse(content: reply, provider: identifier, model: defaultModel, finishReason: "stop")
        }
    }

    @MainActor
    final class StubResolver: AIRecommendationResolving {
        var failing: Set<String> = []
        var covers: [String: CoverReference] = [:]
        private(set) var asked: [String] = []

        static func record(for title: String) -> SourceRecord {
            SourceRecord(key: SourceItemKey(instance: OpenLibrary.key, item: "/works/\(title)"), title: title, authors: ["劉慈欣"],
                         language: nil, contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.viewOnly])
        }

        func match(_ work: AIRecommendation.Work) async throws -> (record: SourceRecord, cover: CoverReference?, blurb: String?)? {
            asked.append(work.title)
            if failing.contains(work.title) { throw URLError(.timedOut) }
            return (Self.record(for: work.title), covers[work.title], "簡介：\(work.title)")
        }
    }
}
