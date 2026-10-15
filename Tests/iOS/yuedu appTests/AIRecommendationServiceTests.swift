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
                         store: AIRecommendationStore? = nil, genres: [String: Double] = ["科幻": 1, "懸疑": 0.4]) -> AIRecommendationService {
        AIRecommendationService(store: store ?? AIRecommendationStore(directory: directory),
                                activeService: { .success(.init(provider: provider, name: "我的服務")) },
                                resolver: resolver ?? StubResolver(), lookupEnabled: { lookup }, genres: { genres },
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

    // MARK: - Doubles

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
        private(set) var asked: [String] = []

        static func record(for title: String) -> SourceRecord {
            SourceRecord(key: SourceItemKey(instance: OpenLibrary.key, item: "/works/\(title)"), title: title, authors: ["劉慈欣"],
                         language: nil, contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.viewOnly])
        }

        func match(_ work: AIRecommendation.Work) async throws -> (record: SourceRecord, cover: CoverReference?, blurb: String?)? {
            asked.append(work.title)
            if failing.contains(work.title) { throw URLError(.timedOut) }
            return (Self.record(for: work.title), nil, "簡介：\(work.title)")
        }
    }
}
