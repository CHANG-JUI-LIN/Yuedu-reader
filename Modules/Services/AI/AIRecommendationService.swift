import Combine
import Foundation

/// Looks a suggested work up in a bibliographic database. Open Library in the app; a stub in
/// tests.
@MainActor
protocol AIRecommendationResolving {
    func match(_ work: AIRecommendation.Work) async throws -> (record: SourceRecord, cover: CoverReference?, blurb: String?)?
}

/// Open Library's official module (OL3): its search for the title and author, the one result
/// that is the same work as the module fill matches it (title equal, authors compatible), then
/// that work's page for a description in the title's script. Two requests a work, at the
/// module's rate. Nil when the module is not installed or turned off, or nothing matches.
@MainActor
final class ModuleRecommendationResolver: AIRecommendationResolving {
    private let moduleID: String
    private let library: RuleModuleLibrary
    private let client: RuleModuleClient

    init(moduleID: String = OfficialRuleModules.openLibraryID, library: RuleModuleLibrary = .shared,
         client: RuleModuleClient = RuleModuleClient()) {
        self.moduleID = moduleID
        self.library = library
        self.client = client
    }

    func match(_ work: AIRecommendation.Work) async throws -> (record: SourceRecord, cover: CoverReference?, blurb: String?)? {
        await library.loadIfNeeded()
        guard let module = library.modules.first(where: { $0.module.id == moduleID })?.module,
              let search = module.search else { return nil }
        let provider = ModuleProvider(module: module, client: client)
        let query = MetadataFillQuery(copyID: UUID(), title: work.title, authors: [work.author], identifiers: [],
                                      copySource: provider.instance, missing: [.intro])
        guard let items = try await provider.searchItems("\(work.title) \(work.author)"),
              let found = ModuleFillProvider.match(in: items, of: search, query: query) else { return nil }
        let item = try await provider.detailed(found, of: search, wanting: [.intro])
        guard case .item(let record, let summary, _) = provider.searchEntry(item) else { return nil }
        let cover: CoverReference? = if case .generated = summary.cover { nil } else { summary.cover }
        let blurb: String? = if case .text(let intro) = ModuleFillProvider.values(of: item, entry: search, query: query)[.intro] {
            intro
        } else {
            nil
        }
        return (record, cover, blurb)
    }
}

