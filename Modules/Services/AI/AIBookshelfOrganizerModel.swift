import Combine
import Foundation

/// Runs AI 整理書架 for the page: gathers what the shelf knows, asks the default service in
/// batches, and holds the proposal while the reader reviews it. Leaving the page cancels
/// the run; nothing is written to the shelf until `apply`.
@MainActor
final class AIBookshelfOrganizerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case review
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var proposal: AIBookshelfProposal?
    private var task: Task<Void, Never>?
    private let injectedProvider: (any LLMProviding)?
    private let origin: AIDiagnostics.Origin
    private let language: AIAnswerLanguage

    init(provider: (any LLMProviding)? = nil, origin: AIDiagnostics.Origin = .observed, language: AIAnswerLanguage = .current) {
        injectedProvider = provider
        self.origin = origin
        self.language = language
    }

    /// The service a run would use, for the page to show before it starts.
    func service() -> Result<AIProviderAssembly.ActiveService, AIProviderAssembly.Unavailable> {
        if let injectedProvider { return .success(.init(provider: injectedProvider, name: injectedProvider.identifier)) }
        return AIProviderAssembly.activeService()
    }

    func start(books: [AIBookshelfOrganizer.Book], existingGroups: [String]) {
        cancel()
        guard !books.isEmpty else { return }
        let provider: any LLMProviding
        switch service() {
        case let .success(active): provider = AITracedProvider(base: active.provider)
        case let .failure(reason):
            phase = .failed(reason.message)
            return
        }
        let batches = AIBookshelfOrganizer.batches(books)
        let language = language
        let origin = origin
        proposal = nil
        phase = .running(completed: 0, total: batches.count)
        task = Task { [weak self] in
            var groups = existingGroups
            var assignments: [UUID: String] = [:]
            do {
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    let request = try AIBookshelfOrganizer.request(books: batch, existingGroups: groups, language: language)
                    let trace = AIDiagnosticStore.shared.begin(feature: "bookshelfOrganizer", bookID: AIRequestTrace.library, origin: origin)
                    trace.event("bookshelfBatch", ["index": "\(index)", "books": "\(batch.count)", "existingGroups": "\(groups.count)",
                                                   "promptVersion": AIBookshelfOrganizer.promptVersion])
                    let raw: LLMRawResponse
                    do {
                        raw = try await AIDiagnostics.$current.withValue(trace) { try await provider.generate(request, model: nil) }
                        AIDiagnosticStore.shared.finish(trace)
                    } catch {
                        AIDiagnosticStore.shared.finish(trace)
                        throw error
                    }
                    try Task.checkCancellation()
                    for (book, group) in try AIBookshelfOrganizer.parse(raw, books: batch) {
                        // Later batches reuse the names earlier ones settled on.
                        let name = AIBookshelfOrganizer.canonical(group, existing: groups)
                        assignments[book] = name
                        if !groups.contains(name) { groups.append(name) }
                    }
                    self?.phase = .running(completed: index + 1, total: batches.count)
                }
                self?.proposal = AIBookshelfProposal(books: books, assignments: assignments, existingGroups: existingGroups)
                self?.phase = .review
            } catch is CancellationError {
                return
            } catch {
                AppLogger.error("AI bookshelf organizer failed", error: error, context: ["books": books.count, "assigned": assignments.count])
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .running = phase { phase = .idle }
    }

    /// Back to the start, dropping any proposal.
    func reset() {
        cancel()
        proposal = nil
        phase = .idle
    }

    func apply(to store: BookStore) {
        guard let proposal, proposal.canApply else { return }
        store.setGroups(proposal.assignments)
        reset()
    }

    func wait() async { await task?.value }

    /// Everything the shelf knows about its books without going to the network: an online
    /// book's category and blurb come from the detail page the source already returned, when
    /// that page is still cached.
    ///
    /// - Parameter records: the books to read, in their order; the whole shelf when nil. AI 推薦
    ///   reads its 30 most recently read books through here.
    static func shelfBooks(store: BookStore, records: [ReadingBook]? = nil) async -> [AIBookshelfOrganizer.Book] {
        let records = records ?? store.books
        let sources = Dictionary(BookSourceStore.shared.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        struct Request: Sendable {
            let book: AIBookshelfOrganizer.Book
            let infoURL: String?
            let source: BookSource?
        }
        let requests = records.map { record in
            Request(book: AIBookshelfOrganizer.Book(id: record.id, title: record.title, author: record.author, group: record.group,
                        chapterTitles: (store.chapters(for: record.id) ?? []).lazy.filter { !$0.isVolume }.prefix(AIBookshelfOrganizer.chapterTitles)
                            .map { ReaderHTMLUtilities.displayText(fromHTMLFragment: $0.title).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }),
                    infoURL: record.isOnline ? record.bookInfoURL : nil,
                    source: record.bookSourceId.flatMap { sources[$0] })
        }
        return await Task.detached(priority: .userInitiated) {
            requests.map { request in
                var book = request.book
                if let url = request.infoURL, !url.isEmpty, let source = request.source,
                   let info = BookSourceFetcher.shared.loadBookInfoPackageSync(url: url, source: source, maximumAge: nil) {
                    book.kind = info.kind
                    book.intro = ReaderHTMLUtilities.displayText(fromHTMLFragment: info.intro)
                }
                return book
            }
        }.value
    }
}
