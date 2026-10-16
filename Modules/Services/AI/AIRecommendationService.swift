import Combine
import Foundation

/// Looks a suggested work up in a bibliographic database. Open Library in the app; a stub in
/// tests.
@MainActor
protocol AIRecommendationResolving {
    func match(_ work: AIRecommendation.Work) async throws -> (record: SourceRecord, cover: CoverReference?, blurb: String?)?
}

/// Open Library: the search by title and author (B), then the work's description when it is
/// written in the title's script. Two requests a work, paced at one a second by
/// `RequestPacer.openLibrary`.
@MainActor
final class OpenLibraryRecommendationResolver: AIRecommendationResolving {
    private let search = OpenLibrarySearch()
    private let fill = OpenLibraryFillProvider()

    func match(_ work: AIRecommendation.Work) async throws -> (record: SourceRecord, cover: CoverReference?, blurb: String?)? {
        guard let found = try await search.work(title: work.title, author: work.author) else { return nil }
        let blurb = try await fill.description(workKey: found.record.key.item, script: WritingScript(of: work.title))
        return (found.record, found.cover, blurb)
    }
}

/// AI 推薦's one use case, 產生推薦 (and 重新產生): read the shelf, ask the reader's AI service,
/// keep the works, then look each up in Open Library for a cover and description.
///
/// The works are saved as soon as the answer is read, so the home shows them while the
/// lookups (one a second) go on. A failed run keeps the previous list.
@MainActor
final class AIRecommendationService: ObservableObject {
    enum State: Equatable {
        case idle
        case generating
        /// Looking the saved works up in Open Library.
        case resolving(completed: Int, total: Int)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .generating, .resolving: true
            case .idle, .failed: false
            }
        }
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// No shelf book has been opened, so there is nothing to recommend from.
        case nothingRead
        /// Every suggestion was already on the shelf.
        case nothingNew

        var errorDescription: String? {
            switch self {
            case .nothingRead: localized("書架上還沒有讀過的書")
            case .nothingNew: localized("AI 推薦的作品都已在書架上")
            }
        }
    }

    static let shared = AIRecommendationService()

    @Published private(set) var state: State = .idle
    let store: AIRecommendationStore

    private let activeService: @MainActor () -> Result<AIProviderAssembly.ActiveService, AIProviderAssembly.Unavailable>
    private let resolver: any AIRecommendationResolving
    private let lookupEnabled: @MainActor () -> Bool
    private let genres: () async -> [String: Double]
    private let language: AIAnswerLanguage
    private let origin: AIDiagnostics.Origin
    private let now: () -> Date
    private var task: Task<Void, Never>?

    init(store: AIRecommendationStore? = nil,
         activeService: @escaping @MainActor () -> Result<AIProviderAssembly.ActiveService, AIProviderAssembly.Unavailable> = AIProviderAssembly.activeService,
         resolver: (any AIRecommendationResolving)? = nil,
         lookupEnabled: @escaping @MainActor () -> Bool = AIRecommendationService.openLibraryChecked,
         genres: (() async -> [String: Double])? = nil,
         language: AIAnswerLanguage = .current,
         origin: AIDiagnostics.Origin = .observed,
         now: @escaping () -> Date = Date.init) {
        self.store = store ?? .shared
        self.activeService = activeService
        self.resolver = resolver ?? OpenLibraryRecommendationResolver()
        self.lookupEnabled = lookupEnabled
        self.genres = genres ?? { await ReadingGenreRecorder.shared.profile().weights(at: Date()) }
        self.language = language
        self.origin = origin
        self.now = now
    }

    /// 資料來源 (6h) has Open Library checked.
    static func openLibraryChecked() -> Bool {
        MetadataFillOrderStore.shared.order(modules: []).entries.first { $0.place == .openLibrary }?.isEnabled ?? false
    }

    /// The service a run would use, for the section to say what is missing before it starts.
    func service() -> Result<AIProviderAssembly.ActiveService, AIProviderAssembly.Unavailable> {
        activeService()
    }

    /// The shelf books sent: those the reader has opened, most recently first, at most
    /// `AIRecommendation.maximumBooks`. A book never opened is not 「最近讀的」.
    static func recentlyRead(_ books: [ReadingBook]) -> [ReadingBook] {
        Array(books.compactMap { book in book.lastOpenedDate.map { (book, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(AIRecommendation.maximumBooks)
            .map(\.0))
    }

    /// 產生推薦. Does nothing while a run is going on.
    func generate(shelf: BookStore) {
        guard !state.isRunning else { return }
        let active: AIProviderAssembly.ActiveService
        switch activeService() {
        case let .success(service): active = service
        case let .failure(reason):
            state = .failed(reason.message)
            return
        }
        state = .generating
        task = Task { [weak self] in
            await self?.run(shelf: shelf, active: active)
        }
    }

    func wait() async { await task?.value }

    private func run(shelf: BookStore, active: AIProviderAssembly.ActiveService) async {
        let list: AIRecommendationList
        do {
            list = try await ask(shelf: shelf, active: active)
        } catch {
            AppLogger.error("AI recommendations failed", error: error, context: ["service": active.name])
            state = .failed(error.localizedDescription)
            return
        }
        store.save(list)
        guard lookupEnabled(), !list.entries.isEmpty else {
            state = .idle
            return
        }
        await resolve(list)
        state = .idle
    }

    private func ask(shelf: BookStore, active: AIProviderAssembly.ActiveService) async throws -> AIRecommendationList {
        let recent = Self.recentlyRead(shelf.books)
        guard !recent.isEmpty else { throw Failure.nothingRead }
        let books = await AIBookshelfOrganizerModel.shelfBooks(store: shelf, records: recent)
            .map { AIRecommendation.Book(title: $0.title, author: $0.author, category: $0.kind) }
        let input = AIRecommendation.Input(books: books, genres: await genres(), language: language)
        let request = try AIRecommendation.request(input)
        let started = SourcePerfTrace.now
        let trace = AIDiagnosticStore.shared.begin(feature: "aiRecommendations", bookID: AIRequestTrace.library, origin: origin)
        trace.event("aiRecommendations", ["books": "\(books.count)", "genres": "\(input.genres.count)",
                                          "promptVersion": AIRecommendation.promptVersion])
        let provider = AITracedProvider(base: active.provider)
        let raw: LLMRawResponse
        do {
            raw = try await AIDiagnostics.$current.withValue(trace) { try await provider.generate(request, model: nil) }
            AIDiagnosticStore.shared.finish(trace)
        } catch {
            AIDiagnosticStore.shared.finish(trace)
            SourcePerfTrace.record("ai.recommend", "outcome=failed books=\(books.count)", since: started, thresholdMs: 0)
            throw error
        }
        let shelfBooks = shelf.books.map { AIRecommendation.Book(title: $0.title, author: $0.author) }
        let works: [AIRecommendation.Work]
        do {
            works = try AIRecommendation.parse(raw, shelf: shelfBooks)
        } catch {
            SourcePerfTrace.record("ai.recommend", "outcome=invalid books=\(books.count)", since: started, thresholdMs: 0)
            throw error
        }
        SourcePerfTrace.record("ai.recommend", "outcome=ok books=\(books.count) works=\(works.count)", since: started, thresholdMs: 0)
        guard !works.isEmpty else { throw Failure.nothingNew }
        return AIRecommendationList(entries: works.map { .init(work: $0) }, generatedAt: now(),
                                    service: active.name, model: raw.model)
    }

    /// One work after another, each written as it is found. Open Library is outside the app:
    /// a lookup that fails leaves that work with its generated cover, and the rest go on.
    private func resolve(_ list: AIRecommendationList) async {
        let started = SourcePerfTrace.now
        var matched = 0
        var failed = 0
        state = .resolving(completed: 0, total: list.entries.count)
        for (index, entry) in list.entries.enumerated() {
            do {
                if let found = try await resolver.match(entry.work) {
                    matched += 1
                    store.setMatch(record: found.record, cover: found.cover, blurb: found.blurb,
                                   for: entry.id, generatedAt: list.generatedAt)
                }
            } catch {
                failed += 1
                AppLogger.network("AI recommendation lookup failed", error: error,
                                  context: ["title": entry.work.title, "author": entry.work.author])
            }
            state = .resolving(completed: index + 1, total: list.entries.count)
        }
        SourcePerfTrace.record("ai.recommend.resolve", "works=\(list.entries.count) matched=\(matched) failed=\(failed)",
                               since: started, thresholdMs: 0)
    }
}