/// AI 推薦's one use case, 產生推薦 (and 重新產生): read the shelf, ask the reader's AI service,
/// keep the works, then look each up in Open Library's module for a cover and description, and
/// fill the covers still missing from 資料來源's places (`fillMissingCovers`).
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
    private let lookupEnabled: @MainActor () async -> Bool
    /// 資料來源's checked places, made for each pass (a provider reads the sources once).
    private let coverProviders: @MainActor () async -> [any MetadataFillProvider]
    private let genres: () async -> [String: Double]
    private let language: AIAnswerLanguage
    private let origin: AIDiagnostics.Origin
    private let now: () -> Date
    private var task: Task<Void, Never>?
    /// A pass of `fillMissingCovers` is going on.
    private var fillingCovers = false
    /// Works whose cover lookup failed this launch (network, no source answered), by
    /// `coverKey`: asked again after a relaunch, not each time the home shows the row.
    private var failedCoverLookups: Set<String> = []

    init(store: AIRecommendationStore? = nil,
         activeService: @escaping @MainActor () -> Result<AIProviderAssembly.ActiveService, AIProviderAssembly.Unavailable> = AIProviderAssembly.activeService,
         resolver: (any AIRecommendationResolving)? = nil,
         lookupEnabled: @escaping @MainActor () async -> Bool = AIRecommendationService.openLibraryChecked,
         coverProviders: (@MainActor () async -> [any MetadataFillProvider])? = nil,
         genres: (() async -> [String: Double])? = nil,
         language: AIAnswerLanguage = .current,
         origin: AIDiagnostics.Origin = .observed,
         now: @escaping () -> Date = Date.init) {
        self.store = store ?? .shared
        self.activeService = activeService
        self.resolver = resolver ?? ModuleRecommendationResolver()
        self.lookupEnabled = lookupEnabled
        self.coverProviders = coverProviders ?? {
            // 資料來源 is the list under 自動補齊書籍資料: with the switch off, nothing is asked.
            guard GlobalSettings.shared.autoFillBookMetadata else { return [] }
            await RuleModuleLibrary.shared.loadIfNeeded()
            return MetadataFillCoordinator.liveProviders()
        }
        self.genres = genres ?? { await ReadingGenreRecorder.shared.profile().weights(at: Date()) }
        self.language = language
        self.origin = origin
        self.now = now
    }

    /// 資料來源 (6h) has Open Library's module checked, and it is installed and not turned off.
    static func openLibraryChecked() async -> Bool {
        let library = RuleModuleLibrary.shared
        await library.loadIfNeeded()
        let place = MetadataFillPlace.module(OfficialRuleModules.openLibraryID)
        return MetadataFillOrderStore.shared.order(modules: library.fillingModules.map(\.id)).entries
            .first { $0.place == place }?.isEnabled ?? false
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
        if !list.entries.isEmpty, await lookupEnabled() {
            await resolve(list)
        }
        // Whether Open Library was asked or not: it is unchecked, or knows no cover of the work
        // (feedback #10: a Chinese title it does not list).
        await fillCovers(of: list, reportsProgress: true)
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

    // MARK: Covers

    /// Feedback #10: a work Open Library gave no cover showed the generated one on its card,
    /// while 作品詳情 found it in the reader's book sources. Each work of the stored list
    /// without a cover is asked of 資料來源's places, as a shelf copy without artwork is
    /// (`MetadataFillRunner.wanted`): by title and author only the reader's book sources give
    /// a cover (`BookSourceFillProvider`). The answer is kept with the work
    /// (`Entry.coverFill`), so a list saved before is filled once and never asked again.
    ///
    /// A run fills its own list; the home's row calls this for a list saved before covers
    /// were filled. Nothing while a run is going on, or while a pass is.
    func fillMissingCovers() async {
        guard !state.isRunning, !fillingCovers, let list = store.list else { return }
        fillingCovers = true
        defer { fillingCovers = false }
        await fillCovers(of: list, reportsProgress: false)
    }

    private func fillCovers(of list: AIRecommendationList, reportsProgress: Bool) async {
        // The stored entries, not the run's: Open Library's covers were written to them since.
        guard let current = store.list, current.generatedAt == list.generatedAt else { return }
        let missing = current.entries.filter { needsCover($0, of: list) }.map(\.id)
        guard !missing.isEmpty else { return }
        let providers = await coverProviders()
        guard !providers.isEmpty else { return }
        let started = SourcePerfTrace.now
        var filled = 0
        var failed = 0
        if reportsProgress { state = .resolving(completed: 0, total: missing.count) }
        for (index, id) in missing.enumerated() {
            if Task.isCancelled { break }
            // A list replaced since (重新產生) is no longer this pass's.
            guard let current = store.list, current.generatedAt == list.generatedAt else { break }
            if let entry = current.entries.first(where: { $0.id == id }), needsCover(entry, of: list) {
                switch await cover(of: entry.work, from: providers) {
                case .answered(let fill):
                    if case .file(_) = fill { filled += 1 }
                    store.setCoverFill(fill, for: id, generatedAt: list.generatedAt)
                case .failed:
                    failed += 1
                    failedCoverLookups.insert(Self.coverKey(id, of: list))
                case .notAsked:
                    break
                }
            }
            if reportsProgress { state = .resolving(completed: index + 1, total: missing.count) }
        }
        SourcePerfTrace.record("ai.recommend.covers", "works=\(missing.count) filled=\(filled) failed=\(failed)",
                               since: started, thresholdMs: 0)
    }

    private func needsCover(_ entry: AIRecommendationList.Entry, of list: AIRecommendationList) -> Bool {
        entry.cover == nil && entry.coverFill == nil && !failedCoverLookups.contains(Self.coverKey(entry.id, of: list))
    }

    private static func coverKey(_ entryID: String, of list: AIRecommendationList) -> String {
        "\(list.generatedAt.timeIntervalSince1970)\u{1F}\(entryID)"
    }

    private enum CoverAnswer {
        /// Every place that could be asked answered.
        case answered(AIRecommendationList.CoverFill)
        /// A place failed (outside the app: network, no source answered) and none gave one.
        case failed
        /// No place could be asked (no enabled source yet): nothing is kept, so a source added
        /// later is asked.
        case notAsked
    }

    /// The places in 資料來源's order; the first cover found is the work's.
    private func cover(of work: AIRecommendation.Work, from providers: [any MetadataFillProvider]) async -> CoverAnswer {
        var asked = false
        var failed = false
        for provider in providers {
            if Task.isCancelled { return .notAsked }
            let wanted = MetadataFillRunner.wanted([.cover], of: provider)
            guard !wanted.isEmpty else { continue }
            let query = MetadataFillQuery(copyID: UUID(), title: work.title, authors: [work.author], identifiers: [],
                                          copySource: AIRecommendationProvider.recordInstance, missing: wanted)
            guard provider.canLookUp(query) else { continue }
            asked = true
            do {
                let result = try await provider.lookUp(query)
                // A search the row's leaving cut short is no answer: the work is asked again.
                if Task.isCancelled { return .notAsked }
                if let name = FilledMetadata.coverFileName(result.values[.cover]) { return .answered(.file(name)) }
            } catch {
                failed = true
                AppLogger.network("AI recommendation cover lookup failed", error: error,
                                  context: ["title": work.title, "author": work.author,
                                            "provider": "\(provider.key.type.rawValue):\(provider.key.id)"])
            }
        }
        if failed { return .failed }
        return asked ? .answered(.notFound) : .notAsked
    }
}
